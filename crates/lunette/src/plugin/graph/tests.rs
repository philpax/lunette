#![expect(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "graph tests construct valid descriptors and assert current actions before unwrapping results"
)]

use pretty_assertions::assert_eq;

use super::*;
use crate::plugin::graph::lifecycle::{Allocation, Phase};

/// Returns the stage and allocation for an instance's live phase.
pub(super) fn live_allocation(graph: &Graph, instance: InstanceId) -> Option<(Stage, &Allocation)> {
    match &graph.node(instance).ok()?.phase {
        Phase::Live { stage, allocation } => Some((*stage, allocation)),
        Phase::Inactive | Phase::Failed { .. } | Phase::Quarantined => None,
    }
}

fn generation(graph: &Graph, instance: InstanceId) -> Option<ProviderGeneration> {
    match live_allocation(graph, instance) {
        Some((Stage::Active(generation), _)) => Some(generation),
        _ => None,
    }
}

fn key(name: &str, schema: u32) -> ContractKey {
    ContractKey::new(name, schema)
}

fn root(graph: &mut Graph, required: &[ContractKey], provided: &[ContractKey]) -> InstanceId {
    graph
        .install(required.to_vec(), provided.to_vec(), None)
        .unwrap()
}

fn begin_load(graph: &mut Graph, instance: InstanceId) -> ActivationId {
    match graph.next_action() {
        Some(Action::BeginLoad {
            instance: actual,
            activation,
            ..
        }) if actual == instance => activation,
        other => panic!("expected a load action for {instance}, got {other:?}"),
    }
}

fn load(graph: &mut Graph, instance: InstanceId) -> ActivationId {
    let activation = begin_load(graph, instance);
    assert!(matches!(
        graph.complete_load(instance, activation, LoadOutcome::Success),
        Ok(LoadResolution::Published(_))
    ));
    activation
}

fn unload(graph: &mut Graph, instance: InstanceId, success: bool) -> ActivationId {
    let Some(Action::BeginUnload {
        instance: actual,
        activation,
    }) = graph.next_action()
    else {
        panic!("expected an unload action for {instance}");
    };
    assert_eq!(actual, instance);
    graph
        .complete_unload(instance, activation, success)
        .expect("unload action should be current");
    activation
}

fn kinds(graph: &mut Graph) -> Vec<DiagnosticKind> {
    graph
        .take_diagnostics()
        .into_iter()
        .map(|diagnostic| diagnostic.kind)
        .collect()
}

#[test]
fn a_provider_reload_publishes_a_new_generation() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    let consumer = root(&mut graph, &[key("service", 1)], &[]);
    graph.request(Intent::Enable(provider)).unwrap();
    graph.request(Intent::Enable(consumer)).unwrap();
    load(&mut graph, provider);
    let first_activation = load(&mut graph, consumer);
    let first_generation = generation(&graph, provider);
    let first_binding = live_allocation(&graph, consumer).unwrap().1.bindings[0].clone();
    assert!(graph.binding_is_current(&first_binding));
    graph.request(Intent::Reload(provider)).unwrap();
    unload(&mut graph, consumer, true);
    unload(&mut graph, provider, true);
    load(&mut graph, provider);
    let second_activation = load(&mut graph, consumer);
    let second = generation(&graph, provider);
    assert_ne!(first_generation, second);
    assert_ne!(first_activation, second_activation);
    let bindings = &live_allocation(&graph, consumer).unwrap().1.bindings;
    assert_eq!(bindings[0].generation, second.unwrap());
    assert!(graph.binding_is_current(&bindings[0]));
    assert!(!graph.binding_is_current(&first_binding));
}

#[test]
fn failed_and_cancelled_loads_do_not_reuse_publication_identity() {
    for outcome in [LoadOutcome::Failed, LoadOutcome::Cancelled] {
        let mut graph = Graph::new();
        let provider = root(&mut graph, &[], &[key("service", 1)]);
        graph.request(Intent::Enable(provider)).unwrap();
        let first = load(&mut graph, provider);
        let first_generation = generation(&graph, provider).unwrap();
        graph.request(Intent::Reload(provider)).unwrap();
        unload(&mut graph, provider, true);

        let ended = begin_load(&mut graph, provider);
        assert_ne!(first, ended);
        assert!(matches!(
            graph.complete_load(provider, ended, outcome),
            Ok(LoadResolution::Ended(_))
        ));
        graph.request(Intent::Enable(provider)).unwrap();
        let current = begin_load(&mut graph, provider);
        assert_ne!(ended, current);
        for stale_outcome in [
            LoadOutcome::Success,
            LoadOutcome::Failed,
            LoadOutcome::Cancelled,
        ] {
            assert_eq!(
                graph.complete_load(provider, ended, stale_outcome),
                Err(GraphError::StaleAction)
            );
            assert_eq!(graph.live(provider, current).unwrap().0, Stage::Loading);
        }
        let current_generation = ProviderGeneration::from_activation(current);
        assert_eq!(
            graph.complete_load(provider, current, LoadOutcome::Success),
            Ok(LoadResolution::Published(current_generation))
        );
        assert_ne!(first_generation, current_generation);
    }
}

#[test]
fn publication_keeps_activation_identity_when_loads_complete_out_of_order() {
    let mut graph = Graph::new();
    let first = root(&mut graph, &[], &[key("first", 1)]);
    let second = root(&mut graph, &[], &[key("second", 1)]);
    let consumer = root(&mut graph, &[key("first", 1), key("second", 1)], &[]);
    for instance in [first, second, consumer] {
        graph.request(Intent::Enable(instance)).unwrap();
    }
    let first_activation = begin_load(&mut graph, first);
    let second_activation = begin_load(&mut graph, second);
    for (instance, activation) in [(second, second_activation), (first, first_activation)] {
        assert_eq!(
            graph.complete_load(instance, activation, LoadOutcome::Success),
            Ok(LoadResolution::Published(
                ProviderGeneration::from_activation(activation)
            ))
        );
    }
    let consumer_activation = begin_load(&mut graph, consumer);
    let (stage, bindings) = graph.live(consumer, consumer_activation).unwrap();
    assert_eq!(stage, Stage::Loading);
    assert_eq!(
        bindings,
        &[
            Binding {
                contract: key("first", 1),
                provider: first,
                generation: ProviderGeneration::from_activation(first_activation),
            },
            Binding {
                contract: key("second", 1),
                provider: second,
                generation: ProviderGeneration::from_activation(second_activation),
            },
        ]
    );
}

#[test]
fn the_last_activation_can_publish_without_another_identifier() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    graph.next_activation = u64::MAX - 1;
    let activation = begin_load(&mut graph, instance);
    assert_eq!(
        graph.complete_load(instance, activation, LoadOutcome::Success),
        Ok(LoadResolution::Published(
            ProviderGeneration::from_activation(activation)
        ))
    );
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Active);
    graph.request(Intent::Reload(instance)).unwrap();
    unload(&mut graph, instance, true);
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::ActivationsExhausted]
    );
}

#[test]
fn self_disable_never_publishes() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    let activation = begin_load(&mut graph, instance);
    graph.request(Intent::Disable(instance)).unwrap();
    assert_eq!(
        graph.complete_load(instance, activation, LoadOutcome::Success),
        Ok(LoadResolution::Rejected)
    );
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Loading);
    assert!(graph.next_action().is_none());
    assert_eq!(
        graph.complete_load(instance, activation, LoadOutcome::Cancelled),
        Ok(LoadResolution::Ended(LifecycleState::Inactive))
    );
    assert!(live_allocation(&graph, instance).is_none());
}

#[test]
fn an_exhausted_activation_counter_is_reported_rather_than_dropped() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    graph.next_activation = u64::MAX;

    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::ActivationsExhausted]
    );
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Inactive);
}

#[test]
fn a_disable_then_enable_during_a_load_restarts_it() {
    let mut graph = Graph::new();
    let id = root(&mut graph, &[], &[]);
    graph.request(Intent::Enable(id)).unwrap();
    let activation = begin_load(&mut graph, id);
    graph.request(Intent::Disable(id)).unwrap();
    graph.request(Intent::Enable(id)).unwrap();
    assert_eq!(
        graph.complete_load(id, activation, LoadOutcome::Success),
        Ok(LoadResolution::Rejected)
    );
    graph
        .complete_load(id, activation, LoadOutcome::Cancelled)
        .unwrap();
    assert_ne!(load(&mut graph, id), activation);
}

#[test]
fn disable_during_an_unload_lets_it_end_inactive() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    load(&mut graph, instance);
    graph.request(Intent::Reload(instance)).unwrap();
    let Some(Action::BeginUnload { activation, .. }) = graph.next_action() else {
        panic!("expected reload unload");
    };
    graph.request(Intent::Disable(instance)).unwrap();
    graph.complete_unload(instance, activation, true).unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Inactive);
    assert!(graph.next_action().is_none());
}

#[test]
fn installation_reserves_nothing_and_enable_reserves_the_exact_key() {
    let mut graph = Graph::new();
    let first = root(&mut graph, &[], &[key("service", 1)]);
    let second = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(first)).unwrap();
    assert_eq!(
        graph.request(Intent::Enable(second)),
        Err(GraphError::ContractConflict {
            key: key("service", 1),
            owner: first,
        })
    );
    assert_eq!(
        graph.request(Intent::Reload(second)),
        Err(GraphError::ContractConflict {
            key: key("service", 1),
            owner: first,
        })
    );
    assert!(!graph.node(second).unwrap().intent.enabled);
}

#[test]
fn duplicate_contract_keys_in_one_descriptor_are_rejected() {
    let mut graph = Graph::new();
    assert_eq!(
        graph.install(vec![], vec![key("service", 1), key("service", 1)], None),
        Err(GraphError::DuplicateProvided {
            key: key("service", 1)
        })
    );
}

#[test]
fn reload_while_loading_restarts_the_load() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[]);
    graph.request(Intent::Enable(instance)).unwrap();
    let activation = begin_load(&mut graph, instance);
    graph.request(Intent::Reload(instance)).unwrap();
    graph
        .complete_load(instance, activation, LoadOutcome::Cancelled)
        .unwrap();
    load(&mut graph, instance);
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Active);
}

#[test]
fn retirement_is_permanent() {
    let mut graph = Graph::new();
    let parent = root(&mut graph, &[], &[]);
    graph.request(Intent::Enable(parent)).unwrap();
    load(&mut graph, parent);
    let child = graph.install(vec![], vec![], Some(parent)).unwrap();
    graph.request(Intent::Enable(child)).unwrap();
    load(&mut graph, child);
    graph.request(Intent::Dispose(parent)).unwrap();
    assert_eq!(
        graph.request(Intent::Enable(child)),
        Err(GraphError::Retired(child))
    );
    assert_eq!(
        graph.request(Intent::Reload(parent)),
        Err(GraphError::Retired(parent))
    );
    assert_eq!(
        graph.install(vec![], vec![], Some(parent)),
        Err(GraphError::Retired(parent))
    );
    unload(&mut graph, child, true);
    unload(&mut graph, parent, true);
    assert!(!graph.contains(child) && !graph.contains(parent));
}

#[test]
fn a_child_needs_a_live_parent_activation() {
    let mut graph = Graph::new();
    let parent = root(&mut graph, &[], &[]);
    assert_eq!(
        graph.install(vec![], vec![], Some(parent)),
        Err(GraphError::ParentInactive(parent))
    );
}

#[test]
fn many_intents_never_block_unloads() {
    let mut graph = Graph::new();
    let roots: Vec<_> = (0..300).map(|_| root(&mut graph, &[], &[])).collect();
    for id in &roots {
        graph.request(Intent::Enable(*id)).unwrap();
        load(&mut graph, *id);
    }
    for id in &roots {
        graph.request(Intent::Disable(*id)).unwrap();
    }
    for id in &roots {
        unload(&mut graph, *id, true);
    }
    assert!(graph.next_action().is_none());
}

#[test]
fn a_quarantined_provider_blocks_consumers_with_a_diagnostic() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(provider)).unwrap();
    load(&mut graph, provider);
    graph.request(Intent::Disable(provider)).unwrap();
    unload(&mut graph, provider, false);
    let replacement = root(&mut graph, &[], &[key("service", 1)]);
    assert_eq!(
        graph.request(Intent::Enable(replacement)),
        Err(GraphError::ContractQuarantined {
            key: key("service", 1),
            owner: provider,
        })
    );
    let consumer = root(&mut graph, &[key("service", 1)], &[]);
    graph.request(Intent::Enable(consumer)).unwrap();
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::ProviderQuarantined {
            required: key("service", 1),
            provider,
        }]
    );
}

#[test]
fn quarantine_after_a_replacement_enabled_blocks_the_replacement() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(provider)).unwrap();
    load(&mut graph, provider);
    graph.request(Intent::Disable(provider)).unwrap();
    let replacement = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(replacement)).unwrap();
    unload(&mut graph, provider, false);
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::ContractQuarantined {
            key: key("service", 1),
            owner: provider,
        }]
    );
}

#[test]
fn cycles_are_found_from_declarations() {
    let mut graph = Graph::new();
    let first = root(&mut graph, &[key("second", 1)], &[key("first", 1)]);
    let second = root(&mut graph, &[key("first", 1)], &[key("second", 1)]);
    graph.request(Intent::Enable(first)).unwrap();
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::DependencyCycle {
            instances: vec![first, second, first]
        }]
    );
    graph.request(Intent::Enable(second)).unwrap();
    assert!(graph.next_action().is_none());
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::DependencyCycle {
            instances: vec![first, second, first]
        }],
        "the second member reports once, and the first does not report again"
    );
}

#[test]
fn a_cycle_on_a_second_requirement_is_reported() {
    let mut graph = Graph::new();
    let base = root(&mut graph, &[], &[key("aaa-root", 1)]);
    let a = root(
        &mut graph,
        &[key("aaa-root", 1), key("b", 1)],
        &[key("a", 1)],
    );
    let b = root(&mut graph, &[key("a", 1)], &[key("b", 1)]);
    for id in [base, a, b] {
        graph.request(Intent::Enable(id)).unwrap();
    }
    load(&mut graph, base);
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![
            DiagnosticKind::DependencyCycle {
                instances: vec![a, b, a]
            },
            DiagnosticKind::DependencyCycle {
                instances: vec![a, b, a]
            }
        ]
    );
}

#[test]
fn self_requirement_is_a_cycle() {
    let mut graph = Graph::new();
    let id = root(&mut graph, &[key("self", 1)], &[key("self", 1)]);
    graph.request(Intent::Enable(id)).unwrap();
    assert!(graph.next_action().is_none());
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::DependencyCycle {
            instances: vec![id, id]
        }]
    );
}

#[test]
fn blocked_reasons_are_distinguished() {
    let mut graph = Graph::new();
    let consumer = root(&mut graph, &[key("service", 2)], &[]);
    graph.request(Intent::Enable(consumer)).unwrap();
    assert!(graph.next_action().is_none());
    let missing = kinds(&mut graph);
    assert_eq!(
        missing,
        vec![DiagnosticKind::MissingProvider {
            required: key("service", 2)
        }]
    );
    assert_eq!(missing[0].severity(), Severity::Waiting);
    let wrong = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(consumer)).unwrap();
    assert!(graph.next_action().is_none());
    let mismatch = kinds(&mut graph);
    assert_eq!(
        mismatch,
        vec![DiagnosticKind::SchemaMismatch {
            required: key("service", 2),
            provided: key("service", 1),
            provider: wrong,
        }]
    );
    assert_eq!(mismatch[0].severity(), Severity::Error);
    let right = root(&mut graph, &[], &[key("service", 2)]);
    assert!(graph.next_action().is_none());
    let disabled = kinds(&mut graph);
    assert_eq!(
        disabled,
        vec![DiagnosticKind::ProviderDisabled {
            required: key("service", 2),
            provider: right,
        }]
    );
    assert_eq!(disabled[0].severity(), Severity::Waiting);
    graph.request(Intent::Enable(right)).unwrap();
    load(&mut graph, right);
    load(&mut graph, consumer);
}

#[test]
fn disabling_a_failed_instance_releases_its_reservation() {
    let mut graph = Graph::new();
    let failing = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(failing)).unwrap();
    let activation = begin_load(&mut graph, failing);
    graph
        .complete_load(failing, activation, LoadOutcome::Failed)
        .unwrap();
    graph.request(Intent::Disable(failing)).unwrap();
    let replacement = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(replacement)).unwrap();
    load(&mut graph, replacement);
}

#[test]
fn a_cleanup_failure_during_unload_quarantines_on_completion() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    load(&mut graph, instance);
    graph.request(Intent::Disable(instance)).unwrap();
    let Some(Action::BeginUnload { activation, .. }) = graph.next_action() else {
        panic!("expected unload");
    };
    graph.mark_cleanup_failed(instance, activation).unwrap();
    graph.complete_unload(instance, activation, true).unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Quarantined);
}

#[test]
fn a_failed_load_retries_only_against_a_changed_environment() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    let consumer = root(&mut graph, &[key("service", 1)], &[]);
    graph.request(Intent::Enable(provider)).unwrap();
    graph.request(Intent::Enable(consumer)).unwrap();
    load(&mut graph, provider);
    let activation = begin_load(&mut graph, consumer);
    graph
        .complete_load(consumer, activation, LoadOutcome::Failed)
        .unwrap();
    assert_eq!(graph.state(consumer).unwrap(), LifecycleState::Failed);
    assert!(
        graph.next_action().is_none(),
        "retried against the same view"
    );
    graph.request(Intent::Reload(provider)).unwrap();
    unload(&mut graph, provider, true);
    load(&mut graph, provider);
    load(&mut graph, consumer);
}

#[test]
fn an_explicit_enable_retries_a_failed_load() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[]);
    graph.request(Intent::Enable(instance)).unwrap();
    let activation = begin_load(&mut graph, instance);
    graph
        .complete_load(instance, activation, LoadOutcome::Failed)
        .unwrap();
    assert!(graph.next_action().is_none());
    graph.request(Intent::Enable(instance)).unwrap();
    load(&mut graph, instance);
}

// Enable and reload of a quarantined instance are rejected.
#[test]
fn a_quarantined_instance_rejects_enable_and_reload() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    let activation = load(&mut graph, instance);
    graph.mark_cleanup_failed(instance, activation).unwrap();
    assert_eq!(
        graph.request(Intent::Reload(instance)),
        Err(GraphError::Quarantined(instance))
    );
    graph.request(Intent::Dispose(instance)).unwrap();
    unload(&mut graph, instance, true);
    assert_eq!(
        graph.request(Intent::Enable(instance)),
        Err(GraphError::Quarantined(instance))
    );
    assert!(graph.contains(instance), "a quarantined record is kept");
}

#[test]
fn a_rollback_failure_quarantines_the_loading_allocation() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("root", 1)]);
    graph.request(Intent::Enable(instance)).unwrap();
    let activation = begin_load(&mut graph, instance);
    graph.mark_cleanup_failed(instance, activation).unwrap();
    assert!(!graph.activation_is_valid(instance, activation).unwrap());
    assert_eq!(
        graph.complete_load(instance, activation, LoadOutcome::Success),
        Ok(LoadResolution::Rejected)
    );
    assert_eq!(
        graph.complete_load(instance, activation, LoadOutcome::Failed),
        Ok(LoadResolution::Ended(LifecycleState::Quarantined))
    );
    graph.request(Intent::Shutdown).unwrap();
    assert!(graph.next_action().is_none());
    assert!(graph.shutdown_requested && graph.instances.is_empty());
}

#[test]
fn shutdown_drains_every_root_despite_cleanup_failures() {
    let mut graph = Graph::new();
    let roots: Vec<_> = (0..300).map(|_| root(&mut graph, &[], &[])).collect();
    for id in &roots {
        graph.request(Intent::Enable(*id)).unwrap();
        load(&mut graph, *id);
    }
    graph.request(Intent::Shutdown).unwrap();
    assert_eq!(
        graph.request(Intent::Disable(roots[0])),
        Err(GraphError::ShuttingDown)
    );
    for (index, id) in roots.into_iter().enumerate() {
        unload(&mut graph, id, index % 3 != 0);
    }
    assert!(graph.next_action().is_none());
    assert!(graph.shutdown_requested && graph.instances.is_empty());
}

#[test]
fn shutdown_drains_children_before_parents() {
    let mut graph = Graph::new();
    let parent = root(&mut graph, &[], &[key("parent", 1)]);
    graph.request(Intent::Enable(parent)).unwrap();
    load(&mut graph, parent);
    let child = graph.install(vec![], vec![], Some(parent)).unwrap();
    graph.request(Intent::Enable(child)).unwrap();
    load(&mut graph, child);
    graph.request(Intent::Shutdown).unwrap();
    unload(&mut graph, child, false);
    unload(&mut graph, parent, true);
    assert!(graph.next_action().is_none());
    assert!(graph.shutdown_requested && graph.instances.is_empty());
}
