//! Real configuration modules and plugin attachment with unmanaged boundaries substituted.
use std::path::Path;

use lunette::{
    lua::keys::{KeyCodes, locking_modifier_names, modifier_names},
    plugin::declarations,
    reload,
};
use mlua::{Function, Lua, Table};

#[path = "../plugin_sources/mod.rs"]
mod plugin_sources;
#[path = "../plugin_support/mod.rs"]
mod plugin_support;

/// A state whose configuration is the shipped one.
pub fn state() -> mlua::Result<Lua> {
    state_for(Path::new("etc/xdg/lunette"))
}

/// A state whose configuration is the directory `configuration`, relative to
/// the repository root, registered as the configuration root resolves it.
pub fn state_for(configuration: &Path) -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, flag): (Table, bool)| {
            table.set_readonly(flag);
            Ok(())
        })?,
    )?;
    let package = lua.create_table()?;
    let loaded = lua.create_table()?;
    let loaders = lua.create_table()?;
    package.set("loaded", loaded)?;
    package.set("preload", loaders.clone())?;
    lua.globals().set("package", package)?;
    lua.globals().set("modules", loaders.clone())?;
    lua.load(include_str!("require.lua"))
        .set_name("desktop module resolver")
        .exec()?;
    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    // The real key vocabulary, so the default rows and modifier sets resolve
    // to what a session hands them.
    native.set("keyCodes", lua.create_function(|_, ()| Ok(KeyCodes))?)?;
    native.set(
        "lockingModifierNames",
        lua.create_function(|_, ()| Ok(locking_modifier_names()))?,
    )?;
    native.set(
        "modifierNames",
        lua.create_function(|_, ()| Ok(modifier_names()))?,
    )?;
    native.set(
        "reload",
        lua.create_function(|lua, ()| {
            let clear: Function = lua.globals().get("clearSubscriptions")?;
            match reload::reload(lua, &|| {
                clear
                    .call::<()>(())
                    .unwrap_or_else(|error| panic!("clear subscriptions: {error}"));
            }) {
                Ok(()) => Ok((true, None)),
                Err(error) => Ok((false, Some(error.to_string()))),
            }
        })?,
    )?;
    loaders.set(
        "@lunette",
        lua.create_function(move |_, ()| Ok(native.clone()))?,
    )?;
    plugin_sources::register(&lua, &loaders)?;
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    plugin_sources::register_directory(&lua, &loaders, &root.join(configuration), "")?;
    loaders.set(
        "fixture/graph",
        lua.load(include_str!("graph.lua"))
            .set_name("desktop composition")
            .into_function()?,
    )?;
    lua.load(include_str!("native.lua"))
        .set_name("desktop unmanaged boundaries")
        .exec()?;
    Ok(lua)
}

pub fn start(lua: &Lua) -> mlua::Result<()> {
    lua.load("require 'main'; lovr.load()")
        .set_name("shipped desktop startup")
        .exec()
}

pub fn shutdown(lua: &Lua) -> mlua::Result<Vec<String>> {
    let errors = plugin_support::shutdown(lua);
    lua.load("assertResourcesReleased()").exec()?;
    Ok(errors)
}

pub fn execute(lua: &Lua, source: &str) -> mlua::Result<()> {
    lua.load(source).set_name("desktop scenario").exec()
}

pub fn callback(lua: &Lua, name: &str) -> mlua::Result<Function> {
    lua.globals().get::<Table>("lovr")?.get(name)
}
