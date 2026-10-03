//! Runtime graph execution: requests, drains, loads, unloads, and failure
//! reporting for the plugin attachment.
//!
//! Requests apply to the graph immediately and return its rejection to the
//! caller. Planning derives from graph state, so a drain picks up requests
//! made while it runs, and the next drain finds work this one did not reach.

use std::{
    cell::RefCell,
    collections::{BTreeMap, HashSet},
    rc::{Rc, Weak},
};

use mlua::{Lua, Value};
use tracing::{debug, error, info};

use crate::plugin::{
    attachment::{
        PluginContext, PluginInstance,
        error::{AttachmentError, FailureCause, FailurePhase, PluginFailure, ProvisionError},
        state::{
            ActivationAuthority, AttachmentHost, CallbackGuard, DeclarationField, DefinitionData,
            DrainGuard, InstanceState, RuntimeState,
        },
        types::PluginState,
    },
    graph::{
        Action, ActivationId, GraphError, InstanceId, Intent, LifecycleState, LoadOutcome,
        LoadResolution, Severity,
    },
};

/// A lifecycle request made through an instance handle.
pub(super) enum Request {
    Enable(InstanceId),
    Disable(InstanceId),
    Reload(InstanceId, Value),
    Dispose(InstanceId),
}

/// Applies a request and drains, unless a drain is already running.
pub(super) fn request_instance(
    lua: &Lua,
    weak: &Weak<RefCell<RuntimeState>>,
    request: Request,
) -> Result<(), AttachmentError> {
    let runtime = weak.upgrade().ok_or(AttachmentError::RuntimeGone)?;
    {
        let mut state = runtime.borrow_mut();
        if state.closed || state.closing {
            return Err(AttachmentError::RuntimeClosed);
        }
        let (operation, intent) = match &request {
            Request::Enable(id) => ("enable", Intent::Enable(*id)),
            Request::Disable(id) => ("disable", Intent::Disable(*id)),
            Request::Reload(id, _) => ("reload", Intent::Reload(*id)),
            Request::Dispose(id) => ("dispose", Intent::Dispose(*id)),
        };
        state
            .graph
            .request(intent)
            .map_err(|source| AttachmentError::Graph { operation, source })?;
        if let Request::Reload(id, config) = request
            && let Some(instance) = state.instances.get_mut(&id)
        {
            instance.config = config;
        }
    }
    drain_runtime(lua, &runtime)
}

pub(super) fn use_definition(
    runtime: &Rc<RefCell<RuntimeState>>,
    definition: Rc<DefinitionData>,
    config: Value,
    parent: Option<InstanceId>,
) -> Result<PluginInstance, AttachmentError> {
    let host = definition
        .host
        .upgrade()
        .ok_or(AttachmentError::NotInstalled)?;
    if host.borrow().epoch != definition.epoch {
        return Err(AttachmentError::StaleDefinition {
            plugin: definition.name.clone(),
        });
    }
    let mut state = runtime.borrow_mut();
    if state.closed || state.closing {
        return Err(AttachmentError::RuntimeClosed);
    }
    let keys = |fields: &[DeclarationField]| fields.iter().map(|field| field.key.clone()).collect();
    let id = state
        .graph
        .install(
            keys(&definition.required),
            keys(&definition.provided),
            parent,
        )
        .map_err(|source| AttachmentError::Graph {
            operation: "install",
            source,
        })?;
    state.instances.insert(
        id,
        InstanceState {
            authority: ActivationAuthority::Detached,
            definition,
            config,
            effects: BTreeMap::new(),
            next_effect: 0,
            service: None,
            last_diagnostic: None,
        },
    );
    Ok(PluginInstance {
        runtime: Rc::downgrade(runtime),
        id,
    })
}

pub(super) fn instance_state(runtime: &Weak<RefCell<RuntimeState>>, id: InstanceId) -> PluginState {
    runtime
        .upgrade()
        .and_then(|runtime| runtime.borrow().graph.state(id).ok())
        .map_or(PluginState::Removed, PluginState::from)
}

pub(super) fn instance_diagnostic(
    runtime: &Weak<RefCell<RuntimeState>>,
    id: InstanceId,
) -> Option<String> {
    let runtime = runtime.upgrade()?;
    let state = runtime.borrow();
    state.instances.get(&id)?.last_diagnostic.clone()
}

/// Performs lifecycle work until the graph has none or the action budget is
/// spent. The budget, which scales with the instance count, stops a defect
/// from looping forever.
pub(super) fn drain_runtime(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
) -> Result<(), AttachmentError> {
    {
        let state = runtime.borrow();
        if state.closed || state.draining {
            return Ok(());
        }
    }
    let result = {
        let _draining = DrainGuard::enter(runtime);
        drain_actions(lua, runtime)
    };
    let finished_closing = {
        let mut state = runtime.borrow_mut();
        let finished = state.closing && !state.closed;
        if finished {
            state.closed = true;
        }
        finished
    };
    if finished_closing {
        let released = std::mem::take(&mut runtime.borrow_mut().instances);
        drop(released);
        prune_closed_runtimes(runtime);
    }
    result
}

fn drain_actions(lua: &Lua, runtime: &Rc<RefCell<RuntimeState>>) -> Result<(), AttachmentError> {
    let mut performed = 0usize;
    loop {
        let budget = drain_budget(&runtime.borrow());
        if performed >= budget {
            return Err(AttachmentError::DrainBudget { budget });
        }
        let action = runtime.borrow_mut().graph.next_action();
        publish_diagnostics(lua, runtime);
        prune_instances(runtime);
        let Some(action) = action else {
            return Ok(());
        };
        performed += 1;
        if let Err(error) = execute_action(lua, runtime, action) {
            if !runtime.borrow().closing {
                return Err(error);
            }
            // Shutdown attempts every remaining cleanup even after an internal failure.
            record_error(runtime, error);
        }
    }
}

fn drain_budget(state: &RuntimeState) -> usize {
    state.graph.len().saturating_mul(8).saturating_add(64)
}

pub(super) fn close_runtime(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
) -> Result<(), AttachmentError> {
    {
        let mut state = runtime.borrow_mut();
        if state.closed {
            return Ok(());
        }
        state.closing = true;
        state
            .graph
            .request(Intent::Shutdown)
            .map_err(|source| AttachmentError::Graph {
                operation: "close",
                source,
            })?;
        if state.draining {
            return Ok(());
        }
    }
    drain_runtime(lua, runtime)
}

/// Runs an operation that may acquire or release resources, then performs
/// the lifecycle work it caused.
///
/// The operation's result is accounted for before queued work can replace its
/// allocation, because no drain runs while it does.
pub(super) fn lifecycle_operation<R>(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    operation: impl FnOnce() -> mlua::Result<R>,
) -> mlua::Result<R> {
    let nested = runtime.borrow().draining;
    let result = {
        let _draining = DrainGuard::enter(runtime);
        operation()
    };
    if nested {
        return result;
    }
    let drained = drain_runtime(lua, runtime);
    let value = result?;
    drained?;
    Ok(value)
}

/// Calls plugin code with the callback depth raised for its duration.
pub(super) fn callback_call<R>(
    runtime: &Rc<RefCell<RuntimeState>>,
    callback: impl FnOnce() -> mlua::Result<R>,
) -> mlua::Result<R> {
    let host = runtime
        .borrow()
        .host
        .upgrade()
        .ok_or_else(|| mlua::Error::from(AttachmentError::NotInstalled))?;
    let _depth = CallbackGuard::enter(host);
    callback()
}

fn execute_action(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    action: Action,
) -> Result<(), AttachmentError> {
    match action {
        Action::BeginLoad {
            instance,
            activation,
            ..
        } => begin_load(lua, runtime, instance, activation),
        Action::BeginUnload {
            instance,
            activation,
        } => begin_unload(lua, runtime, instance, activation),
    }
}

struct Prepared {
    definition: Rc<DefinitionData>,
    config: Value,
    init: mlua::Function,
}

fn prepare_load(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<Prepared, FailureCause> {
    let mut state = runtime.borrow_mut();
    let instance_state = state
        .instances
        .get_mut(&instance)
        .ok_or(FailureCause::MissingRecord)?;
    instance_state.authority = ActivationAuthority::Resources(activation);
    let init = instance_state
        .definition
        .init
        .borrow()
        .as_ref()
        .cloned()
        .ok_or(FailureCause::InitializerCleared)?;
    Ok(Prepared {
        definition: Rc::clone(&instance_state.definition),
        config: instance_state.config.clone(),
        init,
    })
}

fn begin_load(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<(), AttachmentError> {
    let prepared = match prepare_load(runtime, instance, activation) {
        Ok(prepared) => prepared,
        Err(cause) => return fail_load(lua, runtime, instance, activation, cause),
    };
    let context = match lua.create_userdata(PluginContext {
        runtime: Rc::downgrade(runtime),
        instance,
        activation,
    }) {
        Ok(context) => context,
        Err(error) => {
            return fail_load(
                lua,
                runtime,
                instance,
                activation,
                FailureCause::Callback(error),
            );
        }
    };
    let result = callback_call(runtime, || {
        prepared.init.call::<Value>((context, prepared.config))
    });
    let service = match result.map_err(FailureCause::Callback).and_then(|service| {
        validate_service(&service, &prepared.definition.provided)
            .map(|()| service)
            .map_err(FailureCause::Provision)
    }) {
        Ok(service) => service,
        Err(cause) if load_was_cancelled(runtime, instance, activation)? => {
            debug!(
                "plugin load: {} ended after its activation was cancelled: {cause}",
                runtime.borrow().label(instance)
            );
            return cancel_load(lua, runtime, instance, activation);
        }
        Err(cause) => return fail_load(lua, runtime, instance, activation, cause),
    };
    let resolution = runtime
        .borrow_mut()
        .graph
        .complete_load(instance, activation, LoadOutcome::Success)
        .map_err(graph_error("complete a load"))?;
    match resolution {
        LoadResolution::Published(_) => {
            if let Some(instance_state) = runtime.borrow_mut().instances.get_mut(&instance) {
                instance_state.service = Some(service);
                instance_state.last_diagnostic = None;
            }
            Ok(())
        }
        LoadResolution::Rejected => cancel_load(lua, runtime, instance, activation),
        LoadResolution::Ended(_) => Ok(()),
    }
}

/// A load whose activation was cancelled by an intent ended because of that
/// cancellation, not because the plugin failed. A load whose cleanup failed
/// is a failure even though it can no longer publish.
fn load_was_cancelled(
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<bool, AttachmentError> {
    let state = runtime.borrow();
    let valid = state
        .graph
        .activation_is_valid(instance, activation)
        .map_err(graph_error("check a load"))?;
    let quarantined = state
        .graph
        .cleanup_failed(instance)
        .map_err(graph_error("check a load"))?;
    Ok(!valid && !quarantined)
}

fn fail_load(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
    cause: FailureCause,
) -> Result<(), AttachmentError> {
    let plugin = runtime.borrow().label(instance);
    record_failure(
        lua,
        runtime,
        PluginFailure {
            phase: FailurePhase::Load,
            plugin,
            cause,
        },
    );
    rollback_effects(lua, runtime, instance, activation)?;
    runtime
        .borrow_mut()
        .graph
        .complete_load(instance, activation, LoadOutcome::Failed)
        .map_err(graph_error("complete a failed load"))?;
    Ok(())
}

fn cancel_load(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<(), AttachmentError> {
    rollback_effects(lua, runtime, instance, activation)?;
    runtime
        .borrow_mut()
        .graph
        .complete_load(instance, activation, LoadOutcome::Cancelled)
        .map_err(graph_error("complete a cancelled load"))?;
    Ok(())
}

fn begin_unload(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<(), AttachmentError> {
    let effects = {
        let mut state = runtime.borrow_mut();
        match state.instances.get_mut(&instance) {
            Some(instance_state) => {
                instance_state.authority = ActivationAuthority::Cleanup(activation);
                instance_state.service = None;
                Some(std::mem::take(&mut instance_state.effects))
            }
            None => None,
        }
    };
    let success = match effects {
        Some(effects) => run_inverses(lua, runtime, instance, effects, FailurePhase::Cleanup),
        None => {
            let plugin = runtime.borrow().label(instance);
            record_failure(
                lua,
                runtime,
                PluginFailure {
                    phase: FailurePhase::Cleanup,
                    plugin,
                    cause: FailureCause::MissingRecord,
                },
            );
            false
        }
    };
    runtime
        .borrow_mut()
        .graph
        .complete_unload(instance, activation, success)
        .map_err(graph_error("complete an unload"))
}

/// Runs every inverse of a loading allocation in reverse order, quarantining
/// the allocation if one fails.
pub(super) fn rollback_effects(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    activation: ActivationId,
) -> Result<bool, AttachmentError> {
    let effects = {
        let mut state = runtime.borrow_mut();
        let Some(instance_state) = state.instances.get_mut(&instance) else {
            return Ok(true);
        };
        instance_state.authority = ActivationAuthority::Cleanup(activation);
        std::mem::take(&mut instance_state.effects)
    };
    let success = run_inverses(lua, runtime, instance, effects, FailurePhase::Rollback);
    if !success {
        runtime
            .borrow_mut()
            .graph
            .mark_cleanup_failed(instance, activation)
            .map_err(graph_error("quarantine a rollback"))?;
    }
    Ok(success)
}

fn run_inverses(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    instance: InstanceId,
    effects: BTreeMap<u64, mlua::Function>,
    phase: FailurePhase,
) -> bool {
    let mut success = true;
    for (_, inverse) in effects.into_iter().rev() {
        if let Err(error) = callback_call(runtime, || inverse.call::<()>(())) {
            success = false;
            let plugin = runtime.borrow().label(instance);
            record_failure(
                lua,
                runtime,
                PluginFailure {
                    phase,
                    plugin,
                    cause: FailureCause::Callback(error),
                },
            );
        }
    }
    success
}

fn validate_service(value: &Value, fields: &[DeclarationField]) -> Result<(), ProvisionError> {
    let Value::Table(table) = value else {
        return Err(ProvisionError::NotATable);
    };
    let expected: HashSet<&str> = fields.iter().map(|field| field.field.as_str()).collect();
    let mut seen = HashSet::new();
    for pair in table.pairs::<Value, Value>() {
        let (key, value) = pair.map_err(|error| ProvisionError::Unreadable(error.to_string()))?;
        let Value::String(key) = key else {
            return Err(ProvisionError::KeyNotString);
        };
        let key = key
            .to_str()
            .map_err(|error| ProvisionError::Unreadable(error.to_string()))?
            .to_owned();
        if value.is_nil() {
            return Err(ProvisionError::NilField(key));
        }
        if !expected.contains(key.as_str()) {
            return Err(ProvisionError::UnexpectedField(key));
        }
        seen.insert(key);
    }
    if let Some(missing) = expected.iter().find(|field| !seen.contains(**field)) {
        return Err(ProvisionError::MissingField((*missing).to_owned()));
    }
    Ok(())
}

/// Moves graph diagnostics onto their instances and reports them: a waiting
/// condition is logged, and one that needs a configuration change is a failure.
fn publish_diagnostics(lua: &Lua, runtime: &Rc<RefCell<RuntimeState>>) {
    let diagnostics = runtime.borrow_mut().graph.take_diagnostics();
    for diagnostic in diagnostics {
        let (plugin, description) = {
            let mut state = runtime.borrow_mut();
            let description = diagnostic
                .kind
                .describe(&|instance| state.label(instance).to_string());
            if let Some(instance_state) = state.instances.get_mut(&diagnostic.instance) {
                instance_state.last_diagnostic = Some(description.clone());
            }
            (state.label(diagnostic.instance), description)
        };
        match diagnostic.kind.severity() {
            Severity::Waiting => info!("plugin wiring: {plugin}: {description}"),
            Severity::Error => record_failure(
                lua,
                runtime,
                PluginFailure {
                    phase: FailurePhase::Wiring,
                    plugin,
                    cause: FailureCause::Blocked(description),
                },
            ),
        }
    }
}

/// Drops the attachment's record of every instance the graph has removed,
/// and the Lua values a quarantined instance can never use again.
fn prune_instances(runtime: &Rc<RefCell<RuntimeState>>) {
    let released = {
        let mut state = runtime.borrow_mut();
        let state = &mut *state;
        let mut released = Vec::new();
        state
            .instances
            .retain(|id, instance| match state.graph.state(*id) {
                Err(_) => false,
                Ok(LifecycleState::Quarantined) => {
                    released.push(std::mem::replace(&mut instance.config, Value::Nil));
                    released.extend(instance.service.take());
                    true
                }
                Ok(_) => true,
            });
        released
    };
    drop(released);
}

fn prune_closed_runtimes(runtime: &Rc<RefCell<RuntimeState>>) {
    let Some(host) = runtime.borrow().host.upgrade() else {
        return;
    };
    let Ok(mut host) = host.try_borrow_mut() else {
        return;
    };
    host.runtimes
        .retain(|candidate| candidate.try_borrow().map_or(true, |state| !state.closed));
}

/// Records a plugin failure on its instance and reports it.
pub(super) fn record_failure(
    lua: &Lua,
    runtime: &Rc<RefCell<RuntimeState>>,
    failure: PluginFailure,
) {
    let collect = {
        let mut state = runtime.borrow_mut();
        if let Some(instance) = state.instances.get_mut(&failure.plugin.instance) {
            instance.last_diagnostic = Some(failure.to_string());
        }
        state.collect_failures
    };
    if collect {
        runtime
            .borrow_mut()
            .collected
            .push(AttachmentError::Plugin(failure));
        return;
    }
    let host = runtime.borrow().host.upgrade();
    report(lua, host, &failure);
}

fn record_error(runtime: &Rc<RefCell<RuntimeState>>, error: AttachmentError) {
    if runtime.borrow().collect_failures {
        runtime.borrow_mut().collected.push(error);
    } else {
        error!("{error}");
    }
}

fn report(lua: &Lua, host: Option<Rc<RefCell<AttachmentHost>>>, failure: &PluginFailure) {
    let reporter = host
        .as_ref()
        .and_then(|host| host.borrow().reporter.clone());
    match (reporter, host) {
        (Some(reporter), Some(host)) => {
            let _depth = CallbackGuard::enter(host);
            reporter(lua, failure);
        }
        _ => error!("{failure}"),
    }
}

fn graph_error(operation: &'static str) -> impl Fn(GraphError) -> AttachmentError {
    move |source| AttachmentError::Graph { operation, source }
}
