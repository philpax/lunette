//! Detached inspection records for the lifecycle graph.

use std::collections::BTreeMap;

use crate::plugin::graph::{
    ActivationId, Binding, Graph, InstanceId, IntentState, LifecycleState, ProviderGeneration,
    lifecycle::Phase,
};

/// A coherent, read-only copy of graph state. Inspection does not plan transitions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraphSnapshot {
    pub instances: Vec<InstanceSnapshot>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstanceSnapshot {
    pub id: InstanceId,
    pub parent: Option<InstanceId>,
    pub intent: IntentState,
    pub state: LifecycleState,
    pub activation: Option<ActivationId>,
    /// The generation published by this allocation, including while it unloads.
    pub generation: Option<ProviderGeneration>,
    /// Exact bindings of a loading, active, or unloading allocation only.
    pub bindings: Vec<Binding>,
    pub failed_bindings: Vec<Binding>,
    pub children: Vec<InstanceId>,
    /// Instances with live allocations bound to this instance, not declared candidates.
    pub dependents: Vec<InstanceId>,
    pub replacement_requested: bool,
    pub cleanup_failed: bool,
}

impl Graph {
    /// Copies all currently retained instances without draining actions.
    #[must_use]
    pub fn snapshot(&self) -> GraphSnapshot {
        let mut children: BTreeMap<InstanceId, Vec<InstanceId>> = BTreeMap::new();
        let mut dependents: BTreeMap<InstanceId, Vec<InstanceId>> = BTreeMap::new();
        // The ordered instance scan preserves list order and groups each consumer's bindings.
        for (id, node) in &self.instances {
            if let Some(parent) = node.parent {
                children.entry(parent).or_default().push(*id);
            }
            if let Some(allocation) = node.phase.allocation() {
                for binding in &allocation.bindings {
                    let bound = dependents.entry(binding.provider).or_default();
                    // Distinct contracts can bind the same consumer to one provider.
                    if bound.last() != Some(id) {
                        bound.push(*id);
                    }
                }
            }
        }
        GraphSnapshot {
            instances: self
                .instances
                .iter()
                .map(|(id, node)| {
                    let allocation = node.phase.allocation();
                    InstanceSnapshot {
                        id: *id,
                        parent: node.parent,
                        intent: node.intent,
                        state: node.phase.state(),
                        activation: allocation.map(|allocation| allocation.activation),
                        generation: allocation
                            .and_then(|allocation| allocation.published_generation),
                        bindings: allocation
                            .map_or_else(Vec::new, |allocation| allocation.bindings.clone()),
                        failed_bindings: match &node.phase {
                            Phase::Failed { against } => against.clone(),
                            _ => Vec::new(),
                        },
                        children: children.remove(id).unwrap_or_default(),
                        dependents: dependents.remove(id).unwrap_or_default(),
                        replacement_requested: allocation
                            .is_some_and(|allocation| allocation.replace),
                        cleanup_failed: node.is_quarantined(),
                    }
                })
                .collect(),
        }
    }
}

#[cfg(test)]
impl Graph {
    /// Preserves the nested-scan implementation as an independent rewrite oracle.
    pub(super) fn snapshot_reference(&self) -> GraphSnapshot {
        GraphSnapshot {
            instances: self
                .instances
                .iter()
                .map(|(id, node)| {
                    let allocation = node.phase.allocation();
                    InstanceSnapshot {
                        id: *id,
                        parent: node.parent,
                        intent: node.intent,
                        state: node.phase.state(),
                        activation: allocation.map(|allocation| allocation.activation),
                        generation: allocation
                            .and_then(|allocation| allocation.published_generation),
                        bindings: allocation
                            .map_or_else(Vec::new, |allocation| allocation.bindings.clone()),
                        failed_bindings: match &node.phase {
                            Phase::Failed { against } => against.clone(),
                            _ => Vec::new(),
                        },
                        children: self
                            .instances
                            .iter()
                            .filter_map(|(child, node)| {
                                (node.parent == Some(*id)).then_some(*child)
                            })
                            .collect(),
                        dependents: self
                            .instances
                            .iter()
                            .filter_map(|(dependent, node)| {
                                node.phase
                                    .allocation()
                                    .is_some_and(|allocation| {
                                        allocation
                                            .bindings
                                            .iter()
                                            .any(|binding| binding.provider == *id)
                                    })
                                    .then_some(*dependent)
                            })
                            .collect(),
                        replacement_requested: allocation
                            .is_some_and(|allocation| allocation.replace),
                        cleanup_failed: node.is_quarantined(),
                    }
                })
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests;
