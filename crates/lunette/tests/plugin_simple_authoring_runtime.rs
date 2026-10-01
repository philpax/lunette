//! VM-only execution of the production plugin facade against native attachment checks.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_facade_sources;
mod plugin_support;

#[test]
fn runtime_enforces_declared_access_publication_and_native_lifecycle() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_simple_authoring/runtime.luau"))
        .set_name("plugin-facade-runtime")
        .exec()?;
    let errors = plugin_support::shutdown(&lua);
    for expected in [
        "missing provision service",
        "duplicate provision service",
        "is not declared",
        "provision service was nil",
        "initializer must return nothing",
        "production partial initializer failure",
    ] {
        assert!(
            errors.iter().any(|error| error.contains(expected)),
            "missing {expected}: {errors:#?}"
        );
    }
    assert_eq!(errors.len(), 6, "{errors:#?}");
    Ok(())
}

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, readonly): (Table, bool)| {
            table.set_readonly(readonly);
            Ok(())
        })?,
    )?;

    let loaded = lua.create_table()?;
    let preload = lua.create_table()?;
    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, _: String| Ok(native.clone()))?,
    )?;
    for (name, source) in plugin_facade_sources::FACADE_SOURCES {
        preload.set(name, lua.load(source).set_name(name).into_function()?)?;
    }
    lua.globals().set(
        "require",
        lua.create_function(move |_, name: String| {
            let cached: Value = loaded.get(name.clone())?;
            if !cached.is_nil() {
                return Ok(cached);
            }
            let loader: Function = preload.get(name.clone())?;
            let value: Value = loader.call(name.clone())?;
            loaded.set(name, value.clone())?;
            Ok(value)
        })?,
    )?;
    Ok(lua)
}
