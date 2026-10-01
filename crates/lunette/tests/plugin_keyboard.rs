//! Keyboard coverage through the production facade and native runtime.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

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
    macro_rules! module {
        ($name:literal, $file:literal) => {
            modules.set(
                $name,
                lua.load(include_str!($file))
                    .set_name($name)
                    .into_function()?,
            )?;
        };
    }
    module!("@lunette-plugin", "../../../lua/lunette-plugin/init.lua");
    module!(
        "@lunette-plugin/adapter",
        "../../../lua/lunette-plugin/adapter.lua"
    );
    module!(
        "@lunette-contracts/owner",
        "../../../lua/lunette-contracts/owner.lua"
    );
    module!(
        "@lunette-contracts/vocabulary",
        "../../../lua/lunette-contracts/vocabulary.lua"
    );
    module!(
        "@lunette-contracts/surface",
        "../../../lua/lunette-contracts/surface.lua"
    );
    module!(
        "@lunette-contracts/keyboard",
        "../../../lua/lunette-contracts/keyboard.lua"
    );
    module!(
        "@lunette-contracts/panels",
        "../../../lua/lunette-contracts/panels.lua"
    );
    module!(
        "@lunette-contracts/interaction",
        "../../../lua/lunette-contracts/interaction.lua"
    );
    module!(
        "@lunette-plugins/keyboard",
        "../../../lua/lunette-plugins/keyboard/init.lua"
    );
    module!(
        "@lunette-plugins/keyboard/service",
        "../../../lua/lunette-plugins/keyboard/service.lua"
    );
    module!(
        "@lunette-plugins/keyboard/layout",
        "../../../lua/lunette-plugins/keyboard/layout.lua"
    );
    module!(
        "@lunette-plugins/keyboard/draw",
        "../../../lua/lunette-plugins/keyboard/draw.lua"
    );
    module!(
        "@lunette-plugins/panels",
        "../../../lua/lunette-plugins/panels/init.lua"
    );
    module!(
        "@lunette-plugins/panels/events",
        "../../../lua/lunette-plugins/panels/events.lua"
    );
    module!(
        "@lunette-plugins/panels/layer",
        "../../../lua/lunette-plugins/panels/layer.lua"
    );
    module!(
        "@lunette-plugins/panels/raycast",
        "../../../lua/lunette-plugins/panels/raycast.lua"
    );
    module!(
        "@lunette-plugins/interaction",
        "../../../lua/lunette-plugins/interaction/init.lua"
    );
    module!(
        "@lunette-plugins/interaction/grab",
        "../../../lua/lunette-plugins/interaction/grab.lua"
    );
    module!(
        "@lunette-plugins/interaction/pose",
        "../../../lua/lunette-plugins/interaction/pose.lua"
    );
    module!("@mullion/keycodes", "../../../lua/mullion/keycodes.lua");
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
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
