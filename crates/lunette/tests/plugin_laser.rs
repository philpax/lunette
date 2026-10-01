//! Real plugin-facade coverage for the LASER provider.
//!
//! The interaction and panels providers are the checked-in implementations.
//! Only the headset and seat boundaries are represented by fakes: those are
//! unmanaged native resources, while the plugin runtime, contexts, effects,
//! and interaction pointer registry are production implementations.

extern crate lunette_lovr;

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, Value};

mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "collectResources",
        lua.create_function(|lua, ()| lua.gc_collect())?,
    )?;
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
    native.set(
        "newSeat",
        lua.load(
            r#"return function(name)
  local seat = { name = name, dead = false }
  function seat:setFocus(_) return true end
  function seat:destroy() self.dead = true; return true end
  return seat
end"#,
        )
        .eval::<Function>()?,
    )?;
    lua.load(
        r#"
        events = { inputCalls = {}, haptic = {} }
        local vectorMeta = {}
        function vectorMeta.__index(value, key)
          if key == 'length' then
            return function(self)
              return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z)
            end
          end
          if key == 'unpack' then
            return function(self) return self.x, self.y, self.z end
          end
        end
        function vectorMeta.__mul(value, scale)
          if type(value) == 'table' and type(scale) == 'number' then
            return setmetatable({ x = value.x * scale, y = value.y * scale, z = value.z * scale }, vectorMeta)
          end
          return nil
        end
        vector = {
          pack = function(x, y, z)
            return setmetatable({ x = x, y = y, z = z }, vectorMeta)
          end,
        }
        local function matrix(value)
          local pose = {
            x = value and value.x or 0,
            y = value and value.y or 0,
            z = value and value.z or 0,
          }
          function pose:set(other)
            self.x, self.y, self.z = other.x, other.y, other.z
            return self
          end
          function pose:getPosition() return self.x, self.y, self.z end
          function pose:getOrientation() return 0, 0, 1, 0 end
          function pose:translate() return self end
          function pose:scale() return self end
          function pose:invert() return self end
          return pose
        end
        local pass = {
          lineCalls = 0,
          sphereCalls = 0,
          colors = {},
          laserColors = {},
          depthTestCalls = 0,
          depthWriteCalls = 0,
        }
        function pass:setColor(r, g, b, a)
          self.lastColor = { r, g, b, a }
          self.colors[#self.colors + 1] = self.lastColor
          if r ~= 1 or g ~= 1 or b ~= 1 or a ~= 1 then
            self.laserColors[#self.laserColors + 1] = self.lastColor
          end
        end
        function pass:setDepthTest(mode)
          self.depthTestCalls = self.depthTestCalls + 1
          self.lastDepthTest = mode
        end
        function pass:setDepthWrite(value)
          self.depthWriteCalls = self.depthWriteCalls + 1
          self.lastDepthWrite = value
        end
        function pass:line() self.lineCalls = self.lineCalls + 1 end
        function pass:sphere() self.sphereCalls = self.sphereCalls + 1 end
        events.pass = pass
        local headset = {
          vibrate = function(device, strength, duration, frequency)
            events.haptic[device] = (events.haptic[device] or 0) + 1
            events.lastHaptic = { device, strength, duration, frequency }
            return true
          end,
        }
        lovr = { headset = headset, math = { newMat4 = matrix, mat4 = matrix } }
        borrowedSeat = {
          dead = false,
          setFocus = function() return true end,
          destroy = function(self) self.dead = true; return true end,
        }
        "#,
    )
    .exec()?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, _: String| Ok(native.clone()))?,
    )?;
    preload.set(
        "@lunette-plugin",
        lua.load(include_str!("../../../lua/lunette-plugin/init.lua"))
            .set_name("@lunette-plugin/init.lua")
            .into_function()?,
    )?;
    preload.set(
        "@lunette-plugin/adapter",
        lua.load(include_str!("../../../lua/lunette-plugin/adapter.lua"))
            .set_name("@lunette-plugin/adapter.lua")
            .into_function()?,
    )?;

    for (name, source, path) in [
        (
            "laser",
            include_str!("../../../lua/lunette-contracts/laser.lua"),
            "lua/lunette-contracts/laser.lua",
        ),
        (
            "interaction",
            include_str!("../../../lua/lunette-contracts/interaction.lua"),
            "lua/lunette-contracts/interaction.lua",
        ),
        (
            "owner",
            include_str!("../../../lua/lunette-contracts/owner.lua"),
            "lua/lunette-contracts/owner.lua",
        ),
        (
            "panels",
            include_str!("../../../lua/lunette-contracts/panels.lua"),
            "lua/lunette-contracts/panels.lua",
        ),
        (
            "surface",
            include_str!("../../../lua/lunette-contracts/surface.lua"),
            "lua/lunette-contracts/surface.lua",
        ),
        (
            "vocabulary",
            include_str!("../../../lua/lunette-contracts/vocabulary.lua"),
            "lua/lunette-contracts/vocabulary.lua",
        ),
    ] {
        preload.set(
            format!("@lunette-contracts/{name}"),
            lua.load(source).set_name(path).into_function()?,
        )?;
    }

    for (name, source, path) in [
        (
            "panels",
            include_str!("../../../lua/lunette-plugins/panels/init.lua"),
            "lua/lunette-plugins/panels/init.lua",
        ),
        (
            "panels/events",
            include_str!("../../../lua/lunette-plugins/panels/events.lua"),
            "lua/lunette-plugins/panels/events.lua",
        ),
        (
            "panels/layer",
            include_str!("../../../lua/lunette-plugins/panels/layer.lua"),
            "lua/lunette-plugins/panels/layer.lua",
        ),
        (
            "panels/raycast",
            include_str!("../../../lua/lunette-plugins/panels/raycast.lua"),
            "lua/lunette-plugins/panels/raycast.lua",
        ),
        (
            "interaction",
            include_str!("../../../lua/lunette-plugins/interaction/init.lua"),
            "lua/lunette-plugins/interaction/init.lua",
        ),
        (
            "interaction/grab",
            include_str!("../../../lua/lunette-plugins/interaction/grab.lua"),
            "lua/lunette-plugins/interaction/grab.lua",
        ),
        (
            "interaction/pose",
            include_str!("../../../lua/lunette-plugins/interaction/pose.lua"),
            "lua/lunette-plugins/interaction/pose.lua",
        ),
        (
            "laser",
            include_str!("../../../lua/lunette-plugins/laser/init.lua"),
            "lua/lunette-plugins/laser/init.lua",
        ),
        (
            "laser/input",
            include_str!("../../../lua/lunette-plugins/laser/input.lua"),
            "lua/lunette-plugins/laser/input.lua",
        ),
        (
            "laser/draw",
            include_str!("../../../lua/lunette-plugins/laser/draw.lua"),
            "lua/lunette-plugins/laser/draw.lua",
        ),
        (
            "laser/registry",
            include_str!("../../../lua/lunette-plugins/laser/registry.lua"),
            "lua/lunette-plugins/laser/registry.lua",
        ),
    ] {
        preload.set(
            format!("@lunette-plugins/{name}"),
            lua.load(source).set_name(path).into_function()?,
        )?;
    }

    Ok(lua)
}

#[test]
fn production_facade_composes_interaction_and_laser_with_borrowed_seat_cleanup() -> mlua::Result<()>
{
    let lua = state()?;
    let seat = lua
        .load("return { dead = false, destroy = function(self) self.dead = true; return true end }")
        .eval::<Value>()?;
    lua.globals().set("fake_seat", seat)?;

    let fixture: Function = lua
        .load(include_str!("plugin_laser/facade.lua"))
        .set_name("plugin_laser/facade.lua")
        .eval()?;
    let plugin: Table = lua.load("return require '@lunette-plugin'").eval()?;
    let modules = lua.create_table()?;
    modules.set(
        "panels",
        lua.load("return require '@lunette-plugins/panels'")
            .eval::<Value>()?,
    )?;
    modules.set(
        "interaction",
        lua.load("return require '@lunette-plugins/interaction'")
            .eval::<Value>()?,
    )?;
    modules.set(
        "laser",
        lua.load("return require '@lunette-plugins/laser'")
            .eval::<Value>()?,
    )?;
    modules.set(
        "laserCapability",
        lua.load("return require '@lunette-contracts/laser'.capability")
            .eval::<Value>()?,
    )?;
    modules.set("events", lua.create_table()?)?;
    modules.set("seat", lua.globals().get::<Value>("fake_seat")?)?;
    fixture.call::<Value>((plugin, modules))?;

    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    let seat: Table = lua.globals().get("fake_seat")?;
    assert!(!seat.get::<bool>("dead")?);
    Ok(())
}

#[test]
fn followup_records_input_rendering_haptics_and_replacement_cleanup() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Function = lua
        .load(include_str!("plugin_laser/followup.lua"))
        .set_name("plugin_laser/followup.lua")
        .eval()?;
    let plugin: Table = lua.load("return require '@lunette-plugin'").eval()?;
    let modules = lua.create_table()?;
    modules.set(
        "panels",
        lua.load("return require '@lunette-plugins/panels'")
            .eval::<Value>()?,
    )?;
    modules.set(
        "interaction",
        lua.load("return require '@lunette-plugins/interaction'")
            .eval::<Value>()?,
    )?;
    modules.set(
        "interactionCapability",
        lua.load("return require '@lunette-contracts/interaction'.capability")
            .eval::<Value>()?,
    )?;
    modules.set(
        "laser",
        lua.load("return require '@lunette-plugins/laser'")
            .eval::<Value>()?,
    )?;
    modules.set(
        "laserCapability",
        lua.load("return require '@lunette-contracts/laser'.capability")
            .eval::<Value>()?,
    )?;
    let events: Table = lua.globals().get("events")?;
    let pass: Value = events.get("pass")?;
    modules.set("events", events)?;
    modules.set("pass", pass)?;
    modules.set("borrowedSeat", lua.globals().get::<Value>("borrowedSeat")?)?;
    fixture.call::<Value>((plugin, modules))?;

    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
