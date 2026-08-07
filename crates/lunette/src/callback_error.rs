//! Linux-only: what happens to an error raised inside a configuration's
//! callback.
//!
//! [The Lua API](../../../docs/lua-api.md#errors) says the callback boundary
//! logs, emits `lovr.lunerror`, draws a panel, and rate-limits identical errors.
//! Only the first of those and the delivery to Lua are mechanism. The limiter,
//! the wording of a report, and the panel are policy, and policy is
//! `mullion.error`'s — which is why this module hands the error there rather
//! than deciding any of it.
//!
//! # Why there is no limiter here
//!
//! Two limiters keyed differently produce gaps that neither of them explains: an
//! error suppressed natively never reaches the Lua one, whose window then starts
//! from the wrong occurrence. `mullion.error` is told the message and the
//! traceback and owns every decision that follows.
//!
//! # The fallback, and what it does not have
//!
//! A configuration that never requires `mullion` is supported, and so is one
//! whose standard library is missing. There is then no limiter at all: the error
//! is logged and `lovr.lunerror` is called directly, and an error raised every
//! frame is logged every frame. That is the honest behaviour rather than a
//! silent one, and installing `mullion.error` is what fixes it.

use mlua::{Function, Lua, Table};
use tracing::error;

/// Reports an error a configuration's callback raised.
///
/// `context` names the boundary it came through — the callback's own name — and
/// leads the message, so a report says which callback failed without the reader
/// having to recognise the traceback.
///
/// Never raises: this is the floor beneath the callback boundary, and a floor
/// that can fail is not one.
pub fn report(lua: &Lua, context: &str, error: &mlua::Error) {
    let traced = TracedError::of(context, error);

    match hand_to_standard_library(lua, &traced) {
        Ok(true) => (),
        Ok(false) => report_without_a_standard_library(lua, &traced),
        Err(failure) => {
            // The handler itself is broken, so the error it was given would be
            // lost with it. Both are logged, in that order: the one the session
            // hit, then the reason nothing prettier happened to it.
            error!("lua: {}\n{}", traced.message, traced.traceback);
            error!("lua: mullion.error could not be reached to report it: {failure}");
        }
    }
}

/// An error's message and the traceback that goes with it, kept apart.
///
/// `mullion.error` keys its rate limit on both, because one message raised from
/// two places is two defects and conflating them would hide the second behind
/// the first. So the two have to arrive separately, and mlua hands them over
/// joined.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TracedError {
    /// What was raised, led by the boundary it came through.
    pub message: String,
    /// Where it was raised, or an empty string when Lua produced none.
    pub traceback: String,
}

impl TracedError {
    /// Splits what mlua reports into the two halves a report is made of.
    ///
    /// `Function::call` installs `luaL_traceback` as the message handler
    /// (`mlua-0.12.0/src/function.rs:201`), which appends the traceback to the
    /// error string with [`TRACEBACK_MARKER`] between them. An error raised by a
    /// Rust callback instead arrives as [`mlua::Error::CallbackError`], which
    /// already carries the two apart.
    #[must_use]
    pub fn of(context: &str, error: &mlua::Error) -> Self {
        let (message, traceback) = match error {
            mlua::Error::CallbackError { traceback, cause } => {
                (cause.to_string(), traceback.trim_end().to_owned())
            }
            other => split(&other.to_string()),
        };

        Self {
            message: format!("{context}: {message}"),
            traceback,
        }
    }
}

/// What `luaL_traceback` puts between the message and the traceback.
const TRACEBACK_MARKER: &str = "\nstack traceback:";

/// The message and the traceback of a joined error string.
fn split(reported: &str) -> (String, String) {
    match reported.find(TRACEBACK_MARKER) {
        Some(index) => (
            reported[..index].to_owned(),
            reported[index + 1..].trim_end().to_owned(),
        ),
        None => (reported.trim_end().to_owned(), String::new()),
    }
}

/// Hands the error to `mullion.error`, answering whether it was there to take
/// it.
///
/// Reached through `package.loaded` rather than `require`. A configuration that
/// never mentions `mullion` is supported, and requiring it from here would load
/// the standard library into a session that had deliberately gone without one —
/// on the one code path that runs when something is already wrong.
fn hand_to_standard_library(lua: &Lua, traced: &TracedError) -> mlua::Result<bool> {
    let loaded: Table = lua.globals().get::<Table>("package")?.get("loaded")?;
    let Some(module) = loaded.get::<Option<Table>>(ERROR_MODULE)? else {
        return Ok(false);
    };
    let Some(handle) = module.get::<Option<Function>>("handle")? else {
        return Ok(false);
    };

    // Three arguments, with the time left to the module's own clock: the
    // limiter's window is wall time and lunette has no better answer for what
    // the time is than the session does.
    handle.call::<()>((
        traced.message.as_str(),
        traced.traceback.as_str(),
        mlua::Value::Nil,
    ))?;
    Ok(true)
}

/// The module the error handler lives in.
const ERROR_MODULE: &str = "mullion.error";

/// Logs the error and offers it to `lovr.lunerror` directly.
///
/// The payload is the table `mullion.error` builds, so a configuration's handler
/// reads the same two fields whether or not the standard library is loaded.
fn report_without_a_standard_library(lua: &Lua, traced: &TracedError) {
    error!("lua: {}\n{}", traced.message, traced.traceback);

    if let Err(failure) = offer_to_lunerror(lua, traced) {
        error!("lua: lovr.lunerror raised while being told about it: {failure}");
    }
}

/// Calls `lovr.lunerror` if the configuration defined one.
fn offer_to_lunerror(lua: &Lua, traced: &TracedError) -> mlua::Result<()> {
    let Some(lovr) = lua.globals().get::<Option<Table>>("lovr")? else {
        return Ok(());
    };
    let Some(handler) = lovr.get::<Option<Function>>(LUNERROR)? else {
        return Ok(());
    };

    let payload = lua.create_table()?;
    payload.set("message", traced.message.as_str())?;
    payload.set("traceback", traced.traceback.as_str())?;
    handler.call::<()>(payload)
}

/// The callback an error is offered to when there is no standard library.
const LUNERROR: &str = "lunerror";

/// Loads the real `mullion.error` into `lua` and captures what it reports.
///
/// The two modules are compiled in rather than read at run time, so a case
/// covers the files that ship and touches no filesystem. Reports land in the
/// global `reports`, which is what a case counts.
///
/// Here rather than in either test module because both boundaries need it: this
/// module's own cases and the `lun*` dispatch in [`crate::lua::tests`].
///
/// # Panics
///
/// If either module does not load, which is a defect in the standard library
/// rather than anything the case did.
#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test fixture reports a defect in the tree it loads"
)]
pub(crate) fn install_standard_library_handler(lua: &Lua) {
    const MULLION_ERROR: &str = include_str!("../../../lua/mullion/error/init.lua");
    const MULLION_TEARDOWN: &str = include_str!("../../../lua/mullion/teardown.lua");

    let loaded: Table = lua
        .globals()
        .get::<Table>("package")
        .expect("package exists")
        .get("loaded")
        .expect("package.loaded exists");

    let teardown: Table = lua
        .load(MULLION_TEARDOWN)
        .set_name("@mullion/teardown.lua")
        .call(())
        .expect("the teardown registry loads");
    loaded
        .set("mullion.teardown", teardown)
        .expect("the registry is reachable");

    let module: Table = lua
        .load(MULLION_ERROR)
        .set_name("@mullion/error/init.lua")
        .call(())
        .expect("the error handler loads");
    loaded
        .set(ERROR_MODULE, module)
        .expect("the handler is reachable");

    lua.load(
        "reports = {}
         package.loaded['mullion.error'].report = function(text)
             reports[#reports + 1] = text
         end",
    )
    .exec()
    .expect("the report sink is replaced");
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// A state with `lovr`, and with the real `mullion.error` loaded and its
    /// reports captured.
    fn state_with_the_standard_library() -> Lua {
        let lua = state();
        install_standard_library_handler(&lua);
        lua
    }

    fn state() -> Lua {
        let lua = Lua::new();
        lua.load("lovr = {}").exec().expect("lovr is reachable");
        lua
    }

    /// Raises inside a Lua function called the way a callback is, so the error
    /// under test is one Lua produced rather than one a string described.
    fn raised(lua: &Lua, body: &str) -> mlua::Error {
        lua.load(body)
            .set_name("@main.lua")
            .into_function()
            .expect("the chunk compiles")
            .call::<()>(())
            .expect_err("the chunk raises")
    }

    fn reports(lua: &Lua) -> Vec<String> {
        lua.load("return reports")
            .eval::<Table>()
            .expect("the reports are readable")
            .sequence_values::<String>()
            .filter_map(Result::ok)
            .collect()
    }

    #[test]
    fn a_traceback_is_separated_from_the_message_it_was_appended_to() {
        let lua = Lua::new();
        let traced = TracedError::of("lovr.lunwindowopened", &raised(&lua, "error('it broke')"));

        assert!(
            traced.message.starts_with("lovr.lunwindowopened: "),
            "the boundary should lead the message: {}",
            traced.message
        );
        assert!(
            traced.message.contains("it broke"),
            "the message should survive: {}",
            traced.message
        );
        assert!(
            !traced.message.contains("stack traceback:"),
            "the traceback should not be part of the message: {}",
            traced.message
        );
        assert!(
            traced.traceback.starts_with("stack traceback:"),
            "the traceback should be the traceback: {}",
            traced.traceback
        );
    }

    #[test]
    fn an_error_with_no_traceback_reports_an_empty_one() {
        assert_eq!(
            split("lua: it broke"),
            ("lua: it broke".to_owned(), String::new())
        );
    }

    #[test]
    fn a_message_that_is_not_a_string_still_reports() {
        let lua = Lua::new();
        let traced = TracedError::of("lovr.lunwindowopened", &raised(&lua, "error({ code = 1 })"));

        assert!(
            !traced.message.is_empty(),
            "an error raised with a table is still an error and still has to be reported"
        );
    }

    #[test]
    fn the_standard_library_is_what_reports_when_it_is_loaded() {
        let lua = state_with_the_standard_library();

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );

        let reports = reports(&lua);
        assert_eq!(reports.len(), 1);
        assert!(
            reports[0].contains("lovr.lunwindowopened: ") && reports[0].contains("it broke"),
            "{}",
            reports[0]
        );
    }

    /// `lunette-v1.AC8.3`'s second half, at this boundary: the same error over
    /// and over is one report, because the limiter is `mullion.error`'s and this
    /// hands it the same key each time.
    #[test]
    fn the_same_error_raised_every_frame_is_reported_once() {
        let lua = state_with_the_standard_library();
        let function = lua
            .load("error('it broke')")
            .set_name("@main.lua")
            .into_function()
            .expect("the chunk compiles");

        for _ in 0..120 {
            let error = function.call::<()>(()).expect_err("the chunk raises");
            report(&lua, "lovr.lunwindowopened", &error);
        }

        assert_eq!(
            reports(&lua).len(),
            1,
            "an error raised every frame should not fill the display with copies of itself"
        );
    }

    #[test]
    fn two_different_errors_are_two_reports() {
        let lua = state_with_the_standard_library();

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('first')"),
        );
        report(
            &lua,
            "lovr.lunwindowclosed",
            &raised(&lua, "error('second')"),
        );

        assert_eq!(reports(&lua).len(), 2);
    }

    /// A session with no standard library still tells the configuration, so a
    /// `lovr.lunerror` written without `mullion` is not a callback that never
    /// fires.
    #[test]
    fn lunerror_is_called_directly_when_there_is_no_standard_library() {
        let lua = state();
        lua.load("seen = {} function lovr.lunerror(event) seen[#seen + 1] = event end")
            .exec()
            .expect("the handler installs");

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );

        let (count, message, traceback): (usize, String, String) = lua
            .load("return #seen, seen[1].message, seen[1].traceback")
            .eval()
            .expect("the payload is readable");
        assert_eq!(count, 1);
        assert!(message.contains("it broke"), "{message}");
        assert!(traceback.contains("stack traceback:"), "{traceback}");
    }

    /// The standard library emits `lovr.lunerror` itself, so the fallback must
    /// not also emit one.
    #[test]
    fn lunerror_is_emitted_once_when_the_standard_library_is_loaded() {
        let lua = state_with_the_standard_library();
        lua.load("seen = 0 function lovr.lunerror() seen = seen + 1 end")
            .exec()
            .expect("the handler installs");

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );

        assert_eq!(
            lua.load("return seen").eval::<usize>().expect("readable"),
            1,
            "two reporters would hand the configuration the same error twice"
        );
    }

    #[test]
    fn a_configuration_with_no_lunerror_is_not_an_error() {
        let lua = state();

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );
    }

    /// The floor cannot itself fail: a handler that raises leaves the session
    /// running and the error logged.
    #[test]
    fn a_standard_library_handler_that_raises_does_not_take_the_session_with_it() {
        let lua = state_with_the_standard_library();
        lua.load(
            "package.loaded['mullion.error'].handle = function() error('the handler said no') end",
        )
        .exec()
        .expect("the handler is replaced");

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );
    }

    #[test]
    fn a_lunerror_that_raises_does_not_take_the_session_with_it() {
        let lua = state();
        lua.load("function lovr.lunerror() error('the handler said no') end")
            .exec()
            .expect("the handler installs");

        report(
            &lua,
            "lovr.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );
    }
}
