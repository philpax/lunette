//! Owns an offscreen LÖVR state, including every partial initialization path.

use std::{ffi::c_int, mem, ptr};

use lunette_lovr::{Platform, clear_log_callback, raw};
use mlua::{Lua, Table, ffi::lua_State};

use crate::state::{self, Roots};

unsafe extern "C-unwind" {
    fn luaopen_lovr(state: *mut lua_State) -> c_int;
    fn luaopen_lovr_data(state: *mut lua_State) -> c_int;
    fn luaopen_lovr_math(state: *mut lua_State) -> c_int;
    fn luaopen_lovr_graphics(state: *mut lua_State) -> c_int;
}

unsafe extern "C" {
    fn lovrGraphicsSubmit(passes: *mut *mut std::ffi::c_void, count: u32) -> bool;
}

/// Lua values obtained from this owner must be dropped before `finish` or `Drop`.
/// The runner keeps them inside a borrowed execution scope and returns owned errors only.
pub struct Owner {
    lua: Option<Lua>,
    platform: Option<Platform>,
}

impl Owner {
    pub fn new() -> Result<Self, String> {
        let platform = Platform::init().map_err(|error| format!("graphics: {error}"))?;
        let mut owner = Self {
            lua: None,
            platform: Some(platform),
        };
        owner.lua = Some(Lua::new());
        let state = owner.lua().exec_raw_lua(|raw| raw.state());
        // SAFETY: this owner runs every LÖVR call on one thread and owns the
        // interpreter until luax_close. Both FFI declarations describe the same ABI.
        unsafe { raw::luax_setmainthread(state.cast()) };
        Ok(owner)
    }

    pub fn lua(&self) -> &Lua {
        match &self.lua {
            Some(lua) => lua,
            None => unreachable!("the graphics owner has already closed"),
        }
    }

    /// Opens only core, data, math, and graphics; no boot script loads other modules.
    pub fn configure(&self, roots: &Roots) -> mlua::Result<()> {
        let lua = self.lua();
        // SAFETY: each opener follows the Lua C function protocol and uses the
        // same Luau ABI as mlua. The tables stay scoped to this live interpreter.
        let lovr: Table = unsafe { lua.create_c_function(luaopen_lovr)? }.call(())?;
        lua.globals().set("lovr", lovr.clone())?;
        lua.load(
            "lovr._setConf({ window = nil, modules = { audio = false, headset = false, \
             filesystem = false }, graphics = { shadercache = false, antialias = false, \
             vsync = false } })",
        )
        .exec()?;
        for (name, opener) in [
            (
                "data",
                luaopen_lovr_data as unsafe extern "C-unwind" fn(_) -> _,
            ),
            ("math", luaopen_lovr_math),
            ("graphics", luaopen_lovr_graphics),
        ] {
            // SAFETY: the opener's result is consumed before the owner can close.
            let open = unsafe { lua.create_c_function(opener)? };
            lovr.set(name, open.call::<Table>(())?)?;
        }
        state::install(lua, roots)?;
        state::use_configuration(
            lua,
            roots
                .repository
                .join("crates/lunette/tests/graphics/fixtures"),
        )?;
        Ok(())
    }

    pub fn initialize(&self) -> mlua::Result<()> {
        self.lua().load("lovr.graphics.initialize()").exec()
    }

    /// Reports cleanup failures without replacing the fixture's original failure.
    pub fn finish(mut self, outcome: Result<(), String>) -> Result<(), String> {
        let failures = self.close();
        match (outcome, failures.is_empty()) {
            (Ok(()), true) => Ok(()),
            (Err(error), true) => Err(error),
            (Ok(()), false) => Err(format!(
                "graphics: closing the state: {}",
                failures.join("\n")
            )),
            (Err(error), false) => Err(format!(
                "{error}\ngraphics: closing the state: {}",
                failures.join("\n")
            )),
        }
    }

    fn close(&mut self) -> Vec<String> {
        let mut failures = Vec::new();
        if let Some(lua) = self.lua.take() {
            failures.extend(state::shutdown(&lua));
            // SAFETY: only this owner initializes graphics, and all GPU users
            // have returned. Submit pending transfers before waiting for the device.
            unsafe {
                if raw::lovrGraphicsIsInitialized() {
                    if !lovrGraphicsSubmit(ptr::null_mut(), 0) {
                        failures.push("the final graphics submission failed".to_owned());
                    }
                    if !raw::lovrGraphicsWait() {
                        failures.push("waiting for the graphics device failed".to_owned());
                    }
                }
            }
            clear_log_callback();
            let state = lua.exec_raw_lua(|raw| {
                raw.mark_closed();
                raw.state()
            });
            // SAFETY: fixture tables, functions, and userdata handles have left
            // their Rust scopes. lua_close releases even reachable Lua userdata,
            // then luax_close runs LÖVR's registered module finalizers exactly once.
            unsafe { raw::luax_close(state.cast()) };
            // mlua owns this allocator, but its Drop would close the native state
            // a second time. This matches the external ownership in boot.rs.
            mem::forget(lua);
        }
        if let Some(platform) = self.platform.take() {
            platform.destroy();
        }
        failures
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        for failure in self.close() {
            tracing::error!("graphics: closing the state during unwinding: {failure}");
        }
    }
}
