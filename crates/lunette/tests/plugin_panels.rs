//! Execution coverage for the panels provider, with window, monitor, layer,
//! and pose values faked as unmanaged boundaries.

extern crate lunette_lovr;

use std::{cell::Cell, rc::Rc};

use mlua::{Function, Lua, Table, UserData, Value};

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let (lua, _) = plugin_support::module_state(plugin_sources::register)?;
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
            setCurve = function() end,
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
        local vectorMeta = {}
        vector = {
          pack = function(x, y, z)
            return setmetatable({ x = x, y = y, z = z }, vectorMeta)
          end,
        }
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
    let source = include_str!("plugin_panels/panels.luau");
    let callback: Function = lua.load(source).set_name("plugin_panels").eval()?;
    let _: Value = callback.call(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn a_raising_removal_listener_does_not_fail_the_drain_that_removed_the_panel() -> mlua::Result<()> {
    let lua = state()?;
    install_native_fakes(&lua)?;
    let callback: Function = lua
        .load(include_str!("plugin_panels/removal_during_drain.luau"))
        .set_name("plugin_panels/removal_during_drain.luau")
        .eval()?;
    let _: Value = callback.call(())?;
    // The listener's errors went to lunette.reportError, which the fixture
    // counted. No plugin load or cleanup failed because of them.
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "plugin failures: {errors:?}");
    Ok(())
}

#[test]
fn initial_claim_failure_keeps_registry_unchanged_and_allows_retry() -> mlua::Result<()> {
    let lua = state()?;
    install_native_fakes(&lua)?;
    lua.load(include_str!("plugin_panels/acquisition_failure.luau"))
        .set_name("plugin_panels/acquisition_failure.luau")
        .exec()?;
    let errors = plugin_support::shutdown(&lua);
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
        .load(include_str!("plugin_panels/retention.luau"))
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
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn visibility_overrides_chrome_curves_and_shape_hooks_follow_the_contract() -> mlua::Result<()> {
    let lua = state()?;
    install_native_fakes(&lua)?;
    let callback: Function = lua
        .load(include_str!("plugin_panels/visibility.luau"))
        .set_name("plugin_panels/visibility.luau")
        .eval()?;
    let _: Value = callback.call(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
