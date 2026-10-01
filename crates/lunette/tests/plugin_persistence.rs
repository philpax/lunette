//! Persistence bindings and mounted specs through the production plugin attachment.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_sources;
mod plugin_support;

#[test]
fn persistence_bindings_follow_provider_activations() -> mlua::Result<()> {
    let lua = persistence_vm()?;
    lua.load(include_str!("plugin_persistence/runtime.lua"))
        .set_name("persistence runtime")
        .exec()?;
    assert!(lua.globals().get::<bool>("persistenceRuntimeVerified")?);
    // Three outages suspend three consumers, which wait for the provider
    // without reporting an error.
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected runtime errors: {errors:?}");
    Ok(())
}

#[test]
fn mounted_persistence_specs_run_every_case() -> mlua::Result<()> {
    let lua = persistence_vm()?;
    lua.load(include_str!("plugin_persistence/specs.lua"))
        .set_name("persistence specs")
        .exec()?;
    assert_eq!(lua.globals().get::<u32>("persistenceSpecCases")?, 53);
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

fn persistence_vm() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, flag): (Table, bool)| {
            table.set_readonly(flag);
            Ok(())
        })?,
    )?;
    let loaders = lua.create_table()?;
    let loaded = lua.create_table()?;
    lua.globals().set(
        "require",
        lua.create_function({
            let loaders = loaders.clone();
            move |_, name: String| {
                let cached: Value = loaded.get(name.clone())?;
                if !cached.is_nil() {
                    return Ok(cached);
                }
                let loader: Function = loaders.get(name.clone())?;
                let value: Value = loader.call(())?;
                loaded.set(name, value.clone())?;
                Ok(value)
            }
        })?,
    )?;
    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    loaders.set(
        "@lunette",
        lua.create_function(move |_, ()| Ok(native.clone()))?,
    )?;
    plugin_sources::register(&lua, &loaders)?;
    for (name, source) in [
        ("@spec/suite", include_str!("../../../lua/spec/suite.lua")),
        ("@spec/expect", include_str!("../../../lua/spec/expect.lua")),
        (
            "@spec/lunette-desktop/persist/file_spec",
            include_str!("../../../lua/spec/lunette-desktop/persist/file_spec.lua"),
        ),
        (
            "@spec/lunette-desktop/persist/arrangement_spec",
            include_str!("../../../lua/spec/lunette-desktop/persist/arrangement_spec.lua"),
        ),
        (
            "@spec/lunette-desktop/persist/format_spec",
            include_str!("../../../lua/spec/lunette-desktop/persist/format_spec.lua"),
        ),
    ] {
        loaders.set(name, lua.load(source).set_name(name).into_function()?)?;
    }
    lua.load(include_str!("plugin_persistence/native.lua"))
        .set_name("persistence unmanaged boundaries")
        .exec()?;
    Ok(lua)
}
