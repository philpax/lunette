//! Keyboard coverage through the production facade and native runtime.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_sources;
mod plugin_support;

#[test]
fn keyboard_uses_real_dependency_providers() -> mlua::Result<()> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "collectResources",
        lua.create_function(|lua, ()| lua.gc_collect())?,
    )?;
    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
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
    lua.load(include_str!("plugin_keyboard/fixture.lua"))
        .exec()?;
    let callback: Function = lua
        .load(include_str!("plugin_keyboard/behavior.lua"))
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
