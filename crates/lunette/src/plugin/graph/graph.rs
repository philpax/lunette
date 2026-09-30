//! The pure lifecycle transition engine.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::plugin::graph::{
    ActivationId, Binding, ContractKey, GraphError, InstanceId, ProviderGeneration,
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
    /// The last load or cleanup failed. A new attempt requires an explicit intent.
    Failed,
}

/// The persistent intent attached to an instance.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IntentState {
    /// Whether the instance should be active when its prerequisites permit it.
    pub enabled: bool,
    /// Whether the instance is retired and must be removed after cleanup.
    pub retired: bool,
}

/// A request sent to the graph. Requests for the same instance coalesce until
/// the coordinator advances the graph with [`Graph::next_action`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Intent {
    /// Enable an instance, clearing a prior retirement and allowing a failed load retry.
    Enable(InstanceId),
    /// Disable an instance without retiring its registration.
    Disable(InstanceId),
    /// Replace an active attachment, then enable the replacement.
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
        /// The instance to load.
        instance: InstanceId,
        /// The unique load attempt.
        activation: ActivationId,
        /// Requirements in deterministic contract order.
        bindings: Vec<Binding>,
    },
    /// Clean up the instance's current attachment.
    BeginUnload {
        /// The instance to clean up.
        instance: InstanceId,
        /// The activation being cleaned up.
        activation: ActivationId,
    },
}

/// The result of a load callback.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoadOutcome {
    /// The callback completed successfully. The graph still validates that publication is safe.
    Success,
    /// The coordinator cancelled the load before it could publish.
    Cancelled,
    /// The callback failed. The instance enters [`LifecycleState::Failed`].
    Failed,
}

/// The state visible to a reader that needs the exact attachment token.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttachmentState {
    /// The attachment is being loaded.
    Loading,
    /// The attachment is published.
    Active,
    /// The attachment is being cleaned up.
    Unloading,
    /// Cleanup failed, so the attachment remains quarantined.
    Failed,
}

/// A copy of the exact allocation held by an instance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttachmentView {
    /// The lifecycle state for which this view is valid.
    pub state: AttachmentState,
    /// The unique activation token.
    pub activation: ActivationId,
    /// The exact provider generations allocated at load start.
    pub bindings: Vec<Binding>,
    /// The published provider generation for this instance, if it is active.
    pub generation: Option<ProviderGeneration>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Failure {
    Load,
    Cleanup,
}

#[derive(Clone, Debug)]
struct Allocation {
    activation: ActivationId,
    bindings: Vec<Binding>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CleanupPhase {
    Complete,
    Remaining,
    Draining,
}

#[derive(Clone, Debug)]
struct Instance {
    required: Vec<ContractKey>,
    provided: Vec<ContractKey>,
    parent: Option<InstanceId>,
    state: LifecycleState,
    intent: IntentState,
    allocation: Option<Allocation>,
    generation: Option<ProviderGeneration>,
    failure: Option<Failure>,
    cleanup_phase: CleanupPhase,
    reload_requested: bool,
    last_diagnostic: Option<GraphError>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Reservation {
    Instance(InstanceId),
}

/// Pure, deterministic lifecycle graph state.
///
/// The graph does not run plugin code. The coordinator installs descriptors,
/// submits intents, performs returned actions, and reports their completion.
/// A load action is an allocation proposal, not publication: the graph checks
/// the intent and every provider generation again in [`Graph::complete_load`].
/// This is the boundary that prevents a reentrant disable or reload from
/// exposing a transient consumer.
#[derive(Debug)]
pub struct Graph {
    instances: BTreeMap<InstanceId, Instance>,
    reservations: BTreeMap<String, Reservation>,
    pending: VecDeque<InstanceId>,
    queue_limit: usize,
    queue_exhausted: bool,
    shutdown_requested: bool,
    shutdown_complete: bool,
    next_instance: u64,
    next_activation: u64,
    next_generation: u64,
    diagnostics: Vec<GraphError>,
    diagnostic_set: BTreeSet<GraphError>,
}

impl Graph {
    /// Creates an empty graph with a bounded, coalescing intent queue.
    #[must_use]
    pub fn new(queue_limit: usize) -> Self {
        Self {
            instances: BTreeMap::new(),
            reservations: BTreeMap::new(),
            pending: VecDeque::new(),
            queue_limit,
            queue_exhausted: false,
            shutdown_requested: false,
            shutdown_complete: false,
            next_instance: 0,
            next_activation: 0,
            next_generation: 0,
            diagnostics: Vec::new(),
            diagnostic_set: BTreeSet::new(),
        }
    }

    /// Installs a descriptor and reserves every provided contract name.
    ///
    /// Reservation is transactional: all names are checked, including schema
    /// mismatches and duplicate names within the descriptor, before the new
    /// instance is inserted. A parent must already be installed, and a parent
    /// cycle is rejected. Installation does not enable or load the instance.
    pub fn install(
        &mut self,
        mut required: Vec<ContractKey>,
        mut provided: Vec<ContractKey>,
        parent: Option<InstanceId>,
    ) -> Result<InstanceId, GraphError> {
        if self.shutdown_requested {
            return Err(GraphError::ShuttingDown);
        }
        if let Some(parent_id) = parent
            && !self.instances.contains_key(&parent_id)
        {
            return Err(GraphError::UnknownInstance(parent_id));
        }
        required.sort();
        provided.sort();
        if let Some(duplicate) = duplicate_name(&provided) {
            return Err(GraphError::DuplicateProvided {
                name: duplicate.name().to_owned(),
            });
        }

        for key in &provided {
            if let Some(Reservation::Instance(owner)) = self.reservations.get(key.name()) {
                return Err(GraphError::ContractConflict {
                    name: key.name().to_owned(),
                    owner: *owner,
                    attempted: key.clone(),
                });
            }
        }

        let instance = self.allocate_instance()?;
        if let Some(parent_id) = parent
            && self.parent_chain_contains(parent_id, instance)
        {
            return Err(GraphError::ParentCycle {
                child: instance,
                parent: parent_id,
            });
        }
        for key in &provided {
            self.reservations
                .insert(key.name().to_owned(), Reservation::Instance(instance));
        }
        self.instances.insert(
            instance,
            Instance {
                required,
                provided,
                parent,
                state: LifecycleState::Inactive,
                intent: IntentState {
                    enabled: false,
                    retired: false,
                },
                allocation: None,
                generation: None,
                failure: None,
                cleanup_phase: CleanupPhase::Complete,
                reload_requested: false,
                last_diagnostic: None,
            },
        );
        Ok(instance)
    }

    /// Queues an intent. Repeated intents for an instance occupy one queue slot.
    pub fn enqueue(&mut self, intent: Intent) -> Result<(), GraphError> {
        if matches!(intent, Intent::Shutdown) {
            self.shutdown_requested = true;
            self.pending.clear();
            return Ok(());
        }
        if self.shutdown_requested {
            return Err(GraphError::ShuttingDown);
        }
        let instance = intent.instance();
        if !self.instances.contains_key(&instance) {
            return Err(GraphError::UnknownInstance(instance));
        }
        if !self.pending.contains(&instance) && self.pending.len() >= self.queue_limit {
            self.queue_exhausted = true;
            return Err(GraphError::QueueExhausted);
        }
        self.apply_intent(intent)?;
        if !self.pending.contains(&instance) {
            self.pending.push_back(instance);
        }
        Ok(())
    }

    /// Explicitly resumes activation after a queue-exhaustion diagnostic.
    ///
    /// Pending intents are retained and will be coalesced as usual. Shutdown
    /// never requires this call because it always takes priority over loads.
    pub fn resume_after_queue_exhaustion(&mut self) {
        self.queue_exhausted = false;
    }

    /// Returns the next coordinator action, if one is currently safe to start.
    ///
    /// Unloads always precede loads. Dependents and children are selected before
    /// their providers and parents. A blocked dependency records one diagnostic
    /// until that instance's blocking condition changes; repeated polling does
    /// not spin or duplicate the diagnostic.
    pub fn next_action(&mut self) -> Option<Action> {
        self.remove_retired_without_attachment();
        if self.shutdown_requested {
            return self.next_shutdown_action();
        }
        if self.queue_exhausted {
            return None;
        }
        let _ = self.pending.pop_front();
        let draining: Vec<_> = self
            .instances
            .keys()
            .copied()
            .filter(|id| {
                self.instances
                    .get(id)
                    .is_some_and(|node| node.allocation.is_some())
                    && self.must_unload(*id)
            })
            .collect();
        for instance in draining {
            self.retire_children(instance);
        }
        if let Some(action) = self.plan_unload() {
            return Some(action);
        }
        self.plan_load()
    }

    /// Reports the outcome of the exact load action returned by [`Self::next_action`].
    ///
    /// A rejected success retains the loading allocation for rollback. The coordinator
    /// reports [`LoadOutcome::Cancelled`] only after cleanup succeeds, or quarantines
    /// the allocation with [`Self::mark_cleanup_failed`] if an inverse fails.
    pub fn complete_load(
        &mut self,
        instance: InstanceId,
        activation: ActivationId,
        outcome: LoadOutcome,
    ) -> Result<(), GraphError> {
        let node = self
            .instances
            .get_mut(&instance)
            .ok_or(GraphError::UnknownInstance(instance))?;
        let allocation = node
            .allocation
            .as_ref()
            .ok_or(GraphError::InvalidAction)?
            .clone();
        if node.state != LifecycleState::Loading || allocation.activation != activation {
            return Err(GraphError::StaleAction);
        }
        if matches!(outcome, LoadOutcome::Failed) {
            node.state = LifecycleState::Failed;
            node.failure = Some(Failure::Load);
            node.allocation = None;
            node.last_diagnostic = None;
            return Ok(());
        }
        let can_publish = matches!(outcome, LoadOutcome::Success)
            && self.load_is_still_valid(instance, &allocation)
            && self.reserve_instance(instance).is_ok();
        if matches!(outcome, LoadOutcome::Success) && !can_publish {
            return Ok(());
        }
        let generation = if can_publish {
            Some(self.allocate_generation()?)
        } else {
            None
        };
        let release_reservation = {
            let node = self
                .instances
                .get_mut(&instance)
                .ok_or(GraphError::UnknownInstance(instance))?;
            let release = if let Some(generation) = generation {
                node.state = LifecycleState::Active;
                node.failure = None;
                node.generation = Some(generation);
                node.reload_requested = false;
                false
            } else {
                let release = !node.intent.enabled || node.intent.retired;
                node.state = LifecycleState::Inactive;
                node.failure = None;
                node.allocation = None;
                node.generation = None;
                release
            };
            node.last_diagnostic = None;
            release
        };
        if release_reservation {
            self.release_reservation(instance);
        }
        Ok(())
    }

    /// Quarantines an allocation whose rollback or explicit cleanup failed.
    ///
    /// Call instead of completing a load when rollback fails, or after an explicit
    /// effect disposal fails. Shutdown issues one unload for remaining effects,
    /// before providers and parents. The attachment must remove each attempted
    /// inverse before invoking it so a failed inverse is not retried. Reservations
    /// remain quarantined until shutdown finishes. Repeated marks are idempotent.
    pub fn mark_cleanup_failed(
        &mut self,
        instance: InstanceId,
        activation: ActivationId,
    ) -> Result<(), GraphError> {
        let node = self
            .instances
            .get_mut(&instance)
            .ok_or(GraphError::UnknownInstance(instance))?;
        let allocation = node.allocation.as_ref().ok_or(GraphError::InvalidAction)?;
        if allocation.activation != activation {
            return Err(GraphError::StaleAction);
        }
        if node.failure == Some(Failure::Cleanup) {
            return Ok(());
        }
        node.state = LifecycleState::Failed;
        node.failure = Some(Failure::Cleanup);
        node.cleanup_phase = CleanupPhase::Remaining;
        node.generation = None;
        node.last_diagnostic = None;
        self.retire_children(instance);
        Ok(())
    }

    /// Reports completion after all remaining inverses have been attempted.
    ///
    /// A false result quarantines reservations but does not schedule a retry.
    /// A previously quarantined allocation remains failed even on success.
    pub fn complete_unload(
        &mut self,
        instance: InstanceId,
        activation: ActivationId,
        cleanup_success: bool,
    ) -> Result<(), GraphError> {
        let retired = {
            let node = self
                .instances
                .get_mut(&instance)
                .ok_or(GraphError::UnknownInstance(instance))?;
            let allocation = node
                .allocation
                .as_ref()
                .ok_or(GraphError::InvalidAction)?
                .clone();
            if node.state != LifecycleState::Unloading || allocation.activation != activation {
                return Err(GraphError::StaleAction);
            }
            if node.failure == Some(Failure::Cleanup) {
                node.cleanup_phase = CleanupPhase::Complete;
                node.state = LifecycleState::Failed;
                return Ok(());
            }
            node.cleanup_phase = CleanupPhase::Complete;
            if cleanup_success {
                let retired = node.intent.retired;
                node.state = LifecycleState::Inactive;
                node.failure = None;
                node.allocation = None;
                node.generation = None;
                node.reload_requested = false;
                node.last_diagnostic = None;
                retired
            } else {
                node.state = LifecycleState::Failed;
                node.failure = Some(Failure::Cleanup);
                node.last_diagnostic = None;
                false
            }
        };
        if cleanup_success {
            self.release_reservation(instance);
            if retired {
                self.remove_instance(instance);
            }
        }
        Ok(())
    }

    /// Returns the current lifecycle state for an installed instance.
    pub fn state(&self, instance: InstanceId) -> Result<LifecycleState, GraphError> {
        self.instances
            .get(&instance)
            .map(|node| node.state)
            .ok_or(GraphError::UnknownInstance(instance))
    }

    /// Returns the persistent enabled and retired intent for an instance.
    pub fn intent_state(&self, instance: InstanceId) -> Result<IntentState, GraphError> {
        self.instances
            .get(&instance)
            .map(|node| node.intent)
            .ok_or(GraphError::UnknownInstance(instance))
    }

    /// Returns the exact loading, active, unloading, or quarantined attachment.
    pub fn attachment(&self, instance: InstanceId) -> Result<Option<AttachmentView>, GraphError> {
        let node = self
            .instances
            .get(&instance)
            .ok_or(GraphError::UnknownInstance(instance))?;
        Ok(node.allocation.as_ref().map(|allocation| AttachmentView {
            state: match node.state {
                LifecycleState::Loading => AttachmentState::Loading,
                LifecycleState::Active => AttachmentState::Active,
                LifecycleState::Unloading => AttachmentState::Unloading,
                LifecycleState::Failed => AttachmentState::Failed,
                LifecycleState::Inactive => AttachmentState::Loading,
            },
            activation: allocation.activation,
            bindings: allocation.bindings.clone(),
            generation: node.generation,
        }))
    }

    /// Validates an attachment token and exact bindings for a callback or read.
    ///
    /// This remains valid while an attachment is unloading, which lets the
    /// coordinator keep read authority until cleanup completes without allowing
    /// a new consumer to bind to that attachment.
    pub fn validate_attachment(
        &self,
        instance: InstanceId,
        activation: ActivationId,
        bindings: &[Binding],
    ) -> Result<(), GraphError> {
        let node = self
            .instances
            .get(&instance)
            .ok_or(GraphError::UnknownInstance(instance))?;
        let allocation = node.allocation.as_ref().ok_or(GraphError::InvalidAction)?;
        if allocation.activation != activation || allocation.bindings != bindings {
            return Err(GraphError::StaleAction);
        }
        if !matches!(
            node.state,
            LifecycleState::Loading
                | LifecycleState::Active
                | LifecycleState::Unloading
                | LifecycleState::Failed
        ) {
            return Err(GraphError::InvalidAction);
        }
        Ok(())
    }

    /// Checks whether an exact allocation may acquire resources or publish services.
    /// Read authority during unloading is separate from this lifecycle check.
    pub fn activation_is_valid(
        &self,
        instance: InstanceId,
        activation: ActivationId,
    ) -> Result<bool, GraphError> {
        let node = self
            .instances
            .get(&instance)
            .ok_or(GraphError::UnknownInstance(instance))?;
        let Some(allocation) = node.allocation.as_ref() else {
            return Ok(false);
        };
        Ok(allocation.activation == activation
            && matches!(node.state, LifecycleState::Loading | LifecycleState::Active)
            && self.load_is_still_valid(instance, allocation))
    }

    /// Returns and clears diagnostics accumulated while planning transitions.
    pub fn take_diagnostics(&mut self) -> Vec<GraphError> {
        self.diagnostic_set.clear();
        std::mem::take(&mut self.diagnostics)
    }

    /// Reports whether shutdown has drained all live attachments.
    #[must_use]
    pub const fn is_shutdown(&self) -> bool {
        self.shutdown_complete
    }

    fn allocate_instance(&mut self) -> Result<InstanceId, GraphError> {
        let id = self
            .next_instance
            .checked_add(1)
            .ok_or(GraphError::IdExhausted)?;
        self.next_instance = id;
        Ok(InstanceId::from_raw(id))
    }

    fn allocate_activation(&mut self) -> Result<ActivationId, GraphError> {
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

    fn parent_chain_contains(&self, mut current: InstanceId, sought: InstanceId) -> bool {
        while let Some(node) = self.instances.get(&current) {
            if current == sought {
                return true;
            }
            let Some(parent) = node.parent else {
                return false;
            };
            current = parent;
        }
        false
    }

    fn reserve_instance(&mut self, instance: InstanceId) -> Result<(), GraphError> {
        let Some(node) = self.instances.get(&instance) else {
            return Err(GraphError::UnknownInstance(instance));
        };
        for key in &node.provided {
            if let Some(Reservation::Instance(owner)) = self.reservations.get(key.name())
                && *owner != instance
            {
                return Err(GraphError::ContractConflict {
                    name: key.name().to_owned(),
                    owner: *owner,
                    attempted: key.clone(),
                });
            }
        }
        let provided = node.provided.clone();
        for key in provided {
            self.reservations
                .insert(key.name().to_owned(), Reservation::Instance(instance));
        }
        Ok(())
    }

    fn release_reservation(&mut self, instance: InstanceId) {
        let Some(node) = self.instances.get(&instance) else {
            return;
        };
        let provided = node.provided.clone();
        for key in provided {
            if self.reservations.get(key.name()) == Some(&Reservation::Instance(instance)) {
                self.reservations.remove(key.name());
            }
        }
    }

    fn apply_intent(&mut self, intent: Intent) -> Result<(), GraphError> {
        let Some(instance) = intent.instance_opt() else {
            return Ok(());
        };
        match intent {
            Intent::Enable(_) => {
                self.reserve_instance(instance)?;
                if let Some(node) = self.instances.get_mut(&instance) {
                    node.intent.enabled = true;
                    node.intent.retired = false;
                    node.reload_requested = false;
                    if node.state == LifecycleState::Failed && node.failure == Some(Failure::Load) {
                        node.state = LifecycleState::Inactive;
                        node.failure = None;
                    }
                    node.last_diagnostic = None;
                }
            }
            Intent::Disable(_) => {
                if let Some(node) = self.instances.get_mut(&instance) {
                    node.intent.enabled = false;
                    node.reload_requested = false;
                    node.last_diagnostic = None;
                }
            }
            Intent::Reload(_) => {
                if let Some(node) = self.instances.get_mut(&instance) {
                    let reload_requested = matches!(
                        node.state,
                        LifecycleState::Loading
                            | LifecycleState::Active
                            | LifecycleState::Unloading
                    );
                    node.intent.enabled = true;
                    node.intent.retired = false;
                    node.reload_requested = reload_requested;
                    if node.state == LifecycleState::Failed && node.failure == Some(Failure::Load) {
                        node.state = LifecycleState::Inactive;
                        node.failure = None;
                        node.reload_requested = false;
                    }
                    node.last_diagnostic = None;
                }
            }
            Intent::Dispose(_) => {
                self.retire_subtree(instance);
            }
            Intent::Shutdown => {}
        }
        Ok(())
    }

    fn retire_children(&mut self, parent: InstanceId) {
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
        let children: Vec<InstanceId> = self
            .instances
            .iter()
            .filter_map(|(id, node)| (node.parent == Some(root)).then_some(*id))
            .collect();
        if let Some(node) = self.instances.get_mut(&root) {
            node.intent.enabled = false;
            node.intent.retired = true;
            node.reload_requested = false;
            node.last_diagnostic = None;
        }
        for child in children {
            self.retire_subtree(child);
        }
    }

    fn remove_retired_without_attachment(&mut self) {
        let removable: Vec<InstanceId> = self
            .instances
            .iter()
            .filter_map(|(id, node)| {
                (node.intent.retired
                    && node.allocation.is_none()
                    && matches!(
                        node.state,
                        LifecycleState::Inactive | LifecycleState::Failed
                    )
                    && node.failure != Some(Failure::Cleanup)
                    && !self.has_child_with_attachment(*id))
                .then_some(*id)
            })
            .collect();
        for instance in removable {
            self.remove_instance(instance);
        }
    }

    fn remove_instance(&mut self, instance: InstanceId) {
        self.release_reservation(instance);
        self.instances.remove(&instance);
    }

    fn next_shutdown_action(&mut self) -> Option<Action> {
        if let Some(action) = self.plan_unload() {
            return Some(action);
        }
        if self.instances.values().any(|node| {
            matches!(
                node.state,
                LifecycleState::Loading | LifecycleState::Active | LifecycleState::Unloading
            ) || node.cleanup_phase != CleanupPhase::Complete
        }) {
            return None;
        }
        self.instances.clear();
        self.reservations.clear();
        self.shutdown_complete = true;
        None
    }

    fn plan_unload(&mut self) -> Option<Action> {
        let candidates: Vec<InstanceId> = self.instances.keys().copied().collect();
        for instance in candidates {
            let should_unload = self.instances.get(&instance).is_some_and(|node| {
                (node.state == LifecycleState::Active && self.must_unload(instance))
                    || (self.shutdown_requested
                        && node.state == LifecycleState::Failed
                        && node.cleanup_phase == CleanupPhase::Remaining)
            });
            if should_unload && self.can_unload_now(instance) {
                return self.begin_unload(instance);
            }
        }
        None
    }

    fn can_unload_now(&self, instance: InstanceId) -> bool {
        !self.has_active_dependent(instance) && !self.has_child_with_attachment(instance)
    }

    fn begin_unload(&mut self, instance: InstanceId) -> Option<Action> {
        let node = self.instances.get_mut(&instance)?;
        let activation = node.allocation.as_ref()?.activation;
        node.state = LifecycleState::Unloading;
        if node.cleanup_phase == CleanupPhase::Remaining {
            node.cleanup_phase = CleanupPhase::Draining;
        }
        Some(Action::BeginUnload {
            instance,
            activation,
        })
    }

    fn plan_load(&mut self) -> Option<Action> {
        let candidates: Vec<InstanceId> = self.instances.keys().copied().collect();
        for instance in candidates {
            let Some(node) = self.instances.get(&instance) else {
                continue;
            };
            if node.state != LifecycleState::Inactive
                || !node.intent.enabled
                || node.intent.retired
                || node.reload_requested
            {
                continue;
            }
            if !self.parent_is_active(instance) {
                continue;
            }
            let Some(bindings) = self.resolve_bindings(instance) else {
                continue;
            };
            let activation = match self.allocate_activation() {
                Ok(value) => value,
                Err(error) => {
                    self.diagnostics.push(error);
                    return None;
                }
            };
            let Some(node) = self.instances.get_mut(&instance) else {
                continue;
            };
            node.state = LifecycleState::Loading;
            node.failure = None;
            node.allocation = Some(Allocation {
                activation,
                bindings: bindings.clone(),
            });
            return Some(Action::BeginLoad {
                instance,
                activation,
                bindings,
            });
        }
        None
    }

    fn resolve_bindings(&mut self, instance: InstanceId) -> Option<Vec<Binding>> {
        if let Some(cycle) = self.dependency_cycle(instance) {
            self.record_diagnostic(instance, GraphError::DependencyCycle { instances: cycle });
            return None;
        }
        let required = self.instances.get(&instance)?.required.clone();
        let mut bindings = Vec::with_capacity(required.len());
        for required_key in required {
            let Some(Reservation::Instance(provider)) = self.reservations.get(required_key.name())
            else {
                self.record_diagnostic(
                    instance,
                    GraphError::MissingDependency {
                        instance,
                        required: required_key,
                    },
                );
                return None;
            };
            let Some(provider_node) = self.instances.get(provider) else {
                self.record_diagnostic(
                    instance,
                    GraphError::MissingDependency {
                        instance,
                        required: required_key,
                    },
                );
                return None;
            };
            let Some(provided_key) = provider_node
                .provided
                .iter()
                .find(|candidate| candidate.name() == required_key.name())
            else {
                self.record_diagnostic(
                    instance,
                    GraphError::MissingDependency {
                        instance,
                        required: required_key,
                    },
                );
                return None;
            };
            if provided_key.schema() != required_key.schema() {
                self.record_diagnostic(
                    instance,
                    GraphError::SchemaMismatch {
                        instance,
                        required: required_key,
                        provided: provided_key.clone(),
                    },
                );
                return None;
            }
            if *provider == instance {
                self.record_diagnostic(
                    instance,
                    GraphError::DependencyCycle {
                        instances: vec![instance],
                    },
                );
                return None;
            }
            if provider_node.state != LifecycleState::Active
                || provider_node.generation.is_none()
                || provider_node.reload_requested
                || provider_node.intent.retired
                || !provider_node.intent.enabled
            {
                return None;
            }
            let generation = provider_node.generation?;
            bindings.push(Binding::new(required_key, *provider, generation));
        }
        Some(bindings)
    }

    fn dependency_cycle(&self, start: InstanceId) -> Option<Vec<InstanceId>> {
        self.visit_dependencies(start, &mut Vec::new(), &mut BTreeSet::new())
    }

    fn visit_dependencies(
        &self,
        current: InstanceId,
        path: &mut Vec<InstanceId>,
        visited: &mut BTreeSet<InstanceId>,
    ) -> Option<Vec<InstanceId>> {
        if let Some(position) = path.iter().position(|id| *id == current) {
            return Some(canonical_cycle(path[position..].to_vec()));
        }
        if !visited.insert(current) {
            return None;
        }
        let node = self.instances.get(&current)?;
        path.push(current);
        let providers: BTreeSet<_> = node
            .required
            .iter()
            .filter_map(|required| {
                self.reservations
                    .get(required.name())
                    .map(|Reservation::Instance(provider)| *provider)
            })
            .chain(node.parent)
            .collect();
        for provider in providers {
            if let Some(cycle) = self.visit_dependencies(provider, path, visited) {
                return Some(cycle);
            }
        }
        path.pop();
        None
    }

    fn parent_is_active(&self, instance: InstanceId) -> bool {
        self.instances
            .get(&instance)
            .and_then(|node| node.parent)
            .is_none_or(|parent| {
                self.instances.get(&parent).is_some_and(|node| {
                    node.state == LifecycleState::Active && !self.provider_will_unload(parent)
                })
            })
    }

    fn must_unload(&self, instance: InstanceId) -> bool {
        let Some(node) = self.instances.get(&instance) else {
            return false;
        };
        if self.shutdown_requested
            || !node.intent.enabled
            || node.intent.retired
            || node.reload_requested
            || !self.parent_is_active(instance)
            || node.allocation.as_ref().is_some_and(|allocation| {
                allocation
                    .bindings
                    .iter()
                    .any(|binding| self.provider_will_unload(binding.provider))
            })
        {
            return true;
        }
        node.allocation.as_ref().is_some_and(|allocation| {
            allocation.bindings.iter().any(|binding| {
                self.instances
                    .get(&binding.provider)
                    .is_none_or(|provider| {
                        provider.state != LifecycleState::Active
                            || provider.generation != Some(binding.generation)
                            || provider.reload_requested
                            || !provider.intent.enabled
                            || provider.intent.retired
                    })
            })
        })
    }

    fn provider_will_unload(&self, provider: InstanceId) -> bool {
        self.provider_will_unload_with_seen(provider, &mut BTreeSet::new())
    }

    fn provider_will_unload_with_seen(
        &self,
        provider: InstanceId,
        seen: &mut BTreeSet<InstanceId>,
    ) -> bool {
        if !seen.insert(provider) {
            return false;
        }
        let Some(node) = self.instances.get(&provider) else {
            return true;
        };
        if self.shutdown_requested
            || !node.intent.enabled
            || node.intent.retired
            || node.reload_requested
            || node.state != LifecycleState::Active
            || node
                .parent
                .is_some_and(|parent| self.provider_will_unload_with_seen(parent, seen))
        {
            return true;
        }
        node.allocation.as_ref().is_some_and(|allocation| {
            allocation
                .bindings
                .iter()
                .any(|binding| self.provider_will_unload_with_seen(binding.provider, seen))
        })
    }

    fn load_is_still_valid(&self, instance: InstanceId, allocation: &Allocation) -> bool {
        let Some(node) = self.instances.get(&instance) else {
            return false;
        };
        if !node.intent.enabled
            || node.intent.retired
            || node.reload_requested
            || self.shutdown_requested
            || !self.parent_is_active(instance)
        {
            return false;
        }
        allocation.bindings.iter().all(|binding| {
            self.instances
                .get(&binding.provider)
                .is_some_and(|provider| {
                    provider.state == LifecycleState::Active
                        && provider.generation == Some(binding.generation)
                        && !provider.reload_requested
                        && provider.intent.enabled
                        && !provider.intent.retired
                })
        })
    }

    fn has_active_dependent(&self, provider: InstanceId) -> bool {
        self.instances.values().any(|node| {
            (matches!(
                node.state,
                LifecycleState::Active | LifecycleState::Loading | LifecycleState::Unloading
            ) || (node.failure == Some(Failure::Cleanup)
                && (!self.shutdown_requested || node.cleanup_phase != CleanupPhase::Complete)))
                && node.allocation.as_ref().is_some_and(|allocation| {
                    allocation
                        .bindings
                        .iter()
                        .any(|binding| binding.provider == provider)
                })
        })
    }

    fn has_child_with_attachment(&self, parent: InstanceId) -> bool {
        self.instances.values().any(|node| {
            node.parent == Some(parent)
                && !(self.shutdown_requested
                    && node.failure == Some(Failure::Cleanup)
                    && node.cleanup_phase == CleanupPhase::Complete)
                && matches!(
                    node.state,
                    LifecycleState::Loading
                        | LifecycleState::Active
                        | LifecycleState::Unloading
                        | LifecycleState::Failed
                )
                && node.allocation.is_some()
        })
    }

    fn record_diagnostic(&mut self, instance: InstanceId, diagnostic: GraphError) {
        let Some(node) = self.instances.get_mut(&instance) else {
            return;
        };
        if node.last_diagnostic.as_ref() != Some(&diagnostic) {
            if self.diagnostic_set.insert(diagnostic.clone()) {
                self.diagnostics.push(diagnostic.clone());
            }
            node.last_diagnostic = Some(diagnostic);
        }
    }
}

fn canonical_cycle(mut cycle: Vec<InstanceId>) -> Vec<InstanceId> {
    if let Some((offset, _)) = cycle.iter().enumerate().min_by_key(|(_, id)| *id) {
        cycle.rotate_left(offset);
    }
    cycle.push(cycle[0]);
    cycle
}

fn duplicate_name(keys: &[ContractKey]) -> Option<ContractKey> {
    keys.windows(2)
        .find(|pair| pair[0].name() == pair[1].name())
        .map(|pair| pair[1].clone())
}

impl Intent {
    fn instance(self) -> InstanceId {
        match self {
            Self::Enable(instance)
            | Self::Disable(instance)
            | Self::Reload(instance)
            | Self::Dispose(instance) => instance,
            Self::Shutdown => InstanceId::from_raw(0),
        }
    }

    fn instance_opt(self) -> Option<InstanceId> {
        match self {
            Self::Enable(instance)
            | Self::Disable(instance)
            | Self::Reload(instance)
            | Self::Dispose(instance) => Some(instance),
            Self::Shutdown => None,
        }
    }
}
