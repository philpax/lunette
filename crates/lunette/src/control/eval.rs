//! Evaluating one `lunctl` chunk, on the Lua thread, under a time budget.
//!
//! # Between frames, on the thread that owns the state
//!
//! A chunk runs on the main thread between two frames, never concurrently with
//! `lovr.update` or `lovr.draw` ([the Lua API](../../../docs/lua-api.md#lunctl)).
//! That is what makes it safe for a chunk to touch the same state a callback
//! touches: there is no other thread to race, because the control thread never
//! sees a `Lua` at all. `crate::boot` is where the call sits, in the gap between
//! `FrameDriver::end_frame` and the next `begin_frame`.
//!
//! # Nothing outlives the call
//!
//! [`evaluate`] hands the chunk's results to a closure and lets go of them
//! before it returns. Rust never holds a Lua value past the call that produced
//! it — the rule `docs/architecture.md` records, and the reason a soft reload can
//! throw the state away without anything here dangling.
//!
//! # The budget is best-effort, and that is a decision rather than an oversight
//!
//! `debug.sethook(fn, "", N)` with a count hook is the standard way to bound an
//! arbitrary chunk. Under LuaJIT it has a specific failure: **JIT-compiled code
//! does not call debug hooks**, so a trace in a tight loop never returns to the
//! interpreter and the hook never fires. [`evaluate`] therefore applies `jit.off`
//! to the loaded chunk, which forces interpretation and makes the hook reliable.
//! The cost is irrelevant — a control-plane chunk is not a hot path — and the
//! alternative, building LuaJIT with `-DLUAJIT_ENABLE_CHECKHOOK`, would slow the
//! whole session to bound one feature.
//!
//! Even so the bound is advisory. An `error()` raised from a hook can be caught
//! by a `pcall` inside the user's own chunk, and a loop inside a C function or a
//! blocking FFI call is uninterruptible by any hook. A hard bound would need a
//! watchdog outside Lua, and since the chunk holds the Lua thread the only thing
//! a watchdog could do is abort the process — turning a bad `lunctl` command into
//! a crash that takes every connected client with it, which is worse than the
//! hang it prevents. `docs/decisions.md` records the reasoning.
//!
//! # A load error and a runtime error are different outcomes
//!
//! A chunk that does not compile and a chunk that raises are distinguishable
//! here and distinguishable on the wire, because a caller can act differently on
//! each. awesome's remote control collapses both into one string; this does not.

use std::{
    cell::Cell,
    error::Error,
    time::{Duration, Instant},
};

use mlua::{Function, HookTriggers, Lua, MultiValue, Table, VmState};
use tracing::warn;

/// How long a chunk may run before the hook starts raising.
///
/// A newtype rather than a bare [`Duration`], because "how long a chunk gets"
/// and "how long a client waits for an answer" are both durations in this
/// subsystem and swapping them would be silent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Budget(Duration);

impl Budget {
    /// What a chunk gets when nothing says otherwise.
    ///
    /// Long enough for a session inspection that walks every window, short
    /// enough that a chunk which never finishes costs one visible hitch rather
    /// than a frozen headset.
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
/// `R` is whatever the caller's `render` made of the results, so that the values
/// themselves never escape [`evaluate`].
#[derive(Debug)]
pub enum Evaluation<R> {
    /// The chunk ran and its results rendered. A chunk returning nothing renders
    /// an empty list, which is not the same as returning `nil`.
    Returned(R),
    /// The chunk did not compile.
    LoadFailed(String),
    /// The chunk compiled and raised, and the budget was not what raised it.
    Raised(String),
    /// The budget ran out and the chunk was abandoned.
    Abandoned { after: Duration },
    /// The chunk ran and returned something that could not be rendered.
    Unrepresentable(Box<dyn Error + Send + Sync>),
    /// A chunk was asked for from inside one.
    Reentered,
}

/// Compiles and runs `chunk`, rendering whatever it returned.
///
/// The results reach `render` and go no further: it is called once, with the
/// chunk's return values, and everything it was handed is dropped before this
/// returns.
///
/// # Errors
///
/// Reported through [`Evaluation`] rather than through `Result`, because a chunk
/// that failed to compile, a chunk that raised, and a chunk that ran out of time
/// are three outcomes a caller acts differently on and none of them is a failure
/// of this function.
pub fn evaluate<R>(
    lua: &Lua,
    chunk: &str,
    budget: Budget,
    render: impl FnOnce(MultiValue) -> Result<R, Box<dyn Error + Send + Sync>>,
) -> Evaluation<R> {
    // A chunk that asks for another one would otherwise recurse through the
    // hook, the budget, and the queue at once, and a stack overflow here takes
    // every connected client down with the process. `crate::reload` guards
    // itself the same way and for the same reason.
    let Some(_guard) = EvaluatingGuard::acquire() else {
        return Evaluation::Reentered;
    };

    // `=` rather than `@`, so the traceback says `lunctl` rather than treating
    // the chunk's first line as a file name.
    let function = match lua.load(chunk).set_name("=lunctl").into_function() {
        Ok(function) => function,
        Err(error) => return Evaluation::LoadFailed(error.to_string()),
    };

    disable_jit(lua, &function);

    let started = Instant::now();
    let deadline = started + budget.limit();
    let expired = Overrun::default();
    let raised = expired.clone();

    if let Err(error) = lua.set_hook(
        HookTriggers::new().every_nth_instruction(HOOK_INSTRUCTIONS),
        move |_, _| {
            if Instant::now() < deadline {
                return Ok(VmState::Continue);
            }
            raised.set();
            Err(mlua::Error::runtime(OVERRUN_MESSAGE))
        },
    ) {
        // Without a hook the chunk is unbounded, and running it anyway would be
        // the one outcome `lunette-v1.AC8.2` exists to prevent.
        return Evaluation::Raised(format!(
            "lunctl: the time budget could not be installed, so the chunk was not run: {error}"
        ));
    }

    let outcome = function.call::<MultiValue>(());

    // Before `render`, so that serialising a large result cannot be mistaken for
    // the chunk overrunning.
    lua.remove_hook();

    match outcome {
        Ok(values) => {
            if expired.get() {
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
        Err(_) if expired.get() => Evaluation::Abandoned {
            after: started.elapsed(),
        },
        Err(error) => Evaluation::Raised(error.to_string()),
    }
}

/// How many VM instructions pass between two checks of the clock.
///
/// Small enough that the overshoot past the budget is a fraction of a frame, and
/// large enough that reading the clock is not the thing the chunk spends its
/// time on.
const HOOK_INSTRUCTIONS: u32 = 10_000;

/// What the hook raises with.
///
/// It reaches the user only when their own `pcall` catches it, so it says what
/// happened rather than naming an internal.
const OVERRUN_MESSAGE: &str = "lunctl: the chunk ran past its time budget and was abandoned";

/// Forces `function` to run interpreted.
///
/// **JIT-compiled code does not call debug hooks.** A trace in a tight loop
/// never returns to the interpreter, so the count hook installed above would
/// never fire and the budget would not exist. `jit.off(f, true)` disables
/// compilation for the function and everything defined inside it, which is what
/// makes the hook reliable.
///
/// Best-effort by design: a Lua state without `jit` is a plain Lua build, where
/// the hook fires anyway and there is nothing to turn off.
fn disable_jit(lua: &Lua, function: &Function) {
    let off = lua
        .globals()
        .get::<Option<Table>>("jit")
        .and_then(|jit| jit.map_or(Ok(None), |jit| jit.get::<Option<Function>>("off")));

    match off {
        Ok(Some(off)) => {
            // The second argument is recursive: without it only this function is
            // interpreted, and a closure it defines would still be compiled into
            // a trace the hook cannot reach.
            if let Err(error) = off.call::<()>((function.clone(), true)) {
                warn!(
                    "lunctl: a chunk could not be forced to run interpreted, so its time budget \
                     may not be enforced: {error}"
                );
            }
        }
        Ok(None) => {}
        Err(error) => warn!("lunctl: the jit module could not be read: {error}"),
    }
}

/// Whether the hook has raised for this chunk.
///
/// Shared with the hook closure, which outlives the call that installed it as
/// far as the type system is concerned — [`Lua::set_hook`] takes a `'static`
/// callback — so this cannot be a borrow.
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

/// Holds the reentrancy flag for the length of one evaluation.
///
/// Thread-local rather than global, for the reason `crate::reload`'s is: the Lua
/// API is available only in the main state, so the flag belongs to the thread
/// that owns the state rather than to the process.
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
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// A rendering that accepts scalars and refuses everything else.
    ///
    /// Deliberately not the real serialiser: what is under test here is the
    /// evaluation, and a render that says "no" to a function is enough to
    /// exercise the outcome that matters.
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
        evaluate(&Lua::new(), chunk, Budget::DEFAULT, scalars)
    }

    fn returned(outcome: Evaluation<Vec<String>>) -> Vec<String> {
        match outcome {
            Evaluation::Returned(values) => values,
            other => panic!("expected a return, and the chunk {other:?}"),
        }
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
        // Which is not the same as returning nil, and the wire keeps them apart.
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

    /// The budget is what is under test, so the duration is the measurement
    /// rather than a wait for something else to happen: the chunk never
    /// terminates, and 50 milliseconds is long enough for the hook to fire
    /// several times and short enough that the suite does not notice.
    #[test]
    fn a_chunk_that_never_finishes_is_abandoned_rather_than_running_forever() {
        let outcome = evaluate(
            &Lua::new(),
            "while true do end",
            Budget::of(Duration::from_millis(50)),
            scalars,
        );

        let Evaluation::Abandoned { after } = outcome else {
            panic!("expected the budget to end it, and the chunk {outcome:?}");
        };
        assert!(
            after >= Duration::from_millis(50),
            "the chunk was abandoned after {after:?}, which is before its budget ran out",
        );
    }

    /// The documented escape, asserted as the behaviour it is rather than as an
    /// aspiration. A `pcall` inside the chunk catches what the hook raises, and
    /// no hook can do anything about that.
    #[test]
    fn a_chunk_that_catches_the_abort_with_pcall_escapes_the_budget() {
        let outcome = evaluate(
            &Lua::new(),
            "local ok, err = pcall(function() while true do end end) return ok, tostring(err)",
            Budget::of(Duration::from_millis(50)),
            scalars,
        );

        let values = returned(outcome);
        assert_eq!(values[0], "false", "the inner call was aborted");
        assert!(
            values[1].contains("time budget"),
            "the chunk sees what stopped it: {}",
            values[1],
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

    /// A chunk asking for another one would recurse through the hook, the
    /// budget, and the queue at once.
    #[test]
    fn a_chunk_asked_for_from_inside_one_is_refused() {
        let lua = Lua::new();
        let outcome = evaluate(&lua, "return 1", Budget::DEFAULT, |values| {
            // Inside the call, which is where the guard is still held.
            let nested = evaluate(&lua, "return 2", Budget::DEFAULT, scalars);
            assert!(
                matches!(nested, Evaluation::Reentered),
                "{nested:?} should have been refused"
            );
            scalars(values)
        });

        assert_eq!(returned(outcome), vec!["1"]);
    }

    /// The guard is released whatever the chunk did, or one bad chunk would
    /// close the endpoint for the rest of the session.
    #[test]
    fn the_guard_is_released_after_a_chunk_that_raised() {
        let lua = Lua::new();

        let raised = evaluate(&lua, "error('deliberate')", Budget::DEFAULT, scalars);
        assert!(matches!(raised, Evaluation::Raised(_)), "{raised:?}");

        assert_eq!(
            returned(evaluate(&lua, "return 'after'", Budget::DEFAULT, scalars)),
            vec!["after"],
        );
    }

    /// The hook must not still be installed when the next chunk arrives, or a
    /// chunk would inherit the previous one's deadline.
    #[test]
    fn a_chunk_after_an_abandoned_one_gets_its_own_budget() {
        let lua = Lua::new();

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
