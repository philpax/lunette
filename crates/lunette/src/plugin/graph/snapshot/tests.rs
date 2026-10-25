//! Snapshot records and reverse edges across public lifecycle operations.

#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "snapshot tests construct valid descriptors and assert current actions before unwrapping results"
)]

use pretty_assertions::assert_eq;

use super::*;
use crate::plugin::graph::{Action, ContractKey, Intent, LoadOutcome, LoadResolution};

#[test]
fn an_empty_graph_has_no_snapshot_instances() {
    assert_eq!(
        Graph::new().snapshot(),
        GraphSnapshot {
            instances: Vec::new()
        }
    );
}

#[test]
fn a_single_inactive_instance_has_no_allocation_or_edges() {
    let mut graph = Graph::new();
    let id = root(&mut graph, &[], &[]);
    assert_eq!(
        graph.snapshot(),
        GraphSnapshot {
            instances: vec![InstanceSnapshot {
                id,
                parent: None,
                intent: IntentState {
                    enabled: false,
                    retired: false,
                },
                state: LifecycleState::Inactive,
                activation: None,
                generation: None,
                bindings: Vec::new(),
                failed_bindings: Vec::new(),
                children: Vec::new(),
                dependents: Vec::new(),
                replacement_requested: false,
                cleanup_failed: false,
            }],
        }
    );
}

#[test]
fn children_include_inactive_instances_in_instance_order() {
    let mut graph = Graph::new();
    let parent = root(&mut graph, &[], &[]);
    graph.request(Intent::Enable(parent)).unwrap();
    load(&mut graph, parent);
    let first = graph.install(vec![], vec![], Some(parent)).unwrap();
    let unrelated = root(&mut graph, &[], &[]);
    let second = graph.install(vec![], vec![], Some(parent)).unwrap();
    graph.request(Intent::Enable(second)).unwrap();
    load(&mut graph, second);
    let grandchild = graph.install(vec![], vec![], Some(second)).unwrap();
    let third = graph.install(vec![], vec![], Some(parent)).unwrap();

    let snapshot = graph.snapshot();
    assert_eq!(
        snapshot
            .instances
            .iter()
            .map(|node| node.id)
            .collect::<Vec<_>>(),
        vec![parent, first, unrelated, second, grandchild, third]
    );
    assert_eq!(
        instance(&snapshot, parent).children,
        vec![first, second, third]
    );
    assert_eq!(instance(&snapshot, second).children, vec![grandchild]);
    assert!(instance(&snapshot, unrelated).children.is_empty());
    for child in [first, third] {
        assert_eq!(instance(&snapshot, child).parent, Some(parent));
        assert_eq!(instance(&snapshot, child).state, LifecycleState::Inactive);
    }

    graph.request(Intent::Disable(second)).unwrap();
    let activation = begin_unload(&mut graph, second);
    graph.complete_unload(second, activation, true).unwrap();
    let snapshot = graph.snapshot();
    assert_eq!(
        instance(&snapshot, parent).children,
        vec![first, second, third]
    );
    assert_eq!(instance(&snapshot, second).state, LifecycleState::Inactive);
    assert!(instance(&snapshot, second).children.is_empty());
    assert!(!snapshot.instances.iter().any(|node| node.id == grandchild));
}

#[test]
fn dependents_are_unique_and_ordered_across_multiple_contracts() {
    let mut graph = Graph::new();
    let first_key = ContractKey::new("first", 1);
    let second_key = ContractKey::new("second", 1);
    let required = [
        second_key.clone(),
        first_key.clone(),
        second_key.clone(),
        first_key.clone(),
    ];
    let first = root(&mut graph, &required, &[]);
    let inactive = root(&mut graph, &required, &[]);
    let second = root(&mut graph, &required, &[]);
    let provider = root(&mut graph, &[], &[second_key.clone(), first_key.clone()]);
    graph.request(Intent::Enable(provider)).unwrap();
    let activation = load(&mut graph, provider);
    graph.request(Intent::Enable(second)).unwrap();
    load(&mut graph, second);
    graph.request(Intent::Enable(first)).unwrap();
    load(&mut graph, first);

    let snapshot = graph.snapshot();
    let bindings = vec![
        Binding {
            contract: first_key,
            provider,
            generation: ProviderGeneration::from_activation(activation),
        },
        Binding {
            contract: second_key,
            provider,
            generation: ProviderGeneration::from_activation(activation),
        },
    ];
    assert_eq!(
        instance(&snapshot, provider).dependents,
        vec![first, second]
    );
    for consumer in [first, second] {
        assert_eq!(instance(&snapshot, consumer).bindings, bindings);
    }
    assert_eq!(
        instance(&snapshot, inactive).state,
        LifecycleState::Inactive
    );
    assert!(instance(&snapshot, inactive).bindings.is_empty());
}

#[test]
fn interleaved_provider_bindings_list_each_consumer_once() {
    let mut graph = Graph::new();
    let first = ContractKey::new("a-first", 1);
    let middle = ContractKey::new("b-middle", 1);
    let last = ContractKey::new("c-last", 1);
    let outer = root(&mut graph, &[], &[first.clone(), last.clone()]);
    let inner = root(&mut graph, &[], std::slice::from_ref(&middle));
    let consumer = root(&mut graph, &[first, middle, last], &[]);
    for provider in [outer, inner] {
        graph.request(Intent::Enable(provider)).unwrap();
        load(&mut graph, provider);
    }
    graph.request(Intent::Enable(consumer)).unwrap();
    load(&mut graph, consumer);

    let snapshot = graph.snapshot();
    assert_eq!(
        instance(&snapshot, consumer)
            .bindings
            .iter()
            .map(|binding| binding.provider)
            .collect::<Vec<_>>(),
        vec![outer, inner, outer]
    );
    for provider in [outer, inner] {
        assert_eq!(instance(&snapshot, provider).dependents, vec![consumer]);
    }
    assert_eq!(snapshot, graph.snapshot_reference());
}

#[test]
fn bindings_contribute_edges_until_the_live_allocation_ends() {
    let mut graph = Graph::new();
    let key = ContractKey::new("service", 1);
    let provider = root(&mut graph, &[], std::slice::from_ref(&key));
    let consumer = root(&mut graph, std::slice::from_ref(&key), &[]);
    graph.request(Intent::Enable(provider)).unwrap();
    let provider_activation = load(&mut graph, provider);
    graph.request(Intent::Enable(consumer)).unwrap();
    let activation = begin_load(&mut graph, consumer);
    let bindings = vec![Binding {
        contract: key,
        provider,
        generation: ProviderGeneration::from_activation(provider_activation),
    }];

    let loading = graph.snapshot();
    let node = instance(&loading, consumer);
    assert_eq!(node.state, LifecycleState::Loading);
    assert_eq!(node.activation, Some(activation));
    assert_eq!(node.generation, None);
    assert_eq!(node.bindings, bindings);
    assert_eq!(instance(&loading, provider).dependents, vec![consumer]);

    let generation = ProviderGeneration::from_activation(activation);
    assert_eq!(
        graph.complete_load(consumer, activation, LoadOutcome::Success),
        Ok(LoadResolution::Published(generation))
    );
    let active = graph.snapshot();
    let node = instance(&active, consumer);
    assert_eq!(node.state, LifecycleState::Active);
    assert_eq!(node.activation, Some(activation));
    assert_eq!(node.generation, Some(generation));
    assert_eq!(node.bindings, bindings);
    assert_eq!(instance(&active, provider).dependents, vec![consumer]);

    graph.request(Intent::Disable(consumer)).unwrap();
    assert_eq!(begin_unload(&mut graph, consumer), activation);
    let unloading = graph.snapshot();
    let node = instance(&unloading, consumer);
    assert_eq!(node.state, LifecycleState::Unloading);
    assert_eq!(node.activation, Some(activation));
    assert_eq!(node.generation, Some(generation));
    assert_eq!(node.bindings, bindings);
    assert!(node.replacement_requested);
    assert_eq!(instance(&unloading, provider).dependents, vec![consumer]);

    graph.complete_unload(consumer, activation, true).unwrap();
    let inactive = graph.snapshot();
    let node = instance(&inactive, consumer);
    assert_eq!(node.state, LifecycleState::Inactive);
    assert_eq!(node.activation, None);
    assert_eq!(node.generation, None);
    assert!(node.bindings.is_empty());
    assert!(node.failed_bindings.is_empty());
    assert!(!node.replacement_requested);
    assert!(instance(&inactive, provider).dependents.is_empty());
}

#[test]
fn failed_and_quarantined_instances_do_not_contribute_edges() {
    let mut graph = Graph::new();
    let key = ContractKey::new("service", 1);
    let provider = root(&mut graph, &[], std::slice::from_ref(&key));
    let failed = root(&mut graph, std::slice::from_ref(&key), &[]);
    let inactive = root(&mut graph, std::slice::from_ref(&key), &[]);
    let quarantined = root(&mut graph, std::slice::from_ref(&key), &[]);
    graph.request(Intent::Enable(provider)).unwrap();
    let provider_activation = load(&mut graph, provider);
    let bindings = vec![Binding {
        contract: key,
        provider,
        generation: ProviderGeneration::from_activation(provider_activation),
    }];
    graph.request(Intent::Enable(failed)).unwrap();
    let activation = begin_load(&mut graph, failed);
    assert_eq!(
        graph.complete_load(failed, activation, LoadOutcome::Failed),
        Ok(LoadResolution::Ended(LifecycleState::Failed))
    );
    let snapshot = graph.snapshot();
    assert_eq!(instance(&snapshot, failed).state, LifecycleState::Failed);
    assert_eq!(instance(&snapshot, failed).failed_bindings, bindings);
    assert!(instance(&snapshot, provider).dependents.is_empty());

    graph.request(Intent::Enable(quarantined)).unwrap();
    let activation = load(&mut graph, quarantined);
    graph.mark_cleanup_failed(quarantined, activation).unwrap();
    graph.request(Intent::Disable(quarantined)).unwrap();
    assert_eq!(begin_unload(&mut graph, quarantined), activation);
    let unloading = graph.snapshot();
    assert!(instance(&unloading, quarantined).cleanup_failed);
    assert_eq!(instance(&unloading, quarantined).bindings, bindings);
    assert_eq!(instance(&unloading, provider).dependents, vec![quarantined]);

    graph
        .complete_unload(quarantined, activation, true)
        .unwrap();
    let snapshot = graph.snapshot();
    assert_eq!(instance(&snapshot, failed).failed_bindings, bindings);
    assert_eq!(
        instance(&snapshot, inactive).state,
        LifecycleState::Inactive
    );
    assert_eq!(
        instance(&snapshot, quarantined).state,
        LifecycleState::Quarantined
    );
    assert!(instance(&snapshot, quarantined).cleanup_failed);
    assert!(instance(&snapshot, quarantined).failed_bindings.is_empty());
    for id in [failed, inactive, quarantined] {
        let node = instance(&snapshot, id);
        assert_eq!(node.activation, None);
        assert_eq!(node.generation, None);
        assert!(node.bindings.is_empty());
        assert!(node.dependents.is_empty());
    }
    assert!(instance(&snapshot, provider).dependents.is_empty());
}

fn root(graph: &mut Graph, required: &[ContractKey], provided: &[ContractKey]) -> InstanceId {
    graph
        .install(required.to_vec(), provided.to_vec(), None)
        .unwrap()
}

fn load(graph: &mut Graph, instance: InstanceId) -> ActivationId {
    let activation = begin_load(graph, instance);
    assert!(matches!(
        graph.complete_load(instance, activation, LoadOutcome::Success),
        Ok(LoadResolution::Published(_))
    ));
    activation
}

fn begin_load(graph: &mut Graph, instance: InstanceId) -> ActivationId {
    match graph.next_action() {
        Some(Action::BeginLoad {
            instance: actual,
            activation,
        }) if actual == instance => activation,
        other => panic!("expected a load action for {instance}, got {other:?}"),
    }
}

fn begin_unload(graph: &mut Graph, instance: InstanceId) -> ActivationId {
    match graph.next_action() {
        Some(Action::BeginUnload {
            instance: actual,
            activation,
        }) if actual == instance => activation,
        other => panic!("expected an unload action for {instance}, got {other:?}"),
    }
}

fn instance(snapshot: &GraphSnapshot, id: InstanceId) -> &InstanceSnapshot {
    snapshot
        .instances
        .iter()
        .find(|node| node.id == id)
        .expect("the snapshot should retain the instance")
}
