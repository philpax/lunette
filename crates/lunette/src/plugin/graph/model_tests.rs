//! A model checker over the pure lifecycle graph.
//!
//! Each case installs instances with random requirements, provisions, and
//! parents, applies random intents, and advances the graph with random load
//! outcomes, cleanup failures, reentrant intents, and children installed
//! during loads. After every operation it checks the structural invariants.
//! At the end it checks that the graph quiesces with every satisfiable
//! enabled instance active and that shutdown terminates.

#![expect(
    clippy::unwrap_used,
    reason = "the model reports a failed graph operation by panicking, which proptest shrinks"
)]

use std::collections::{BTreeMap, BTreeSet};

use proptest::{
    prelude::*,
    test_runner::{Config, RngSeed},
};

use super::*;

#[derive(Clone, Debug)]
enum Op {
    Install {
        required: Vec<(u8, u8)>,
        provided: Vec<(u8, u8)>,
        parent: Option<u8>,
    },
    Intent {
        kind: u8,
        target: u8,
    },
    MarkFailure(u8),
    Step(Step),
}

#[derive(Clone, Debug)]
struct Step {
    reentrant: Option<(u8, u8)>,
    child: bool,
    outcome: u8,
    cleanup_ok: bool,
}

#[derive(Clone, Debug)]
struct Declared {
    required: Vec<ContractKey>,
    provided: Vec<ContractKey>,
    parent: Option<InstanceId>,
}

fn key((name, schema): (u8, u8)) -> ContractKey {
    ContractKey::new(format!("k{name}"), u32::from(schema))
}

fn keys() -> impl Strategy<Value = Vec<(u8, u8)>> {
    prop::collection::vec((0u8..4, 1u8..3), 0..3)
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        3 => (keys(), keys(), prop::option::of(0u8..8)).prop_map(|(required, provided, parent)| {
            Op::Install {
                required,
                provided,
                parent,
            }
        }),
        4 => (0u8..4, 0u8..8).prop_map(|(kind, target)| Op::Intent { kind, target }),
        1 => (0u8..8).prop_map(Op::MarkFailure),
        6 => (
            prop::option::of((0u8..4, 0u8..8)),
            prop::bool::weighted(0.2),
            0u8..10,
            prop::bool::weighted(0.9),
        )
            .prop_map(|(reentrant, child, outcome, cleanup_ok)| {
                Op::Step(Step {
                    reentrant,
                    child,
                    outcome,
                    cleanup_ok,
                })
            }),
    ]
}

struct Model {
    graph: Graph,
    ids: Vec<InstanceId>,
    declared: BTreeMap<InstanceId, Declared>,
}

impl Model {
    fn pick(&self, index: u8) -> Option<InstanceId> {
        (!self.ids.is_empty()).then(|| self.ids[usize::from(index) % self.ids.len()])
    }

    fn install(&mut self, declared: Declared) {
        if let Ok(id) = self.graph.install(
            declared.required.clone(),
            declared.provided.clone(),
            declared.parent,
        ) {
            self.ids.push(id);
            self.declared.insert(id, declared);
        }
    }

    fn intent(&mut self, kind: u8, target: u8) {
        let Some(id) = self.pick(target) else {
            return;
        };
        let intent = match kind {
            0 => Intent::Enable(id),
            1 => Intent::Disable(id),
            2 => Intent::Reload(id),
            _ => Intent::Dispose(id),
        };
        // Rejections are part of the model; they must leave the graph valid.
        let _rejected = self.graph.request(intent);
    }

    fn step(&mut self, step: &Step) {
        match self.graph.next_action() {
            Some(Action::BeginLoad {
                instance,
                activation,
                ..
            }) => {
                if step.child {
                    let child = Declared {
                        required: Vec::new(),
                        provided: vec![key((7, 1))],
                        parent: Some(instance),
                    };
                    let before = self.ids.len();
                    self.install(child);
                    if let Some(child) = self.ids.get(before).copied() {
                        let _rejected = self.graph.request(Intent::Enable(child));
                    }
                }
                if let Some((kind, target)) = step.reentrant {
                    self.intent(kind, target);
                }
                let outcome = match step.outcome {
                    0 => LoadOutcome::Failed,
                    1 => LoadOutcome::Cancelled,
                    _ => LoadOutcome::Success,
                };
                let resolution = self
                    .graph
                    .complete_load(instance, activation, outcome)
                    .unwrap();
                if resolution == LoadResolution::Rejected {
                    if !step.cleanup_ok {
                        self.graph
                            .mark_cleanup_failed(instance, activation)
                            .unwrap();
                    }
                    let ended = self
                        .graph
                        .complete_load(instance, activation, LoadOutcome::Cancelled)
                        .unwrap();
                    assert!(matches!(ended, LoadResolution::Ended(_)));
                }
            }
            Some(Action::BeginUnload {
                instance,
                activation,
            }) => {
                if let Some((kind, target)) = step.reentrant {
                    self.intent(kind, target);
                }
                self.graph
                    .complete_unload(instance, activation, step.cleanup_ok)
                    .unwrap();
            }
            None => {}
        }
    }

    fn mark_failure(&mut self, target: u8) {
        let Some(id) = self.pick(target) else {
            return;
        };
        if let Ok(Some(view)) = self.graph.attachment(id)
            && view.state == AttachmentState::Active
        {
            self.graph.mark_cleanup_failed(id, view.activation).unwrap();
        }
    }

    fn live(&self) -> impl Iterator<Item = InstanceId> + '_ {
        self.ids
            .iter()
            .copied()
            .filter(|id| self.graph.contains(*id))
    }

    fn check(&self) -> Result<(), TestCaseError> {
        let mut holders: BTreeMap<ContractKey, InstanceId> = BTreeMap::new();
        let mut claimants: BTreeMap<ContractKey, InstanceId> = BTreeMap::new();
        for id in self.live() {
            let declared = &self.declared[&id];
            let state = self.graph.state(id).unwrap();
            let intent = self.graph.intent_state(id).unwrap();
            let view = self.graph.attachment(id).unwrap();
            if let Some(view) = &view {
                for binding in &view.bindings {
                    let provider = self.graph.attachment(binding.provider).ok().flatten();
                    prop_assert!(
                        provider.as_ref().is_some_and(|provider| {
                            provider.state == AttachmentState::Active
                                && provider.generation == Some(binding.generation)
                        }),
                        "{id} ({state:?}) is bound to {} which is not active at {}",
                        binding.provider,
                        binding.generation
                    );
                }
                for key in &declared.provided {
                    if let Some(other) = holders.insert(key.clone(), id) {
                        prop_assert!(false, "{other} and {id} both hold {key}");
                    }
                }
            }
            if intent.enabled && !intent.retired && state != LifecycleState::Quarantined {
                for key in &declared.provided {
                    if let Some(other) = claimants.insert(key.clone(), id) {
                        prop_assert!(false, "enabled {other} and {id} both reserve {key}");
                    }
                }
            }
            if let Some(parent) = declared.parent {
                prop_assert!(self.graph.contains(parent), "{id} outlived parent {parent}");
                let parent_view = self.graph.attachment(parent).unwrap();
                if view.is_some() {
                    prop_assert!(
                        parent_view
                            .as_ref()
                            .is_some_and(|parent| parent.state == AttachmentState::Active),
                        "{id} is attached under a parent that is not active"
                    );
                }
                if parent_view.is_none() {
                    prop_assert!(intent.retired, "{id} is an orphan of an ended activation");
                }
            }
        }
        Ok(())
    }

    /// The instances that a quiescent graph must have active: enabled, not
    /// failed or quarantined, under a satisfiable parent, with every
    /// requirement provided by a satisfiable instance and no provided
    /// contract held by a quarantined instance.
    fn satisfiable(&self) -> BTreeSet<InstanceId> {
        let live: Vec<InstanceId> = self.live().collect();
        let quarantined: BTreeSet<InstanceId> = live
            .iter()
            .copied()
            .filter(|id| self.graph.state(*id).unwrap() == LifecycleState::Quarantined)
            .collect();
        let quarantined_provides = |key: &ContractKey| {
            quarantined
                .iter()
                .any(|id| self.declared[id].provided.contains(key))
        };
        let mut satisfiable = BTreeSet::new();
        loop {
            let before = satisfiable.len();
            for id in &live {
                if satisfiable.contains(id) {
                    continue;
                }
                let declared = &self.declared[id];
                let intent = self.graph.intent_state(*id).unwrap();
                let state = self.graph.state(*id).unwrap();
                let eligible = intent.enabled
                    && !intent.retired
                    && !matches!(state, LifecycleState::Failed | LifecycleState::Quarantined)
                    && declared
                        .parent
                        .is_none_or(|parent| satisfiable.contains(&parent))
                    && !declared.provided.iter().any(&quarantined_provides)
                    && declared.required.iter().all(|key| {
                        !quarantined_provides(key)
                            && satisfiable.iter().any(|provider| {
                                provider != id && self.declared[provider].provided.contains(key)
                            })
                    });
                if eligible {
                    satisfiable.insert(*id);
                }
            }
            if satisfiable.len() == before {
                return satisfiable;
            }
        }
    }

    fn quiesce(&mut self) -> Result<(), TestCaseError> {
        let bound = self.ids.len() * 8 + 16;
        let mut steps = 0;
        while let Some(action) = self.graph.next_action() {
            steps += 1;
            prop_assert!(steps <= bound, "the graph did not quiesce");
            match action {
                Action::BeginLoad {
                    instance,
                    activation,
                    ..
                } => {
                    let resolution = self
                        .graph
                        .complete_load(instance, activation, LoadOutcome::Success)
                        .unwrap();
                    if resolution == LoadResolution::Rejected {
                        self.graph
                            .complete_load(instance, activation, LoadOutcome::Cancelled)
                            .unwrap();
                    }
                }
                Action::BeginUnload {
                    instance,
                    activation,
                } => self
                    .graph
                    .complete_unload(instance, activation, true)
                    .unwrap(),
            }
            self.check()?;
        }
        let active: BTreeSet<InstanceId> = self
            .live()
            .filter(|id| self.graph.state(*id).unwrap() == LifecycleState::Active)
            .collect();
        let satisfiable = self.satisfiable();
        prop_assert_eq!(
            &active,
            &satisfiable,
            "the active set is not the satisfiable enabled set"
        );
        Ok(())
    }

    fn shutdown(&mut self, failures: &[bool]) -> Result<(), TestCaseError> {
        self.graph.request(Intent::Shutdown).unwrap();
        let bound = self.ids.len() + 1;
        let mut steps = 0;
        while let Some(action) = self.graph.next_action() {
            steps += 1;
            prop_assert!(steps <= bound, "shutdown did not terminate");
            let Action::BeginUnload {
                instance,
                activation,
            } = action
            else {
                return Err(TestCaseError::fail("a load started during shutdown"));
            };
            let success = !failures.get(steps).copied().unwrap_or(false);
            self.graph
                .complete_unload(instance, activation, success)
                .unwrap();
        }
        prop_assert!(self.graph.is_shutdown(), "shutdown did not complete");
        Ok(())
    }
}

fn config() -> Config {
    Config {
        cases: 2048,
        failure_persistence: None,
        rng_seed: RngSeed::Fixed(0x006c_756e_6574_7465),
        ..Config::default()
    }
}

proptest! {
    #![proptest_config(config())]

    #[test]
    fn graph_model(
        ops in prop::collection::vec(op(), 1..48),
        failures in prop::collection::vec(prop::bool::weighted(0.2), 0..16),
    ) {
        let mut model = Model {
            graph: Graph::new(),
            ids: Vec::new(),
            declared: BTreeMap::new(),
        };
        for op in ops {
            match op {
                Op::Install { required, provided, parent } => {
                    let parent = parent.and_then(|index| model.pick(index));
                    model.install(Declared {
                        required: required.into_iter().map(key).collect(),
                        provided: provided.into_iter().map(key).collect(),
                        parent,
                    });
                }
                Op::Intent { kind, target } => model.intent(kind, target),
                Op::MarkFailure(target) => model.mark_failure(target),
                Op::Step(step) => model.step(&step),
            }
            model.check()?;
        }
        model.quiesce()?;
        model.shutdown(&failures)?;
    }
}
