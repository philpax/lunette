//! Interaction and focus lifecycle and behavior through the production plugin facade.
extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "collectResources",
        lua.create_function(|lua, ()| lua.gc_collect())?,
    )?;
    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    let loaded = lua.create_table()?;
    loaded.set("@lunette", native)?;
    lua.globals().set("loaded", loaded)?;
    let modules = lua.create_table()?;
    plugin_sources::register(&lua, &modules)?;
    lua.globals().set("modules", modules)?;
    lua.globals().set(
        "require",
        lua.create_function(|lua, name: String| {
            let loaded: Table = lua.globals().get("loaded")?;
            let cached: Value = loaded.get(name.clone())?;
            if !cached.is_nil() {
                return Ok(cached);
            }
            let modules: Table = lua.globals().get("modules")?;
            let loader: Function = modules.get(name.clone())?;
            let result: Value = loader.call(())?;
            loaded.set(name, result.clone())?;
            Ok(result)
        })?,
    )?;
    Ok(lua)
}

#[test]
fn pointers_share_grab_state_and_release_on_owner_cleanup() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_interaction/runtime.luau"))
        .set_name("interaction/runtime")
        .exec()?;
    // The first failing release is raised to the fixture's destroy call. The
    // second fails while its owner unloads, so it is reported against that
    // owner, and nothing else is.
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors.len() == 1 && errors[0].contains("native button release failed"),
        "unexpected cleanup errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn focus_grants_are_held_per_owner_and_seat_and_announced() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_interaction/focus.luau"))
        .set_name("interaction/focus")
        .exec()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected cleanup errors: {errors:?}");
    Ok(())
}
