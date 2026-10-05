//! Immutable inspection data, detached from native runtime and callback authority.
//!
//! Effect inspection retains every registered inverse's metadata for the current or most recently
//! ended activation, including disarmed entries. It does not retain inverse callbacks. The history
//! has no size bound within an activation: native metadata and each copied snapshot cost linear
//! space in that activation's registration count. A new load clears the preceding activation's
//! history; instance removal and runtime closure release it. This preserves complete acquisition
//! order for inspection rather than silently pruning disarmed entries. Retained snapshots own
//! their copies and remain unchanged after those native records are released.

use std::{cell::RefCell, rc::Rc};

use lunette_luau::{Type, Typed, closed_set};
use mlua::{IntoLua, Lua, Value};

use crate::{
    lua::declarations::{Record, RecordField, Recorded, of},
    plugin::{
        attachment::{
            state::{ActivationAuthority, DeclarationField, RuntimeState},
            types::PluginState,
        },
        graph::{Binding, Blocker, ContractKey, DiagnosticKind, Graph, InstanceId, Severity},
    },
};

closed_set! {
    /// Whether a registered inverse can still run or is being attempted.
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum PluginEffectState {
        Armed = "armed",
        Cleaning = "cleaning",
        Disarmed = "disarmed",
    }
}

closed_set! {
    /// The authority retained by an attachment, independent of its requested intent.
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum PluginAuthority {
        Detached = "detached",
        Resources = "resources",
        Cleanup = "cleanup",
    }
}

closed_set! {
    /// Whether a graph diagnostic waits for configuration or requires a change.
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum PluginDiagnosticSeverity {
        Waiting = "waiting",
        Error = "error",
    }
}

closed_set! {
    /// Current planner conditions, not allocation edges.
    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub enum PluginBlockerKind {
        Shutdown = "shutdown",
        Disabled = "disabled",
        Retired = "retired",
        Quarantined = "quarantined",
        ReplacementRequested = "replacementRequested",
        ParentUnavailable = "parentUnavailable",
        ProviderUnavailable = "providerUnavailable",
        ContractHeld = "contractHeld",
        ProviderPending = "providerPending",
        FailedBindingsUnchanged = "failedBindingsUnchanged",
        MissingProvider = "missingProvider",
        ProviderDisabled = "providerDisabled",
        SchemaMismatch = "schemaMismatch",
        ProviderQuarantined = "providerQuarantined",
        ContractQuarantined = "contractQuarantined",
        DependencyCycle = "dependencyCycle",
        PublishConflict = "publishConflict",
        ActivationsExhausted = "activationsExhausted",
    }
}

macro_rules! snapshot_enum {
    ($($name:ident),+ $(,)?) => {$(
        impl Typed for $name {
            fn luau() -> Type { Type::Named(stringify!($name)) }
        }
        impl IntoLua for $name {
            fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
                self.as_str().into_lua(lua)
            }
        }
    )+};
}
snapshot_enum!(
    PluginEffectState,
    PluginAuthority,
    PluginDiagnosticSeverity,
    PluginBlockerKind
);

/// All lists in a snapshot are immutable, including their elements.
#[derive(Debug)]
pub(crate) struct SnapshotList<T>(Vec<T>);

impl<T: Typed> Typed for SnapshotList<T> {
    fn luau() -> Type {
        T::luau().readonly_array()
    }
}

impl<T: IntoLua> IntoLua for SnapshotList<T> {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let table = lua.create_sequence_from(self.0)?;
        table.set_readonly(true);
        Ok(Value::Table(table))
    }
}

macro_rules! snapshot_record {
    ($name:ident { $($field:ident => $lua_name:literal : $ty:ty),* $(,)? }) => {
        #[derive(Debug)]
        pub(crate) struct $name { $(pub(crate) $field: $ty,)* }
        impl Typed for $name {
            fn luau() -> Type { Type::Named(stringify!($name)) }
        }
        impl Recorded for $name {
            const RECORD: Record = Record {
                name: stringify!($name),
                doc: "Immutable data copied from one synchronous runtime inspection.",
                fields: &[$(RecordField { name: $lua_name, doc: "", ty: of::<$ty> },)*],
            };
        }
        impl IntoLua for $name {
            fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
                let table = lua.create_table()?;
                $(table.raw_set($lua_name, self.$field)?;)*
                table.set_readonly(true);
                Ok(Value::Table(table))
            }
        }
    };
}

snapshot_record!(PluginContractSnapshot {
    name => "name": String,
    schema => "schema": u32,
    display => "display": String,
});
snapshot_record!(PluginCapabilitySnapshot {
    field => "field": String,
    contract => "contract": PluginContractSnapshot,
});
snapshot_record!(PluginBindingSnapshot {
    contract => "contract": PluginContractSnapshot,
    provider_id => "providerId": String,
    generation_id => "generationId": String,
    current => "current": bool,
});
snapshot_record!(PluginEffectSnapshot {
    owner_id => "ownerId": String,
    source_id => "sourceId": String,
    activation_id => "activationId": String,
    ordinal => "ordinal": String,
    state => "state": PluginEffectState,
});
snapshot_record!(PluginBlockerSnapshot {
    kind => "kind": PluginBlockerKind,
    message => "message": String,
    contract => "contract": Option<PluginContractSnapshot>,
    provided => "provided": Option<PluginContractSnapshot>,
    related_id => "relatedId": Option<String>,
    generation_id => "generationId": Option<String>,
    instance_ids => "instanceIds": SnapshotList<String>,
});
snapshot_record!(PluginDiagnosticSnapshot {
    instance_id => "instanceId": String,
    severity => "severity": PluginDiagnosticSeverity,
    blocker => "blocker": PluginBlockerSnapshot,
});
snapshot_record!(PluginInstanceSnapshot {
    id => "id": String,
    parent_id => "parentId": Option<String>,
    name => "name": String,
    enabled => "enabled": bool,
    retired => "retired": bool,
    state => "state": PluginState,
    activation_id => "activationId": Option<String>,
    generation_id => "generationId": Option<String>,
    required => "required": SnapshotList<PluginCapabilitySnapshot>,
    provided => "provided": SnapshotList<PluginCapabilitySnapshot>,
    bindings => "bindings": SnapshotList<PluginBindingSnapshot>,
    failed_bindings => "failedBindings": SnapshotList<PluginBindingSnapshot>,
    children => "children": SnapshotList<String>,
    dependents => "dependents": SnapshotList<String>,
    replacement_requested => "replacementRequested": bool,
    cleanup_failed => "cleanupFailed": bool,
    authority => "authority": PluginAuthority,
    blockers => "blockers": SnapshotList<PluginBlockerSnapshot>,
    diagnostic => "diagnostic": Option<String>,
    last_failure => "lastFailure": Option<String>,
    last_graph_diagnostic => "lastGraphDiagnostic": Option<PluginBlockerSnapshot>,
    effects => "effects": SnapshotList<PluginEffectSnapshot>,
});
snapshot_record!(PluginRuntimeSnapshot {
    instances => "instances": SnapshotList<PluginInstanceSnapshot>,
    diagnostics => "diagnostics": SnapshotList<PluginDiagnosticSnapshot>,
    shutdown_requested => "shutdownRequested": bool,
    draining => "draining": bool,
    closing => "closing": bool,
    closed => "closed": bool,
});

/// Takes one borrow to copy coherent native state, releasing it before any Lua allocation.
pub(super) fn snapshot(runtime: &Rc<RefCell<RuntimeState>>) -> mlua::Result<PluginRuntimeSnapshot> {
    let state = runtime
        .try_borrow()
        .map_err(|_| mlua::Error::runtime("plugin snapshot: runtime state is mutably borrowed"))?;
    let graph = state.graph.snapshot();
    let mut instances = Vec::with_capacity(graph.instances.len());
    for node in graph.instances {
        let record = state.instances.get(&node.id).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "plugin snapshot: missing attachment record for {}",
                node.id
            ))
        })?;
        let binding = |binding| binding_snapshot(&state.graph, binding);
        instances.push(PluginInstanceSnapshot {
            id: instance_id(node.id),
            parent_id: node.parent.map(instance_id),
            name: record.definition.name.to_string(),
            enabled: node.intent.enabled,
            retired: node.intent.retired,
            state: node.state.into(),
            activation_id: node.activation.map(|id| id.raw().to_string()),
            generation_id: node.generation.map(|id| id.raw().to_string()),
            required: capabilities(&record.definition.required),
            provided: capabilities(&record.definition.provided),
            bindings: SnapshotList(node.bindings.into_iter().map(binding).collect()),
            failed_bindings: SnapshotList(node.failed_bindings.into_iter().map(binding).collect()),
            children: SnapshotList(node.children.into_iter().map(instance_id).collect()),
            dependents: SnapshotList(node.dependents.into_iter().map(instance_id).collect()),
            replacement_requested: node.replacement_requested,
            cleanup_failed: node.cleanup_failed,
            authority: match record.authority {
                ActivationAuthority::Detached => PluginAuthority::Detached,
                ActivationAuthority::Resources(_) => PluginAuthority::Resources,
                ActivationAuthority::Cleanup(_) => PluginAuthority::Cleanup,
            },
            blockers: SnapshotList(
                node.blockers
                    .into_iter()
                    .map(|blocker| blocker_snapshot(&state, blocker))
                    .collect(),
            ),
            diagnostic: record.last_diagnostic.clone(),
            last_failure: record.last_failure.clone(),
            last_graph_diagnostic: node
                .last_diagnostic
                .map(|kind| diagnostic_blocker(&state, kind)),
            effects: SnapshotList(
                record
                    .effect_states
                    .iter()
                    .map(|(ordinal, effect)| PluginEffectSnapshot {
                        owner_id: instance_id(node.id),
                        // Native registration knows the context that owns the inverse, not a broker caller.
                        source_id: instance_id(node.id),
                        activation_id: effect.activation.raw().to_string(),
                        ordinal: ordinal.to_string(),
                        state: effect.state,
                    })
                    .collect(),
            ),
        });
    }
    Ok(PluginRuntimeSnapshot {
        instances: SnapshotList(instances),
        diagnostics: SnapshotList(
            graph
                .diagnostics
                .into_iter()
                .map(|diagnostic| PluginDiagnosticSnapshot {
                    instance_id: instance_id(diagnostic.instance),
                    severity: match diagnostic.kind.severity() {
                        Severity::Waiting => PluginDiagnosticSeverity::Waiting,
                        Severity::Error => PluginDiagnosticSeverity::Error,
                    },
                    blocker: diagnostic_blocker(&state, diagnostic.kind),
                })
                .collect(),
        ),
        shutdown_requested: graph.shutdown_requested,
        draining: state.draining,
        closing: state.closing,
        closed: state.closed,
    })
}

pub(crate) fn records() -> Vec<Record> {
    vec![
        PluginContractSnapshot::RECORD,
        PluginCapabilitySnapshot::RECORD,
        PluginBindingSnapshot::RECORD,
        PluginEffectSnapshot::RECORD,
        PluginBlockerSnapshot::RECORD,
        PluginDiagnosticSnapshot::RECORD,
        PluginInstanceSnapshot::RECORD,
        PluginRuntimeSnapshot::RECORD,
    ]
}

pub(super) fn instance_id(id: InstanceId) -> String {
    id.raw().to_string()
}

fn capabilities(fields: &[DeclarationField]) -> SnapshotList<PluginCapabilitySnapshot> {
    SnapshotList(
        fields
            .iter()
            .map(|field| PluginCapabilitySnapshot {
                field: field.field.clone(),
                contract: contract_snapshot(field.key.clone()),
            })
            .collect(),
    )
}

fn contract_snapshot(key: ContractKey) -> PluginContractSnapshot {
    PluginContractSnapshot {
        name: key.name().to_owned(),
        schema: key.schema(),
        display: key.to_string(),
    }
}

fn binding_snapshot(graph: &Graph, binding: Binding) -> PluginBindingSnapshot {
    PluginBindingSnapshot {
        current: graph.binding_is_current(&binding),
        contract: contract_snapshot(binding.contract),
        provider_id: instance_id(binding.provider),
        generation_id: binding.generation.raw().to_string(),
    }
}

fn blocker_snapshot(state: &RuntimeState, blocker: Blocker) -> PluginBlockerSnapshot {
    let (kind, message, contract, related_id, generation_id) = match blocker {
        Blocker::Diagnostic(kind) => return diagnostic_blocker(state, kind),
        Blocker::Shutdown => (
            PluginBlockerKind::Shutdown,
            "runtime shutdown requested".to_owned(),
            None,
            None,
            None,
        ),
        Blocker::Disabled => (
            PluginBlockerKind::Disabled,
            "instance is not enabled".to_owned(),
            None,
            None,
            None,
        ),
        Blocker::Retired => (
            PluginBlockerKind::Retired,
            "instance is permanently retired".to_owned(),
            None,
            None,
            None,
        ),
        Blocker::Quarantined => (
            PluginBlockerKind::Quarantined,
            "an inverse failed; the instance cannot load again".to_owned(),
            None,
            None,
            None,
        ),
        Blocker::ReplacementRequested => (
            PluginBlockerKind::ReplacementRequested,
            "this allocation must end before another can load".to_owned(),
            None,
            None,
            None,
        ),
        Blocker::FailedBindingsUnchanged => (
            PluginBlockerKind::FailedBindingsUnchanged,
            "the last load failed against the current provider bindings".to_owned(),
            None,
            None,
            None,
        ),
        Blocker::ParentUnavailable { parent } => (
            PluginBlockerKind::ParentUnavailable,
            format!("parent {} is not available", state.label(parent)),
            None,
            Some(instance_id(parent)),
            None,
        ),
        Blocker::ProviderUnavailable { binding } => (
            PluginBlockerKind::ProviderUnavailable,
            format!(
                "bound provider {} at {} is not available",
                state.label(binding.provider),
                binding.generation
            ),
            Some(contract_snapshot(binding.contract)),
            Some(instance_id(binding.provider)),
            Some(binding.generation.raw().to_string()),
        ),
        Blocker::ContractHeld { contract, owner } => (
            PluginBlockerKind::ContractHeld,
            format!(
                "contract {contract} is still held by {}",
                state.label(owner)
            ),
            Some(contract_snapshot(contract)),
            Some(instance_id(owner)),
            None,
        ),
        Blocker::ProviderPending { required, provider } => (
            PluginBlockerKind::ProviderPending,
            format!(
                "provider {} of {required} is not ready",
                state.label(provider)
            ),
            Some(contract_snapshot(required)),
            Some(instance_id(provider)),
            None,
        ),
    };
    PluginBlockerSnapshot {
        kind,
        message,
        contract,
        related_id,
        generation_id,
        provided: None,
        instance_ids: SnapshotList(Vec::new()),
    }
}

fn diagnostic_blocker(state: &RuntimeState, diagnostic: DiagnosticKind) -> PluginBlockerSnapshot {
    let message = diagnostic.describe(&|id| state.label(id).to_string());
    let (kind, contract, provided, related_id, instance_ids) = match diagnostic {
        DiagnosticKind::MissingProvider { required } => (
            PluginBlockerKind::MissingProvider,
            Some(required),
            None,
            None,
            Vec::new(),
        ),
        DiagnosticKind::ProviderDisabled { required, provider } => (
            PluginBlockerKind::ProviderDisabled,
            Some(required),
            None,
            Some(provider),
            Vec::new(),
        ),
        DiagnosticKind::SchemaMismatch {
            required,
            provided,
            provider,
        } => (
            PluginBlockerKind::SchemaMismatch,
            Some(required),
            Some(provided),
            Some(provider),
            Vec::new(),
        ),
        DiagnosticKind::ProviderQuarantined { required, provider } => (
            PluginBlockerKind::ProviderQuarantined,
            Some(required),
            None,
            Some(provider),
            Vec::new(),
        ),
        DiagnosticKind::ContractQuarantined { key, owner } => (
            PluginBlockerKind::ContractQuarantined,
            Some(key),
            None,
            Some(owner),
            Vec::new(),
        ),
        DiagnosticKind::PublishConflict { key, owner } => (
            PluginBlockerKind::PublishConflict,
            Some(key),
            None,
            Some(owner),
            Vec::new(),
        ),
        DiagnosticKind::DependencyCycle { instances } => (
            PluginBlockerKind::DependencyCycle,
            None,
            None,
            None,
            instances,
        ),
        DiagnosticKind::ActivationsExhausted => (
            PluginBlockerKind::ActivationsExhausted,
            None,
            None,
            None,
            Vec::new(),
        ),
    };
    PluginBlockerSnapshot {
        kind,
        message,
        contract: contract.map(contract_snapshot),
        provided: provided.map(contract_snapshot),
        related_id: related_id.map(instance_id),
        generation_id: None,
        instance_ids: SnapshotList(instance_ids.into_iter().map(instance_id).collect()),
    }
}

#[cfg(test)]
mod tests;
