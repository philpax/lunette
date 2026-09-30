//! Runtime graph execution, callback validation, and cleanup for the plugin attachment.

use std::{
    cell::{Cell, RefCell},
    collections::HashSet,
    rc::{Rc, Weak},
};

use mlua::{FromLua, Function, Lua, Table, Value};
use tracing::error;

use super::{
    ActivationAuthority, AttachmentHost, Command, DeclarationField, DefinitionData, InstanceState,
    PluginContext, PluginEffect, PluginInstance, RuntimeState, graph_error,
};
use crate::plugin::graph::{
    Action, ActivationId, AttachmentState, InstanceId, Intent, LoadOutcome,
};

pub(super) fn request_instance(
    lua: &Lua,
    weak: &Weak<RefCell<RuntimeState>>,
    command: Command,
) -> mlua::Result<()> {
    let runtime = weak
        .upgrade()
        .ok_or_else(|| mlua::Error::runtime("plugin runtime: runtime is gone"))?;
    {
        let mut state = runtime.borrow_mut();
        if state.closed || state.closing {
            return Err(mlua::Error::runtime("plugin runtime: runtime is closed"));
        }
        if state.draining {
            if state.queue.len() >= 256 {
                return Err(mlua::Error::runtime(
                    "plugin runtime: lifecycle queue is full",
                ));
            }
            state.queue.push_back(command);
            return Ok(());
        }
        state.queue.push_back(command);
    }
    drain_runtime(lua, &runtime)
}

pub(super) fn use_definition(
    _lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    definition: Rc<DefinitionData>,
    config: Value,
    parent: Option<InstanceId>,
) -> mlua::Result<PluginInstance> {
    if definition.host.upgrade().is_none() {
        return Err(mlua::Error::runtime(
            "plugin definition: attachment is gone",
        ));
    }
    let mut state = runtime.borrow_mut();
    if state.closed || state.closing {
        return Err(mlua::Error::runtime("plugin runtime: runtime is closed"));
    }
    let required = definition
        .required
        .iter()
        .map(|field| field.key.clone())
        .collect();
    let provided = definition
        .provided
        .iter()
        .map(|field| field.key.clone())
        .collect();
    let id = state
        .graph
        .install(required, provided, parent)
        .map_err(graph_error)?;
    state.instances.insert(
        id,
        InstanceState {
            authority: ActivationAuthority::Detached,
            definition,
            config,
            effects: Vec::new(),
            service: None,
            cancelled: false,
        },
    );
    Ok(PluginInstance {
        runtime: Rc::downgrade(runtime),
        id,
    })
}

pub(super) fn child(
    lua: &Lua,
    context: &PluginContext,
    definition: Rc<DefinitionData>,
    config: Value,
) -> mlua::Result<PluginInstance> {
    validate_context(lua, context, true)?;
    let runtime = context
        .runtime
        .upgrade()
        .ok_or_else(|| mlua::Error::runtime("plugin context: runtime is gone"))?;
    use_definition(lua, &runtime, definition, config, Some(context.instance))
}

pub(super) fn drain_runtime(lua: &Lua, runtime: &Rc<RefCell<RuntimeState>>) -> mlua::Result<()> {
    {
        let mut state = runtime.borrow_mut();
        if state.closed {
            return Ok(());
        }
        if state.draining {
            return Ok(());
        }
        state.draining = true;
    }

    let mut processed = 0usize;
    let mut failure = None;
    loop {
        processed += 1;
        let budget = {
            let state = runtime.borrow();
            if state.closing {
                state.instances.len().saturating_mul(2).saturating_add(258)
            } else {
                256
            }
        };
        if processed > budget {
            failure = Some(mlua::Error::runtime(
                "plugin drain: request budget exhausted",
            ));
            break;
        }
        let command = runtime.borrow_mut().queue.pop_front();
        if let Some(command) = command {
            if let Err(error) = apply_command(runtime, command) {
                failure = Some(error);
                break;
            }
            continue;
        }
        let action = runtime.borrow_mut().graph.next_action();
        let Some(action) = action else {
            let diagnostics = runtime.borrow_mut().graph.take_diagnostics();
            for diagnostic in diagnostics {
                record_error(runtime, diagnostic.to_string());
            }
            break;
        };
        if let Err(error) = execute_action(lua, runtime, action) {
            if runtime.borrow().closing {
                record_error(runtime, error.to_string());
                continue;
            }
            failure = Some(error);
            break;
        }
    }

    if runtime.borrow().closing && !runtime.borrow().closed {
        runtime.borrow_mut().closed = true;
        clear_runtime_references(runtime);
    }
    runtime.borrow_mut().draining = false;
    if let Some(error) = failure {
        record_error(runtime, error.to_string());
        return Err(error);
    }
    Ok(())
}

fn flush_commands(runtime: &Rc<RefCell<RuntimeState>>) -> mlua::Result<()> {
    loop {
        let command = {
            let mut state = runtime.borrow_mut();
            let priority = state
                .queue
                .iter()
                .position(|command| !matches!(command, Command::Enable(_)));
            match priority {
                Some(index) => state.queue.remove(index),
                None => state.queue.pop_front(),
            }
        };
        let Some(command) = command else {
            return Ok(());
        };
        apply_command(runtime, command)?;
    }
}

fn apply_command(runtime: &Rc<RefCell<RuntimeState>>, command: Command) -> mlua::Result<()> {
    let mut state = runtime.borrow_mut();
    match &command {
        Command::Disable(id) | Command::Dispose(id) | Command::Reload(id, _) => {
            if let Some(instance) = state.instances.get_mut(id) {
                instance.cancelled = true;
            }
        }
        Command::Shutdown => {
            for instance in state.instances.values_mut() {
                instance.cancelled = true;
            }
        }
        Command::Enable(_) => {}
    }
    let intent = match &command {
        Command::Enable(id) => Intent::Enable(*id),
        Command::Disable(id) => Intent::Disable(*id),
        Command::Reload(id, _) => Intent::Reload(*id),
        Command::Dispose(id) => Intent::Dispose(*id),
        Command::Shutdown => Intent::Shutdown,
    };
    state.graph.enqueue(intent).map_err(graph_error)?;
    if let Command::Enable(id) = command
        && state
            .instances
            .get(&id)
            .is_some_and(|instance| instance.cancelled)
        && state
            .graph
            .attachment(id)
            .map_err(graph_error)?
            .is_some_and(|view| view.state == AttachmentState::Active)
    {
        state
            .graph
            .enqueue(Intent::Reload(id))
            .map_err(graph_error)?;
    }
    if let Command::Reload(id, config) = command {
        let instance = state
            .instances
            .get_mut(&id)
            .ok_or_else(|| mlua::Error::runtime("plugin runtime: unknown instance"))?;
        instance.config = config;
    }
    Ok(())
}

fn execute_action(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    action: Action,
) -> mlua::Result<()> {
    match action {
        Action::BeginLoad {
            instance,
            activation,
            bindings: _,
        } => begin_load(lua, runtime, instance, activation),
        Action::BeginUnload {
            instance,
            activation,
        } => begin_unload(lua, runtime, instance, activation),
    }
}

fn begin_load(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: crate::plugin::graph::ActivationId,
) -> mlua::Result<()> {
    if let Some(instance_state) = runtime.borrow_mut().instances.get_mut(&instance) {
        instance_state.cancelled = false;
        instance_state.authority = ActivationAuthority::Resources(activation);
    }
    let (definition, config, init) = {
        let state = runtime.borrow();
        let instance_state = state.instances.get(&instance).ok_or_else(|| {
            mlua::Error::runtime("plugin runtime: graph returned unknown instance")
        })?;
        let init = instance_state
            .definition
            .init
            .borrow()
            .as_ref()
            .cloned()
            .ok_or_else(|| {
                mlua::Error::runtime("plugin definition: callback references were cleared")
            })?;
        (
            Rc::clone(&instance_state.definition),
            instance_state.config.clone(),
            init,
        )
    };
    let context = lua.create_userdata(PluginContext {
        runtime: Rc::downgrade(runtime),
        instance,
        activation,
    })?;
    let result = callback_call(runtime, lua, || init.call::<Value>((context, config)));
    let service = match result {
        Ok(service) => match validate_service(&service, &definition.provided) {
            Ok(()) => service,
            Err(error) => {
                complete_load_failure(lua, runtime, instance, activation, error.to_string())?;
                return Ok(());
            }
        },
        Err(error) => {
            complete_load_failure(lua, runtime, instance, activation, error.to_string())?;
            return Ok(());
        }
    };

    if let Err(error) = flush_commands(runtime) {
        complete_load_failure(lua, runtime, instance, activation, error.to_string())?;
        return Ok(());
    }
    let cancelled = runtime
        .borrow()
        .instances
        .get(&instance)
        .is_some_and(|state| state.cancelled);
    if cancelled {
        rollback_effects(lua, runtime, instance, activation)?;
    }
    if runtime
        .borrow()
        .graph
        .attachment(instance)
        .map_err(graph_error)?
        .is_some_and(|view| view.state == AttachmentState::Failed)
    {
        return Ok(());
    }
    let published = {
        let mut state = runtime.borrow_mut();
        state
            .graph
            .complete_load(
                instance,
                activation,
                if cancelled {
                    LoadOutcome::Cancelled
                } else {
                    LoadOutcome::Success
                },
            )
            .map_err(graph_error)?;
        state
            .graph
            .attachment(instance)
            .map_err(graph_error)?
            .is_some_and(|view| view.state == AttachmentState::Active)
    };
    if published {
        runtime
            .borrow_mut()
            .instances
            .get_mut(&instance)
            .ok_or_else(|| mlua::Error::runtime("plugin runtime: instance disappeared"))?
            .service = Some(service);
    } else if !cancelled && rollback_effects(lua, runtime, instance, activation)? {
        runtime
            .borrow_mut()
            .graph
            .complete_load(instance, activation, LoadOutcome::Cancelled)
            .map_err(graph_error)?;
    }
    Ok(())
}

fn complete_load_failure(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: crate::plugin::graph::ActivationId,
    message: String,
) -> mlua::Result<()> {
    record_error(runtime, format!("plugin load: {message}"));
    rollback_effects(lua, runtime, instance, activation)?;
    if runtime
        .borrow()
        .graph
        .attachment(instance)
        .map_err(graph_error)?
        .is_some_and(|view| view.state == AttachmentState::Failed)
    {
        return Ok(());
    }
    runtime
        .borrow_mut()
        .graph
        .complete_load(instance, activation, LoadOutcome::Failed)
        .map_err(graph_error)?;
    Ok(())
}

fn begin_unload(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: crate::plugin::graph::ActivationId,
) -> mlua::Result<()> {
    enter_cleanup(runtime, instance, activation)?;
    let effects = {
        let mut state = runtime.borrow_mut();
        let instance_state = state.instances.get_mut(&instance).ok_or_else(|| {
            mlua::Error::runtime("plugin runtime: graph returned unknown instance")
        })?;
        instance_state.service = None;
        std::mem::take(&mut instance_state.effects)
    };
    let mut success = true;
    for effect in effects.into_iter().rev().flatten() {
        if let Err(error) = callback_call(runtime, lua, || effect.call::<()>(())) {
            success = false;
            record_error(runtime, format!("plugin cleanup: {error}"));
        }
    }
    runtime
        .borrow_mut()
        .graph
        .complete_unload(instance, activation, success)
        .map_err(graph_error)
}

fn validate_service(value: &Value, fields: &[DeclarationField]) -> mlua::Result<()> {
    let Value::Table(table) = value else {
        return Err(mlua::Error::runtime(
            "plugin load: init must return a table",
        ));
    };
    let expected: HashSet<&str> = fields.iter().map(|field| field.field.as_str()).collect();
    let mut seen = HashSet::new();
    for pair in table.pairs::<Value, Value>() {
        let (key, value) = pair?;
        let Value::String(key) = key else {
            return Err(mlua::Error::runtime(
                "plugin load: provided record keys must be strings",
            ));
        };
        let key = key.to_str()?.to_owned();
        if value.is_nil() {
            return Err(mlua::Error::runtime(format!(
                "plugin load: provided field '{key}' is nil"
            )));
        }
        if !expected.contains(key.as_str()) {
            return Err(mlua::Error::runtime(format!(
                "plugin load: provided record has unexpected field '{key}'"
            )));
        }
        seen.insert(key);
    }
    if seen.len() != expected.len() {
        let missing = expected
            .iter()
            .find(|field| !seen.contains(**field))
            .copied()
            .unwrap_or("<unknown>");
        return Err(mlua::Error::runtime(format!(
            "plugin load: provided record is missing field '{missing}'"
        )));
    }
    Ok(())
}

pub(super) fn services(lua: &Lua, context: &PluginContext) -> mlua::Result<super::Unknown> {
    let runtime = context
        .runtime
        .upgrade()
        .ok_or_else(|| mlua::Error::runtime("plugin context: runtime is gone"))?;
    {
        let state = runtime.borrow();
        let view = state
            .graph
            .attachment(context.instance)
            .map_err(graph_error)?
            .ok_or_else(|| mlua::Error::runtime("plugin context: attachment is stale"))?;
        if view.activation != context.activation
            || !matches!(
                view.state,
                AttachmentState::Loading | AttachmentState::Active | AttachmentState::Unloading
            )
        {
            return Err(mlua::Error::runtime("plugin context: context is stale"));
        }
        state
            .graph
            .validate_attachment(context.instance, context.activation, &view.bindings)
            .map_err(graph_error)?;
    }
    let (bindings, definition, provider_values) = {
        let state = runtime.borrow();
        let view = state
            .graph
            .attachment(context.instance)
            .map_err(graph_error)?
            .ok_or_else(|| mlua::Error::runtime("plugin context: attachment is stale"))?;
        let definition = state
            .instances
            .get(&context.instance)
            .map(|instance| Rc::clone(&instance.definition))
            .ok_or_else(|| mlua::Error::runtime("plugin context: instance is gone"))?;
        let mut values = Vec::new();
        for binding in &view.bindings {
            let provider = state
                .instances
                .get(&binding.provider)
                .ok_or_else(|| mlua::Error::runtime("plugin context: provider is gone"))?;
            let service =
                provider.service.as_ref().cloned().ok_or_else(|| {
                    mlua::Error::runtime("plugin context: provider is not active")
                })?;
            let provider_field = provider
                .definition
                .provided
                .iter()
                .find(|field| field.key == binding.contract)
                .map(|field| field.field.clone())
                .ok_or_else(|| mlua::Error::runtime("plugin context: provider field is missing"))?;
            values.push((binding.clone(), provider_field, service));
        }
        (view.bindings, definition, values)
    };
    let table = lua.create_table()?;
    for (binding, provider_field, service) in provider_values {
        let consumer_field = definition
            .required
            .iter()
            .find(|field| field.key == binding.contract)
            .map(|field| field.field.clone())
            .ok_or_else(|| mlua::Error::runtime("plugin context: required field is missing"))?;
        let service = Table::from_lua(service, lua)?;
        let value: Value = service.get(provider_field)?;
        table.set(consumer_field, value)?;
    }
    let _ = bindings;
    Ok(super::Unknown(Value::Table(table)))
}

pub(super) fn effect(
    lua: &Lua,
    context: &PluginContext,
    acquire: Function,
) -> mlua::Result<PluginEffect> {
    let runtime = validate_context(lua, context, true)?;
    lifecycle_operation(lua, &runtime, || {
        let inverse = callback_call(&runtime, lua, || acquire.call::<Function>(()))?;
        let ordinal = {
            let mut state = runtime.borrow_mut();
            let view = state
                .graph
                .attachment(context.instance)
                .map_err(graph_error)?
                .ok_or_else(|| mlua::Error::runtime("plugin effect: attachment is stale"))?;
            if view.activation != context.activation {
                return Err(mlua::Error::runtime("plugin effect: context is stale"));
            }
            let instance = state
                .instances
                .get_mut(&context.instance)
                .ok_or_else(|| mlua::Error::runtime("plugin effect: instance is gone"))?;
            instance.effects.push(Some(inverse));
            instance.effects.len() - 1
        };
        flush_commands(&runtime)?;
        if validate_context(lua, context, true).is_err() {
            let loading = runtime
                .borrow()
                .graph
                .attachment(context.instance)
                .map_err(graph_error)?
                .is_some_and(|view| {
                    view.activation == context.activation && view.state == AttachmentState::Loading
                });
            if loading {
                rollback_effects(lua, &runtime, context.instance, context.activation)?;
            }
            return Err(mlua::Error::runtime("plugin effect: acquisition cancelled"));
        }
        Ok(PluginEffect {
            runtime: Rc::downgrade(&runtime),
            instance: context.instance,
            activation: context.activation,
            ordinal,
            disposed: Cell::new(false),
        })
    })
}

pub(super) fn dispose_effect(lua: &Lua, effect: &PluginEffect) -> mlua::Result<()> {
    let Some(runtime) = effect.runtime.upgrade() else {
        return Ok(());
    };
    let inverse = {
        let mut state = runtime.borrow_mut();
        let Some(view) = state
            .graph
            .attachment(effect.instance)
            .map_err(graph_error)?
        else {
            return Ok(());
        };
        if view.activation != effect.activation {
            return Ok(());
        }
        let Some(instance) = state.instances.get_mut(&effect.instance) else {
            return Ok(());
        };
        instance
            .effects
            .get_mut(effect.ordinal)
            .and_then(Option::take)
    };
    let Some(inverse) = inverse else {
        return Ok(());
    };
    lifecycle_operation(lua, &runtime, || {
        let previous = enter_cleanup(&runtime, effect.instance, effect.activation)?;
        if let Err(error) = callback_call(&runtime, lua, || inverse.call::<()>(())) {
            runtime
                .borrow_mut()
                .graph
                .mark_cleanup_failed(effect.instance, effect.activation)
                .map_err(graph_error)?;
            record_error(&runtime, format!("plugin cleanup: {error}"));
            return Err(error);
        }
        // Successful explicit disposal ends only this inverse's scope; rollback never restores authority.
        let mut state = runtime.borrow_mut();
        let view = state
            .graph
            .attachment(effect.instance)
            .map_err(graph_error)?;
        if view.is_some_and(|view| {
            view.activation == effect.activation
                && matches!(
                    view.state,
                    AttachmentState::Loading | AttachmentState::Active
                )
        }) && let Some(instance) = state.instances.get_mut(&effect.instance)
            && instance.authority == ActivationAuthority::Cleanup(effect.activation)
        {
            instance.authority = previous;
        }
        Ok(())
    })
}

pub(super) fn check_owner(
    lua: &Lua,
    provider: &PluginContext,
    caller: &PluginContext,
) -> mlua::Result<()> {
    let runtime = validate_context(lua, provider, false)?;
    if !Rc::ptr_eq(
        &runtime,
        &caller
            .runtime
            .upgrade()
            .ok_or_else(|| mlua::Error::runtime("plugin context: caller runtime is gone"))?,
    ) {
        return Err(mlua::Error::runtime(
            "plugin context: caller belongs to another runtime",
        ));
    }
    let state = runtime.borrow();
    let provider_view = state
        .graph
        .attachment(provider.instance)
        .map_err(graph_error)?
        .ok_or_else(|| mlua::Error::runtime("plugin context: provider attachment is stale"))?;
    if provider_view.state != AttachmentState::Active {
        return Err(mlua::Error::runtime(
            "plugin context: provider is not active",
        ));
    }
    let caller_view = state
        .graph
        .attachment(caller.instance)
        .map_err(graph_error)?
        .ok_or_else(|| mlua::Error::runtime("plugin context: caller attachment is stale"))?;
    if caller_view.activation != caller.activation
        || !state
            .instances
            .get(&caller.instance)
            .is_some_and(|instance| instance.authority.permits_resources(caller.activation))
        || !matches!(
            caller_view.state,
            AttachmentState::Loading | AttachmentState::Active
        )
    {
        return Err(mlua::Error::runtime(
            "plugin context: caller is not active or loading",
        ));
    }
    let provider_generation = provider_view
        .generation
        .ok_or_else(|| mlua::Error::runtime("plugin context: provider has no generation"))?;
    if !caller_view.bindings.iter().any(|binding| {
        binding.provider == provider.instance && binding.generation == provider_generation
    }) {
        return Err(mlua::Error::runtime(
            "plugin context: caller does not own this provider",
        ));
    }
    Ok(())
}

pub(super) fn context_active(context: &PluginContext) -> bool {
    let Some(runtime) = context.runtime.upgrade() else {
        return false;
    };
    let state = runtime.borrow();
    state
        .graph
        .attachment(context.instance)
        .ok()
        .flatten()
        .is_some_and(|view| {
            view.activation == context.activation
                && state
                    .instances
                    .get(&context.instance)
                    .is_some_and(|instance| {
                        instance.authority.permits_resources(context.activation)
                    })
                && matches!(
                    view.state,
                    AttachmentState::Loading | AttachmentState::Active
                )
        })
}

fn validate_context(
    _lua: &Lua,
    context: &PluginContext,
    allow_loading: bool,
) -> mlua::Result<Rc<RefCell<RuntimeState>>> {
    let runtime = context
        .runtime
        .upgrade()
        .ok_or_else(|| mlua::Error::runtime("plugin context: runtime is gone"))?;
    flush_commands(&runtime)?;
    let state = runtime.borrow();
    if !state
        .instances
        .get(&context.instance)
        .is_some_and(|instance| instance.authority.permits_resources(context.activation))
    {
        return Err(mlua::Error::runtime(
            "plugin context: activation is cleanup-only",
        ));
    }
    if allow_loading
        && (state.closing
            || state
                .instances
                .get(&context.instance)
                .is_some_and(|instance| instance.cancelled))
    {
        return Err(mlua::Error::runtime("plugin context: activation cancelled"));
    }
    let view = state
        .graph
        .attachment(context.instance)
        .map_err(graph_error)?
        .ok_or_else(|| mlua::Error::runtime("plugin context: attachment is stale"))?;
    let valid_state = if allow_loading {
        matches!(
            view.state,
            AttachmentState::Loading | AttachmentState::Active
        )
    } else {
        view.state == AttachmentState::Active
    };
    if view.activation != context.activation || !valid_state {
        return Err(mlua::Error::runtime("plugin context: context is stale"));
    }
    if allow_loading
        && !state
            .graph
            .activation_is_valid(context.instance, context.activation)
            .map_err(graph_error)?
    {
        return Err(mlua::Error::runtime("plugin context: activation cancelled"));
    }
    drop(state);
    Ok(runtime)
}

fn enter_cleanup(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> mlua::Result<ActivationAuthority> {
    let mut state = runtime.borrow_mut();
    let view = state
        .graph
        .attachment(instance)
        .map_err(graph_error)?
        .ok_or_else(|| mlua::Error::runtime("plugin cleanup: attachment is stale"))?;
    if view.activation != activation {
        return Err(mlua::Error::runtime("plugin cleanup: activation is stale"));
    }
    let instance = state
        .instances
        .get_mut(&instance)
        .ok_or_else(|| mlua::Error::runtime("plugin cleanup: instance is gone"))?;
    let previous = instance.authority;
    instance.authority = ActivationAuthority::Cleanup(activation);
    Ok(previous)
}

fn rollback_effects(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> mlua::Result<bool> {
    enter_cleanup(runtime, instance, activation)?;
    let effects = {
        let mut state = runtime.borrow_mut();
        let view = state
            .graph
            .attachment(instance)
            .map_err(graph_error)?
            .ok_or_else(|| mlua::Error::runtime("plugin rollback: attachment is stale"))?;
        if view.activation != activation {
            return Err(mlua::Error::runtime("plugin rollback: activation is stale"));
        }
        let instance = state
            .instances
            .get_mut(&instance)
            .ok_or_else(|| mlua::Error::runtime("plugin rollback: instance is gone"))?;
        std::mem::take(&mut instance.effects)
    };
    let mut success = true;
    for effect in effects.into_iter().rev().flatten() {
        if let Err(error) = callback_call(runtime, lua, || effect.call::<()>(())) {
            success = false;
            record_error(runtime, format!("plugin rollback: {error}"));
        }
    }
    if !success {
        runtime
            .borrow_mut()
            .graph
            .mark_cleanup_failed(instance, activation)
            .map_err(graph_error)?;
    }
    Ok(success)
}

fn lifecycle_operation<R>(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    operation: impl FnOnce() -> mlua::Result<R>,
) -> mlua::Result<R> {
    let already_draining = {
        let mut state = runtime.borrow_mut();
        let already_draining = state.draining;
        state.draining = true;
        already_draining
    };
    // The callback result must be accounted for before queued work can replace its allocation.
    let result = operation();
    if already_draining {
        return result;
    }
    runtime.borrow_mut().draining = false;
    let drain_result = drain_runtime(lua, runtime);
    match (result, drain_result) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Ok(value), Ok(())) => Ok(value),
    }
}

fn callback_call<R>(
    runtime: &Rc<RefCell<RuntimeState>>,
    lua: &Lua,
    callback: impl FnOnce() -> mlua::Result<R>,
) -> mlua::Result<R> {
    let host = runtime
        .borrow()
        .host
        .upgrade()
        .ok_or_else(|| mlua::Error::runtime("plugin callback: attachment is gone"))?;
    {
        let mut host_state = host.borrow_mut();
        host_state.callback_depth += 1;
    }
    let result = callback();
    {
        let mut host_state = host.borrow_mut();
        host_state.callback_depth = host_state.callback_depth.saturating_sub(1);
    }
    let _ = lua;
    result
}

pub(super) fn close_runtime(lua: &Lua, runtime: &Rc<RefCell<RuntimeState>>) -> mlua::Result<()> {
    {
        let mut state = runtime.borrow_mut();
        if state.closed {
            return Ok(());
        }
        state.closing = true;
        state.queue.clear();
        state.queue.push_front(Command::Shutdown);
        if state.draining {
            return Ok(());
        }
    }
    drain_runtime(lua, runtime)
}

fn clear_runtime_references(runtime: &Rc<RefCell<RuntimeState>>) {
    let dropped = {
        let mut state = runtime.borrow_mut();
        (
            std::mem::take(&mut state.instances),
            std::mem::take(&mut state.queue),
        )
    };
    drop(dropped);
}

pub(super) fn clear_host_references(host: &Rc<RefCell<AttachmentHost>>) {
    let definitions = {
        let mut host = host.borrow_mut();
        let definitions = host
            .definitions
            .iter()
            .filter_map(Weak::upgrade)
            .collect::<Vec<_>>();
        host.definitions.clear();
        definitions
    };
    for definition in definitions {
        let callback = definition.init.borrow_mut().take();
        drop(callback);
    }
}

fn record_error(runtime: &Rc<RefCell<RuntimeState>>, message: String) {
    error!("{message}");
    runtime.borrow_mut().errors.push(message);
}
