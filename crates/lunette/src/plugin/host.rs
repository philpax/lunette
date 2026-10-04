//! Host-owned shutdown operations for the Lua plugin attachment.

use mlua::Lua;
use tracing::warn;

use crate::plugin::attachment;

/// Runs shutdown in order: retire runtimes, clear subscribers, flush the final
/// frame, quiesce native state, and close Lua last.
pub fn terminal_shutdown<Runtime, Subscribers, Flush, Native, Close>(
    runtime_shutdown: Runtime,
    clear_subscribers: Subscribers,
    flush_frame: Flush,
    native_quiesce: Native,
    close_external: Close,
) where
    Runtime: FnOnce(),
    Subscribers: FnOnce(),
    Flush: FnOnce(),
    Native: FnOnce(),
    Close: FnOnce(),
{
    runtime_shutdown();
    clear_subscribers();
    flush_frame();
    native_quiesce();
    close_external();
}

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
