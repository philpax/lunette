//! Linux-only: the parts of lunette that are not the entry point.
//!
//! The binary is `main.rs`. It owns the environment, the subscriber, and the LÖVR
//! boot sequence. The crate holds everything the binary coordinates but does not
//! execute. Tests can reach the code directly. The crate declares its public
//! surface in one place.
//!
//! The [`import`] module runs on the compositor thread.
//! It converts a committed client buffer into a resource the graphics device holds.
//! The [`texture`] module runs on the frame thread.
//! It converts that resource into a LÖVR `Texture`.
//! The modules split at the boundary between creating an image,
//! which touches no queue, and submitting work, which does.
//! The [`lua`] module presents all of it to the user's configuration.
//! The [`events`] module notifies the configuration when an event occurs.
//! The configuration does not poll for events.
//! The [`layers`] module promotes panels onto OpenXR composition layers
//! through the discrete steps [`scale`] defines.
//! The [`scene`] module handles the state where every panel is on a layer.
//! Lunette then has nothing to render itself.
//! A frame that renders nothing skips the whole projection layer and draws no empty one.
//! The [`mirrors`] module provides the second kind of target for Lua: the user's own screens.
//! The screencast portal mirrors them, and the compositor does not host them.
//! A sink targeting one of the screens delivers its content to the [`host`] module.
//! The [`properties`] module holds the sole per-window state Rust keeps for the configuration.
//! A soft reload discards the Lua state, and this state must persist across the reload.
//! The [`restart`] module performs every step of [`reload`] and also discards the Vulkan device.
//! The compositor releases the device, and lunette then destroys it.
//! The compositor receives a new device afterwards.
//! The session uses the [`safe_mode`] configuration when the user's configuration does not load.
//! The fallback is embedded in the binary.
//! No file on disk can remove it.
//! Code outside the session sends Lua chunks through the [`control`] module over a Unix socket,
//! and the main thread evaluates the chunks between frames.
//! The [`frame`] module runs the other modules once per frame in the order they require.
//! It is the sole module that starts the compositor thread.

pub mod aliases;
pub mod callback_error;
pub mod control;
pub mod events;
pub mod frame;
pub mod host;
pub mod import;
pub mod keymaps;
pub mod layers;
pub mod lua;
pub mod mirrors;
pub mod plugin;
pub mod properties;
pub mod reload;
pub mod require;
pub mod restart;
pub mod safe_mode;
pub mod scale;
pub mod scene;
pub mod texture;

/// Helpers shared across the crate's unit tests.
///
/// A test that evaluates Lua against an mlua-owned state must open LÖVR's fork library set,
/// as production's LÖVR state does. `luaL_openlibs` adds the fork's `package` library,
/// which `scope_to_modules` and the library handlers read.
/// mlua's `Lua::new()` opens its StdLib set alone, and that set has no `package`.
#[cfg(test)]
pub(crate) mod test_lua {
    /// An mlua state with LÖVR's fork library set opened.
    pub(crate) fn session_lua() -> mlua::Lua {
        let lua = mlua::Lua::new();
        // SAFETY: the state is fresh, and no call is in progress. Production
        // opens the libraries on the LÖVR state before any chunk runs.
        lua.exec_raw_lua(|raw| unsafe {
            mlua::ffi::luaL_openlibs(raw.state());
        });
        lua
    }
}
