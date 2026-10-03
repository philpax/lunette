//! Integration tests over the real native plugin attachment and its userdata.

extern crate lunette_lovr;

use std::{cell::Cell, rc::Rc};

use lunette::plugin::declarations;
use mlua::{Function, Lua, Table, UserData, Value};

mod plugin_facade_sources;
mod plugin_support;

fn state() -> mlua::Result<(Lua, Table)> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    let setreadonly = lua.create_function(|_, (table, readonly): (Table, bool)| {
        table.set_readonly(readonly);
        Ok(())
    })?;
    lua.globals().set("setreadonly", setreadonly)?;
    let module = lua.create_table()?;
    declarations::install(&lua, &module)?;
    let plugin = module.get("plugin")?;
    Ok((lua, plugin))
}

fn run_fixture(lua: &Lua, module: &Table, name: &str) -> mlua::Result<()> {
    let source = match name {
        "shutdown_stress" => include_str!("plugin_runtime/shutdown_stress.luau"),
        "cleanup_failure" => include_str!("plugin_runtime/cleanup_failure.luau"),
        "authority" => include_str!("plugin_runtime/authority.luau"),
        "identity" => include_str!("plugin_runtime/identity.luau"),
        "effects" => include_str!("plugin_runtime/effects.luau"),
        "fails" => include_str!("plugin_runtime/fails.luau"),
        "ownership" => include_str!("plugin_runtime/ownership.luau"),
        "reentrant" => include_str!("plugin_runtime/reentrant.luau"),
        "children" => include_str!("plugin_runtime/children.luau"),
        "malformed" => include_str!("plugin_runtime/malformed.luau"),
        "nested" => include_str!("plugin_runtime/nested.luau"),
        "cancel_reenable" => include_str!("plugin_runtime/cancel_reenable.luau"),
        "pending_cleanup" => include_str!("plugin_runtime/pending_cleanup.luau"),
        "cancel_boundary" => include_str!("plugin_runtime/cancel_boundary.luau"),
        "active_acquisition" => include_str!("plugin_runtime/active_acquisition.luau"),
        "active_provider_acquisition" => {
            include_str!("plugin_runtime/active_provider_acquisition.luau")
        }
        "inverse_reentry" => include_str!("plugin_runtime/inverse_reentry.luau"),
        "dependency_publication" => include_str!("plugin_runtime/dependency_publication.luau"),
        "rollback_authority" => include_str!("plugin_runtime/rollback_authority.luau"),
        "explicit_cleanup_authority" => {
            include_str!("plugin_runtime/explicit_cleanup_authority.luau")
        }
        "cancel" => include_str!("plugin_runtime/cancel.luau"),
        "quarantine" => include_str!("plugin_runtime/quarantine.luau"),
        "witness" => include_str!("plugin_runtime/witness.luau"),
        "stale" => include_str!("plugin_runtime/stale.luau"),
        "yield" => include_str!("plugin_runtime/yield.luau"),
        other => return Err(mlua::Error::runtime(format!("unknown fixture {other}"))),
    };
    let function: Function = lua.load(source).set_name(name).eval()?;
    function.call((module.clone(),))
}

#[test]
fn fixture_runner_invokes_returned_callback_and_propagates_failures() -> mlua::Result<()> {
    let (lua, module) = state()?;
    let result = run_fixture(&lua, &module, "fails");
    assert!(matches!(result, Err(error) if error.to_string().contains("fixture callback failure")));
    Ok(())
}

#[test]
fn leaked_effect_payload_is_released_by_shutdown() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "witness")?;
    lua.globals().set("witness_runtime", Value::Nil)?;
    lua.globals().set("witness_instance", Value::Nil)?;
    let payload: Table = lua.globals().get("witness_payload")?;
    assert!(!payload.get::<bool>("released")?);
    assert!(plugin_support::shutdown(&lua).is_empty());
    assert!(payload.get::<bool>("released")?);
    lua.gc_collect()?;
    Ok(())
}

#[test]
fn rollback_and_explicit_dispose_failures_quarantine() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "cleanup_failure")?;
    // The rollback failure happens while a drain loads the instance, so it is
    // reported. The explicit disposal failure is raised to its caller, and the
    // fixture asserts it through the instance's diagnostic.
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors
            .iter()
            .any(|error| error.contains("inverse failed rollback")),
        "{errors:?}"
    );
    assert!(
        !errors
            .iter()
            .any(|error| error.contains("inverse failed explicit")),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn cancelled_initializer_reenable_publishes_only_fresh_generation() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "cancel_reenable")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn pending_failed_cleanup_precedes_provider_and_parent_cleanup() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "pending_cleanup")?;
    // The failing disposal is raised to the fixture, which catches it.
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn cancellation_is_observed_at_acquisition_boundary() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "cancel_boundary")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn active_acquisition_serializes_close_disable_and_reload() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "active_acquisition")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn active_provider_acquisition_cancellation_preserves_graph_cleanup_order() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "active_provider_acquisition")?;
    // A consumer waiting for a disabled provider is not an error.
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected errors: {errors:?}");
    Ok(())
}

#[test]
fn reentrant_inverse_failure_quarantines_the_original_activation() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "inverse_reentry")?;
    // The withdrawn acquisition's failing inverse is reported; the explicit
    // disposal's failure is raised to the fixture instead.
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 1, "unexpected errors: {errors:?}");
    assert!(
        errors
            .iter()
            .all(|error| error.contains("reentrant inverse failure"))
    );
    Ok(())
}

#[test]
fn invalid_dependency_publication_retains_failed_rollback_allocation() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "dependency_publication")?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 4, "unexpected errors: {errors:?}");
    assert_eq!(
        errors
            .iter()
            .filter(|error| error.contains("dependency publication rollback failure"))
            .count(),
        2,
        "{errors:?}"
    );
    assert_eq!(
        errors
            .iter()
            .filter(|error| error.starts_with("plugin wiring: ")
                && error.contains("is quarantined after a cleanup failure"))
            .count(),
        2,
        "the observer must name the quarantined provider: {errors:?}"
    );
    Ok(())
}

#[test]
fn public_facade_rollback_uses_native_cleanup_authority() -> mlua::Result<()> {
    let (lua, module) = state()?;
    let fixture: Function = lua
        .load(include_str!("plugin_runtime/facade_cleanup_authority.luau"))
        .set_name("facade_cleanup_authority")
        .eval()?;
    let sources = lua.create_table()?;
    for (name, source) in plugin_facade_sources::FACADE_SOURCES {
        sources.set(name, source)?;
    }
    fixture.call::<()>((module, sources))?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 2, "unexpected errors: {errors:?}");
    assert!(
        errors
            .iter()
            .all(|error| error.contains("facade cleanup initializer failure")
                || error.contains("missing provision service")),
        "unexpected errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn explicit_cleanup_temporarily_revokes_resource_authority_and_preserves_live_owner()
-> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "explicit_cleanup_authority")?;
    // Both failing disposals are raised to the fixture, which asserts them.
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected errors: {errors:?}");
    Ok(())
}

#[test]
fn failed_load_rollback_revokes_resource_authority_before_inverses() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "rollback_authority")?;
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 9, "unexpected errors: {errors:?}");
    assert_eq!(
        errors
            .iter()
            .filter(|error| error.contains("rollback authority inverse failure"))
            .count(),
        3
    );
    assert!(
        errors.iter().all(|error| {
            error.contains("rollback authority") || error.contains("provided record")
        }),
        "unexpected errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn shutdown_bypasses_queue_and_action_limits() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "shutdown_stress")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn exact_caller_activation_and_cleanup_read_authority() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "authority")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn production_bindings_preserve_arbitrary_service_identity_and_share_definitions()
-> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "identity")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn production_bindings_roll_back_exact_provided_records_and_effects() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "effects")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn production_runtime_roots_survive_runtime_userdata_collection() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "ownership")?;
    lua.gc_collect()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn production_contexts_queue_reentrant_requests_and_bound_shutdown() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "reentrant")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn production_children_unload_before_parents() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "children")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn production_rejects_malformed_provisions_and_rolls_back_nested_acquisition() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "malformed")?;
    run_fixture(&lua, &module, "nested")?;
    let nested_events: Table = lua.globals().get("nested_events")?;
    assert_eq!(nested_events.raw_len(), 3);
    assert_eq!(nested_events.get::<String>(1)?, "outer-acquire");
    assert_eq!(nested_events.get::<String>(2)?, "inner-acquire");
    assert_eq!(nested_events.get::<String>(3)?, "inner-release");
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors
            .iter()
            .any(|error| error.contains("provided record has unexpected field")),
        "cleanup errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn production_rejects_stale_contexts_and_yielding_acquisition() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "stale")?;
    run_fixture(&lua, &module, "yield")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors.iter().any(|error| error.contains("yield")),
        "cleanup errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn production_cancels_loading_acquisition_before_publication() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "cancel")?;
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn production_releases_payload_and_quarantines_failed_cleanup() -> mlua::Result<()> {
    let (lua, module) = state()?;
    run_fixture(&lua, &module, "quarantine")?;
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors.iter().any(|error| error.contains("cleanup failed")),
        "cleanup errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn binding_requires_frozen_table_and_is_one_time() -> mlua::Result<()> {
    let (lua, module) = state()?;
    let contract: mlua::AnyUserData = module
        .get::<Function>("contract")?
        .call(("test/bind", 1_u64))?;
    let bind = module.get::<Function>("bind")?;
    let mutable = lua.create_table()?;
    assert!(
        bind.call::<()>((contract.clone(), mutable.clone()))
            .is_err()
    );
    mutable.set_readonly(true);
    bind.call::<()>((contract.clone(), mutable.clone()))?;
    assert!(bind.call::<()>((contract, mutable)).is_err());
    assert!(plugin_support::shutdown(&lua).is_empty());
    Ok(())
}

#[test]
fn failed_cleanup_releases_config_while_runtime_is_retained() -> mlua::Result<()> {
    let (lua, module) = state()?;
    let dropped = Rc::new(Cell::new(false));
    let witness = lua.create_userdata(DropWitness(Rc::clone(&dropped)))?;
    let setup: Function = lua
        .load(
            r#"
      return function(plugin, payload)
        retained_runtime = plugin.runtime()
        local definition = plugin.define({}, {}, function(context, config)
          context:effect(function()
            return function() assert(config ~= nil); error('retained cleanup failure') end
          end)
          return {}
        end)
        local instance = retained_runtime:use(definition, payload)
        instance:enable()
      end
    "#,
        )
        .eval()?;
    setup.call::<()>((module, witness))?;
    assert!(!dropped.get());
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors
            .iter()
            .any(|error| error.contains("retained cleanup failure"))
    );
    lua.gc_collect()?;
    lua.gc_collect()?;
    assert!(dropped.get(), "retained runtime kept failed config alive");
    assert!(!lua.globals().get::<Value>("retained_runtime")?.is_nil());
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
fn shutdown_releases_escaped_definition_initializer_references() -> mlua::Result<()> {
    let (lua, module) = state()?;
    let witness_dropped = Rc::new(Cell::new(false));
    let witness = lua.create_userdata(DropWitness(Rc::clone(&witness_dropped)))?;
    let contract: mlua::AnyUserData = module
        .get::<Function>("contract")?
        .call(("test/escaped", 1_u64))?;
    let provided = lua.create_table()?;
    provided.set("service", contract.clone())?;
    let required = lua.create_table()?;
    let factory: Function = lua
        .load(
            "return function(w) return function(_, _) local _ = w; return { service = {} } end end",
        )
        .eval()?;
    let init: Function = factory.call(witness)?;
    let definition: Value = module
        .get::<Function>("define")?
        .call((required, provided, init))?;
    let _escaped = definition;
    assert!(!witness_dropped.get());
    assert!(plugin_support::shutdown(&lua).is_empty());
    lua.gc_collect()?;
    assert!(witness_dropped.get());
    Ok(())
}
