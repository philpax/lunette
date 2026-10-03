//! Regressions for the native plugin attachment: cancellation, panics,
//! request ordering, stale handles, retention, drain budgets, and diagnostics.

extern crate lunette_lovr;

use std::{
    cell::Cell,
    panic::{AssertUnwindSafe, catch_unwind},
    rc::Rc,
};

use lunette::plugin::attachment;
use mlua::{Function, Lua, Table, Value};

mod plugin_support;

fn state() -> mlua::Result<(Lua, Table)> {
    plugin_support::native_state()
}

fn run_fixture(lua: &Lua, plugin: &Table, name: &str) -> mlua::Result<()> {
    let source = match name {
        "cancelled_initializer" => include_str!("plugin_attachment/cancelled_initializer.luau"),
        "panic" => include_str!("plugin_attachment/panic.luau"),
        "after_panic" => include_str!("plugin_attachment/after_panic.luau"),
        "requests" => include_str!("plugin_attachment/requests.luau"),
        "stale_effects" => include_str!("plugin_attachment/stale_effects.luau"),
        "fan_out" => include_str!("plugin_attachment/fan_out.luau"),
        "diagnostics" => include_str!("plugin_attachment/diagnostics.luau"),
        other => return Err(mlua::Error::runtime(format!("unknown fixture {other}"))),
    };
    let callback: Function = lua.load(source).set_name(name).eval()?;
    callback.call((plugin.clone(),))
}

#[test]
fn a_cancelled_initializer_error_is_not_a_load_failure() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    run_fixture(&lua, &plugin, "cancelled_initializer")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn a_panicking_callback_does_not_wedge_the_attachment() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    lua.globals().set(
        "panic_now",
        lua.create_function(|_, ()| -> mlua::Result<()> {
            panic!("plugin callback panic");
        })?,
    )?;
    let unwound = catch_unwind(AssertUnwindSafe(|| run_fixture(&lua, &plugin, "panic")));
    assert!(unwound.is_err(), "the panic did not reach the caller");
    assert!(
        !attachment::callback_active(&lua),
        "the callback depth outlived the panic"
    );
    run_fixture(&lua, &plugin, "after_panic")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn requests_apply_in_order_and_fail_where_they_are_made() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    run_fixture(&lua, &plugin, "requests")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn disposing_a_stale_effect_does_nothing() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    run_fixture(&lua, &plugin, "stale_effects")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn a_provider_reload_drains_every_dependent() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    run_fixture(&lua, &plugin, "fan_out")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn state_and_diagnostics_name_the_definition() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    run_fixture(&lua, &plugin, "diagnostics")?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(
        errors.len(),
        1,
        "a waiting consumer was reported: {errors:?}"
    );
    assert!(
        errors[0].starts_with("plugin load: audit failing plugin (instance ")
            && errors[0].contains("audit initializer failure"),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn a_removed_instance_releases_its_configuration() -> mlua::Result<()> {
    let (lua, plugin) = state()?;
    let dropped = Rc::new(Cell::new(false));
    let witness = lua.create_userdata(plugin_support::DropWitness(Rc::clone(&dropped)))?;
    let setup: Function = lua
        .load(
            r#"
      return function(plugin, payload)
        retained_runtime = plugin.runtime()
        local definition = plugin.define({}, {}, function(context, config)
          context:effect(function()
            return function() assert(config ~= nil) end
          end)
          return {}
        end)
        local instance = retained_runtime:use(definition, payload)
        instance:enable()
        instance:dispose()
      end
    "#,
        )
        .eval()?;
    setup.call::<()>((plugin, witness))?;
    lua.gc_collect()?;
    lua.gc_collect()?;
    assert!(dropped.get(), "a removed instance kept its configuration");
    assert!(!lua.globals().get::<Value>("retained_runtime")?.is_nil());
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}
