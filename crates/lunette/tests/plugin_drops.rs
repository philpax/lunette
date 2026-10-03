//! The drops broker, and the interaction provider emitting through it.

extern crate lunette_lovr;

use mlua::Lua;

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let (lua, _) = plugin_support::module_state(plugin_sources::register)?;
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
fn drops_are_owned_disposable_protected_and_emitted_when_a_grab_ends() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_drops/fixture.luau"))
        .set_name("plugin_drops/fixture.luau")
        .exec()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
