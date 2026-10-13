//! Linux-only: reports errors raised by configuration callbacks.
//!
//! [The Lua API](../../../docs/development/native/lua-api.md#errors) defines the callback boundary. The error
//! stream provider owns rate limiting. A listener failure does not stop later listeners.

use mlua::{Function, IntoLua, Lua};
use tracing::error;

use crate::lua::ErrorEvent;

/// Reports a callback error to every listener.
///
/// The context prefixes the message so the boundary is identifiable without its traceback.
pub fn report(lua: &Lua, listeners: &[Function], context: &str, error: &mlua::Error) {
    report_traced(lua, listeners, &TracedError::of(context, error));
}

/// Reports an error with a separate message and traceback.
///
/// Listener failures are logged because this is the last reporting boundary.
pub fn report_traced(lua: &Lua, listeners: &[Function], traced: &TracedError) {
    error!("lua: {}\n{}", traced.message, traced.traceback);

    if let Err(failure) = offer_to_listeners(lua, listeners, traced) {
        error!("lua: a lunette.onError listener raised while being told about it: {failure}");
    }
}

/// An error's message and the traceback that goes with it, kept apart.
///
/// The error stream provider keys its rate limit on both fields, so identical messages from
/// different tracebacks remain distinct.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TracedError {
    /// The raised error, with the boundary leading it.
    pub message: String,
    /// The traceback, or an empty string when Lua reports none.
    pub traceback: String,
}

impl TracedError {
    /// Separates the error message from its traceback.
    ///
    /// `Function::call` appends the traceback after [`TRACEBACK_MARKER`]. Rust callback errors
    /// arrive as [`mlua::Error::CallbackError`] with the message and traceback already separate.
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

/// Calls every `lunette.onError` listener, even when an earlier listener raises.
fn offer_to_listeners(lua: &Lua, listeners: &[Function], traced: &TracedError) -> mlua::Result<()> {
    if listeners.is_empty() {
        return Ok(());
    }

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

    fn listener(lua: &Lua, name: &str) -> Function {
        lua.globals()
            .get::<Function>(name)
            .expect("the handler is a function")
    }

    /// Raises the way a callback does, so the error carries the traceback mlua appends.
    fn raised(lua: &Lua, body: &str) -> mlua::Error {
        lua.load(body)
            .set_name("main.luau")
            .into_function()
            .expect("the chunk compiles")
            .call::<()>(())
            .expect_err("the chunk raises")
    }

    #[test]
    fn a_traceback_is_separated_from_its_message_or_empty_when_absent() {
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
        assert_eq!(
            split("lua: it broke"),
            ("lua: it broke".to_owned(), String::new())
        );
    }

    /// A listener that raises does not stop later ones, and each is called directly with the
    /// message and the traceback.
    #[test]
    fn every_listener_is_offered_the_message_and_traceback_even_after_one_raises() {
        let lua = crate::test_lua::session_lua();
        lua.load(
            "seen = {} function refuse() error('the handler said no') end \
             function record(event) seen[#seen + 1] = event end",
        )
        .exec()
        .expect("the handlers install");
        let listeners = [listener(&lua, "refuse"), listener(&lua, "record")];

        report(
            &lua,
            &listeners,
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
}
