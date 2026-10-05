//! Detached inspection records for the lifecycle graph.

use crate::plugin::graph::{
    ActivationId, Binding, ContractKey, Diagnostic, DiagnosticKind, Graph, InstanceId, IntentState,
    LifecycleState, ProviderGeneration, lifecycle::Phase,
};

/// A coherent, read-only copy of graph state. Inspection does not plan transitions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GraphSnapshot {
    pub shutdown_requested: bool,
    pub instances: Vec<InstanceSnapshot>,
    pub diagnostics: Vec<Diagnostic>,
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
    pub required: Vec<ContractKey>,
    pub provided: Vec<ContractKey>,
    /// Exact bindings of a loading, active, or unloading allocation only.
    pub bindings: Vec<Binding>,
    pub failed_bindings: Vec<Binding>,
    pub children: Vec<InstanceId>,
    /// Instances with live allocations bound to this instance, not declared candidates.
    pub dependents: Vec<InstanceId>,
    pub replacement_requested: bool,
    pub cleanup_failed: bool,
    pub blockers: Vec<Blocker>,
    pub last_diagnostic: Option<DiagnosticKind>,
}

/// Current conditions derived from the same lookups and checks as lifecycle planning.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Blocker {
    Shutdown,
    Disabled,
    Retired,
    Quarantined,
    ReplacementRequested,
    ParentUnavailable {
        parent: InstanceId,
    },
    ProviderUnavailable {
        binding: Binding,
    },
    ContractHeld {
        contract: ContractKey,
        owner: InstanceId,
    },
    ProviderPending {
        required: ContractKey,
        provider: InstanceId,
    },
    FailedBindingsUnchanged,
    Diagnostic(DiagnosticKind),
}

#[cfg(test)]
mod tests;

impl Graph {
    /// Copies all currently retained instances without draining actions or diagnostics.
    #[must_use]
    pub fn snapshot(&self) -> GraphSnapshot {
        GraphSnapshot {
            shutdown_requested: self.shutdown_requested,
            diagnostics: self.diagnostics.clone(),
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
                        required: node.required.clone(),
                        provided: node.provided.clone(),
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
                        blockers: self.inspection_blockers(*id),
                        last_diagnostic: node.last_diagnostic.clone(),
                    }
                })
                .collect(),
        }
    }
}
