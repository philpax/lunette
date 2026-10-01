//! Host-owned lifecycle operations for the Lua plugin attachment. Shutdown
//! failures are logged and never skip the remaining host cleanup, while an
//! epoch reset's error reaches the reload caller.

use mlua::Lua;
use tracing::warn;

use crate::plugin::attachment;

/// Runs the terminal host sequence in its required order: retire runtimes,
/// clear subscribers, flush the final frame, quiesce native state, and close
/// the Lua state last. Boot and the lifecycle tests share this sequence.
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

/// Retires every runtime attached to `lua`, logging each cleanup failure and
/// continuing.
pub fn shutdown(lua: &Lua, context: &str) {
    for failure in attachment::shutdown_all(lua) {
        warn!("{context}: {failure}; cleanup continued");
    }
}

/// Starts the next runtime epoch after the previous attachment has retired.
/// The epoch starts even when this returns an error.
pub fn reset_epoch(lua: &Lua) -> mlua::Result<()> {
    Ok(attachment::reset_epoch(lua)?)
}

/// Returns whether a plugin callback is currently running for `lua`.
#[must_use]
pub fn callback_active(lua: &Lua) -> bool {
    attachment::callback_active(lua)
}
