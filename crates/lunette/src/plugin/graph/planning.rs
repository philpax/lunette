//! Plans lifecycle transitions and diagnostics for enabled instances.

use std::collections::BTreeSet;

use crate::plugin::graph::{
    Action, Binding, ContractKey, DiagnosticKind, Graph, InstanceId,
    lifecycle::{Phase, Stage},
};

impl Graph {
    /// Returns the next coordinator action.
    ///
    /// Unloads take priority over loads. Dependents and children unload first; providers and
    /// parents unload after them.
    pub fn next_action(&mut self) -> Option<Action> {
        self.retire_children_of_ending_parents();
        self.remove_retired();
        if let Some(action) = self.plan_unload() {
            return Some(action);
        }
        if self.shutdown_requested {
            self.finish_shutdown();
            return None;
        }
        self.plan_load()
    }

    ///
    /// It must end when the instance is disabled, retired, reloaded, or shut
    /// down, when its parent will unload, or when any provider it is bound to
    /// will unload or has published a different generation.
    pub(super) fn must_unload(&self, instance: InstanceId) -> bool {
        self.must_unload_with_seen(instance, &mut BTreeSet::new())
    }

    fn must_unload_with_seen(&self, instance: InstanceId, seen: &mut BTreeSet<InstanceId>) -> bool {
        if !seen.insert(instance) {
            return false;
        }
        let Some(node) = self.instances.get(&instance) else {
            return true;
        };
        let Some(allocation) = node.phase.allocation() else {
            return true;
        };
        self.shutdown_requested
            || !node.intent.enabled
            || node.intent.retired
            || allocation.replace
            || node
                .parent
                .is_some_and(|parent| self.will_unload_with_seen(parent, seen))
            || allocation.bindings.iter().any(|binding| {
                !self.binding_is_current(binding)
                    || self.will_unload_with_seen(binding.provider, seen)
            })
    }

    fn will_unload(&self, instance: InstanceId) -> bool {
        self.will_unload_with_seen(instance, &mut BTreeSet::new())
    }

    fn will_unload_with_seen(&self, instance: InstanceId, seen: &mut BTreeSet<InstanceId>) -> bool {
        let active = self.instances.get(&instance).is_some_and(|node| {
            matches!(
                node.phase,
                Phase::Live {
                    stage: Stage::Active(_),
                    ..
                }
            )
        });
        !active || self.must_unload_with_seen(instance, seen)
    }

    /// Retires child instances while their parent allocation remains active.
    fn retire_children_of_ending_parents(&mut self) {
        let ending: Vec<InstanceId> = self
            .instances
            .iter()
            .filter(|(id, node)| node.phase.allocation().is_some() && self.must_unload(**id))
            .map(|(id, _)| *id)
            .collect();
        for parent in ending {
            self.retire_children(parent);
        }
    }

    fn plan_unload(&mut self) -> Option<Action> {
        let instance = self.instances.iter().find_map(|(id, node)| {
            (matches!(
                node.phase,
                Phase::Live {
                    stage: Stage::Active(_),
                    ..
                }
            ) && self.must_unload(*id)
                && self.can_unload_now(*id))
            .then_some(*id)
        })?;
        self.begin_unload(instance)
    }

    /// Keeps providers and parents active until dependent and child allocations end.
    fn can_unload_now(&self, instance: InstanceId) -> bool {
        !self.instances.values().any(|node| {
            node.phase.allocation().is_some_and(|allocation| {
                node.parent == Some(instance)
                    || allocation
                        .bindings
                        .iter()
                        .any(|binding| binding.provider == instance)
            })
        })
    }

    fn plan_load(&mut self) -> Option<Action> {
        let candidates: Vec<InstanceId> = self
            .instances
            .iter()
            .filter(|(_, node)| {
                node.intent.enabled
                    && !node.intent.retired
                    && matches!(node.phase, Phase::Inactive | Phase::Failed { .. })
            })
            .map(|(id, _)| *id)
            .collect();
        for instance in candidates {
            if let Some(action) = self.plan_instance_load(instance) {
                return Some(action);
            }
        }
        None
    }

    fn plan_instance_load(&mut self, instance: InstanceId) -> Option<Action> {
        let node = self.instances.get(&instance)?;
        if node.parent.is_some_and(|parent| self.will_unload(parent)) {
            return None;
        }
        match self.own_contract_blocker(instance) {
            Some(OwnBlocker::Held) => return None,
            Some(OwnBlocker::Quarantined(kind)) => {
                self.record_diagnostic(instance, kind);
                return None;
            }
            None => {}
        }
        match self.resolve(instance) {
            Resolution::Bound(bindings) => {
                let node = self.instances.get(&instance)?;
                if let Phase::Failed { against } = &node.phase
                    && *against == bindings
                {
                    return None;
                }
                self.begin_load(instance, bindings)
            }
            Resolution::Waiting => None,
            Resolution::Blocked(kind) => {
                self.record_diagnostic(instance, kind);
                None
            }
        }
    }

    /// Finds a conflicting instance that still holds a provided contract.
    fn own_contract_blocker(&self, instance: InstanceId) -> Option<OwnBlocker> {
        let node = self.instances.get(&instance)?;
        // Quarantined rivals block first. Other rivals hold the contract through a pending
        // quarantine, an allocation, or a claim until they drain or yield.
        let mut held = false;
        for (key, owner, other) in self.rivals(instance, node) {
            if matches!(other.phase, Phase::Quarantined) {
                return Some(OwnBlocker::Quarantined(
                    DiagnosticKind::ContractQuarantined {
                        key: key.clone(),
                        owner,
                    },
                ));
            }
            held |= other.phase.allocation().is_some() || other.claims();
        }
        held.then_some(OwnBlocker::Held)
    }

    fn resolve(&self, instance: InstanceId) -> Resolution {
        let Some(node) = self.instances.get(&instance) else {
            return Resolution::Waiting;
        };
        let mut bindings = Vec::with_capacity(node.required.len());
        let mut problem = None;
        let mut pending = false;
        for required in &node.required {
            match self.provider_for(required) {
                Lookup::Claimant(provider) if provider == instance => {
                    problem.get_or_insert(DiagnosticKind::DependencyCycle {
                        instances: vec![instance, instance],
                    });
                }
                Lookup::Claimant(provider) => {
                    let generation =
                        self.instances
                            .get(&provider)
                            .and_then(|node| match node.phase {
                                Phase::Live {
                                    stage: Stage::Active(generation),
                                    ..
                                } => Some(generation),
                                _ => None,
                            });
                    match generation {
                        Some(generation) if !self.will_unload(provider) => {
                            bindings.push(Binding {
                                contract: required.clone(),
                                provider,
                                generation,
                            });
                        }
                        _ => pending = true,
                    }
                }
                Lookup::Quarantined(provider) => {
                    problem.get_or_insert(DiagnosticKind::ProviderQuarantined {
                        required: required.clone(),
                        provider,
                    });
                }
                Lookup::Disabled(provider) => {
                    problem.get_or_insert(DiagnosticKind::ProviderDisabled {
                        required: required.clone(),
                        provider,
                    });
                }
                Lookup::Mismatch { provider, provided } => {
                    problem.get_or_insert(DiagnosticKind::SchemaMismatch {
                        required: required.clone(),
                        provided,
                        provider,
                    });
                }
                Lookup::Missing => {
                    problem.get_or_insert(DiagnosticKind::MissingProvider {
                        required: required.clone(),
                    });
                }
            }
        }
        if problem.is_none() && !pending {
            return Resolution::Bound(bindings);
        }
        if let Some(instances) = self.declared_cycle(instance) {
            return Resolution::Blocked(DiagnosticKind::DependencyCycle { instances });
        }
        problem.map_or(Resolution::Waiting, Resolution::Blocked)
    }

    /// Finds the instance that serves, or would serve, an exact requirement.
    fn provider_for(&self, required: &ContractKey) -> Lookup {
        let exact = || {
            self.instances
                .iter()
                .filter(|(_, node)| node.provided.contains(required))
        };
        if let Some((provider, _)) =
            exact().find(|(_, node)| matches!(node.phase, Phase::Quarantined))
        {
            return Lookup::Quarantined(*provider);
        }
        if let Some((provider, _)) = exact().find(|(_, node)| node.claims()) {
            return Lookup::Claimant(*provider);
        }
        if let Some((provider, _)) = exact().find(|(_, node)| !node.intent.retired) {
            return Lookup::Disabled(*provider);
        }
        self.instances
            .iter()
            .filter(|(_, node)| !node.intent.retired)
            .find_map(|(provider, node)| {
                node.provided
                    .iter()
                    .find(|key| key.name() == required.name())
                    .map(|key| Lookup::Mismatch {
                        provider: *provider,
                        provided: key.clone(),
                    })
            })
            .unwrap_or(Lookup::Missing)
    }

    /// Finds a cycle reachable from an instance through its declarations, not
    /// through what is loaded, so a cycle through a disabled member is reported.
    fn declared_cycle(&self, start: InstanceId) -> Option<Vec<InstanceId>> {
        self.visit_declarations(start, &mut Vec::new(), &mut BTreeSet::new())
    }

    fn visit_declarations(
        &self,
        current: InstanceId,
        path: &mut Vec<InstanceId>,
        visited: &mut BTreeSet<InstanceId>,
    ) -> Option<Vec<InstanceId>> {
        if let Some(position) = path.iter().position(|id| *id == current) {
            return Some(canonical_cycle(&path[position..]));
        }
        if !visited.insert(current) {
            return None;
        }
        let node = self.instances.get(&current)?;
        path.push(current);
        let mut next = BTreeSet::new();
        for required in &node.required {
            let exact: Vec<_> = self
                .instances
                .iter()
                .filter(|(_, candidate)| {
                    candidate.provided.contains(required) && !candidate.intent.retired
                })
                .collect();
            let claimants: Vec<InstanceId> = exact
                .iter()
                .filter(|(_, candidate)| candidate.claims())
                .map(|(id, _)| **id)
                .collect();
            if claimants.is_empty() {
                next.extend(exact.iter().map(|(id, _)| **id));
            } else {
                next.extend(claimants);
            }
        }
        next.extend(node.parent);
        for provider in next {
            if let Some(cycle) = self.visit_declarations(provider, path, visited) {
                return Some(cycle);
            }
        }
        path.pop();
        None
    }
}

enum OwnBlocker {
    Held,
    Quarantined(DiagnosticKind),
}

enum Resolution {
    Bound(Vec<Binding>),
    Waiting,
    Blocked(DiagnosticKind),
}

enum Lookup {
    Claimant(InstanceId),
    Quarantined(InstanceId),
    Disabled(InstanceId),
    Mismatch {
        provider: InstanceId,
        provided: ContractKey,
    },
    Missing,
}

/// Rotates a cycle to start at its smallest identity and closes it.
fn canonical_cycle(cycle: &[InstanceId]) -> Vec<InstanceId> {
    let mut cycle = cycle.to_vec();
    if let Some((offset, _)) = cycle.iter().enumerate().min_by_key(|(_, id)| **id) {
        cycle.rotate_left(offset);
    }
    if let Some(first) = cycle.first().copied() {
        cycle.push(first);
    }
    cycle
}
