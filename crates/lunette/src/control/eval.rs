//! Evaluating one `lunctl` chunk, on the Lua thread, under a time budget.
//!
//! # Between frames, on the thread that owns the state
//!
//! A chunk runs on the main thread between two frames, never concurrently with
//! `lovr.update` or `lovr.draw` ([the Lua API](../../../docs/development/native/lua-api.md#lunctl)).
//! The control thread never touches a `Lua`, so no other thread races the chunk
//! and it can touch the same state a callback touches. `crate::boot` makes the
//! call in the gap between `FrameDriver::end_frame` and the next `begin_frame`.
//!
//! # Nothing outlives the call
//!
//! [`answer`] serialises the chunk's results into a [`Reply`] and drops them
//! before it returns. Rust never holds a Lua value past the call that produced
//! it, so a soft reload can discard the state without anything left dangling.
//! `docs/development/architecture.md` records the rule.
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
//! uninterruptible by any hook. Both interpreted and native Luau execution
//! use these safepoints; enabling CodeGen does not make the budget a hard bound.
//!
//! A hard bound would need a watchdog outside Lua. The chunk holds the Lua
//! thread, so a watchdog cannot stop the run without aborting the process.
//! Aborting turns a bad `lunctl` command into a crash that takes every
//! connected client with it. The crash is worse than the hang the advisory
//! bound prevents.
//! `docs/development/native/lua-api.md` records the reasoning.
//!
//! # Load errors and runtime errors
//!
//! A chunk that does not compile and a chunk that raises are distinguishable
//! here and on the wire, because a caller can act differently on each.
//! awesome's remote control collapses both into one string; the evaluation
//! keeps them apart.

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    time::{Duration, Instant},
};

use mlua::{Function, Lua, MultiValue, Table};
use tracing::warn;

use crate::control::{serialise, wire::Reply};

/// Evaluates one chunk against the Lua state and answers with what it did.
///
/// Called from the frame loop, between two frames, on the thread that owns the
/// state, under [`Budget::DEFAULT`]. The chunk's results are serialised and
/// dropped before this returns.
///
/// A chunk that failed to compile, a chunk that raised, and a chunk that ran
/// out of time are outcomes a caller acts differently on, and each is its own
/// [`Reply`]. None is a failure of this function.
#[must_use]
pub fn answer(lua: &Lua, chunk: &str) -> Reply {
    evaluate_with_clock(lua, chunk, Budget::DEFAULT, Rc::new(WallClock))
}

/// The outside-world seam for the interrupt's clock.
///
/// The interrupt callback is `extern "C"` and has no userdata parameter, so the
/// deadline check cannot take a `Clock` by reference. The clock is installed
/// into the thread-local interrupt state alongside the deadline. A test
/// substitutes a clock it controls, and the budget tests are deterministic.
trait Clock {
    fn now(&self) -> Instant;
}

/// The production clock: the wall clock.
struct WallClock;

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
#[derive(Clone, Copy, Debug)]
struct Budget(Duration);

impl Budget {
    /// The budget every chunk gets.
    ///
    /// Long enough for a session inspection that walks every window, and short
    /// enough that a chunk which never finishes costs one visible hitch. The
    /// headset does not freeze.
    const DEFAULT: Self = Self(Duration::from_millis(250));
}

fn evaluate_with_clock(lua: &Lua, chunk: &str, budget: Budget, clock: Rc<dyn Clock>) -> Reply {
    // The chunk is named `=lunctl`. The `=` marker makes the traceback name
    // `lunctl`; `@` would treat the chunk's first line as a file name.
    let function = match lua.load(chunk).set_name("=lunctl").into_function() {
        Ok(function) => function,
        Err(error) => return Reply::LoadError(error.to_string()),
    };

    // The failure is reported, not ignored. A chunk evaluated against the bare
    // globals would fail as though the user misspelled a name.
    if let Err(error) = scope_to_modules(lua, &function) {
        return Reply::RuntimeError(format!(
            "lunctl: the chunk's environment could not be built, so it was not run: {error}"
        ));
    }

    if let Err(error) = crate::execution::compile(lua, &function) {
        return Reply::LoadError(error.to_string());
    }

    let started = clock.now();
    let overrun = Overrun::default();
    let interrupt = Interrupt {
        deadline: started + budget.0,
        overrun: overrun.clone(),
        raised: Cell::new(false),
        clock,
    };

    // SAFETY: the interrupt is installed for the exact length of the call and
    // removed before this returns; the raw state is the one `lua` wraps and it
    // outlives the call. The thread-local state the callback reads is set and
    // cleared on the same thread, the only thread the chunk runs on.
    unsafe { install_interrupt(lua, interrupt) };
    let outcome = function.call::<MultiValue>(());
    // The interrupt is removed before serialising, so serialising a large
    // result cannot be mistaken for the chunk overrunning.
    unsafe { remove_interrupt(lua) };

    match outcome {
        Ok(values) => {
            if overrun.get() {
                warn!(
                    "lunctl: a chunk caught its own time budget with pcall and carried on; the \
                     budget is best-effort and this is what escaping it looks like"
                );
            }
            match serialise::results(values) {
                Ok(values) => Reply::Returned(values),
                Err(error) => Reply::Unrepresentable(error.to_string()),
            }
        }
        Err(_) if overrun.get() => Reply::Abandoned {
            after: started.elapsed(),
        },
        Err(error) => Reply::RuntimeError(error.to_string()),
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
    clock: Rc<dyn Clock>,
}

thread_local! {
    static INTERRUPT: RefCell<Option<Interrupt>> = const { RefCell::new(None) };
    #[cfg(test)]
    static OVERRUN_WAS_NATIVE: Cell<bool> = const { Cell::new(false) };
}

/// What the interrupt raises with. Reaches the user when their own `pcall`
/// catches it; otherwise it is the abandoned-chunk error.
const OVERRUN_MESSAGE: &[u8] = b"lunctl: the chunk ran past its time budget and was abandoned";

/// Installs `interrupt` as the running state's native interrupt callback.
///
/// The callback is the VM's safepoint hook: Luau calls it at loop back edges,
/// call/return, and GC. When the clock has passed the deadline and the chunk
/// is at its own frame, it raises [`OVERRUN_MESSAGE`] with `lua_error`, which
/// longjmps to the enclosing `lua_pcall`. The chunk is abandoned.
///
/// # Safety
///
/// `lua` must be a live state, and the interrupt must be removed with
/// [`remove_interrupt`] on the same thread before anything else runs the state.
unsafe fn install_interrupt(lua: &Lua, interrupt: Interrupt) {
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

                if interrupt.clock.now() < interrupt.deadline {
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

            #[cfg(test)]
            OVERRUN_WAS_NATIVE.with(|native| {
                // SAFETY: the interrupt runs in the frame whose execution mode is queried.
                native.set(unsafe { ffi::lua_incustomexecution(state, 0) } != 0);
            });

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

        (*callbacks).interrupt = Some(on_interrupt);
        INTERRUPT.with(|slot| *slot.borrow_mut() = Some(interrupt));
    }
}

/// Clears the state's interrupt callback and the thread-local budget.
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
        // SAFETY: the caller guarantees the state is live. Nothing else in the
        // session installs an interrupt, so clearing it restores the state.
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
struct Overrun(Rc<Cell<bool>>);

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
/// `docs/plugins/native-api.md` documents `lunctl 'return #lunette.windows()'`. A
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

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use mlua::ffi;
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::control::wire::Value;

    /// A budget the tests choose, short enough that an overrun on the wall
    /// clock costs little.
    const SHORT: Budget = Budget(Duration::from_millis(50));

    fn run(chunk: &str) -> Reply {
        answer(&crate::test_lua::session_lua(), chunk)
    }

    /// A clock the test controls, so the budget tests are deterministic and do
    /// not depend on the wall clock.
    ///
    /// `now` advances by a fixed step on every call. The first read returns
    /// `start`, which the evaluation uses for `started`, and every later read
    /// is further into the future. With a step larger than the test budget, the
    /// first interrupt safepoint runs with the deadline already passed.
    struct TestClock(RefCell<Instant>);

    impl Clock for TestClock {
        fn now(&self) -> Instant {
            let mut slot = self.0.borrow_mut();
            let now = *slot;
            *slot = now + Duration::from_secs(1);
            now
        }
    }

    fn with_test_clock(lua: &Lua, chunk: &str) -> Reply {
        evaluate_with_clock(
            lua,
            chunk,
            SHORT,
            Rc::new(TestClock(RefCell::new(Instant::now()))),
        )
    }

    fn returned(reply: Reply) -> Vec<Value> {
        match reply {
            Reply::Returned(values) => values,
            other => panic!("expected a return, and the chunk answered {other:?}"),
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
        // Every example in docs/plugins/native-api.md takes this form.
        let lua = with_preloaded_module();

        assert_eq!(
            returned(answer(&lua, "return pretend.answer()")),
            vec![Value::Integer(42)],
        );
    }

    #[test]
    fn a_module_does_not_displace_a_global_of_the_same_name() {
        let lua = with_preloaded_module();
        lua.load("pretend = { answer = function() return 7 end }")
            .exec()
            .expect("the global assigns");

        assert_eq!(
            returned(answer(&lua, "return pretend.answer()")),
            vec![Value::Integer(7)],
        );
    }

    #[test]
    fn an_unknown_name_is_nil_rather_than_a_module_that_could_not_be_found() {
        // Requiring every missed global would break the ordinary
        // `if somethingOptional then` shape.
        let lua = with_preloaded_module();

        assert_eq!(
            returned(answer(&lua, "return nothingIsNamedThis")),
            vec![Value::Nil],
        );
    }

    #[test]
    fn a_name_a_chunk_sets_is_visible_to_the_next_chunk() {
        // A later lunctl call reads what an earlier chunk stored.
        let lua = crate::test_lua::session_lua();

        returned(answer(&lua, "remembered = 5"));

        assert_eq!(
            returned(answer(&lua, "return remembered")),
            vec![Value::Integer(5)],
        );
    }

    #[test]
    fn a_chunk_returns_every_value_it_returned_and_nothing_when_it_returned_nothing() {
        assert_eq!(
            returned(run("return 1, 'two', true, nil")),
            vec![
                Value::Integer(1),
                Value::String(b"two".to_vec()),
                Value::Boolean(true),
                Value::Nil,
            ],
        );
        // Returning nothing is not the same as returning `nil`, and the wire
        // keeps the two apart.
        assert_eq!(returned(run("local x = 1")), Vec::new());
        assert_eq!(returned(run("return nil")), vec![Value::Nil]);
    }

    #[test]
    fn a_load_error_is_distinguishable_from_a_runtime_error() {
        // awesome collapses both into one string. A caller can act differently
        // on each, so they stay apart.
        let load = run("this is not lua {{{");
        assert!(
            matches!(load, Reply::LoadError(_)),
            "{load:?} is a syntax error"
        );

        let Reply::RuntimeError(message) = run("error('deliberate')") else {
            panic!("the chunk raises");
        };
        assert!(message.contains("deliberate"), "{message}");
    }

    /// The budget is the subject under test. The injected clock moves, the wall
    /// clock does not. A chunk that runs forever cannot return control to the
    /// test to advance the clock, so the clock reads past the deadline from its
    /// second read on. The first safepoint runs with the deadline already
    /// passed and raises, the same mechanism as a real overrun.
    #[test]
    fn a_chunk_that_never_finishes_is_abandoned_rather_than_running_forever() {
        for mode in [
            crate::execution::ExecutionMode::Interpreter,
            crate::execution::ExecutionMode::Optimized,
        ] {
            let lua = crate::test_lua::session_lua();
            crate::execution::configure(&lua, mode).expect("the execution mode is supported");
            let outcome = with_test_clock(&lua, "while true do end");

            assert!(
                matches!(outcome, Reply::Abandoned { .. }),
                "expected the {mode:?} budget to end it, and the chunk answered {outcome:?}"
            );
            assert_eq!(
                returned(answer(&lua, "return 42")),
                vec![Value::Integer(42)]
            );
        }
    }

    #[test]
    fn native_execution_is_bounded_or_rejected_when_unavailable() {
        let lua = crate::test_lua::session_lua();
        let configured = crate::execution::configure(&lua, crate::execution::ExecutionMode::Native);
        if !crate::execution::supported() {
            assert!(
                configured.is_err(),
                "unsupported native execution is rejected"
            );
            assert_eq!(
                returned(answer(&lua, "return 42")),
                vec![Value::Integer(42)]
            );
            return;
        }
        configured.expect("native execution is supported");
        unsafe extern "C-unwind" fn native_probe(state: *mut ffi::lua_State) -> i32 {
            // SAFETY: Lua invokes this callback with a live state and a Lua caller at level 1.
            unsafe {
                let native = ffi::lua_incustomexecution(state, 1);
                ffi::lua_pushboolean(state, native);
            }
            1
        }
        // SAFETY: the callback follows the Lua C ABI, has no captures, and only inspects its caller.
        let probe = unsafe { lua.create_c_function(native_probe) }.expect("the probe is created");
        lua.globals()
            .set("native_probe", probe)
            .expect("the probe is installed");
        assert_eq!(
            returned(answer(
                &lua,
                "local functions = {function(probe) local total = 0; for i = 1, 100 do total += i end; return probe(), total end}; return functions[1](native_probe)"
            )),
            vec![Value::Boolean(true), Value::Integer(5050)],
        );
        OVERRUN_WAS_NATIVE.with(|native| native.set(false));
        let outcome = with_test_clock(&lua, "while true do end");
        assert!(matches!(outcome, Reply::Abandoned { .. }), "{outcome:?}");
        assert!(
            OVERRUN_WAS_NATIVE.with(Cell::get),
            "the interrupt abandons a native frame"
        );
        assert_eq!(
            returned(answer(&lua, "return 42")),
            vec![Value::Integer(42)]
        );
        assert!(matches!(answer(&lua, "local ="), Reply::LoadError(_)));
        assert!(
            matches!(answer(&lua, "error('native sentinel')"), Reply::RuntimeError(message) if message.contains("native sentinel"))
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

        let outcome = with_test_clock(&lua, "return elsewhere(500)");

        assert!(
            matches!(outcome, Reply::Abandoned { .. }),
            "the chunk's own frame is bounded, and the chunk answered {outcome:?}"
        );
    }

    #[test]
    fn a_result_that_cannot_be_serialised_is_reported_rather_than_dropped() {
        let Reply::Unrepresentable(message) = run("return 1, function() end") else {
            panic!("a function has no wire form");
        };
        assert!(message.contains("result 2"), "{message}");
        assert!(message.contains("function"), "{message}");
    }

    /// The interrupt must not still be installed when the next chunk arrives.
    /// A chunk would then inherit the previous one's deadline.
    #[test]
    fn a_chunk_after_an_abandoned_one_gets_its_own_budget() {
        let lua = crate::test_lua::session_lua();

        let abandoned = evaluate_with_clock(&lua, "while true do end", SHORT, Rc::new(WallClock));
        assert!(
            matches!(abandoned, Reply::Abandoned { .. }),
            "{abandoned:?}"
        );

        assert_eq!(
            returned(answer(&lua, "return 'after'")),
            vec![Value::String(b"after".to_vec())],
        );
    }
}
