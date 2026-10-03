//! Keyboard coverage through the production facade and native runtime.

extern crate lunette_lovr;

use lunette::lua::keys::{KeyCodes, locking_modifier_names, modifier_names};
use mlua::{Function, Lua, Value};

mod plugin_sources;
mod plugin_support;

/// A state with the real plugin roots, the real key vocabulary, and the
/// fixture's matrices and seats.
fn state() -> mlua::Result<Lua> {
    let (lua, native) = plugin_support::module_state(plugin_sources::register)?;
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
