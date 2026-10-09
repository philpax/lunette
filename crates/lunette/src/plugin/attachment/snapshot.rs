//! Immutable inspection data, detached from native runtime and callback authority.

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
        graph::{Binding, ContractKey, Graph, InstanceId},
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
snapshot_enum!(PluginEffectState, PluginAuthority);

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
    activation_id => "activationId": String,
    ordinal => "ordinal": String,
    state => "state": PluginEffectState,
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
    diagnostic => "diagnostic": Option<String>,
    last_failure => "lastFailure": Option<String>,
    effects => "effects": SnapshotList<PluginEffectSnapshot>,
});
snapshot_record!(PluginRuntimeSnapshot {
    instances => "instances": SnapshotList<PluginInstanceSnapshot>,
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
            diagnostic: record.last_diagnostic.clone(),
            last_failure: record.last_failure.clone(),
            effects: SnapshotList(
                record
                    .effect_states
                    .iter()
                    .map(|(ordinal, effect)| PluginEffectSnapshot {
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

#[cfg(test)]
mod tests;
