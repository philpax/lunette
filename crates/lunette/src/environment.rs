//! Protects the standard library in a session's shared global environment so Luau's builtin fast paths stay valid.
//!
//! Luau compiles calls such as `math.min(a, b)` and loops over `pairs(t)` to fast paths that assume the builtins are
//! unchanged, and enables them only in a safe environment. Without protection the environment cannot be safe, so every
//! builtin call looks up its import and calls the C function. [`protect`] freezes the standard library tables, moves the
//! builtin names behind the global table's metatable so that rebinding one raises an error instead of being silently
//! ignored by compiled fast paths, and marks the environment safe.
//!
//! Load-time import resolution stays disabled. A safe environment would otherwise resolve imports such as
//! `lovr.graphics.newBuffer` once when a chunk loads, and later rebinding of those tables would leave stale values.

use std::ffi::c_int;

use mlua::{Lua, Table, Value, ffi};

/// Standard library tables, which become read-only.
const LIBRARIES: &[&str] = &[
    "bit32",
    "buffer",
    "class",
    "coroutine",
    "debug",
    "integer",
    "math",
    "os",
    "quaternion",
    "string",
    "table",
    "utf8",
    "vector",
];

/// Global functions that Luau compiles to fast paths, which cannot be rebound.
const FUNCTIONS: &[&str] = &[
    "assert",
    "getmetatable",
    "ipairs",
    "next",
    "pairs",
    "pcall",
    "rawequal",
    "rawget",
    "rawlen",
    "rawset",
    "select",
    "setmetatable",
    "tonumber",
    "tostring",
    "type",
    "typeof",
    "unpack",
    "xpcall",
];

/// Freezes the standard library, prevents its global names from being rebound, and marks the environment safe.
///
/// Call it once per state, after the host installs its own globals and before configuration code runs. Chunks loaded
/// earlier keep working and take the fast paths from then on. Writing a library field raises Luau's read-only error,
/// and assigning one of the protected global names raises an error that names it. Other globals stay writable.
pub fn protect(lua: &Lua) -> mlua::Result<()> {
    let globals = lua.globals();
    if globals.metatable().is_some() {
        return Err(mlua::Error::runtime(
            "lua environment: the global table already has a metatable",
        ));
    }
    let builtins = lua.create_table()?;
    for name in LIBRARIES.iter().chain(FUNCTIONS) {
        let value: Value = globals.raw_get(*name)?;
        if let Value::Table(library) = &value {
            library.set_readonly(true);
        }
        if !value.is_nil() {
            builtins.raw_set(*name, value)?;
            globals.raw_set(*name, Value::Nil)?;
        }
    }
    builtins.set_readonly(true);
    let metatable = lua.create_table()?;
    metatable.raw_set("__index", builtins.clone())?;
    metatable.raw_set(
        "__newindex",
        lua.create_function(move |_, (target, key, value): (Table, Value, Value)| {
            if builtins.raw_get::<Value>(&key)?.is_nil() {
                target.raw_set(key, value)
            } else {
                Err(mlua::Error::runtime(format!(
                    "lua environment: the standard library global {} cannot be replaced",
                    key.to_string()?
                )))
            }
        })?,
    )?;
    metatable.set_readonly(true);
    globals.set_metatable(Some(metatable))?;
    // SAFETY: `exec_raw` locks the live VM and restores the stack; both calls only set flags on it.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            lua_setresolveimports(state, 0);
            ffi::lua_setsafeenv(state, ffi::LUA_GLOBALSINDEX, 1);
        })
    }
}

unsafe extern "C-unwind" {
    // Exported by the shared LÖVR library's Luau fork.
    fn lua_setresolveimports(state: *mut ffi::lua_State, enabled: c_int);
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests fail at the operation that violates the contract"
)]
mod tests;
