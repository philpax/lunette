//! Operations on plugin contexts, services, and resource effects.

use std::{cell::RefCell, rc::Rc};

use mlua::{Function, Lua, Table, Value};

use crate::plugin::{
    attachment::{
        PluginContext, PluginEffect, PluginInstance, Unknown,
        error::{
            AttachmentError, ContextOperation, ContextReason, FailureCause, FailurePhase,
            PluginFailure,
        },
        lifecycle::{
            callback_call, lifecycle_operation, record_failure, rollback_effects, run_inverse,
            use_definition,
        },
        snapshot::PluginEffectState,
        state::{ActivationAuthority, DefinitionData, DrainGuard, EffectState, RuntimeState},
    },
    contracts::DeclarationField,
    graph::{ActivationId, Binding, InstanceId, Stage},
};

pub(super) fn services(lua: &Lua, context: &PluginContext) -> Result<Unknown, AttachmentError> {
    let fail = |reason| AttachmentError::Context {
        operation: ContextOperation::Services,
        reason,
    };
    let runtime = context
        .runtime
        .upgrade()
        .ok_or(fail(ContextReason::RuntimeGone))?;
    let values = {
        let state = runtime.borrow();
        let (_, bindings) = state
            .graph
            .live(context.instance, context.activation)
            .ok_or(fail(ContextReason::Stale))?;
        let definition = state
            .instances
            .get(&context.instance)
            .map(|instance| Rc::clone(&instance.definition))
            .ok_or(fail(ContextReason::InstanceGone))?;
        let mut values = Vec::with_capacity(bindings.len());
        for binding in bindings {
            if !state.graph.binding_is_current(binding) {
                return Err(fail(ContextReason::ProviderStale));
            }
            let provider = state
                .instances
                .get(&binding.provider)
                .ok_or(fail(ContextReason::ProviderStale))?;
            let service = provider
                .service
                .clone()
                .ok_or(fail(ContextReason::ProviderStale))?;
            let provider_field = field_for(&provider.definition.provided, binding)
                .ok_or(fail(ContextReason::FieldMissing))?;
            let consumer_field = field_for(&definition.required, binding)
                .ok_or(fail(ContextReason::FieldMissing))?;
            values.push((consumer_field, provider_field, service));
        }
        values
    };
    let lua_error = |source| AttachmentError::Lua {
        operation: "services",
        source,
    };
    let table = lua.create_table().map_err(lua_error)?;
    for (consumer_field, provider_field, service) in values {
        let service: Table = lua.unpack(service).map_err(lua_error)?;
        let value: Value = service.get(provider_field).map_err(lua_error)?;
        table.set(consumer_field, value).map_err(lua_error)?;
    }
    Ok(Unknown(Value::Table(table)))
}

fn field_for(fields: &[DeclarationField], binding: &Binding) -> Option<String> {
    fields
        .iter()
        .find(|field| field.key == binding.contract)
        .map(|field| field.field.clone())
}

/// Acquires a resource and registers its inverse for the activation.
///
/// If cancellation races with acquisition, the inverse runs before cancellation
/// is raised. A loading activation rolls back all inverses; an active activation
/// runs the new inverse.
pub(super) fn effect(
    lua: &Lua,
    context: &PluginContext,
    acquire: Function,
) -> mlua::Result<PluginEffect> {
    let runtime = live_context(context, ContextOperation::Effect, Require::Resources)?;
    lifecycle_operation(lua, &runtime, || {
        register_effect(lua, &runtime, context, acquire)
    })
}

/// Registers an effect without draining queued lifecycle work on return.
///
/// The guard keeps lifecycle work deferred through acquisition and cancellation rollback.
pub(super) fn effect_deferred(
    lua: &Lua,
    context: &PluginContext,
    acquire: Function,
) -> mlua::Result<PluginEffect> {
    let runtime = live_context(context, ContextOperation::Effect, Require::Resources)?;
    let _draining = DrainGuard::enter(&runtime);
    register_effect(lua, &runtime, context, acquire)
}

fn register_effect(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    context: &PluginContext,
    acquire: Function,
) -> mlua::Result<PluginEffect> {
    let inverse = callback_call(runtime, || acquire.call::<Function>(()))?;
    let ordinal = {
        let mut state = runtime.borrow_mut();
        let instance =
            state
                .instances
                .get_mut(&context.instance)
                .ok_or(AttachmentError::Context {
                    operation: ContextOperation::Effect,
                    reason: ContextReason::InstanceGone,
                })?;
        let ordinal = instance.next_effect;
        instance.next_effect += 1;
        instance.effects.insert(ordinal, inverse);
        instance.effect_states.insert(
            ordinal,
            EffectState {
                activation: context.activation,
                state: PluginEffectState::Armed,
            },
        );
        ordinal
    };
    if live_context(context, ContextOperation::Effect, Require::Resources).is_err() {
        withdraw_acquisition(lua, runtime, context, ordinal)?;
        return Err(AttachmentError::Context {
            operation: ContextOperation::Effect,
            reason: ContextReason::Cancelled,
        }
        .into());
    }
    Ok(PluginEffect {
        runtime: Rc::downgrade(runtime),
        instance: context.instance,
        activation: context.activation,
        ordinal,
    })
}

fn withdraw_acquisition(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    context: &PluginContext,
    ordinal: u64,
) -> Result<(), AttachmentError> {
    let loading = matches!(
        runtime
            .borrow()
            .graph
            .live(context.instance, context.activation),
        Some((Stage::Loading, _))
    );
    if loading {
        return rollback_effects(lua, runtime, context.instance, context.activation);
    }
    let inverse = {
        let mut state = runtime.borrow_mut();
        state
            .instances
            .get_mut(&context.instance)
            .and_then(|instance| instance.effects.remove(&ordinal))
    };
    let Some(inverse) = inverse else {
        return Ok(());
    };
    let previous = enter_cleanup(runtime, context.instance, context.activation)?;
    let result = run_inverse(runtime, context.instance, ordinal, &inverse);
    leave_cleanup(runtime, context.instance, context.activation, previous);
    if let Err(error) = result {
        quarantine(runtime, context.instance, context.activation)?;
        let plugin = runtime.borrow().label(context.instance);
        record_failure(
            lua,
            runtime,
            PluginFailure {
                phase: FailurePhase::Rollback,
                plugin,
                cause: FailureCause::Callback(error),
            },
        );
    }
    Ok(())
}

/// A failing inverse quarantines the activation and is raised. Cleanup owns
/// inverses after the activation ends.
pub(super) fn dispose_effect(lua: &Lua, effect: &PluginEffect) -> mlua::Result<()> {
    let Some(runtime) = effect.runtime.upgrade() else {
        return Ok(());
    };
    let inverse = {
        let mut state = runtime.borrow_mut();
        if state
            .graph
            .live(effect.instance, effect.activation)
            .is_none()
        {
            return Ok(());
        }
        state
            .instances
            .get_mut(&effect.instance)
            .and_then(|instance| instance.effects.remove(&effect.ordinal))
    };
    let Some(inverse) = inverse else {
        return Ok(());
    };
    lifecycle_operation(lua, &runtime, || {
        let previous = enter_cleanup(&runtime, effect.instance, effect.activation)?;
        if let Err(error) = run_inverse(&runtime, effect.instance, effect.ordinal, &inverse) {
            // The authority stays cleanup-only: a quarantined activation acquires nothing more.
            quarantine(&runtime, effect.instance, effect.activation)?;
            let mut state = runtime.borrow_mut();
            let plugin = state.label(effect.instance);
            if let Some(instance) = state.instances.get_mut(&effect.instance) {
                let description = PluginFailure {
                    phase: FailurePhase::Disposal,
                    plugin,
                    cause: FailureCause::Callback(error.clone()),
                }
                .to_string();
                instance.last_diagnostic = Some(description.clone());
                instance.last_failure = Some(description);
            }
            return Err(error);
        }
        leave_cleanup(&runtime, effect.instance, effect.activation, previous);
        Ok(())
    })
}

pub(super) fn child(
    context: &PluginContext,
    definition: Rc<DefinitionData>,
    config: Value,
) -> Result<PluginInstance, AttachmentError> {
    let runtime = live_context(context, ContextOperation::Child, Require::Resources)?;
    use_definition(&runtime, definition, config, Some(context.instance))
}

/// The caller must be a live dependent bound to this provider generation.
///
/// Native userdata identity prevents caller-created values from acting as owners.
pub(super) fn check_owner(
    provider: &PluginContext,
    caller: &PluginContext,
) -> Result<(), AttachmentError> {
    let fail = |reason| AttachmentError::Context {
        operation: ContextOperation::CheckOwner,
        reason,
    };
    let runtime = live_context(provider, ContextOperation::CheckOwner, Require::Active)?;
    let caller_runtime = caller
        .runtime
        .upgrade()
        .ok_or(fail(ContextReason::RuntimeGone))?;
    if !Rc::ptr_eq(&runtime, &caller_runtime) {
        return Err(fail(ContextReason::ForeignRuntime));
    }
    let state = runtime.borrow();
    let Some((Stage::Active(provider_generation), _)) =
        state.graph.live(provider.instance, provider.activation)
    else {
        return Err(fail(ContextReason::Stale));
    };
    let caller_bindings = match state.graph.live(caller.instance, caller.activation) {
        Some((Stage::Loading | Stage::Active(_), bindings)) => bindings,
        _ => return Err(fail(ContextReason::CallerInactive)),
    };
    let permitted = state
        .instances
        .get(&caller.instance)
        .is_some_and(|instance| instance.authority.permits_resources(caller.activation));
    if !permitted {
        return Err(fail(ContextReason::CallerInactive));
    }
    if !caller_bindings.iter().any(|binding| {
        binding.provider == provider.instance && binding.generation == provider_generation
    }) {
        return Err(fail(ContextReason::NotOwner));
    }
    Ok(())
}

pub(super) fn context_active(context: &PluginContext) -> bool {
    let Some(runtime) = context.runtime.upgrade() else {
        return false;
    };
    let state = runtime.borrow();
    state
        .instances
        .get(&context.instance)
        .is_some_and(|instance| instance.authority.permits_resources(context.activation))
        && state
            .graph
            .activation_is_valid(context.instance, context.activation)
            .unwrap_or(false)
}

/// Reports whether this activation's services remain published.
///
/// A disposal failure does not stop service reads before unload.
pub(super) fn context_serving(context: &PluginContext) -> bool {
    context.runtime.upgrade().is_some_and(|runtime| {
        matches!(
            runtime
                .borrow()
                .graph
                .live(context.instance, context.activation),
            Some((Stage::Active(_), _))
        )
    })
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Require {
    Resources,
    Active,
}

fn live_context(
    context: &PluginContext,
    operation: ContextOperation,
    require: Require,
) -> Result<Rc<RefCell<RuntimeState>>, AttachmentError> {
    let fail = |reason| AttachmentError::Context { operation, reason };
    let runtime = context
        .runtime
        .upgrade()
        .ok_or(fail(ContextReason::RuntimeGone))?;
    {
        let state = runtime.borrow();
        let instance = state
            .instances
            .get(&context.instance)
            .ok_or(fail(ContextReason::InstanceGone))?;
        if !instance.authority.permits_resources(context.activation) {
            return Err(fail(ContextReason::CleanupOnly));
        }
        let (stage, _) = state
            .graph
            .live(context.instance, context.activation)
            .ok_or(fail(ContextReason::Stale))?;
        match require {
            Require::Resources => {
                let valid = state
                    .graph
                    .activation_is_valid(context.instance, context.activation)
                    .unwrap_or(false);
                if !valid {
                    return Err(fail(ContextReason::Cancelled));
                }
            }
            Require::Active => {
                if !matches!(stage, Stage::Active(_)) {
                    return Err(fail(ContextReason::Stale));
                }
            }
        }
    }
    Ok(runtime)
}

/// Revokes resource authority while an inverse runs, returning the authority
/// to restore if the activation is still live afterwards.
fn enter_cleanup(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<ActivationAuthority, AttachmentError> {
    let mut state = runtime.borrow_mut();
    let record = state
        .instances
        .get_mut(&instance)
        .ok_or(AttachmentError::Context {
            operation: ContextOperation::Cleanup,
            reason: ContextReason::InstanceGone,
        })?;
    Ok(std::mem::replace(
        &mut record.authority,
        ActivationAuthority::Cleanup(activation),
    ))
}

// Explicit disposal restores authority only while the allocation is live and no nested inverse failed.
fn leave_cleanup(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
    previous: ActivationAuthority,
) {
    let mut state = runtime.borrow_mut();
    let live = matches!(
        state.graph.live(instance, activation),
        Some((Stage::Loading | Stage::Active(_), _))
    );
    if live
        && matches!(state.graph.cleanup_failed(instance), Ok(false))
        && let Some(record) = state.instances.get_mut(&instance)
        && record.authority == ActivationAuthority::Cleanup(activation)
    {
        record.authority = previous;
    }
}

fn quarantine(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<(), AttachmentError> {
    runtime
        .borrow_mut()
        .graph
        .mark_cleanup_failed(instance, activation)
        .map_err(|source| AttachmentError::Graph {
            operation: "quarantine an activation",
            source,
        })
}
