//! Policy integration through the production plugin facade and native lifecycle.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_sources;
mod plugin_support;

#[test]
fn policy_providers_compose_and_release_caller_resources() -> mlua::Result<()> {
    run(include_str!("plugin_policy/fixtures/policy.luau"))
}

#[test]
fn tags_are_held_excluded_laid_out_and_announced() -> mlua::Result<()> {
    run(include_str!("plugin_policy/fixtures/tags.luau"))
}

/// Runs a fixture against the real providers, with the native fixture's
/// layer claims and matrices.
fn run(fixture: &str) -> mlua::Result<()> {
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
    lua.load(include_str!("plugin_policy/fixtures/native.luau"))
        .exec()?;
    lua.load(fixture).exec()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
