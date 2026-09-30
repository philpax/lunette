//! Execution coverage for the neutral panels provider.
//!
//! The plugin facade and lifecycle are production bindings. Window, monitor,
//! layer, and pose values are Lua fakes because they are unmanaged boundaries;
//! the provider itself is the real module loaded from the checked-in tree.

extern crate lunette_lovr;

use std::{cell::Cell, rc::Rc};

use lunette::plugin::{attachment, declarations};
use mlua::{Function, Lua, Table, UserData, Value};

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
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

    let require = lua.create_function(|lua, name: String| {
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
    })?;
    lua.globals().set("require", require)?;

    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, _: String| Ok(native.clone()))?,
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
            "@lunette-contracts/panels",
            include_str!("../../../lua/lunette-contracts/panels.lua"),
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
    ] {
        preload.set(name, lua.load(source).set_name(name).into_function()?)?;
    }

    Ok(lua)
}

fn install_native_fakes(lua: &Lua) -> mlua::Result<()> {
    lua.load(
        r#"
        local lunette = require '@lunette'
        claims = {}
        claimCount = 0
        shaderCreated = 0
        shaderReleased = 0
        lunette.claimLayer = function(options)
          local layer = {
            viewports = {},
            setViewport = function(self, x, y, width, height)
              self.viewports[#self.viewports + 1] = { x, y, width, height }
            end,
            setPosition = function() end,
            setOrientation = function() end,
            setDimensions = function() end,
          }
          local claim = {
            dead = false,
            granted = false,
            width = options.width,
            height = options.height,
            layer = false,
          }
          function claim:release()
            if self.dead then return false end
            self.dead = true
            self.layer = false
            return true
          end
          claims[#claims + 1] = claim
          return claim
        end
        lovr = {
          graphics = {
            newShader = function()
              shaderCreated = shaderCreated + 1
              local shader = {}
              function shader:release()
                shaderReleased = shaderReleased + 1
              end
              return shader
            end,
          },
          math = {
            newMat4 = function(value)
              local pose = { value = value }
              function pose:set(other) self.value = other; return self end
              function pose:getPosition() return 0, 0, -2 end
              function pose:getOrientation() return 0, 0, 1, 0 end
              function pose:scale() return self end
              function pose:translate() return self end
              return pose
            end,
            mat4 = function(value)
              return lovr.math.newMat4(value)
            end,
          },
        }
        "#,
    )
    .exec()
}

#[test]
fn provider_uses_real_facade_with_unmanaged_native_fakes() -> mlua::Result<()> {
    let lua = state()?;
    install_native_fakes(&lua)?;
    let source = include_str!("plugin_panels/panels.lua");
    let callback: Function = lua.load(source).set_name("plugin_panels").eval()?;
    let _: Value = callback.call(())?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn initial_claim_failure_keeps_registry_unchanged_and_allows_retry() -> mlua::Result<()> {
    let lua = state()?;
    install_native_fakes(&lua)?;
    lua.load(include_str!("plugin_panels/acquisition_failure.lua"))
        .set_name("plugin_panels/acquisition_failure.lua")
        .exec()?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

struct Payload(Rc<Cell<usize>>);

impl UserData for Payload {}

impl Drop for Payload {
    fn drop(&mut self) {
        self.0.set(self.0.get() + 1);
    }
}

#[test]
fn destroyed_panels_release_payloads_while_provider_is_active() -> mlua::Result<()> {
    let lua = state()?;
    install_native_fakes(&lua)?;
    let fixture: Table = lua
        .load(include_str!("plugin_panels/retention.lua"))
        .set_name("panel_retention")
        .eval()?;
    let cycle: Function = fixture.get("cycle")?;
    let dropped = Rc::new(Cell::new(0));
    for count in 1..=64 {
        cycle.call::<()>((
            lua.create_userdata(Payload(dropped.clone()))?,
            count % 2 == 0,
        ))?;
        lua.gc_collect()?;
        lua.gc_collect()?;
        assert_eq!(dropped.get(), count, "destroyed panel retained its source");
    }
    fixture.get::<Function>("close")?.call::<()>(())?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
