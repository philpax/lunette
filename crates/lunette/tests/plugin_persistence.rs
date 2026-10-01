//! Persistence bindings and mounted specs through the production plugin attachment.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

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
    assert_eq!(lua.globals().get::<u32>("persistenceSpecCases")?, 48);
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
    for (name, source) in [
        (
            "@lunette-plugin",
            include_str!("../../../lua/lunette-plugin/init.lua"),
        ),
        (
            "@lunette-plugin/adapter",
            include_str!("../../../lua/lunette-plugin/adapter.lua"),
        ),
        (
            "@lunette-contracts/owner",
            include_str!("../../../lua/lunette-contracts/owner.lua"),
        ),
        (
            "@lunette-contracts/surface",
            include_str!("../../../lua/lunette-contracts/surface.lua"),
        ),
        (
            "@lunette-contracts/vocabulary",
            include_str!("../../../lua/lunette-contracts/vocabulary.lua"),
        ),
        (
            "@lunette-contracts/panels",
            include_str!("../../../lua/lunette-contracts/panels.lua"),
        ),
        (
            "@lunette-contracts/tags",
            include_str!("../../../lua/lunette-contracts/tags.lua"),
        ),
        (
            "@lunette-contracts/rules",
            include_str!("../../../lua/lunette-contracts/rules.lua"),
        ),
        (
            "@lunette-plugins/panels",
            include_str!("../../../lua/lunette-plugins/panels/init.lua"),
        ),
        (
            "@lunette-plugins/panels/events",
            include_str!("../../../lua/lunette-plugins/panels/events.lua"),
        ),
        (
            "@lunette-plugins/panels/layer",
            include_str!("../../../lua/lunette-plugins/panels/layer.lua"),
        ),
        (
            "@lunette-plugins/panels/raycast",
            include_str!("../../../lua/lunette-plugins/panels/raycast.lua"),
        ),
        (
            "@lunette-plugins/tags",
            include_str!("../../../lua/lunette-plugins/tags/init.lua"),
        ),
        (
            "@lunette-plugins/tags/service",
            include_str!("../../../lua/lunette-plugins/tags/service.lua"),
        ),
        (
            "@lunette-plugins/rules",
            include_str!("../../../lua/lunette-plugins/rules/init.lua"),
        ),
        (
            "@lunette-plugins/rules/policy",
            include_str!("../../../lua/lunette-plugins/rules/policy.lua"),
        ),
        (
            "@lunette-plugins/rules/service",
            include_str!("../../../lua/lunette-plugins/rules/service.lua"),
        ),
        (
            "@mullion/persist",
            include_str!("../../../lua/mullion/persist/init.lua"),
        ),
        (
            "@mullion/persist/format",
            include_str!("../../../lua/mullion/persist/format.lua"),
        ),
        (
            "@mullion/pose",
            include_str!("../../../lua/mullion/pose.lua"),
        ),
        ("@spec/suite", include_str!("../../../lua/spec/suite.lua")),
        ("@spec/expect", include_str!("../../../lua/spec/expect.lua")),
        (
            "@spec/mullion/persist/file_spec",
            include_str!("../../../lua/spec/mullion/persist/file_spec.lua"),
        ),
        (
            "@spec/mullion/persist/arrangement_spec",
            include_str!("../../../lua/spec/mullion/persist/arrangement_spec.lua"),
        ),
        (
            "@spec/mullion/persist/format_spec",
            include_str!("../../../lua/spec/mullion/persist/format_spec.lua"),
        ),
    ] {
        loaders.set(name, lua.load(source).set_name(name).into_function()?)?;
    }
    lua.load(include_str!("plugin_persistence/native.lua"))
        .set_name("persistence unmanaged boundaries")
        .exec()?;
    Ok(lua)
}
