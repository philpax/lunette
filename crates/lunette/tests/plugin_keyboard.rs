//! Keyboard coverage through the production facade and native runtime.

extern crate lunette_lovr;

use lunette::{
    lua::keys::{KeyCodes, locking_modifier_names, modifier_names},
    plugin::declarations,
};
use mlua::{Function, Lua, Table, Value};

mod plugin_sources;
mod plugin_support;

/// A state with the real plugin roots, the real key vocabulary, and the
/// fixture's matrices and seats.
fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "collectResources",
        lua.create_function(|lua, ()| lua.gc_collect())?,
    )?;
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
    lua.globals().set("native", native)?;
    let modules = lua.create_table()?;
    plugin_sources::register(&lua, &modules)?;
    lua.globals().set("modules", modules)?;
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, flag): (Table, bool)| {
            table.set_readonly(flag);
            Ok(())
        })?,
    )?;
    lua.load(include_str!("plugin_keyboard/fixture.luau"))
        .exec()?;
    Ok(lua)
}

#[test]
fn keyboard_uses_real_dependency_providers() -> mlua::Result<()> {
    let lua = state()?;
    let callback: Function = lua
        .load(include_str!("plugin_keyboard/behavior.luau"))
        .eval()?;
    let _: Value = callback.call(())?;
    // The one failure is the release the fixture makes fail, reported once
    // against the owner whose cleanup raised.
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(
        errors[0].contains("native keyboard release failed"),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn rows_actions_layers_and_hooks_follow_the_options() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_keyboard/hooks.luau"))
        .set_name("keyboard hooks")
        .exec()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}
