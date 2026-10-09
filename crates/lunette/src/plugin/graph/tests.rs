//! Example tests for what the model in `model_tests` does not observe: error variants,
//! diagnostics, binding currency, retry policy, and quarantine.

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

fn fail(graph: &mut Graph, instance: InstanceId) {
    let activation = begin_load(graph, instance);
    graph
        .complete_load(instance, activation, LoadOutcome::Failed)
        .unwrap();
}

fn unload(graph: &mut Graph, instance: InstanceId, success: bool) {
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
}

fn kinds(graph: &mut Graph) -> Vec<DiagnosticKind> {
    graph
        .take_diagnostics()
        .into_iter()
        .map(|diagnostic| diagnostic.kind)
        .collect()
}

#[test]
fn a_provider_reload_makes_old_bindings_stale() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    let consumer = root(&mut graph, &[key("service", 1)], &[]);
    graph.request(Intent::Enable(provider)).unwrap();
    graph.request(Intent::Enable(consumer)).unwrap();
    load(&mut graph, provider);
    load(&mut graph, consumer);
    let first = live_allocation(&graph, consumer).unwrap().1.bindings[0].clone();
    assert!(graph.binding_is_current(&first));
    graph.request(Intent::Reload(provider)).unwrap();
    unload(&mut graph, consumer, true);
    unload(&mut graph, provider, true);
    load(&mut graph, provider);
    load(&mut graph, consumer);
    let second = &live_allocation(&graph, consumer).unwrap().1.bindings[0];
    assert_ne!(first.generation, second.generation);
    assert!(graph.binding_is_current(second));
    assert!(!graph.binding_is_current(&first));
}

#[test]
fn an_enabled_provider_reserves_its_keys_until_disabled() {
    let mut graph = Graph::new();
    assert_eq!(
        graph.install(vec![], vec![key("service", 1), key("service", 1)], None),
        Err(GraphError::DuplicateProvided {
            key: key("service", 1)
        })
    );
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
    fail(&mut graph, first);
    graph.request(Intent::Disable(first)).unwrap();
    graph.request(Intent::Enable(second)).unwrap();
    load(&mut graph, second);
}

#[test]
fn a_failed_load_retries_on_a_changed_environment_or_an_explicit_enable() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    let consumer = root(&mut graph, &[key("service", 1)], &[]);
    graph.request(Intent::Enable(provider)).unwrap();
    graph.request(Intent::Enable(consumer)).unwrap();
    load(&mut graph, provider);
    fail(&mut graph, consumer);
    assert_eq!(graph.state(consumer).unwrap(), LifecycleState::Failed);
    assert!(
        graph.next_action().is_none(),
        "retried against the same view"
    );
    graph.request(Intent::Reload(provider)).unwrap();
    unload(&mut graph, provider, true);
    load(&mut graph, provider);
    fail(&mut graph, consumer);
    assert!(graph.next_action().is_none());
    graph.request(Intent::Enable(consumer)).unwrap();
    load(&mut graph, consumer);
}

#[test]
fn blocked_consumers_report_why_once() {
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
    assert_eq!(
        kinds(&mut graph),
        vec![DiagnosticKind::ProviderDisabled {
            required: key("service", 2),
            provider: right,
        }]
    );

    let mut graph = Graph::new();
    let first = root(&mut graph, &[key("second", 1)], &[key("first", 1)]);
    let second = root(&mut graph, &[key("first", 1)], &[key("second", 1)]);
    graph.request(Intent::Enable(first)).unwrap();
    graph.request(Intent::Enable(second)).unwrap();
    assert!(graph.next_action().is_none());
    assert!(graph.next_action().is_none());
    let cycle = DiagnosticKind::DependencyCycle {
        instances: vec![first, second, first],
    };
    assert_eq!(
        kinds(&mut graph),
        vec![cycle.clone(), cycle],
        "each member reports the cycle once"
    );
}

#[test]
fn a_cleanup_failure_quarantines_the_instance_and_its_contracts() {
    let mut graph = Graph::new();
    let provider = root(&mut graph, &[], &[key("service", 1)]);
    graph.request(Intent::Enable(provider)).unwrap();
    let activation = load(&mut graph, provider);
    graph.mark_cleanup_failed(provider, activation).unwrap();
    assert_eq!(
        graph.request(Intent::Reload(provider)),
        Err(GraphError::Quarantined(provider))
    );
    graph.request(Intent::Disable(provider)).unwrap();
    unload(&mut graph, provider, true);
    assert_eq!(graph.state(provider).unwrap(), LifecycleState::Quarantined);
    assert_eq!(
        graph.request(Intent::Enable(provider)),
        Err(GraphError::Quarantined(provider))
    );
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
fn a_rollback_failure_quarantines_the_loading_instance() {
    let mut graph = Graph::new();
    let instance = root(&mut graph, &[], &[key("service", 1)]);
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
}

#[test]
fn a_disposed_parent_retires_its_children_permanently() {
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
        graph.install(vec![], vec![], Some(parent)),
        Err(GraphError::Retired(parent))
    );
    unload(&mut graph, child, true);
    unload(&mut graph, parent, true);
    assert!(!graph.contains(child) && !graph.contains(parent));
}
