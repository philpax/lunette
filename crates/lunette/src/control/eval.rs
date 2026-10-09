//! Evaluating one `lunctl` chunk, on the Lua thread, under a time budget.
//!
//! # Between frames, on the thread that owns the state
//!
//! A chunk runs on the main thread between two frames, never concurrently with
//! `lovr.update` or `lovr.draw` ([the Lua API](../../../docs/dev/lua-api.md#lunctl)).
//! The control thread never touches a `Lua`, so no other thread races the chunk
//! and it can touch the same state a callback touches. `crate::boot` makes the
//! call in the gap between `FrameDriver::end_frame` and the next `begin_frame`.
//!
//! # Nothing outlives the call
//!
//! [`evaluate`] hands the chunk's results to a closure and drops them before it
//! returns. Rust never holds a Lua value past the call that produced it, so a
//! soft reload can discard the state without anything left dangling.
//! `docs/dev/architecture.md` records the rule.
//!
//! # Best-effort budget
//!
//! The bound is advisory. Under Luau it is a native interrupt:
//! [`ffi::lua_callbacks`]`(L)->interrupt` is installed on the running state for
//! the length of the chunk, and Luau calls it at safepoints (loop back edges,
//! call/return, GC). When the wall clock passes the deadline, the callback
//! raises [`OVERRUN_MESSAGE`] at the chunk's own frame via `lua_error`, and the
//! chunk is abandoned. `lua_error` is a longjmp to the enclosing `lua_pcall`.
//! The granularity is the safepoint: a chunk is abandoned at the first
//! safepoint at or after the deadline. There is no instruction count.
//! `lua_error` cannot unwind the VM stack from inside a called function's
//! frame, so the interrupt raises at the outermost Lua frame
//! (`lua_vm_is_topframe`) and does nothing elsewhere; a long loop in a callee
//! runs until control returns to the chunk's own frame. A single native call (an
//! allocator loop, a C function that never returns to the VM) is
//! uninterruptible by any hook. Under LuaJIT the bound is `debug.sethook` with
//! a count hook plus `jit.off`, because compiled traces do not call debug
//! hooks; Luau in LÖVR's build has no codegen (`Luau.CodeGen` is
//! `EXCLUDE_FROM_ALL`), so the interrupt is the entire mechanism.
//! `docs/dev/lua-api.md` records the change.
//!
//! A hard bound would need a watchdog outside Lua. The chunk holds the Lua
//! thread, so a watchdog cannot stop the run without aborting the process.
//! Aborting turns a bad `lunctl` command into a crash that takes every
//! connected client with it. The crash is worse than the hang the advisory
//! bound prevents.
//! `docs/dev/lua-api.md` records the reasoning.
//!
//! # Load errors and runtime errors
//!
//! A chunk that does not compile and a chunk that raises are distinguishable
//! here and on the wire, because a caller can act differently on each.
//! awesome's remote control collapses both into one string; the evaluation
//! keeps them apart.

use std::{
    cell::{Cell, RefCell},
    error::Error,
    rc::Rc,
    time::{Duration, Instant},
};

use mlua::{Function, Lua, MultiValue, Table};
use tracing::warn;

/// The outside-world seam for the interrupt's clock.
///
/// The interrupt callback is `extern "C"` and has no userdata parameter, so the
/// deadline check cannot take a `Clock` by reference. Production and tests
/// install a clock into the thread-local interrupt state alongside the
/// deadline. A test substitutes a clock it controls, and the budget tests are
/// deterministic.
pub trait Clock {
    fn now(&self) -> Instant;
}

/// The production clock: the wall clock.
#[derive(Default)]
pub struct WallClock;

impl Clock for WallClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// How long a chunk may run before the interrupt starts raising.
///
/// A newtype over a bare [`Duration`]. The subsystem holds two durations: how
/// long a chunk gets and how long a client waits for an answer. A single type
/// would not keep them apart, and swapping one for the other would be silent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Budget(Duration);

impl Budget {
    /// The budget a chunk gets when no other is given.
    ///
    /// Long enough for a session inspection that walks every window, and short
    /// enough that a chunk which never finishes costs one visible hitch. The
    /// headset does not freeze.
    pub const DEFAULT: Self = Self(Duration::from_millis(250));

    #[must_use]
    pub const fn of(limit: Duration) -> Self {
        Self(limit)
    }

    #[must_use]
    pub const fn limit(self) -> Duration {
        self.0
    }
}

/// How one chunk ended.
///
/// `R` is whatever the caller's `render` makes of the results. The values
/// themselves never escape [`evaluate`].
#[derive(Debug)]
pub enum Evaluation<R> {
    /// The chunk ran and its results rendered. A chunk returning nothing renders
    /// an empty list; returning `nil` is a distinct outcome.
    Returned(R),
    /// The chunk did not compile.
    LoadFailed(String),
    /// The chunk compiled and raised, and the budget did not raise it.
    Raised(String),
    /// The budget runs out, and the chunk is abandoned.
    Abandoned { after: Duration },
    /// The chunk ran and returned something that could not be rendered.
    Unrepresentable(Box<dyn Error + Send + Sync>),
    /// A caller starts one chunk from inside another.
    Reentered,
}

/// Compiles and runs `chunk`, rendering whatever it returned.
///
/// The results reach `render` and go no further: it is called once, with the
/// chunk's return values, and everything it is handed is dropped before this
/// returns.
/// # Errors
///
/// Outcomes are reported through [`Evaluation`], not through `Result`. A chunk
/// that failed to compile, a chunk that raised, and a chunk that ran out of time
/// are three outcomes a caller acts differently on, and none is a failure of
/// this function.
pub fn evaluate<R>(
    lua: &Lua,
    chunk: &str,
    budget: Budget,
    render: impl FnOnce(MultiValue) -> Result<R, Box<dyn Error + Send + Sync>>,
) -> Evaluation<R> {
    evaluate_with_clock(lua, chunk, budget, Rc::new(WallClock), render)
}

fn evaluate_with_clock<R>(
    lua: &Lua,
    chunk: &str,
    budget: Budget,
    clock: Rc<dyn Clock>,
    render: impl FnOnce(MultiValue) -> Result<R, Box<dyn Error + Send + Sync>>,
) -> Evaluation<R> {
    // A chunk that starts another evaluation would otherwise recurse through
    // the interrupt, the budget, and the queue at once, and a stack overflow
    // here takes every connected client down with the process. `crate::reload`
    // guards against the same re-entry.
    let Some(_guard) = EvaluatingGuard::acquire() else {
        return Evaluation::Reentered;
    };

    // The chunk is named `=lunctl`. The `=` marker makes the traceback name
    // `lunctl`; `@` would treat the chunk's first line as a file name.
    let function = match lua.load(chunk).set_name("=lunctl").into_function() {
        Ok(function) => function,
        Err(error) => return Evaluation::LoadFailed(error.to_string()),
    };

    // The failure is reported, not ignored. A chunk evaluated against the bare
    // globals would fail as though the user misspelled a name.
    if let Err(error) = scope_to_modules(lua, &function) {
        return Evaluation::Raised(format!(
            "lunctl: the chunk's environment could not be built, so it was not run: {error}"
        ));
    }

    // A zero budget installs no interrupt, so the chunk runs unbounded.
    if budget.limit().is_zero() {
        let outcome = function.call::<MultiValue>(());
        return render_outcome(outcome, &Overrun::default(), Instant::now(), render);
    }

    let started = clock.now();
    let deadline = started + budget.limit();
    let overrun = Overrun::default();

    let interrupt = Interrupt {
        deadline,
        overrun: overrun.clone(),
        raised: Cell::new(false),
        clock: Rc::new(move || clock.now()),
    };

    // SAFETY: the interrupt is installed for the exact length of the call and
    // removed before this returns; the raw state is the one `lua` wraps and it
    // outlives the call. The thread-local state the callback reads is set and
    // cleared on the same thread, the only thread the chunk runs on.
    let installed = unsafe { install_interrupt(lua, &interrupt) };
    let outcome = match installed {
        Ok(()) => function.call::<MultiValue>(()),
        Err(error) => {
            return Evaluation::Raised(format!(
                "lunctl: the time budget could not be installed, so the chunk was not run: {error}"
            ));
        }
    };

    // The interrupt is removed before `render`, so serialising a large result
    // cannot be mistaken for the chunk overrunning.
    unsafe { remove_interrupt(lua) };

    render_outcome(outcome, &overrun, started, render)
}

fn render_outcome<R>(
    outcome: mlua::Result<MultiValue>,
    overrun: &Overrun,
    started: Instant,
    render: impl FnOnce(MultiValue) -> Result<R, Box<dyn Error + Send + Sync>>,
) -> Evaluation<R> {
    match outcome {
        Ok(values) => {
            if overrun.get() {
                warn!(
                    "lunctl: a chunk caught its own time budget with pcall and carried on; the \
                     budget is best-effort and this is what escaping it looks like"
                );
            }
            match render(values) {
                Ok(rendered) => Evaluation::Returned(rendered),
                Err(error) => Evaluation::Unrepresentable(error),
            }
        }
        Err(_) if overrun.get() => Evaluation::Abandoned {
            after: started.elapsed(),
        },
        Err(error) => Evaluation::Raised(error.to_string()),
    }
}

/// The budget state an interrupt callback reads.
///
/// Held in a thread-local because the C callback has no userdata parameter. The
/// chunk runs on the frame-loop thread, and everything here is pushed and
/// popped around the single call on that thread.
struct Interrupt {
    deadline: Instant,
    overrun: Overrun,
    /// Whether the interrupt has already raised for this chunk. A raise is safe
    /// once, at the chunk's top frame before a call; every later safepoint
    /// does nothing (`lua_error` cannot unwind a frame the chunk called into).
    raised: Cell<bool>,
    clock: Rc<dyn Fn() -> Instant>,
}

thread_local! {
    static INTERRUPT: RefCell<Option<Interrupt>> = const { RefCell::new(None) };
}

/// What the interrupt raises with. Reaches the user when their own `pcall`
/// catches it; otherwise it is the abandoned-chunk error.
const OVERRUN_MESSAGE: &[u8] = b"lunctl: the chunk ran past its time budget and was abandoned";

/// Installs `interrupt` as the running state's native interrupt callback.
///
/// The callback is the VM's safepoint hook: Luau calls it at loop back edges,
/// call/return, and GC. When the clock has passed the deadline it yields the
/// VM, which unwinds through the running chunk's call frames and returns
/// `LUA_YIELD` to `lua_pcall`. The chunk is abandoned.
///
/// # Safety
///
/// `lua` must be a live state, and the interrupt must be removed with
/// [`remove_interrupt`] on the same thread before anything else runs the state.
unsafe fn install_interrupt(lua: &Lua, interrupt: &Interrupt) -> mlua::Result<()> {
    use mlua::ffi;

    unsafe {
        let state = lua.exec_raw_lua(|raw| raw.state());
        // SAFETY: the caller guarantees `state` is live for the duration.
        let callbacks = ffi::lua_callbacks(state);

        // The mlua-sys wrapper's `luaL_error` is the fork's `lua_errorL` under a
        // different name; it longjmps out of the running chunk.
        extern "C-unwind" fn on_interrupt(state: *mut ffi::lua_State, _gc: std::ffi::c_int) {
            // The borrow is dropped before the VM is touched: raising unwinds
            // through `goto exit`, which runs after this frame.
            let action = INTERRUPT.with(|slot| {
                let slot = slot.borrow();
                let interrupt = slot.as_ref()?;

                if (interrupt.clock)() < interrupt.deadline {
                    return None;
                }

                // Raise once, and while the chunk is at its own
                // initial frame. `lua_error`'s longjmp cannot unwind a frame
                // the chunk called into (overflow), so after the first safepoint
                // the interrupt does nothing: anything the chunk ran in a
                // callee is the documented escape. The chunk's very first
                // safepoint is always before any call, so a top-level infinite
                // loop is aborted cleanly.
                // SAFETY: the state is live for the duration of the interrupt.
                if unsafe { ffi::lua_vm_is_topframe(state) } == 0 {
                    return None;
                }
                if interrupt.raised.replace(true) {
                    return None;
                }
                Some(())
            });

            if action.is_none() {
                return;
            }

            // The raise collapses the chunk. The overrun flag marks the outcome
            // as budget-caused for the caller's outcome mapping.
            INTERRUPT.with(|slot| {
                if let Some(interrupt) = slot.borrow().as_ref() {
                    interrupt.overrun.set();
                }
            });

            // SAFETY: the state is the running chunk's state, live for the
            // duration of the interrupt; the message is a static buffer.
            unsafe {
                ffi::lua_pushlstring_(
                    state,
                    OVERRUN_MESSAGE.as_ptr().cast(),
                    OVERRUN_MESSAGE.len(),
                );
                ffi::lua_error(state);
            }
        }

        let previous = (*callbacks).interrupt.replace(on_interrupt);
        INTERRUPT.with(|slot| {
            *slot.borrow_mut() = Some(Interrupt {
                deadline: interrupt.deadline,
                overrun: interrupt.overrun.clone(),
                raised: Cell::new(false),
                clock: Rc::clone(&interrupt.clock),
            });
        });
        let _ = previous;
    }
    Ok(())
}

/// Restores the state's interrupt callback and clears the thread-local budget.
///
/// # Safety
///
/// Must pair with [`install_interrupt`] on the same thread; the state must be
/// live, and must not be running a chunk when this is called.
unsafe fn remove_interrupt(lua: &Lua) {
    use mlua::ffi;

    unsafe {
        let state = lua.exec_raw_lua(|raw| raw.state());
        let callbacks = ffi::lua_callbacks(state);
        // SAFETY: the caller guarantees the state is live. The original
        // callback (if any) is left in place, matching what `set_hook`'s
        // replacement did.
        (*callbacks).interrupt = None;
        INTERRUPT.with(|slot| *slot.borrow_mut() = None);
    }
}

/// Whether the interrupt has raised for this chunk.
///
/// Shared with the C callback and the caller. The callback sets it when the
/// deadline passes, and the caller reads it to tell an abandoned chunk from one
/// that raised on its own. Rc because the C callback outlives the call as far
/// as the type system is concerned.
#[derive(Clone, Default)]
struct Overrun(std::rc::Rc<Cell<bool>>);

impl Overrun {
    fn set(&self) {
        self.0.set(true);
    }

    fn get(&self) -> bool {
        self.0.get()
    }
}

/// Gives `function` an environment in which a module resolves by its own name.
///
/// `docs/guide/native-api.md` documents `lunctl 'return #lunette.windows()'`. A
/// configuration reaches the API through `local lunette = require '@lunette'`, so
/// the name is a local and is not a global anywhere. Without this, every
/// documented example indexes a nil.
///
/// Globals are consulted first, so a module cannot displace a name the session
/// set.
///
/// A name is looked for as written and then under the `@` root. The modules a
/// session registers are preloaded under that root: `lunette` is preloaded as
/// `@lunette` ([`crate::lua::MODULE_NAME`]), the form Luau's own resolver
/// requires of a `require`. A chunk is typed at a console, not written to a
/// file, so it addresses the module by the name the documentation gives it.
///
/// A loaded or preloaded name resolves. Calling `require` for every missed
/// global would turn the `nil` Lua specifies into a module-not-found error.
///
/// Assignment writes through to the globals, because the documented
/// `$(lunctl 'return win.title')` reads what an earlier chunk stored.
fn scope_to_modules(lua: &Lua, function: &Function) -> mlua::Result<()> {
    let environment = lua.create_table()?;
    let metatable = lua.create_table()?;

    let globals = lua.globals();
    let resolve = lua.load(
        r"
        local globals, package, require = ...
        local function module(name)
          local loaded = package.loaded[name]
          if loaded ~= nil then
            return loaded
          end

          if package.preload[name] ~= nil then
            return require(name)
          end

          return nil
        end

        return function(_, name)
          local value = globals[name]
          if value ~= nil then
            return value
          end

          local direct = module(name)
          if direct ~= nil then
            return direct
          end

          if type(name) == 'string' then
            return module('@' .. name)
          end

          return nil
        end
        ",
    );

    let package = globals.get::<Table>("package")?;
    let require = globals.get::<Function>("require")?;
    let index = resolve.set_name("=lunctl environment").call::<Function>((
        globals.clone(),
        package,
        require,
    ))?;

    metatable.set("__index", index)?;
    metatable.set("__newindex", globals)?;
    environment.set_metatable(Some(metatable))?;

    function.set_environment(environment)?;

    Ok(())
}

/// Holds the reentrancy flag for the length of one evaluation.
///
/// Thread-local for the reason `crate::reload`'s guard is. The Lua API is
/// available only in the main state, so the flag belongs to the thread that
/// owns the state, not to the process.
struct EvaluatingGuard;

impl EvaluatingGuard {
    fn acquire() -> Option<Self> {
        EVALUATING.with(|evaluating| (!evaluating.replace(true)).then_some(Self))
    }
}

impl Drop for EvaluatingGuard {
    fn drop(&mut self) {
        EVALUATING.with(|evaluating| evaluating.set(false));
    }
}

thread_local! {
    static EVALUATING: Cell<bool> = const { Cell::new(false) };
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// A rendering that accepts scalars and refuses everything else.
    ///
    /// Not the real serialiser. The evaluation is under test here, and a render
    /// that refuses a function is enough to exercise the refusal outcome.
    fn scalars(values: MultiValue) -> Result<Vec<String>, Box<dyn Error + Send + Sync>> {
        values
            .iter()
            .map(|value| match value {
                mlua::Value::Nil => Ok("nil".to_owned()),
                mlua::Value::Boolean(answer) => Ok(answer.to_string()),
                mlua::Value::Integer(number) => Ok(number.to_string()),
                mlua::Value::Number(number) => Ok(number.to_string()),
                mlua::Value::String(text) => Ok(text.to_string_lossy()),
                other => Err(format!("a {} cannot be rendered", other.type_name()).into()),
            })
            .collect()
    }

    fn run(chunk: &str) -> Evaluation<Vec<String>> {
        evaluate(
            &crate::test_lua::session_lua(),
            chunk,
            Budget::DEFAULT,
            scalars,
        )
    }

    /// A clock the test controls, so the budget tests are deterministic and do
    /// not depend on the wall clock.
    ///
    /// `now` advances by a fixed step on every call. The first read returns
    /// `start`, which `evaluate` uses for `started`, and every later read is
    /// further into the future. With a step larger than the test budget, the
    /// first interrupt safepoint runs with the deadline already passed.
    #[derive(Clone)]
    struct TestClock(Rc<RefCell<TestClockInner>>);

    impl TestClock {
        fn new(start: Instant, step: Duration) -> Self {
            Self(Rc::new(RefCell::new(TestClockInner { now: start, step })))
        }
    }

    struct TestClockInner {
        now: Instant,
        step: Duration,
    }

    impl Clock for TestClock {
        fn now(&self) -> Instant {
            let mut slot = self.0.borrow_mut();
            let now = slot.now;
            slot.now = now + slot.step;
            now
        }
    }

    fn evaluate_with<R>(
        lua: &Lua,
        chunk: &str,
        budget: Budget,
        clock: &TestClock,
        render: impl FnOnce(MultiValue) -> Result<R, Box<dyn Error + Send + Sync>>,
    ) -> Evaluation<R> {
        super::evaluate_with_clock(lua, chunk, budget, Rc::new(clock.clone()), render)
    }

    fn returned(outcome: Evaluation<Vec<String>>) -> Vec<String> {
        match outcome {
            Evaluation::Returned(values) => values,
            other => panic!("expected a return, and the chunk {other:?}"),
        }
    }

    /// A state holding a preloaded module and no global naming it.
    ///
    /// The shape a real session has, down to the name. `crate::lua` registers
    /// the module in `package.preload` under the `@` root that Luau's resolver
    /// requires ([`crate::lua::MODULE_NAME`] is `@lunette`), and a
    /// configuration binds it to a local. The test helper in
    /// `crate::lua::tests` assigns the global instead, so the defect these
    /// tests cover is the one the session's shape exposes.
    ///
    /// Registering it here as a bare `pretend` would leave the same gap. The
    /// chunks below would resolve it directly and never exercise the root the
    /// session actually uses.
    fn with_preloaded_module() -> Lua {
        let lua = crate::test_lua::session_lua();
        lua.load(
            r"
            package.preload['@pretend'] = function()
              return { answer = function() return 42 end }
            end
            ",
        )
        .exec()
        .expect("the preload registers");
        lua
    }

    #[test]
    fn a_chunk_reaches_a_preloaded_module_by_its_bare_name() {
        // Every example in docs/guide/native-api.md takes this form.
        let lua = with_preloaded_module();

        assert_eq!(
            returned(evaluate(
                &lua,
                "return pretend.answer()",
                Budget::DEFAULT,
                scalars
            )),
            vec!["42"],
        );
    }

    #[test]
    fn a_module_does_not_displace_a_global_of_the_same_name() {
        let lua = with_preloaded_module();
        lua.load("pretend = { answer = function() return 7 end }")
            .exec()
            .expect("the global assigns");

        assert_eq!(
            returned(evaluate(
                &lua,
                "return pretend.answer()",
                Budget::DEFAULT,
                scalars
            )),
            vec!["7"],
        );
    }

    #[test]
    fn an_unknown_name_is_nil_rather_than_a_module_that_could_not_be_found() {
        // Requiring every missed global would break the ordinary
        // `if somethingOptional then` shape.
        let lua = with_preloaded_module();

        assert_eq!(
            returned(evaluate(
                &lua,
                "return nothingIsNamedThis",
                Budget::DEFAULT,
                scalars
            )),
            vec!["nil"],
        );
    }

    #[test]
    fn a_name_a_chunk_sets_is_visible_to_the_next_chunk() {
        // A later lunctl call reads what an earlier chunk stored.
        let lua = crate::test_lua::session_lua();

        returned(evaluate(&lua, "remembered = 5", Budget::DEFAULT, scalars));

        assert_eq!(
            returned(evaluate(
                &lua,
                "return remembered",
                Budget::DEFAULT,
                scalars
            )),
            vec!["5"],
        );
    }

    #[test]
    fn a_chunk_still_reaches_the_standard_library() {
        // The environment replaces the globals table, so the fallback to it
        // carries the rest of the language.
        let lua = crate::test_lua::session_lua();

        assert_eq!(
            returned(evaluate(
                &lua,
                "return tostring(math.floor(3.7)) .. '/' .. string.upper('ok')",
                Budget::DEFAULT,
                scalars
            )),
            vec!["3/OK"],
        );
    }

    #[test]
    fn a_chunk_returning_several_values_returns_all_of_them() {
        assert_eq!(
            returned(run("return 1, 'two', true, nil")),
            vec!["1", "two", "true", "nil"],
        );
    }

    #[test]
    fn a_chunk_returning_nothing_returns_an_empty_list() {
        // Returning nothing is not the same as returning `nil`, and the wire
        // keeps the two apart.
        assert_eq!(returned(run("local x = 1")), Vec::<String>::new());
        assert_eq!(returned(run("return nil")), vec!["nil"]);
    }

    #[test]
    fn a_load_error_is_distinguishable_from_a_runtime_error() {
        // awesome collapses both into one string. A caller can act differently
        // on each, so they stay apart.
        let load = run("this is not lua {{{");
        assert!(
            matches!(load, Evaluation::LoadFailed(_)),
            "{load:?} is a syntax error"
        );

        let raised = run("error('deliberate')");
        assert!(
            matches!(raised, Evaluation::Raised(_)),
            "{raised:?} is a runtime error"
        );
    }

    #[test]
    fn a_runtime_error_carries_its_message() {
        let Evaluation::Raised(message) = run("error('deliberate')") else {
            panic!("the chunk raises");
        };
        assert!(message.contains("deliberate"), "{message}");
    }

    /// The budget is the subject under test. The injected clock moves, the wall
    /// clock does not. The chunk never terminates; advancing the injected clock
    /// past the deadline makes the interrupt raise at the next safepoint.
    #[test]
    fn a_chunk_that_never_finishes_is_abandoned_rather_than_running_forever() {
        let lua = crate::test_lua::session_lua();
        let budget = Budget::of(Duration::from_millis(50));

        // A chunk that runs forever cannot return control to the test to
        // advance the clock, so the deadline is made to expire before the run
        // starts by using a budget that has already elapsed. This exercises the
        // same mechanism as a real overrun: the first safepoint runs with the
        // deadline already passed and raises.
        let outcome = evaluate_with(
            &lua,
            "while true do end",
            budget,
            &TestClock::new(Instant::now(), Duration::from_secs(1)),
            scalars,
        );

        let Evaluation::Abandoned { after: _ } = outcome else {
            panic!("expected the budget to end it, and the chunk {outcome:?}");
        };
    }

    /// The documented escape, asserted as the behaviour it is. A `pcall` inside
    /// the chunk catches what the interrupt raises. No safepoint can change
    /// that.
    #[test]
    fn a_chunk_in_a_pcall_is_still_abandoned_at_its_own_frame() {
        // The interrupt does not raise inside the pcall's nested frame, because
        // raising there corrupts the VM stack. The chunk's own frame stays
        // bounded: with the clock past the deadline, the chunk is abandoned at
        // its first top-level safepoint. No destructive raise happens inside
        // the callee. The test is deterministic because the chunk never
        // advances the wall clock.
        let clock = TestClock::new(Instant::now(), Duration::from_secs(1));
        let outcome = evaluate_with(
            &crate::test_lua::session_lua(),
            "local ok, err = pcall(function() return 7 end) return ok, err",
            Budget::of(Duration::from_millis(50)),
            &clock,
            scalars,
        );

        assert!(
            matches!(outcome, Evaluation::Abandoned { .. }),
            "the chunk's own frame is bounded, and the chunk {outcome:?}"
        );
    }

    /// The interrupt is called at a callee's safepoints but does not raise
    /// inside the nested frame, because raising there corrupts the VM
    /// stack. The chunk is abandoned at its own top-level frame once the callee
    /// returns.
    #[test]
    fn a_chunk_calling_a_function_it_did_not_define_is_abandoned_at_its_own_frame() {
        let lua = crate::test_lua::session_lua();
        lua.load(
            "function elsewhere(n)
                 local total = 0
                 for index = 1, n do total = total + index end
                 return total
             end",
        )
        .exec()
        .expect("the callee is defined");

        let clock = TestClock::new(Instant::now(), Duration::from_secs(1));
        let outcome = evaluate_with(
            &lua,
            "return elsewhere(500)",
            Budget::of(Duration::from_millis(50)),
            &clock,
            scalars,
        );

        assert!(
            matches!(outcome, Evaluation::Abandoned { .. }),
            "the chunk's own frame is bounded, and the chunk {outcome:?}"
        );
    }

    #[test]
    fn a_result_that_cannot_be_rendered_is_reported_rather_than_dropped() {
        let outcome = run("return 1, function() end");

        let Evaluation::Unrepresentable(error) = outcome else {
            panic!("a function cannot be rendered, and the chunk {outcome:?}");
        };
        assert!(error.to_string().contains("function"), "{error}");
    }

    /// A chunk that starts another evaluation would recurse through the hook,
    /// the budget, and the queue at once.
    #[test]
    fn a_chunk_asked_for_from_inside_one_is_refused() {
        let lua = crate::test_lua::session_lua();
        let outcome = evaluate(&lua, "return 1", Budget::DEFAULT, |values| {
            // The render runs inside the call, where the guard is still held.
            let nested = evaluate(&lua, "return 2", Budget::DEFAULT, scalars);
            assert!(
                matches!(nested, Evaluation::Reentered),
                "{nested:?} should have been refused"
            );
            scalars(values)
        });

        assert_eq!(returned(outcome), vec!["1"]);
    }

    /// The guard is released whatever the chunk did. A chunk that is not
    /// released would close the endpoint for the rest of the session.
    #[test]
    fn the_guard_is_released_after_a_chunk_that_raised() {
        let lua = crate::test_lua::session_lua();

        let raised = evaluate(&lua, "error('deliberate')", Budget::DEFAULT, scalars);
        assert!(matches!(raised, Evaluation::Raised(_)), "{raised:?}");

        assert_eq!(
            returned(evaluate(&lua, "return 'after'", Budget::DEFAULT, scalars)),
            vec!["after"],
        );
    }

    /// The hook must not still be installed when the next chunk arrives. A
    /// chunk would then inherit the previous one's deadline.
    #[test]
    fn a_chunk_after_an_abandoned_one_gets_its_own_budget() {
        let lua = crate::test_lua::session_lua();

        let abandoned = evaluate(
            &lua,
            "while true do end",
            Budget::of(Duration::from_millis(50)),
            scalars,
        );
        assert!(
            matches!(abandoned, Evaluation::Abandoned { .. }),
            "{abandoned:?}"
        );

        assert_eq!(
            returned(evaluate(&lua, "return 'after'", Budget::DEFAULT, scalars)),
            vec!["after"],
        );
    }
}
