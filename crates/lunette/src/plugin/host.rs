//! Host-owned shutdown operations for the Lua plugin attachment.

use mlua::Lua;
use tracing::warn;

use crate::plugin::attachment;

/// Retires attached runtimes, starts a contract epoch, and logs shutdown failures.
pub fn shutdown(lua: &Lua, context: &str) {
    for failure in attachment::shutdown_all(lua) {
        warn!("{context}: {failure}; cleanup continued");
    }
}

/// Reports whether a plugin callback is running in `lua`.
#[must_use]
pub fn callback_active(lua: &Lua) -> bool {
    attachment::callback_active(lua)
}
