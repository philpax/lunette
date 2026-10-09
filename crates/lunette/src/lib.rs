//! Linux-only: coordinates the compositor, capture, Lua session, and frame loop.
//!
//! The binary owns environment access, logging, and LÖVR startup. This crate exposes the subsystems
//! that the binary coordinates and the tests exercise directly.

pub mod aliases;
pub mod callback_error;
pub mod control;
pub mod events;
pub mod frame;
pub mod host;
pub mod import;
pub mod keymaps;
pub mod layers;
#[cfg(test)]
pub(crate) mod log_capture;
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

/// Creates test Lua states with LÖVR's `package` library available.
///
/// `mlua::Lua::new()` does not open that library, which module scoping and library handlers use.
#[cfg(test)]
pub(crate) mod test_lua {
    /// An mlua state with LÖVR's fork library set opened.
    pub(crate) fn session_lua() -> mlua::Lua {
        let lua = mlua::Lua::new();
        // SAFETY: the state is fresh, and no call is in progress.
        lua.exec_raw_lua(|raw| unsafe {
            mlua::ffi::luaL_openlibs(raw.state());
        });
        lua
    }
}
