//! Real configuration modules and plugin attachment with unmanaged boundaries substituted.
use std::{fs, path::Path};

use lunette::{
    plugin::{attachment, declarations},
    reload,
};
use mlua::{Function, Lua, Table};

pub fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
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
    native.set(
        "reload",
        lua.create_function(|lua, ()| {
            let forget: Function = lua.globals().get("forgetSubscriptions")?;
            match reload::reload(lua, &|| {
                forget
                    .call::<()>(())
                    .unwrap_or_else(|error| panic!("forget subscriptions: {error}"));
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
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for (directory, alias) in [
        ("lua/lunette-plugin", "@lunette-plugin"),
        ("lua/lunette-contracts", "@lunette-contracts"),
        ("lua/lunette-plugins", "@lunette-plugins"),
        ("lua/mullion", "@mullion"),
        ("etc/xdg/lunette", ""),
    ] {
        register(&lua, &loaders, &root.join(directory), alias)?;
    }
    lua.load(include_str!("native.lua"))
        .set_name("desktop unmanaged boundaries")
        .exec()?;
    Ok(lua)
}

fn register(lua: &Lua, loaders: &Table, directory: &Path, prefix: &str) -> mlua::Result<()> {
    for entry in fs::read_dir(directory).map_err(mlua::Error::external)? {
        let path = entry.map_err(mlua::Error::external)?.path();
        let stem = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .ok_or_else(|| mlua::Error::external("module name is not utf8"))?;
        let name = if prefix.is_empty() {
            stem.to_owned()
        } else {
            format!("{prefix}/{stem}")
        };
        if path.is_dir() {
            register(lua, loaders, &path, &name)?;
        } else if path.extension().is_some_and(|extension| extension == "lua") {
            let name = if stem == "init" { prefix } else { &name };
            let source = fs::read_to_string(&path).map_err(mlua::Error::external)?;
            loaders.set(
                name,
                lua.load(&source)
                    .set_name(path.to_string_lossy())
                    .into_function()?,
            )?;
        }
    }
    Ok(())
}

pub fn start(lua: &Lua) -> mlua::Result<()> {
    lua.load("require 'main'; lovr.load()")
        .set_name("shipped desktop startup")
        .exec()
}

pub fn shutdown(lua: &Lua) -> mlua::Result<Vec<String>> {
    let errors = attachment::shutdown_all(lua);
    lua.load("assertResourcesReleased()").exec()?;
    Ok(errors)
}

pub fn execute(lua: &Lua, source: &str) -> mlua::Result<()> {
    lua.load(source).set_name("desktop scenario").exec()
}

pub fn callback(lua: &Lua, name: &str) -> mlua::Result<Function> {
    lua.globals().get::<Table>("lovr")?.get(name)
}
