//! Integration coverage for the error-display provider.
//!
//! The plugin facade and runtime, the panels provider, and the error-display
//! provider are real checked-in implementations. Only the unmanaged native
//! `onError` subscription seam is replaced by the fixture.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_support;

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

    let package = lua.create_table()?;
    let loaded = lua.create_table()?;
    let preload = lua.create_table()?;
    package.set("loaded", loaded)?;
    package.set("preload", preload.clone())?;
    lua.globals().set("package", package)?;
    lua.globals().set(
        "require",
        lua.create_function(|lua, name: String| {
            let package: Table = lua.globals().get("package")?;
            let loaded: Table = package.get("loaded")?;
            let preload: Table = package.get("preload")?;
            let cached: Value = loaded.get(name.clone())?;
            if !cached.is_nil() {
                return Ok(cached);
            }
            let loader: Function = preload.get(name.clone())?;
            let value: Value = loader.call(name.clone())?;
            let value = if value.is_nil() {
                Value::Boolean(true)
            } else {
                value
            };
            loaded.set(name, value.clone())?;
            Ok(value)
        })?,
    )?;

    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, _: String| Ok(native.clone()))?,
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
            "@lunette-contracts/error-display",
            include_str!("../../../lua/lunette-contracts/error-display.lua"),
        ),
        (
            "@lunette-contracts/owner",
            include_str!("../../../lua/lunette-contracts/owner.lua"),
        ),
        (
            "@lunette-contracts/panels",
            include_str!("../../../lua/lunette-contracts/panels.lua"),
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
            "@lunette-plugins/error-display",
            include_str!("../../../lua/lunette-plugins/error-display/init.lua"),
        ),
        (
            "@lunette-plugins/error-display/format",
            include_str!("../../../lua/lunette-plugins/error-display/format.lua"),
        ),
        (
            "@lunette-plugins/error-display/limiter",
            include_str!("../../../lua/lunette-plugins/error-display/limiter.lua"),
        ),
        (
            "@lunette-plugins/error-display/panel",
            include_str!("../../../lua/lunette-plugins/error-display/panel.lua"),
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
    ] {
        preload.set(name, lua.load(source).set_name(name).into_function()?)?;
    }

    Ok(lua)
}

#[test]
fn provider_preserves_native_errors_while_displaying_and_unloading_safely() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Function = lua
        .load(include_str!("plugin_error_display/error_display.lua"))
        .set_name("plugin_error_display/error_display.lua")
        .eval()?;

    fixture.call::<Value>(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
