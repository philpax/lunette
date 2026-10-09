#![expect(
    clippy::expect_used,
    reason = "snapshot tests assert valid graph actions and installed identities"
)]

use crate::plugin::graph::{
    Action, ActivationId, Graph, InstanceId, InstanceSnapshot, Intent, LifecycleState, LoadOutcome,
};

fn node(graph: &Graph, id: InstanceId) -> InstanceSnapshot {
    graph
        .snapshot()
        .instances
        .into_iter()
        .find(|node| node.id == id)
        .expect("retained instance")
}

fn next(graph: &mut Graph, id: InstanceId) -> ActivationId {
    let (Some(Action::BeginLoad {
        instance,
        activation,
    })
    | Some(Action::BeginUnload {
        instance,
        activation,
    })) = graph.next_action()
    else {
        panic!("expected an action for {id}");
    };
    assert_eq!(instance, id);
    activation
}

fn load(graph: &mut Graph, id: InstanceId) {
    let activation = next(graph, id);
    assert_eq!(node(graph, id).activation, Some(activation));
    assert_eq!(
        node(graph, id).generation,
        None,
        "a loading instance has not published"
    );
    graph
        .complete_load(id, activation, LoadOutcome::Success)
        .expect("publish");
}

#[test]
fn snapshot_tracks_activation_children_retirement_and_quarantine() {
    let mut graph = Graph::new();
    let parent = graph.install(vec![], vec![], None).expect("parent");
    graph.request(Intent::Enable(parent)).expect("enable");
    load(&mut graph, parent);
    assert!(node(&graph, parent).generation.is_some());
    let child = graph.install(vec![], vec![], Some(parent)).expect("child");
    graph.request(Intent::Enable(child)).expect("enable");
    load(&mut graph, child);
    assert_eq!(node(&graph, parent).children, vec![child]);
    assert_eq!(node(&graph, child).parent, Some(parent));

    graph.request(Intent::Dispose(parent)).expect("dispose");
    let activation = next(&mut graph, child);
    let retiring = node(&graph, child);
    assert!(retiring.intent.retired && !retiring.intent.enabled);
    assert_eq!(retiring.state, LifecycleState::Unloading);
    graph
        .complete_unload(child, activation, true)
        .expect("remove child");
    let activation = next(&mut graph, parent);
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
