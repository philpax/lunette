//! Linux-only: what happens to an error raised inside a configuration's
//! callback.
//!
//! [The Lua API](../../../docs/dev/lua-api.md#errors) says the callback boundary
//! logs the error and notifies every `lunette.onError` listener. The limiter,
//! the wording of a report, and the display are policy in the error-display
//! provider, `@lunette-plugins/error-display`, which subscribes like any other
//! listener and is never looked up.
//!
//! # No native limiter
//!
//! A native limiter and a Lua limiter, keyed differently, produce gaps: an
//! error suppressed natively never reaches the Lua limiter, whose window then
//! starts from the wrong occurrence. Every listener is notified, and each
//! listener handles the error independently.
//!
//! # Sessions without the error display
//!
//! A configuration that does not enable the error-display provider is
//! supported. There is then no limiter: the error is logged and each listener
//! is notified, and an error raised every frame is logged every frame. Enabling
//! the provider installs the limiter that suppresses the repetition on the
//! display.
//!
//! A listener that raises does not stop the ones after it. A session whose
//! error display itself raises still reaches every other listener.

use mlua::{Function, IntoLua, Lua};
use tracing::error;

use crate::lua::ErrorEvent;

/// Reports an error a configuration's callback raised.
///
/// `context` names the boundary the error came through, the callback's own
/// name, and leads the message, so a report says which callback failed without
/// the reader having to read the traceback.
///
/// Never raises. The callback boundary has no reporting path below this one,
/// so a failure would leave the error unreported.
pub fn report(lua: &Lua, listeners: &[Function], context: &str, error: &mlua::Error) {
    report_traced(lua, listeners, &TracedError::of(context, error));
}

/// Reports an error whose message and traceback are already apart.
///
/// `lunette.reportError` reaches the boundary through this, so a Lua
/// dispatcher that protects each of its handlers reports a handler's error the
/// way a raising callback is reported. Never raises, for the reason
/// [`report`] does not.
pub fn report_traced(lua: &Lua, listeners: &[Function], traced: &TracedError) {
    error!("lua: {}\n{}", traced.message, traced.traceback);

    if let Err(failure) = offer_to_listeners(lua, listeners, traced) {
        error!("lua: a lunette.onError listener raised while being told about it: {failure}");
    }
}

/// An error's message and the traceback that goes with it, kept apart.
///
/// The error-display provider keys its rate limit on both. One message raised from two
/// places is two defects, and conflating them would hide the second behind the
/// first. The listener receives the two separately, and mlua reports them
/// joined.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TracedError {
    /// The raised error, with the boundary leading it.
    pub message: String,
    /// The traceback, or an empty string when Lua reports none.
    pub traceback: String,
}

impl TracedError {
    /// Splits what mlua reports into the two halves a report is made of.
    ///
    /// `Function::call` installs `luaL_traceback` as the message handler
    /// (mlua-0.12.0/src/function.rs), which appends the traceback to the error
    /// string with [`TRACEBACK_MARKER`] between them. An error raised by a Rust
    /// callback arrives as [`mlua::Error::CallbackError`], which already
    /// carries the two apart.
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

/// Calls every `lunette.onError` listener with the error.
///
/// Every listener runs, including the ones after a listener that raised: a
/// panel that fails to draw does not stop a logger from receiving the error.
fn offer_to_listeners(lua: &Lua, listeners: &[Function], traced: &TracedError) -> mlua::Result<()> {
    if listeners.is_empty() {
        return Ok(());
    }

    // Built through the declared type, so a listener sees the fields the
    // declaration names.
    let payload = ErrorEvent {
        message: traced.message.clone(),
        traceback: traced.traceback.clone(),
    }
    .into_lua(lua)?;

    let mut raised = Ok(());
    for handler in listeners {
        if let Err(failure) = handler.call::<()>(payload.clone()) {
            raised = Err(failure);
        }
    }
    raised
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// The named global, as a listener `report` can be handed.
    fn listener(lua: &Lua, name: &str) -> Function {
        lua.globals()
            .get::<Function>(name)
            .expect("the handler is a function")
    }

    /// A state with `lovr` on it, which the reporting path requires.
    fn state() -> Lua {
        let lua = crate::test_lua::session_lua();
        lua.load("lovr = {}").exec().expect("lovr is reachable");
        lua
    }

    /// Raises inside a Lua function called the way a callback is, so the error
    /// arrives with the traceback mlua appends.
    fn raised(lua: &Lua, body: &str) -> mlua::Error {
        lua.load(body)
            .set_name("main.lua")
            .into_function()
            .expect("the chunk compiles")
            .call::<()>(())
            .expect_err("the chunk raises")
    }

    #[test]
    fn a_traceback_is_separated_from_the_message_it_was_appended_to() {
        let lua = crate::test_lua::session_lua();
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
        let lua = crate::test_lua::session_lua();
        let traced = TracedError::of("lovr.lunwindowopened", &raised(&lua, "error({ code = 1 })"));

        assert!(
            !traced.message.is_empty(),
            "an error raised with a table is still an error and still has to be reported"
        );
    }

    /// A listener the configuration subscribed receives the error directly,
    /// with no error-display provider in between.
    #[test]
    fn a_listener_is_called_directly_with_the_message_and_traceback() {
        let lua = state();
        lua.load("seen = {} function record(event) seen[#seen + 1] = event end")
            .exec()
            .expect("the handler installs");
        let listener = listener(&lua, "record");

        report(
            &lua,
            std::slice::from_ref(&listener),
            "lunette.lunwindowopened",
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

    #[test]
    fn a_configuration_with_no_listener_is_not_an_error() {
        let lua = state();

        report(
            &lua,
            &[],
            "lunette.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );
    }

    #[test]
    fn a_listener_that_raises_does_not_take_the_session_with_it() {
        let lua = state();
        lua.load("function record() error('the handler said no') end")
            .exec()
            .expect("the handler installs");
        let listener = listener(&lua, "record");

        report(
            &lua,
            std::slice::from_ref(&listener),
            "lunette.lunwindowopened",
            &raised(&lua, "error('it broke')"),
        );
    }
}
