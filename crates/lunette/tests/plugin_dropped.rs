//! The dropped event is owned by the panels provider and emitted by interaction.

extern crate lunette_lovr;

use lunette::plugin::{attachment, declarations};
use mlua::{Function, Lua, Table, Value};

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    lua.globals().set(
        "collectResources",
        lua.create_function(|lua, ()| lua.gc_collect())?,
    )?;
    let loaded = lua.create_table()?;
    let modules = lua.create_table()?;
    loaded.set("@lunette", {
        let native = lua.create_table()?;
        declarations::install(&lua, &native)?;
        native
    })?;
    lua.globals().set("loaded", loaded)?;
    lua.globals().set("modules", modules.clone())?;
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

    lua.load(
        r#"
        local native = require '@lunette'
        native.claimLayer = function()
          return { dead = false, granted = false, width = 1, height = 1, release = function() end }
        end
        local function matrix(value)
          local m = { x = value and value.x or 0, y = value and value.y or 0, z = value and value.z or 0 }
          function m:getPosition() return self.x, self.y, self.z end
          function m:unpack() return 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, self.x, self.y, self.z, 1 end
          function m:set(other) self.x, self.y, self.z = other.x, other.y, other.z; return self end
          function m:invert() self.x, self.y, self.z = -self.x, -self.y, -self.z; return self end
          function m:mul(other) self.x, self.y, self.z = self.x + other.x, self.y + other.y, self.z + other.z; return self end
          function m:translate(x, y, z) self.x, self.y, self.z = self.x + x, self.y + y, self.z + z; return self end
          return m
        end
        lovr = { math = { newMat4 = matrix, mat4 = matrix } }
        "#,
    )
    .exec()?;
    Ok(lua)
}

#[test]
fn dropped_is_owned_filtered_disposable_and_emitted_before_pose_storage() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_dropped/fixture.lua"))
        .set_name("plugin_dropped/fixture.lua")
        .exec()?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
