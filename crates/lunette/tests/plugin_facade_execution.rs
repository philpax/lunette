//! Execution tests for the public Lua plugin facade.
//!
//! The fixtures load the checked-in facade modules and call their returned
//! functions against the production native declaration installer. Only module
//! lookup and the readonly bridge are supplied by this test.

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

    Ok(lua)
}

fn run_fixture(lua: &Lua, name: &str) -> mlua::Result<()> {
    run_fixture_value(lua, name).map(|_| ())
}

fn run_fixture_value(lua: &Lua, name: &str) -> mlua::Result<Value> {
    let source = match name {
        "local_plugin_without_mullion" => {
            include_str!("plugin_facade_execution/local_plugin_without_mullion.lua")
        }
        "definition_require_inert" => {
            include_str!("plugin_facade_execution/definition_require_inert.lua")
        }
        "multiple_provisions_runtime" => {
            include_str!("plugin_facade_execution/multiple_provisions_runtime.lua")
        }
        "failure" => include_str!("plugin_facade_execution/failure.lua"),
        "provision_failures" => include_str!("plugin_facade_execution/provision_failures.lua"),
        "cancellation" => include_str!("plugin_facade_execution/cancellation.lua"),
        "payload_release" => include_str!("plugin_facade_execution/payload_release.lua"),
        other => return Err(mlua::Error::runtime(format!("unknown fixture {other}"))),
    };
    let callback: Function = lua.load(source).set_name(name).eval()?;
    let plugin: Table = lua.load("return require '@lunette-plugin'").eval()?;
    callback.call((plugin,))
}

#[test]
fn fixture_runner_invokes_returned_callback_and_propagates_failures() -> mlua::Result<()> {
    let lua = state()?;
    let result = run_fixture(&lua, "failure");
    assert!(matches!(result, Err(error) if error.to_string().contains("facade fixture failure")));
    Ok(())
}

struct DropWitness(Rc<Cell<bool>>);

impl UserData for DropWitness {}

impl Drop for DropWitness {
    fn drop(&mut self) {
        self.0.set(true);
    }
}

#[test]
fn provision_failures_roll_back_and_publish_no_consumers() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "provision_failures")?;
    let errors = attachment::shutdown_all(&lua);
    let expected = [
        "missing provision missing",
        "duplicate provision duplicate",
        "provision nil_value was nil",
        "capability is not declared",
        "initializer must return nothing",
        "escaped initializer failure",
        "partial initializer failure",
        "requires missing contract local/failure-cancelled@1",
    ];
    assert_eq!(errors.len(), expected.len(), "diagnostics: {errors:?}");
    for message in expected {
        assert!(
            errors.iter().any(|error| error.contains(message)),
            "missing {message}: {errors:?}"
        );
    }
    Ok(())
}

#[test]
fn cancellation_during_effect_rolls_back_once_without_publication() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "cancellation")?;
    let errors = attachment::shutdown_all(&lua);
    assert!(
        errors
            .iter()
            .any(|error| error.contains("plugin effect: acquisition cancelled")),
        "cancellation diagnostic absent: {errors:?}"
    );
    Ok(())
}

#[test]
fn service_payload_is_released_with_an_escaped_provision_callback() -> mlua::Result<()> {
    let lua = state()?;
    let dropped = Rc::new(Cell::new(false));
    let witness = lua.create_userdata(DropWitness(Rc::clone(&dropped)))?;
    lua.globals().set("payload_witness", witness)?;
    let escaped = run_fixture_value(&lua, "payload_release")?;
    lua.globals().set("escaped_provide", escaped)?;
    lua.globals().set("payload_witness", Value::Nil)?;
    assert!(!dropped.get());
    assert!(attachment::shutdown_all(&lua).is_empty());
    lua.gc_collect()?;
    assert!(dropped.get());
    Ok(())
}

#[test]
fn local_plugin_without_mullion() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "local_plugin_without_mullion")?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn definition_require_inert() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "definition_require_inert")?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn multiple_provisions_runtime() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "multiple_provisions_runtime")?;
    let errors = attachment::shutdown_all(&lua);
    let expected = [
        "provision missing was nil",
        "missing provision spare",
        "duplicate provision duplicate",
        "initializer must return nothing",
    ];
    assert_eq!(errors.len(), expected.len(), "diagnostics: {errors:?}");
    for message in expected {
        assert!(
            errors.iter().any(|error| error.contains(message)),
            "missing {message}: {errors:?}"
        );
    }
    Ok(())
}
