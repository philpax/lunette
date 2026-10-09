#![expect(
    clippy::expect_used,
    reason = "snapshot tests assert valid graph actions and installed identities"
)]

use crate::plugin::graph::{
    Action, ContractKey, Graph, InstanceId, InstanceSnapshot, Intent, LifecycleState, LoadOutcome,
};

fn node(graph: &Graph, id: InstanceId) -> InstanceSnapshot {
    graph
        .snapshot()
        .instances
        .into_iter()
        .find(|node| node.id == id)
        .expect("retained instance")
}

fn begin(graph: &mut Graph, id: InstanceId) -> crate::plugin::graph::ActivationId {
    let Some(Action::BeginLoad {
        instance,
        activation,
    }) = graph.next_action()
    else {
        panic!("load action");
    };
    assert_eq!(instance, id);
    activation
}

fn load(graph: &mut Graph, id: InstanceId) {
    let activation = begin(graph, id);
    graph
        .complete_load(id, activation, LoadOutcome::Success)
        .expect("publish");
}

#[test]
fn snapshot_tracks_bindings_generations_retired_children_and_quarantine() {
    let mut graph = Graph::new();
    let key = ContractKey::new("inspection/service", 3);
    let first = graph
        .install(vec![], vec![key.clone()], None)
        .expect("provider");
    let second = graph
        .install(vec![], vec![key.clone()], None)
        .expect("substitute");
    let consumer = graph
        .install(vec![key.clone()], vec![], None)
        .expect("consumer");
    graph.request(Intent::Enable(first)).expect("enable");
    graph.request(Intent::Enable(consumer)).expect("enable");
    let loading = begin(&mut graph, first);
    assert_eq!(node(&graph, first).activation, Some(loading));
    assert_eq!(node(&graph, first).generation, None);
    graph
        .complete_load(first, loading, LoadOutcome::Success)
        .expect("publish");
    let attempt = begin(&mut graph, consumer);
    let bindings = node(&graph, consumer).bindings;
    assert_eq!(bindings[0].provider, first);
    assert_eq!(node(&graph, first).dependents, vec![consumer]);
    graph
        .complete_load(consumer, attempt, LoadOutcome::Failed)
        .expect("failed");
    assert_eq!(node(&graph, consumer).state, LifecycleState::Failed);
    assert!(node(&graph, consumer).bindings.is_empty());
    assert_eq!(node(&graph, consumer).failed_bindings, bindings);
    assert!(node(&graph, first).dependents.is_empty());
    let before = graph.snapshot();
    assert_eq!(before, graph.snapshot());
    assert!(graph.next_action().is_none());
    graph.request(Intent::Disable(first)).expect("disable");
    graph
        .request(Intent::Enable(second))
        .expect("substitution intent");
    let Some(Action::BeginUnload {
        instance,
        activation,
    }) = graph.next_action()
    else {
        panic!("unload");
    };
    assert_eq!(instance, first);
    let unloading = node(&graph, first);
    assert_eq!(unloading.state, LifecycleState::Unloading);
    assert_eq!(unloading.generation, Some(bindings[0].generation));
    assert!(!unloading.intent.enabled);
    graph
        .complete_unload(first, activation, true)
        .expect("clean unload");
    load(&mut graph, second);
    load(&mut graph, consumer);
    let replacement = node(&graph, consumer);
    assert_eq!(replacement.bindings[0].provider, second);
    assert_ne!(replacement.bindings[0].generation, bindings[0].generation);
    assert!(replacement.failed_bindings.is_empty());
    assert_eq!(node(&graph, second).dependents, vec![consumer]);
    let published = node(&graph, second).generation;
    graph
        .request(Intent::Reload(second))
        .expect("reload provider");
    let Some(Action::BeginUnload {
        instance,
        activation,
    }) = graph.next_action()
    else {
        panic!("consumer unload");
    };
    assert_eq!(instance, consumer);
    assert_eq!(node(&graph, consumer).bindings, replacement.bindings);
    graph
        .complete_unload(consumer, activation, true)
        .expect("consumer unload");
    let Some(Action::BeginUnload {
        instance,
        activation,
    }) = graph.next_action()
    else {
        panic!("provider unload");
    };
    assert_eq!(instance, second);
    graph
        .complete_unload(second, activation, true)
        .expect("provider unload");
    load(&mut graph, second);
    load(&mut graph, consumer);
    assert_ne!(node(&graph, second).generation, published);
    assert_eq!(
        node(&graph, consumer).bindings[0].generation,
        node(&graph, second).generation.expect("generation")
    );

    let mut graph = Graph::new();
    let parent = graph.install(vec![], vec![], None).expect("parent");
    graph.request(Intent::Enable(parent)).expect("enable");
    load(&mut graph, parent);
    let child = graph.install(vec![], vec![], Some(parent)).expect("child");
    graph.request(Intent::Enable(child)).expect("enable");
    load(&mut graph, child);
    assert_eq!(node(&graph, parent).children, vec![child]);
    graph.request(Intent::Dispose(parent)).expect("dispose");
    let Some(Action::BeginUnload {
        instance,
        activation,
    }) = graph.next_action()
    else {
        panic!("child unload");
    };
    assert_eq!(instance, child);
    let retiring = node(&graph, child);
    assert_eq!(retiring.parent, Some(parent));
    assert!(retiring.intent.retired && !retiring.intent.enabled);
    assert_eq!(retiring.state, LifecycleState::Unloading);
    graph
        .complete_unload(child, activation, true)
        .expect("remove child");
    assert!(
        !graph
            .snapshot()
            .instances
            .iter()
            .any(|node| node.id == child)
    );
    let Some(Action::BeginUnload {
        instance,
        activation,
    }) = graph.next_action()
    else {
        panic!("parent unload");
    };
    assert_eq!(instance, parent);
    graph
        .complete_unload(parent, activation, false)
        .expect("quarantine");
    let retained = node(&graph, parent);
    assert_eq!(retained.state, LifecycleState::Quarantined);
    assert!(retained.cleanup_failed && retained.intent.retired);
    assert!(retained.children.is_empty());
    graph.request(Intent::Shutdown).expect("shutdown");
    assert!(graph.next_action().is_none());
    assert!(graph.snapshot().instances.is_empty());
}
