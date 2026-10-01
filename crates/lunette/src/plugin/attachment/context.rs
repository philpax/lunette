//! Operations performed through a plugin context: reading services,
//! acquiring and disposing effects, installing children, and checking owners.

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
            callback_call, lifecycle_operation, record_failure, rollback_effects, use_definition,
        },
        state::{ActivationAuthority, DeclarationField, DefinitionData, RuntimeState},
    },
    graph::{ActivationId, AttachmentState, Binding, InstanceId},
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
        let view = state
            .graph
            .attachment(context.instance)
            .ok()
            .flatten()
            .filter(|view| view.activation == context.activation)
            .ok_or(fail(ContextReason::Stale))?;
        let definition = state
            .instances
            .get(&context.instance)
            .map(|instance| Rc::clone(&instance.definition))
            .ok_or(fail(ContextReason::InstanceGone))?;
        let mut values = Vec::with_capacity(view.bindings.len());
        for binding in &view.bindings {
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

/// Acquires a resource and registers its inverse with the activation.
///
/// When the activation is cancelled while the acquisition runs, the inverse
/// is not left registered: a loading activation rolls back every inverse, and
/// an active one runs just the new inverse, before the cancellation is raised.
pub(super) fn effect(
    lua: &Lua,
    context: &PluginContext,
    acquire: Function,
) -> mlua::Result<PluginEffect> {
    let runtime = live_context(context, ContextOperation::Effect, Require::Resources)?;
    lifecycle_operation(lua, &runtime, || {
        let inverse = callback_call(&runtime, || acquire.call::<Function>(()))?;
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
            ordinal
        };
        if live_context(context, ContextOperation::Effect, Require::Resources).is_err() {
            withdraw_acquisition(lua, &runtime, context, ordinal)?;
            return Err(AttachmentError::Context {
                operation: ContextOperation::Effect,
                reason: ContextReason::Cancelled,
            }
            .into());
        }
        Ok(PluginEffect {
            runtime: Rc::downgrade(&runtime),
            instance: context.instance,
            activation: context.activation,
            ordinal,
        })
    })
}

fn withdraw_acquisition(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    context: &PluginContext,
    ordinal: u64,
) -> Result<(), AttachmentError> {
    let loading = runtime
        .borrow()
        .graph
        .attachment(context.instance)
        .ok()
        .flatten()
        .is_some_and(|view| {
            view.activation == context.activation && view.state == AttachmentState::Loading
        });
    if loading {
        rollback_effects(lua, runtime, context.instance, context.activation)?;
        return Ok(());
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
    let result = callback_call(runtime, || inverse.call::<()>(()));
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

/// Runs an effect's inverse once.
///
/// Disposing an effect whose runtime is closed, whose instance was removed,
/// or whose activation has ended does nothing: that activation's cleanup has
/// already run the inverse or will run it. A failing inverse quarantines the
/// activation and is raised to the caller.
pub(super) fn dispose_effect(lua: &Lua, effect: &PluginEffect) -> mlua::Result<()> {
    let Some(runtime) = effect.runtime.upgrade() else {
        return Ok(());
    };
    let inverse = {
        let mut state = runtime.borrow_mut();
        let current = state
            .graph
            .attachment(effect.instance)
            .ok()
            .flatten()
            .is_some_and(|view| view.activation == effect.activation);
        if !current {
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
        let result = callback_call(&runtime, || inverse.call::<()>(()));
        if let Err(error) = result {
            // The authority stays cleanup-only: a quarantined activation acquires nothing more.
            quarantine(&runtime, effect.instance, effect.activation)?;
            let mut state = runtime.borrow_mut();
            let plugin = state.label(effect.instance);
            if let Some(instance) = state.instances.get_mut(&effect.instance) {
                instance.last_diagnostic = Some(
                    PluginFailure {
                        phase: FailurePhase::Disposal,
                        plugin,
                        cause: FailureCause::Callback(error.clone()),
                    }
                    .to_string(),
                );
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

/// Checks that `caller` is a live context of an instance bound to this
/// provider's current generation.
///
/// Both contexts are native userdata, so the identity is the context itself
/// rather than any value a caller can construct.
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
    let provider_generation = state
        .graph
        .attachment(provider.instance)
        .ok()
        .flatten()
        .and_then(|view| view.generation)
        .ok_or(fail(ContextReason::Stale))?;
    let caller_view = state
        .graph
        .attachment(caller.instance)
        .ok()
        .flatten()
        .filter(|view| {
            view.activation == caller.activation
                && matches!(
                    view.state,
                    AttachmentState::Loading | AttachmentState::Active
                )
        })
        .ok_or(fail(ContextReason::CallerInactive))?;
    let permitted = state
        .instances
        .get(&caller.instance)
        .is_some_and(|instance| instance.authority.permits_resources(caller.activation));
    if !permitted {
        return Err(fail(ContextReason::CallerInactive));
    }
    if !caller_view.bindings.iter().any(|binding| {
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
            .attachment(context.instance)
            .ok()
            .flatten()
            .is_some_and(|view| {
                view.activation == context.activation
                    && matches!(
                        view.state,
                        AttachmentState::Loading | AttachmentState::Active
                    )
            })
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Require {
    /// The activation may acquire resources: it is loading or active, holds
    /// resource authority, and has not been cancelled.
    Resources,
    /// The activation is published and holds resource authority.
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
        let view = state
            .graph
            .attachment(context.instance)
            .ok()
            .flatten()
            .filter(|view| view.activation == context.activation)
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
                if view.state != AttachmentState::Active {
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

// Successful explicit disposal ends only this inverse's scope; rollback never restores authority.
fn leave_cleanup(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
    previous: ActivationAuthority,
) {
    let mut state = runtime.borrow_mut();
    let live = state
        .graph
        .attachment(instance)
        .ok()
        .flatten()
        .is_some_and(|view| {
            view.activation == activation
                && matches!(
                    view.state,
                    AttachmentState::Loading | AttachmentState::Active
                )
        });
    if live
        && let Some(record) = state.instances.get_mut(&instance)
        && record.authority == ActivationAuthority::Cleanup(activation)
    {
        record.authority = previous;
    }
}

/// Quarantines an activation whose inverse failed. No drain runs inside a
/// lifecycle operation, so the activation is still the current one.
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
