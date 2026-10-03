//! The pure lifecycle state, intents, and attachment reports.

use std::collections::BTreeMap;

use crate::plugin::graph::{
    ActivationId, Binding, ContractKey, Diagnostic, DiagnosticKind, GraphError, InstanceId,
    ProviderGeneration,
};

/// The lifecycle phase of an installed instance.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LifecycleState {
    /// The instance has no live attachment.
    Inactive,
    /// The coordinator is loading the instance for the recorded activation.
    Loading,
    /// The instance is published and may serve its provided contracts.
    Active,
    /// The coordinator is cleaning up the recorded activation.
    Unloading,
    /// The last load failed. The graph retries it when the providers it would
    /// bind differ from the ones it failed against, or on an explicit enable or
    /// reload.
    Failed,
    /// A cleanup inverse failed. The instance never loads again and keeps its
    /// contract reservations until shutdown completes.
    Quarantined,
}

/// The persistent intent attached to an instance.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IntentState {
    /// Whether the instance should be active when its prerequisites permit it.
    pub enabled: bool,
    /// Whether the instance is retired and must be removed after cleanup.
    /// Retirement is permanent.
    pub retired: bool,
}

/// A request applied to the graph. Intents take effect immediately as state;
/// the transitions they imply are returned by [`Graph::next_action`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Intent {
    /// Enable an instance and reserve its provided contracts. A failed load is
    /// retried.
    Enable(InstanceId),
    /// Disable an instance without retiring it. A live attachment ends, and
    /// the provided contracts are released once it has.
    Disable(InstanceId),
    /// Replace a live attachment, then enable the replacement.
    Reload(InstanceId),
    /// Disable and retire an instance. Retiring a parent retires its children.
    Dispose(InstanceId),
    /// Stop all new loads and drain every live attachment.
    Shutdown,
}

/// A load or unload operation for the coordinator to perform.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Action {
    /// Load the instance and give it the exact provider generations allocated by the graph.
    BeginLoad {
        instance: InstanceId,
        activation: ActivationId,
        /// Requirements in deterministic contract order.
        bindings: Vec<Binding>,
    },
    /// Clean up the instance's current attachment.
    BeginUnload {
        instance: InstanceId,
        activation: ActivationId,
    },
}

/// The result of a load callback.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoadOutcome {
    /// The callback completed successfully. The graph still validates that publication is safe.
    Success,
    /// The coordinator cancelled the load and rolled it back.
    Cancelled,
    /// The callback failed and the coordinator rolled it back.
    Failed,
}

/// What the graph did with a load report.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoadResolution {
    /// The load was published at this generation.
    Published(ProviderGeneration),
    /// The load succeeded but may not be published. The allocation is kept so
    /// the coordinator can roll it back and report [`LoadOutcome::Cancelled`].
    Rejected,
    /// The allocation ended, and the instance is now in this state.
    Ended(LifecycleState),
}

/// Pure, deterministic lifecycle graph state.
///
/// The coordinator performs the actions it returns. A load action is only an
/// allocation proposal: [`Graph::complete_load`] rechecks the intent and every
/// provider generation, so a reentrant disable or reload cannot publish a
/// transient consumer.
#[derive(Debug, Default)]
pub struct Graph {
    pub(super) instances: BTreeMap<InstanceId, Instance>,
    pub(super) shutdown_requested: bool,
    next_instance: u64,
    pub(super) next_activation: u64,
    next_generation: u64,
    pub(super) diagnostics: Vec<Diagnostic>,
}

impl Graph {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Installs a descriptor without reserving, enabling, or loading it.
    ///
    /// A parent must hold a loading or active attachment. The child is retired
    /// when that activation ends.
    pub fn install(
        &mut self,
        mut required: Vec<ContractKey>,
        mut provided: Vec<ContractKey>,
        parent: Option<InstanceId>,
    ) -> Result<InstanceId, GraphError> {
        if self.shutdown_requested {
            return Err(GraphError::ShuttingDown);
        }
        if let Some(parent_id) = parent {
            let parent_node = self
                .instances
                .get(&parent_id)
                .ok_or(GraphError::UnknownInstance(parent_id))?;
            if parent_node.intent.retired {
                return Err(GraphError::Retired(parent_id));
            }
            if !matches!(
                parent_node.phase,
                Phase::Live {
                    stage: Stage::Loading | Stage::Active(_),
                    ..
                }
            ) {
                return Err(GraphError::ParentInactive(parent_id));
            }
        }
        required.sort();
        required.dedup();
        provided.sort();
        if let Some(pair) = provided.windows(2).find(|pair| pair[0] == pair[1]) {
            return Err(GraphError::DuplicateProvided {
                key: pair[0].clone(),
            });
        }
        let instance = self.allocate_instance()?;
        self.instances.insert(
            instance,
            Instance {
                required,
                provided,
                parent,
                phase: Phase::Inactive,
                intent: IntentState {
                    enabled: false,
                    retired: false,
                },
                last_diagnostic: None,
            },
        );
        Ok(instance)
    }

    /// Applies an intent.
    ///
    /// Enable and reload reserve every provided contract and are rejected on a
    /// conflicting provider or a retired or quarantined instance. Disable,
    /// reload, and dispose condemn a live attachment, so a disable then an enable
    /// restarts the instance.
    pub fn request(&mut self, intent: Intent) -> Result<(), GraphError> {
        let instance = match intent {
            Intent::Shutdown => {
                self.shutdown_requested = true;
                return Ok(());
            }
            Intent::Enable(instance)
            | Intent::Disable(instance)
            | Intent::Reload(instance)
            | Intent::Dispose(instance) => instance,
        };
        if self.shutdown_requested {
            return Err(GraphError::ShuttingDown);
        }
        let node = self
            .instances
            .get(&instance)
            .ok_or(GraphError::UnknownInstance(instance))?;
        match intent {
            Intent::Enable(_) | Intent::Reload(_) => {
                self.check_enable(instance, node)?;
                let reload = matches!(intent, Intent::Reload(_));
                let node = self.node_mut(instance)?;
                node.intent.enabled = true;
                node.last_diagnostic = None;
                match &mut node.phase {
                    Phase::Failed { .. } => node.phase = Phase::Inactive,
                    Phase::Live { allocation, stage } if reload && *stage != Stage::Unloading => {
                        allocation.replace = true;
                    }
                    _ => {}
                }
            }
            Intent::Disable(_) => {
                let node = self.node_mut(instance)?;
                node.intent.enabled = false;
                node.last_diagnostic = None;
                if let Phase::Live { allocation, .. } = &mut node.phase {
                    allocation.replace = true;
                }
            }
            Intent::Dispose(_) => self.retire_subtree(instance),
            Intent::Shutdown => {}
        }
        Ok(())
    }

    /// Reports the outcome of the exact load action returned by [`Self::next_action`].
    ///
    /// A failed or cancelled load must already be rolled back. A rejected success
    /// keeps its allocation for the coordinator to roll back and report as
    /// [`LoadOutcome::Cancelled`].
    pub fn complete_load(
        &mut self,
        instance: InstanceId,
        activation: ActivationId,
        outcome: LoadOutcome,
    ) -> Result<LoadResolution, GraphError> {
        let allocation = self.loading_allocation(instance, activation)?;
        match outcome {
            LoadOutcome::Failed => Ok(self.end_load(instance, true)),
            LoadOutcome::Cancelled => {
                let failed = allocation.rejection.is_some();
                Ok(self.end_load(instance, failed))
            }
            LoadOutcome::Success => {
                if allocation.quarantine_pending || self.must_unload(instance) {
                    return Ok(LoadResolution::Rejected);
                }
                if let Some(conflict) = self.publish_conflict(instance) {
                    self.record_diagnostic(instance, conflict.clone());
                    if let Phase::Live { allocation, .. } = &mut self.node_mut(instance)?.phase {
                        allocation.rejection = Some(conflict);
                    }
                    return Ok(LoadResolution::Rejected);
                }
                let generation = self.allocate_generation()?;
                let node = self.node_mut(instance)?;
                if let Phase::Live { stage, .. } = &mut node.phase {
                    *stage = Stage::Active(generation);
                }
                node.last_diagnostic = None;
                Ok(LoadResolution::Published(generation))
            }
        }
    }

    /// Records that an inverse of a live allocation failed.
    ///
    /// The instance is quarantined when the allocation ends: it never loads again
    /// and keeps its reservations until shutdown. Repeated marks are idempotent.
    pub fn mark_cleanup_failed(
        &mut self,
        instance: InstanceId,
        activation: ActivationId,
    ) -> Result<(), GraphError> {
        let node = self.node_mut(instance)?;
        let Phase::Live { allocation, .. } = &mut node.phase else {
            return Err(GraphError::InvalidAction);
        };
        if allocation.activation != activation {
            return Err(GraphError::StaleAction);
        }
        allocation.quarantine_pending = true;
        Ok(())
    }

    /// Reports completion after every remaining inverse has been attempted.
    ///
    /// A false result, or an earlier [`Self::mark_cleanup_failed`],
    /// quarantines the instance. A clean unload of a retired instance removes
    /// it once it has no children.
    pub fn complete_unload(
        &mut self,
        instance: InstanceId,
        activation: ActivationId,
        cleanup_success: bool,
    ) -> Result<(), GraphError> {
        let node = self.node_mut(instance)?;
        let Phase::Live { allocation, stage } = &node.phase else {
            return Err(GraphError::InvalidAction);
        };
        if *stage != Stage::Unloading || allocation.activation != activation {
            return Err(GraphError::StaleAction);
        }
        let quarantined = !cleanup_success || allocation.quarantine_pending;
        node.phase = if quarantined {
            Phase::Quarantined
        } else {
            Phase::Inactive
        };
        self.retire_children(instance);
        self.remove_retired();
        Ok(())
    }

    pub fn state(&self, instance: InstanceId) -> Result<LifecycleState, GraphError> {
        self.node(instance).map(|node| node.phase.state())
    }

    #[must_use]
    pub fn contains(&self, instance: InstanceId) -> bool {
        self.instances.contains_key(&instance)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.instances.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.instances.is_empty()
    }

    /// Returns the stage and the exact provider bindings of the instance's
    /// loading, active, or unloading allocation, when that allocation belongs
    /// to `activation`.
    #[must_use]
    pub fn live(
        &self,
        instance: InstanceId,
        activation: ActivationId,
    ) -> Option<(Stage, &[Binding])> {
        let Phase::Live { stage, allocation } = &self.instances.get(&instance)?.phase else {
            return None;
        };
        (allocation.activation == activation).then_some((*stage, allocation.bindings.as_slice()))
    }

    /// Checks whether an exact allocation may acquire resources or publish services.
    ///
    /// The allocation must be loading or active and not condemned, directly or
    /// through a provider or parent.
    pub fn activation_is_valid(
        &self,
        instance: InstanceId,
        activation: ActivationId,
    ) -> Result<bool, GraphError> {
        let node = self.node(instance)?;
        let Phase::Live { stage, allocation } = &node.phase else {
            return Ok(false);
        };
        Ok(allocation.activation == activation
            && match stage {
                Stage::Loading => !allocation.quarantine_pending,
                Stage::Active(_) => true,
                Stage::Unloading => false,
            }
            && !self.must_unload(instance))
    }

    /// Reports whether the instance is quarantined, or will be when its live
    /// allocation ends.
    pub fn cleanup_failed(&self, instance: InstanceId) -> Result<bool, GraphError> {
        self.node(instance).map(Instance::is_quarantined)
    }

    /// Reports whether a binding still names its provider's published generation.
    #[must_use]
    pub fn binding_is_current(&self, binding: &Binding) -> bool {
        self.instances.get(&binding.provider).is_some_and(|node| {
            matches!(
                node.phase,
                Phase::Live { stage: Stage::Active(generation), .. }
                    if generation == binding.generation
            )
        })
    }

    /// Returns and clears diagnostics accumulated while planning transitions.
    ///
    /// An instance's diagnostic is recorded once until its blocking condition
    /// or its intent changes, so repeated polling does not duplicate it.
    pub fn take_diagnostics(&mut self) -> Vec<Diagnostic> {
        std::mem::take(&mut self.diagnostics)
    }

    pub(super) fn node(&self, instance: InstanceId) -> Result<&Instance, GraphError> {
        self.instances
            .get(&instance)
            .ok_or(GraphError::UnknownInstance(instance))
    }

    pub(super) fn node_mut(&mut self, instance: InstanceId) -> Result<&mut Instance, GraphError> {
        self.instances
            .get_mut(&instance)
            .ok_or(GraphError::UnknownInstance(instance))
    }

    fn allocate_instance(&mut self) -> Result<InstanceId, GraphError> {
        let id = self
            .next_instance
            .checked_add(1)
            .ok_or(GraphError::IdExhausted)?;
        self.next_instance = id;
        Ok(InstanceId::from_raw(id))
    }

    pub(super) fn allocate_activation(&mut self) -> Result<ActivationId, GraphError> {
        let id = self
            .next_activation
            .checked_add(1)
            .ok_or(GraphError::IdExhausted)?;
        self.next_activation = id;
        Ok(ActivationId::from_raw(id))
    }

    fn allocate_generation(&mut self) -> Result<ProviderGeneration, GraphError> {
        let id = self
            .next_generation
            .checked_add(1)
            .ok_or(GraphError::IdExhausted)?;
        self.next_generation = id;
        Ok(ProviderGeneration::from_raw(id))
    }

    /// Rejects an enable or reload that cannot hold the instance's reservations.
    fn check_enable(&self, instance: InstanceId, node: &Instance) -> Result<(), GraphError> {
        if node.is_quarantined() {
            return Err(GraphError::Quarantined(instance));
        }
        if node.intent.retired {
            return Err(GraphError::Retired(instance));
        }
        // The first rival that is or will be quarantined, or that claims the
        // contract by intent, rejects the request.
        for (key, owner, other) in self.rivals(instance, node) {
            if other.is_quarantined() {
                return Err(GraphError::ContractQuarantined {
                    key: key.clone(),
                    owner,
                });
            }
            if other.claims() {
                return Err(GraphError::ContractConflict {
                    key: key.clone(),
                    owner,
                });
            }
        }
        Ok(())
    }

    /// Iterates the other instances that provide a contract `node` provides,
    /// each with the contract they share, contract by contract.
    pub(super) fn rivals<'a>(
        &'a self,
        instance: InstanceId,
        node: &'a Instance,
    ) -> impl Iterator<Item = (&'a ContractKey, InstanceId, &'a Instance)> {
        node.provided.iter().flat_map(move |key| {
            self.instances
                .iter()
                .filter(move |(other, other_node)| {
                    **other != instance && other_node.provided.contains(key)
                })
                .map(move |(other, other_node)| (key, *other, other_node))
        })
    }

    fn loading_allocation(
        &self,
        instance: InstanceId,
        activation: ActivationId,
    ) -> Result<Allocation, GraphError> {
        let node = self.node(instance)?;
        let Phase::Live { stage, allocation } = &node.phase else {
            return Err(GraphError::InvalidAction);
        };
        if *stage != Stage::Loading || allocation.activation != activation {
            return Err(GraphError::StaleAction);
        }
        Ok(allocation.clone())
    }

    /// Ends a loading allocation that will not be published.
    fn end_load(&mut self, instance: InstanceId, failed: bool) -> LoadResolution {
        let Some(node) = self.instances.get_mut(&instance) else {
            return LoadResolution::Ended(LifecycleState::Inactive);
        };
        let Phase::Live { allocation, .. } = &node.phase else {
            return LoadResolution::Ended(node.phase.state());
        };
        let next = if allocation.quarantine_pending {
            Phase::Quarantined
        } else if failed {
            Phase::Failed {
                against: allocation.bindings.clone(),
            }
        } else {
            Phase::Inactive
        };
        node.phase = next;
        let state = node.phase.state();
        self.retire_children(instance);
        self.remove_retired();
        LoadResolution::Ended(state)
    }

    /// Finds a provided contract that another instance holds at publication.
    fn publish_conflict(&self, instance: InstanceId) -> Option<DiagnosticKind> {
        let node = self.instances.get(&instance)?;
        // Only a rival that holds an allocation or is quarantined conflicts
        // here. A claim alone does not: the claimant has not loaded.
        self.rivals(instance, node).find_map(|(key, owner, other)| {
            (other.phase.allocation().is_some() || other.is_quarantined()).then(|| {
                DiagnosticKind::PublishConflict {
                    key: key.clone(),
                    owner,
                }
            })
        })
    }

    pub(super) fn retire_children(&mut self, parent: InstanceId) {
        let children: Vec<_> = self
            .instances
            .iter()
            .filter_map(|(id, node)| (node.parent == Some(parent)).then_some(*id))
            .collect();
        for child in children {
            self.retire_subtree(child);
        }
    }

    fn retire_subtree(&mut self, root: InstanceId) {
        if let Some(node) = self.instances.get_mut(&root) {
            node.intent.enabled = false;
            node.intent.retired = true;
            node.last_diagnostic = None;
            if let Phase::Live { allocation, .. } = &mut node.phase {
                allocation.replace = true;
            }
        }
        self.retire_children(root);
    }

    /// Removes retired instances that have no attachment and no children.
    ///
    /// Children always carry larger identities than their parents, so one
    /// pass in descending order removes a whole retired subtree.
    pub(super) fn remove_retired(&mut self) {
        let candidates: Vec<InstanceId> = self.instances.keys().rev().copied().collect();
        for instance in candidates {
            let removable = self.instances.get(&instance).is_some_and(|node| {
                node.intent.retired && matches!(node.phase, Phase::Inactive | Phase::Failed { .. })
            }) && !self
                .instances
                .values()
                .any(|node| node.parent == Some(instance));
            if removable {
                self.instances.remove(&instance);
            }
        }
    }

    pub(super) fn finish_shutdown(&mut self) {
        if self
            .instances
            .values()
            .any(|node| node.phase.allocation().is_some())
        {
            return;
        }
        self.instances.clear();
    }

    pub(super) fn begin_load(
        &mut self,
        instance: InstanceId,
        bindings: Vec<Binding>,
    ) -> Option<Action> {
        // The planner has no error channel, so exhaustion is reported the way
        // every other reason an enabled instance cannot load is.
        let Ok(activation) = self.allocate_activation() else {
            self.record_diagnostic(instance, DiagnosticKind::ActivationsExhausted);
            return None;
        };
        let node = self.instances.get_mut(&instance)?;
        node.phase = Phase::Live {
            stage: Stage::Loading,
            allocation: Allocation {
                activation,
                bindings: bindings.clone(),
                replace: false,
                quarantine_pending: false,
                rejection: None,
            },
        };
        node.last_diagnostic = None;
        Some(Action::BeginLoad {
            instance,
            activation,
            bindings,
        })
    }

    pub(super) fn begin_unload(&mut self, instance: InstanceId) -> Option<Action> {
        let node = self.instances.get_mut(&instance)?;
        let Phase::Live { stage, allocation } = &mut node.phase else {
            return None;
        };
        *stage = Stage::Unloading;
        Some(Action::BeginUnload {
            instance,
            activation: allocation.activation,
        })
    }

    pub(super) fn record_diagnostic(&mut self, instance: InstanceId, kind: DiagnosticKind) {
        let Some(node) = self.instances.get_mut(&instance) else {
            return;
        };
        if node.last_diagnostic.as_ref() != Some(&kind) {
            node.last_diagnostic = Some(kind.clone());
            self.diagnostics.push(Diagnostic { instance, kind });
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct Instance {
    pub(super) required: Vec<ContractKey>,
    pub(super) provided: Vec<ContractKey>,
    pub(super) parent: Option<InstanceId>,
    pub(super) phase: Phase,
    pub(super) intent: IntentState,
    pub(super) last_diagnostic: Option<DiagnosticKind>,
}

impl Instance {
    /// Whether the instance holds its provided contracts by intent: it is
    /// enabled and not retired, or it is quarantined.
    pub(super) fn claims(&self) -> bool {
        self.is_quarantined() || (self.intent.enabled && !self.intent.retired)
    }

    /// Whether the instance is quarantined, or will be when its live allocation ends.
    pub(super) fn is_quarantined(&self) -> bool {
        match &self.phase {
            Phase::Quarantined => true,
            Phase::Live { allocation, .. } => allocation.quarantine_pending,
            Phase::Inactive | Phase::Failed { .. } => false,
        }
    }
}

/// An instance's lifecycle phase together with the data each phase owns.
#[derive(Clone, Debug)]
pub(super) enum Phase {
    Inactive,
    Failed {
        /// The bindings the failed load was given. The load is retried only
        /// against different ones.
        against: Vec<Binding>,
    },
    Quarantined,
    Live {
        stage: Stage,
        allocation: Allocation,
    },
}

impl Phase {
    pub(super) const fn state(&self) -> LifecycleState {
        match self {
            Self::Inactive => LifecycleState::Inactive,
            Self::Failed { .. } => LifecycleState::Failed,
            Self::Quarantined => LifecycleState::Quarantined,
            Self::Live { stage, .. } => match stage {
                Stage::Loading => LifecycleState::Loading,
                Stage::Active(_) => LifecycleState::Active,
                Stage::Unloading => LifecycleState::Unloading,
            },
        }
    }

    pub(super) const fn allocation(&self) -> Option<&Allocation> {
        match self {
            Self::Live { allocation, .. } => Some(allocation),
            Self::Inactive | Self::Failed { .. } | Self::Quarantined => None,
        }
    }
}

/// The stage of a live allocation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Stage {
    Loading,
    /// The allocation is published at this provider generation.
    Active(ProviderGeneration),
    Unloading,
}

#[derive(Clone, Debug)]
pub(super) struct Allocation {
    pub(super) activation: ActivationId,
    pub(super) bindings: Vec<Binding>,
    /// The allocation must end: the instance was disabled, reloaded, or retired.
    pub(super) replace: bool,
    /// An inverse failed, so the instance is quarantined when the allocation ends.
    pub(super) quarantine_pending: bool,
    /// A successful load that may not publish, and must fail rather than retry.
    pub(super) rejection: Option<DiagnosticKind>,
}
