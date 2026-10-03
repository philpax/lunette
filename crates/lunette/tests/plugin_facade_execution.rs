//! Execution tests for the public Lua plugin facade against the production
//! native declaration installer.

extern crate lunette_lovr;

use std::{cell::Cell, rc::Rc};

use lunette::plugin::{attachment, declarations};
use mlua::{Function, Lua, Table, UserData, Value};

mod plugin_facade_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
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
    for (name, source) in plugin_facade_sources::FACADE_SOURCES {
        preload.set(name, lua.load(source).set_name(name).into_function()?)?;
    }

    Ok(lua)
}

fn run_fixture(lua: &Lua, name: &str) -> mlua::Result<()> {
    run_fixture_value(lua, name).map(|_| ())
}

fn run_fixture_value(lua: &Lua, name: &str) -> mlua::Result<Value> {
    let source = match name {
        "local_plugin_with_only_the_facade" => {
            include_str!("plugin_facade_execution/local_plugin_with_only_the_facade.luau")
        }
        "definition_require_inert" => {
            include_str!("plugin_facade_execution/definition_require_inert.luau")
        }
        "multiple_provisions_runtime" => {
            include_str!("plugin_facade_execution/multiple_provisions_runtime.luau")
        }
        "failure" => include_str!("plugin_facade_execution/failure.luau"),
        "provision_failures" => include_str!("plugin_facade_execution/provision_failures.luau"),
        "cancellation" => include_str!("plugin_facade_execution/cancellation.luau"),
        "payload_release" => include_str!("plugin_facade_execution/payload_release.luau"),
        "revocation" => include_str!("plugin_facade_execution/revocation.luau"),
        "subscriptions" => include_str!("plugin_facade_execution/subscriptions.luau"),
        "ownership_helpers" => include_str!("plugin_facade_execution/ownership_helpers.luau"),
        "schema_mismatch" => include_str!("plugin_facade_execution/schema_mismatch.luau"),
        "error_positions" => include_str!("plugin_facade_execution/error_positions.luau"),
        "child_enabled" => include_str!("plugin_facade_execution/child_enabled.luau"),
        "spec_validation" => include_str!("plugin_facade_execution/spec_validation.luau"),
        "options" => include_str!("plugin_facade_execution/options.luau"),
        "declared_access" => include_str!("plugin_facade_execution/declared_access.luau"),
        "quarantine_pending_provider" => {
            include_str!("plugin_facade_execution/quarantine_pending_provider.luau")
        }
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
    let errors = plugin_support::shutdown(&lua);
    let expected = [
        "missing provision missing",
        "duplicate provision duplicate",
        "provision nil_value was nil",
        "is not declared",
        "initializer must return nothing",
        "escaped initializer failure",
        "partial initializer failure",
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
    // The initializer raises the cancellation its own disable caused. A
    // cancelled load is not a failure, so nothing is reported.
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected errors: {errors:?}");
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
    assert!(plugin_support::shutdown(&lua).is_empty());
    lua.gc_collect()?;
    assert!(dropped.get());
    Ok(())
}

#[test]
fn local_plugin_with_only_the_facade() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "local_plugin_with_only_the_facade")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn definition_require_inert() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "definition_require_inert")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn multiple_provisions_runtime() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "multiple_provisions_runtime")?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "diagnostics: {errors:?}");
    assert!(
        errors[0].contains("missing provision spare"),
        "diagnostics: {errors:?}"
    );
    Ok(())
}

#[test]
fn a_context_reaches_only_declared_capabilities_while_current() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "declared_access")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn a_kept_service_is_revoked_with_its_provider_and_never_writable() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "revocation")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn context_subscriptions_end_with_their_activation() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "subscriptions")?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(
        errors[0].contains("answers the function that cancels it"),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn owns_and_acquire_follow_the_owner_check() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "ownership_helpers")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn a_schema_mismatch_blocks_the_consumer_and_is_reported() -> mlua::Result<()> {
    let lua = state()?;
    let diagnostic: String = lua.unpack(run_fixture_value(&lua, "schema_mismatch")?)?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(errors[0].contains(&diagnostic), "{errors:?} {diagnostic}");
    Ok(())
}

#[test]
fn plugin_errors_keep_their_position_and_traceback() -> mlua::Result<()> {
    let lua = state()?;
    let membership: String = lua.unpack(run_fixture_value(&lua, "error_positions")?)?;
    assert!(
        membership.starts_with("[string \"error_positions\"]:"),
        "a membership error points at the plugin code: {membership}"
    );
    assert!(
        membership
            .contains("plugin require: capability local/positions-undeclared@1 is not declared"),
        "{membership}"
    );
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "{errors:?}");
    let report = &errors[0];
    let line = report
        .lines()
        .find(|line| line.contains("initializer position failure"))
        .unwrap_or_default();
    assert!(
        line.contains("[string \"error_positions\"]:26: initializer position failure"),
        "the error keeps the position it was raised at: {report}"
    );
    assert!(
        !line.contains("adapter"),
        "the adapter adds no position: {report}"
    );
    assert!(
        report.contains("raiseFromInitializer"),
        "the traceback reaches the raising function: {report}"
    );
    assert!(
        report.starts_with("plugin load: failing (instance "),
        "the report names the definition by its declared name: {report}"
    );
    Ok(())
}

#[test]
fn malformed_specs_are_rejected_at_the_caller_with_the_problem_named() -> mlua::Result<()> {
    let lua = state()?;
    let messages: Vec<String> = lua.unpack(run_fixture_value(&lua, "spec_validation")?)?;
    let expected = [
        "plugin define: unknown field require; the fields are name, requires, provides, and init",
        "plugin define: name is a string, not a nil",
        "plugin define: name is empty",
        "plugin define: init is a function, not a nil",
        "plugin define: requires is a table of capabilities, not a string",
        "plugin define: provides is a table of capabilities, not a number",
        "plugin define: a definition is a table of fields, not a function",
        "plugin capability: unknown field witness; the fields are name and schema",
        "plugin capability: name is a string, not a nil",
        "plugin capability: name is empty",
        "plugin capability: schema is a positive integer, not 1.5",
        "plugin capability: schema is a positive integer, not 0",
        "plugin capability: schema is a number, not a nil",
    ];
    assert_eq!(messages.len(), expected.len(), "{messages:#?}");
    for (message, expected) in messages.iter().zip(expected) {
        assert!(
            message.starts_with("[string \"spec_validation\"]:"),
            "the error points at the caller: {message}"
        );
        assert!(message.ends_with(expected), "{message}");
    }
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn a_child_is_enabled_when_it_is_installed() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "child_enabled")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}

#[test]
fn a_provider_awaiting_quarantine_keeps_serving_its_consumers() -> mlua::Result<()> {
    let lua = state()?;
    run_fixture(&lua, "quarantine_pending_provider")?;
    // The failed disposal raised to its caller and is not reported again. The
    // consumer, still enabled, then waits on a quarantined provider.
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(
        errors[0].contains("is quarantined after a cleanup failure"),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn the_facade_exports_no_unbound_contract_tokens() -> mlua::Result<()> {
    let lua = state()?;
    let contract: Value = lua
        .load("return require('@lunette-plugin').contract")
        .eval()?;
    assert!(contract.is_nil());
    Ok(())
}

#[test]
fn a_capability_from_a_retired_epoch_is_named_as_retired() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(
        "old_capability = require('@lunette-plugin').capability { name = 'local/retired', schema = 1 }",
    )
    .exec()?;
    assert!(attachment::shutdown_all(&lua).is_empty());
    let result = lua
        .load(
            "return require('@lunette-plugin').define { name = 'retired', requires = { old = old_capability }, init = function() end }",
        )
        .exec();
    let message = result
        .err()
        .map(|error| error.to_string())
        .unwrap_or_default();
    assert!(
        message.contains(
            "declaration field 'old' contains a capability from a retired contract epoch"
        ),
        "{message}"
    );
    Ok(())
}

#[test]
fn configuration_merges_records_replaces_other_values_and_names_unknown_options() -> mlua::Result<()>
{
    let lua = state()?;
    run_fixture(&lua, "options")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}
