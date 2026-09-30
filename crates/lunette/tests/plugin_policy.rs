//! Policy integration through the production plugin facade and native lifecycle.

extern crate lunette_lovr;

use lunette::plugin::{attachment, declarations};
use mlua::{Function, Lua, Table, Value};

#[test]
fn policy_providers_compose_and_release_caller_resources() -> mlua::Result<()> {
    let lua = Lua::new();
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
            "@lunette-contracts/layout",
            include_str!("../../../lua/lunette-contracts/layout.lua"),
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
            "@lunette-plugins/rules",
            include_str!("../../../lua/lunette-plugins/rules/init.lua"),
        ),
        (
            "@lunette-plugins/layout/arc",
            include_str!("../../../lua/lunette-plugins/layout/arc/init.lua"),
        ),
        (
            "@lunette-plugins/tags/service",
            include_str!("../../../lua/lunette-plugins/tags/service.lua"),
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
            "@lunette-plugins/layout/arc/service",
            include_str!("../../../lua/lunette-plugins/layout/arc/service.lua"),
        ),
        (
            "@mullion/pose",
            include_str!("../../../lua/mullion/pose.lua"),
        ),
    ] {
        loaders.set(name, lua.load(source).set_name(name).into_function()?)?;
    }
    lua.load(include_str!("plugin_policy/fixtures/native.lua"))
        .exec()?;
    lua.load(include_str!("plugin_policy/fixtures/policy.lua"))
        .exec()?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
