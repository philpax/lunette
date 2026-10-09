//! Host lifecycle witnesses for plugin attachment retirement.
//!
//! These tests use a Lua state and the attachment runtime. External Lua close uses the
//! actual state.

#![expect(
    clippy::expect_used,
    reason = "the lifecycle witness uses expectations to report violated ordering and ownership contracts"
)]

use std::{cell::Cell, mem::ManuallyDrop, rc::Rc};

use lunette::{
    mirrors::NoMonitors,
    plugin::{attachment, declarations},
    reload,
};
use mlua::{Function, Lua, Table};

use crate::plugin_support::DropWitness;

mod plugin_support;

#[test]
fn reload_retires_the_attachment_before_rebuilding_the_epoch() -> mlua::Result<()> {
    let lua = configured_state()?;
    let module = lua.create_table()?;
    declarations::install(&lua, &module)?;
    let plugin: Table = module.get("plugin")?;
    lua.globals().set("plugin", plugin.clone())?;
    lua.load(
        r#"
        cleanup_order = {}
        old_active = false
        old_definition = plugin.define({}, {}, function(context, config)
          old_active = context:active()
          context:effect(function()
            return function()
              cleanup_order[#cleanup_order + 1] = 'runtime'
            end
          end)
          return {}
        end)
        old_runtime = plugin.runtime()
        old_instance = old_runtime:use(old_definition, {})
        old_instance:enable()
        "#,
    )
    .exec()?;

    let forget_subscriptions = || {
        lua.load("cleanup_order[#cleanup_order + 1] = 'subscriptions'")
            .exec()
            .expect("subscription cleanup witness runs");
    };
    set_reload_configuration(&lua)?;
    reload::reload(&lua, &NoMonitors, &forget_subscriptions).map_err(mlua::Error::external)?;

    assert_eq!(
        lua.load("return table.concat(cleanup_order, ',')")
            .eval::<String>()?,
        "runtime,subscriptions"
    );
    assert!(!lunette::plugin::host::callback_active(&lua));

    lua.globals().set("old_active", false)?;
    let (stale_ok, stale_error) = lua
        .load(
            "return pcall(function() local stale = new_runtime:use(old_definition, {}); stale:enable() end)",
        )
        .eval::<(bool, mlua::Value)>()?;
    assert!(
        !stale_ok,
        "a definition from the retired epoch must not activate in a new runtime"
    );
    let stale_message = stale_error.to_string()?;
    assert!(
        stale_message.contains("belongs to a retired contract epoch"),
        "a stale definition should be rejected when it is used, got {stale_message}"
    );
    assert!(!lua.globals().get::<bool>("old_active")?);

    assert!(
        lua.globals().get::<bool>("new_active")?,
        "the same contract identity must activate in the rebuilt epoch"
    );
    Ok(())
}

/// The boot path closes the Lua state externally and does not drop its mlua
/// handle, so a reference the host still holds is dropped after the state is
/// gone. The fork's closed-state guard is what makes that drop inert.
#[test]
fn a_reference_dropped_after_external_close_does_not_touch_the_state() -> mlua::Result<()> {
    let state = ExternalState::new();
    let dropped = Rc::new(Cell::new(false));
    let factory: Function = state
        .lua
        .load(
            "return function(witness) return function() assert(witness ~= nil); return 42 end end",
        )
        .eval()?;
    let callback: Function = factory.call(
        state
            .lua
            .create_userdata(DropWitness(Rc::clone(&dropped)))?,
    )?;
    drop(factory);
    assert_eq!(callback.call::<i64>(())?, 42);
    state.close();
    assert!(
        dropped.get(),
        "closing the state collects the callback's payload"
    );
    // The closed state invalidates the callback, but dropping it remains safe.
    drop(callback);
    Ok(())
}

fn set_reload_configuration(lua: &Lua) -> mlua::Result<()> {
    lua.load(
        r#"
        package.preload.main = function()
          new_token = plugin.contract('test/epoch', 1)
          new_definition = plugin.define({}, {}, function(context, config)
            new_active = context:active()
            return {}
          end)
          new_runtime = plugin.runtime()
          new_instance = new_runtime:use(new_definition, {})
          new_instance:enable()
          return {}
        end
        "#,
    )
    .exec()
}

fn configured_state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    attachment::install(&lua)?;
    lua.load(
        r#"
        lovr = { handlers = {} }
        arg = {}
        package = { loaded = {}, preload = {} }
        require = function(name)
          if package.loaded[name] ~= nil then return package.loaded[name] end
          local loader = assert(package.preload[name], 'missing module: ' .. name)
          local value = loader()
          if value == nil then value = true end
          package.loaded[name] = value
          return value
        end
        package.preload.main = function()
          function lovr.load() end
          return {}
        end
        "#,
    )
    .exec()?;
    Ok(lua)
}

struct ExternalState {
    lua: ManuallyDrop<Lua>,
    raw: *mut mlua::ffi::lua_State,
}

impl ExternalState {
    fn new() -> Self {
        let lua = Lua::new();
        let raw = lua.exec_raw_lua(|raw| raw.state());
        Self {
            lua: ManuallyDrop::new(lua),
            raw,
        }
    }

    fn close(self) {
        self.lua.exec_raw_lua(|raw| raw.mark_closed());
        // SAFETY: the terminal seam has retired every callback and this is the
        // unique external state owner; no Lua callback is executing.
        unsafe { mlua::ffi::lua_close(self.raw) };
        std::mem::forget(self);
    }
}

impl Drop for ExternalState {
    fn drop(&mut self) {
        self.lua.exec_raw_lua(|raw| raw.mark_closed());
        // SAFETY: this is the unique owner, and no callback is executing.
        unsafe { mlua::ffi::lua_close(self.raw) };
    }
}
