//! Host-owned lifecycle operations for the Lua plugin attachment.
//!
//! The attachment owns the runtime graph and serializes callback requests. This
//! module keeps host policy at the boundary: shutdown failures are diagnostic
//! and never skip the remaining host cleanup, while an epoch reset is a state
//! transition whose error must reach the reload caller.

use mlua::Lua;
use tracing::warn;

use crate::plugin::attachment;

/// Runs the terminal host sequence in its required ownership order.
///
/// Runtime-owned Lua values and cleanup callbacks are retired first. Subscriber
/// handles are then cleared, the final frame is flushed, native state is made
/// quiescent or stopped, and the external Lua state is closed last. Keeping the
/// sequence here lets boot and lifecycle tests exercise the same orchestration;
/// each caller still supplies the concrete native and close operations it owns.
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

/// Retires every runtime attached to `lua`.
///
/// Attachment cleanup is best effort. The attachment attempts every cleanup
/// callback and returns the failures of this shutdown; the host logs each one
/// and continues with subscriber, frame, native, and Lua cleanup.
pub fn shutdown(lua: &Lua, context: &str) {
    for failure in attachment::shutdown_all(lua) {
        warn!("{context}: {failure}; cleanup continued");
    }
}

/// Starts the next runtime epoch after the previous attachment has retired.
///
/// # Errors
///
/// Returns the attachment's error. The new epoch has started even then: an
/// error lists shutdown failures, or reports that the registry could not
/// advance its epoch.
pub fn reset_epoch(lua: &Lua) -> mlua::Result<()> {
    Ok(attachment::reset_epoch(lua)?)
}

/// Returns whether a plugin callback is currently running for `lua`.
#[must_use]
pub fn callback_active(lua: &Lua) -> bool {
    attachment::callback_active(lua)
}
