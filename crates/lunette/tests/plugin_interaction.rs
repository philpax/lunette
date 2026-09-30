//! Interaction lifecycle and grab behavior through the production plugin facade.
extern crate lunette_lovr;

use lunette::plugin::{attachment, declarations};
use mlua::{Function, Lua, Table, Value};

#[test]
fn pointers_share_grab_state_and_release_on_owner_cleanup() -> mlua::Result<()> {
    let lua = Lua::new();
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
            "@lunette-contracts/vocabulary",
            include_str!("../../../lua/lunette-contracts/vocabulary.lua"),
        ),
        (
            "@lunette-contracts/surface",
            include_str!("../../../lua/lunette-contracts/surface.lua"),
        ),
        (
            "@lunette-contracts/panels",
            include_str!("../../../lua/lunette-contracts/panels.lua"),
        ),
        (
            "@lunette-contracts/interaction",
            include_str!("../../../lua/lunette-contracts/interaction.lua"),
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
            "@lunette-plugins/interaction",
            include_str!("../../../lua/lunette-plugins/interaction/init.lua"),
        ),
        (
            "@lunette-plugins/interaction/grab",
            include_str!("../../../lua/lunette-plugins/interaction/grab.lua"),
        ),
        (
            "@lunette-plugins/interaction/pose",
            include_str!("../../../lua/lunette-plugins/interaction/pose.lua"),
        ),
    ] {
        modules.set(name, lua.load(source).set_name(name).into_function()?)?;
    }
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
    lua.load(include_str!("plugin_interaction/runtime.lua"))
        .set_name("interaction/runtime")
        .exec()?;
    let errors = attachment::shutdown_all(&lua);
    assert_eq!(
        errors.len(),
        2,
        "provider and owner cleanup errors: {errors:?}"
    );
    assert!(
        errors
            .iter()
            .all(|error| error.contains("native button release failed")),
        "unexpected cleanup errors: {errors:?}"
    );
    Ok(())
}
