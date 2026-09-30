#![expect(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "graph tests construct valid descriptors and assert current actions before unwrapping results"
)]

use super::*;

#[test]
fn parent_disable_and_reload_drain_children_without_shutdown() {
    for reload in [false, true] {
        let mut graph = Graph::new(8);
        let parent = graph.install(vec![], vec![key("parent", 1)], None).unwrap();
        graph.enqueue(Intent::Enable(parent)).unwrap();
        load(&mut graph, parent);
        let child = graph
            .install(vec![], vec![key("child", 1)], Some(parent))
            .unwrap();
        graph.enqueue(Intent::Enable(child)).unwrap();
        load(&mut graph, child);
        graph
            .enqueue(if reload {
                Intent::Reload(parent)
            } else {
                Intent::Disable(parent)
            })
            .unwrap();
        unload(&mut graph, child, true);
        unload(&mut graph, parent, true);
        assert!(matches!(
            graph.state(child),
            Err(GraphError::UnknownInstance(_))
        ));
        if reload {
            load(&mut graph, parent);
        }
        assert!(graph.next_action().is_none());
    }
}

#[test]
fn failed_child_cleanup_does_not_block_terminal_shutdown() {
    let mut graph = Graph::new(8);
    let parent = graph.install(vec![], vec![key("parent", 1)], None).unwrap();
    graph.enqueue(Intent::Enable(parent)).unwrap();
    load(&mut graph, parent);
    let child = graph
        .install(vec![], vec![key("child", 1)], Some(parent))
        .unwrap();
    graph.enqueue(Intent::Enable(child)).unwrap();
    load(&mut graph, child);
    graph.enqueue(Intent::Dispose(child)).unwrap();
    unload(&mut graph, child, false);
    assert!(graph.install(vec![], vec![key("child", 2)], None).is_err());
    graph.enqueue(Intent::Shutdown).unwrap();
    unload(&mut graph, parent, true);
    assert!(graph.next_action().is_none());
    assert!(graph.is_shutdown());
    assert!(graph.attachment(child).is_err());
}

#[test]
fn cycle_on_second_requirement_is_reported() {
    let mut graph = Graph::new(8);
    let root = graph
        .install(vec![], vec![key("aaa-root", 1)], None)
        .unwrap();
    let a = graph
        .install(
            vec![key("aaa-root", 1), key("b", 1)],
            vec![key("a", 1)],
            None,
        )
        .unwrap();
    let b = graph
        .install(vec![key("a", 1)], vec![key("b", 1)], None)
        .unwrap();
    for id in [root, a, b] {
        graph.enqueue(Intent::Enable(id)).unwrap();
    }
    load(&mut graph, root);
    assert!(graph.next_action().is_none());
    assert_eq!(
        graph.take_diagnostics(),
        vec![GraphError::DependencyCycle {
            instances: vec![a, b, a]
        }]
    );
}

#[test]
fn explicit_cleanup_failure_drains_children_and_quarantines_until_shutdown() {
    let mut graph = Graph::new(8);
    let parent = graph.install(vec![], vec![key("parent", 1)], None).unwrap();
    graph.enqueue(Intent::Enable(parent)).unwrap();
    let activation = load(&mut graph, parent);
    let child = graph.install(vec![], vec![], Some(parent)).unwrap();
    graph.enqueue(Intent::Enable(child)).unwrap();
    load(&mut graph, child);
    graph.mark_cleanup_failed(parent, activation).unwrap();
    unload(&mut graph, child, true);
    assert!(graph.next_action().is_none());
    assert!(graph.install(vec![], vec![key("parent", 2)], None).is_err());
    graph.enqueue(Intent::Shutdown).unwrap();
    unload(&mut graph, parent, true);
    assert!(graph.next_action().is_none());
    assert!(graph.is_shutdown());
}

#[test]
fn failed_rollback_retains_exact_allocation() {
    let mut graph = Graph::new(8);
    let instance = graph.install(vec![], vec![key("root", 1)], None).unwrap();
    graph.enqueue(Intent::Enable(instance)).unwrap();
    let Some(Action::BeginLoad { activation, .. }) = graph.next_action() else {
        panic!("expected loading allocation");
    };
    graph.mark_cleanup_failed(instance, activation).unwrap();
    assert_eq!(
        graph.complete_load(instance, activation, LoadOutcome::Failed),
        Err(GraphError::StaleAction)
    );
    assert_eq!(
        graph.attachment(instance).unwrap().unwrap().activation,
        activation
    );
    assert!(graph.install(vec![], vec![key("root", 2)], None).is_err());
    graph.enqueue(Intent::Shutdown).unwrap();
    unload(&mut graph, instance, false);
    assert!(graph.next_action().is_none());
    assert!(graph.is_shutdown());
}

#[test]
fn shutdown_drains_all_roots_despite_exhaustion_and_cleanup_failures() {
    let mut graph = Graph::new(1);
    let mut roots = Vec::new();
    for _ in 0..300 {
        let id = graph.install(vec![], vec![], None).unwrap();
        graph.enqueue(Intent::Enable(id)).unwrap();
        load(&mut graph, id);
        roots.push(id);
    }
    graph.enqueue(Intent::Disable(roots[0])).unwrap();
    assert_eq!(
        graph.enqueue(Intent::Disable(roots[1])),
        Err(GraphError::QueueExhausted)
    );
    graph.enqueue(Intent::Shutdown).unwrap();
    for (index, id) in roots.into_iter().enumerate() {
        unload(&mut graph, id, index % 3 != 0);
    }
    assert!(graph.next_action().is_none());
    assert!(graph.is_shutdown());
}

#[test]
fn quarantined_remaining_cleanup_precedes_provider_and_parent() {
    for child in [false, true] {
        for success in [false, true] {
            let mut graph = Graph::new(8);
            let provider = graph
                .install(vec![], vec![key("provider", 1)], None)
                .unwrap();
            graph.enqueue(Intent::Enable(provider)).unwrap();
            load(&mut graph, provider);
            let consumer = graph
                .install(
                    if child {
                        vec![]
                    } else {
                        vec![key("provider", 1)]
                    },
                    vec![key("consumer", 1)],
                    child.then_some(provider),
                )
                .unwrap();
            graph.enqueue(Intent::Enable(consumer)).unwrap();
            let activation = load(&mut graph, consumer);
            graph.mark_cleanup_failed(consumer, activation).unwrap();
            graph.enqueue(Intent::Shutdown).unwrap();
            assert_eq!(
                graph.next_action(),
                Some(Action::BeginUnload {
                    instance: consumer,
                    activation
                })
            );
            let view = graph.attachment(consumer).unwrap().unwrap();
            graph
                .validate_attachment(consumer, activation, &view.bindings)
                .unwrap();
            assert!(graph.next_action().is_none());
            graph
                .complete_unload(consumer, activation, success)
                .unwrap();
            assert_eq!(graph.state(consumer).unwrap(), LifecycleState::Failed);
            unload(&mut graph, provider, true);
            assert!(graph.next_action().is_none());
            assert!(graph.is_shutdown());
        }
    }
}

#[test]
fn cancelled_load_after_disable_enable_starts_fresh_activation() {
    let mut graph = Graph::new(8);
    let id = graph.install(vec![], vec![], None).unwrap();
    graph.enqueue(Intent::Enable(id)).unwrap();
    let Some(Action::BeginLoad { activation, .. }) = graph.next_action() else {
        panic!("expected load")
    };
    graph.enqueue(Intent::Disable(id)).unwrap();
    graph.enqueue(Intent::Enable(id)).unwrap();
    graph
        .complete_load(id, activation, LoadOutcome::Cancelled)
        .unwrap();
    let fresh = load(&mut graph, id);
    assert_ne!(fresh, activation);
}

fn key(name: &str, schema: u32) -> ContractKey {
    ContractKey::new(name, schema)
}

fn load(graph: &mut Graph, instance: InstanceId) -> ActivationId {
    let Some(Action::BeginLoad {
        instance: actual,
        activation,
        ..
    }) = graph.next_action()
    else {
        panic!("expected a load action for {instance}");
    };
    assert_eq!(actual, instance);
    graph
        .complete_load(instance, activation, LoadOutcome::Success)
        .expect("load action should be current");
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

#[test]
fn graph_transition_model() {
    let mut graph = Graph::new(8);
    let instance = graph
        .install(Vec::new(), vec![key("root", 1)], None)
        .unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Inactive);
    graph.enqueue(Intent::Enable(instance)).unwrap();
    let activation = load(&mut graph, instance);
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Active);
    graph.enqueue(Intent::Disable(instance)).unwrap();
    let unload_activation = unload(&mut graph, instance, true);
    assert_eq!(activation, unload_activation);
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Inactive);
}

#[test]
fn diamond_drain() {
    let mut graph = Graph::new(16);
    let root = graph
        .install(Vec::new(), vec![key("root", 1)], None)
        .unwrap();
    let left = graph
        .install(vec![key("root", 1)], vec![key("left", 1)], None)
        .unwrap();
    let right = graph
        .install(vec![key("root", 1)], vec![key("right", 1)], None)
        .unwrap();
    let leaf = graph
        .install(
            vec![key("left", 1), key("right", 1)],
            vec![key("leaf", 1)],
            None,
        )
        .unwrap();
    for instance in [root, left, right, leaf] {
        graph.enqueue(Intent::Enable(instance)).unwrap();
    }
    load(&mut graph, root);
    load(&mut graph, left);
    load(&mut graph, right);
    load(&mut graph, leaf);

    graph.enqueue(Intent::Disable(root)).unwrap();
    let Some(Action::BeginUnload { instance, .. }) = graph.next_action() else {
        panic!("expected leaf unload");
    };
    assert_eq!(instance, leaf);
}

#[test]
fn activation_generation_change() {
    let mut graph = Graph::new(8);
    let provider = graph
        .install(Vec::new(), vec![key("service", 1)], None)
        .unwrap();
    let consumer = graph
        .install(vec![key("service", 1)], vec![key("consumer", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(provider)).unwrap();
    load(&mut graph, provider);
    graph.enqueue(Intent::Enable(consumer)).unwrap();
    let first_activation = load(&mut graph, consumer);
    let first = graph.attachment(consumer).unwrap().unwrap();
    let first_generation = first.generation;

    graph.enqueue(Intent::Reload(provider)).unwrap();
    let _ = unload(&mut graph, consumer, true);
    let _ = unload(&mut graph, provider, true);
    graph.enqueue(Intent::Enable(provider)).unwrap();
    load(&mut graph, provider);
    let second_generation = graph.attachment(provider).unwrap().unwrap().generation;
    assert_ne!(first_generation, second_generation);
    graph.enqueue(Intent::Enable(consumer)).unwrap();
    let second_activation = load(&mut graph, consumer);
    assert_ne!(first_activation, second_activation);
}

#[test]
fn child_ownership() {
    let mut graph = Graph::new(8);
    let parent = graph
        .install(Vec::new(), vec![key("parent", 1)], None)
        .unwrap();
    let child = graph
        .install(Vec::new(), vec![key("child", 1)], Some(parent))
        .unwrap();
    graph.enqueue(Intent::Enable(child)).unwrap();
    assert!(graph.next_action().is_none());
    graph.enqueue(Intent::Enable(parent)).unwrap();
    load(&mut graph, parent);
    graph.enqueue(Intent::Enable(child)).unwrap();
    load(&mut graph, child);
    graph.enqueue(Intent::Dispose(parent)).unwrap();
    let Some(Action::BeginUnload { instance, .. }) = graph.next_action() else {
        panic!("expected child unload");
    };
    assert_eq!(instance, child);
}

#[test]
fn cycle_diagnostic() {
    let mut graph = Graph::new(8);
    let first = graph
        .install(vec![key("second", 1)], vec![key("first", 1)], None)
        .unwrap();
    let second = graph
        .install(vec![key("first", 1)], vec![key("second", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(first)).unwrap();
    graph.enqueue(Intent::Enable(second)).unwrap();
    assert!(graph.next_action().is_none());
    assert!(matches!(
        graph.take_diagnostics().as_slice(),
        [GraphError::DependencyCycle { .. }]
    ));
    assert!(graph.next_action().is_none());
    assert!(graph.take_diagnostics().is_empty());
}

#[test]
fn self_disable_never_publishes() {
    let mut graph = Graph::new(8);
    let instance = graph
        .install(Vec::new(), vec![key("service", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(instance)).unwrap();
    let Some(Action::BeginLoad { activation, .. }) = graph.next_action() else {
        panic!("expected load");
    };
    graph.enqueue(Intent::Disable(instance)).unwrap();
    graph
        .complete_load(instance, activation, LoadOutcome::Success)
        .unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Loading);
    assert_eq!(
        graph.attachment(instance).unwrap().unwrap().activation,
        activation
    );
    assert!(graph.next_action().is_none());
    graph
        .complete_load(instance, activation, LoadOutcome::Cancelled)
        .unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Inactive);
    assert!(graph.attachment(instance).unwrap().is_none());
}

#[test]
fn reentrant_cleanup_queue() {
    let mut graph = Graph::new(8);
    let instance = graph
        .install(Vec::new(), vec![key("service", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(instance)).unwrap();
    load(&mut graph, instance);
    graph.enqueue(Intent::Reload(instance)).unwrap();
    let Some(Action::BeginUnload { activation, .. }) = graph.next_action() else {
        panic!("expected reload unload");
    };
    graph.enqueue(Intent::Disable(instance)).unwrap();
    graph.complete_unload(instance, activation, true).unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Inactive);
    assert!(graph.next_action().is_none());
}

#[test]
fn queue_exhaustion_shutdown() {
    let mut graph = Graph::new(1);
    let first = graph
        .install(Vec::new(), vec![key("first", 1)], None)
        .unwrap();
    let second = graph
        .install(Vec::new(), vec![key("second", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(first)).unwrap();
    assert_eq!(
        graph.enqueue(Intent::Enable(second)),
        Err(GraphError::QueueExhausted)
    );
    assert!(graph.next_action().is_none());
    graph.enqueue(Intent::Shutdown).unwrap();
    assert!(graph.next_action().is_none());
    assert!(graph.is_shutdown());
}

#[test]
fn cleanup_failure_quarantines_reservation() {
    let mut graph = Graph::new(8);
    let instance = graph
        .install(Vec::new(), vec![key("service", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(instance)).unwrap();
    load(&mut graph, instance);
    graph.enqueue(Intent::Dispose(instance)).unwrap();
    let Some(Action::BeginUnload { activation, .. }) = graph.next_action() else {
        panic!("expected unload");
    };
    graph.complete_unload(instance, activation, false).unwrap();
    assert_eq!(graph.state(instance).unwrap(), LifecycleState::Failed);
    assert_eq!(graph.enqueue(Intent::Enable(instance)), Ok(()));
    assert!(graph.next_action().is_none());
    assert!(matches!(
        graph.install(Vec::new(), vec![key("service", 1)], None),
        Err(GraphError::ContractConflict { .. })
    ));
}

#[test]
fn conflict_is_transactional_and_clean_dispose_releases_name() {
    let mut graph = Graph::new(8);
    let first = graph
        .install(Vec::new(), vec![key("service", 1)], None)
        .unwrap();
    assert!(matches!(
        graph.install(Vec::new(), vec![key("service", 2)], None),
        Err(GraphError::ContractConflict { .. })
    ));
    let second = graph
        .install(Vec::new(), vec![key("other", 1)], None)
        .unwrap();
    assert_eq!(second.get(), first.get() + 1);
    graph.enqueue(Intent::Enable(first)).unwrap();
    load(&mut graph, first);
    graph.enqueue(Intent::Dispose(first)).unwrap();
    let _ = unload(&mut graph, first, true);
    assert!(
        graph
            .install(Vec::new(), vec![key("service", 2)], None)
            .is_ok()
    );
}

#[test]
fn disabled_provider_releases_name_for_replacement() {
    let mut graph = Graph::new(8);
    let provider = graph
        .install(Vec::new(), vec![key("service", 1)], None)
        .unwrap();
    graph.enqueue(Intent::Enable(provider)).unwrap();
    load(&mut graph, provider);
    graph.enqueue(Intent::Disable(provider)).unwrap();
    let _ = unload(&mut graph, provider, true);
    let replacement = graph
        .install(Vec::new(), vec![key("service", 2)], None)
        .unwrap();
    assert_eq!(
        graph.enqueue(Intent::Enable(provider)),
        Err(GraphError::ContractConflict {
            name: "service".to_owned(),
            owner: replacement,
            attempted: key("service", 1),
        })
    );
    graph.enqueue(Intent::Enable(replacement)).unwrap();
    load(&mut graph, replacement);
    graph.enqueue(Intent::Dispose(provider)).unwrap();
    assert!(graph.next_action().is_none());
    assert!(matches!(
        graph.install(Vec::new(), vec![key("service", 2)], None),
        Err(GraphError::ContractConflict { owner, .. }) if owner == replacement
    ));
    let consumer = graph
        .install(vec![key("service", 2)], Vec::new(), None)
        .unwrap();
    graph.enqueue(Intent::Enable(consumer)).unwrap();
    let Some(Action::BeginLoad { bindings, .. }) = graph.next_action() else {
        panic!("expected consumer load");
    };
    assert_eq!(bindings.len(), 1);
    assert_eq!(bindings[0].provider, replacement);
}

#[test]
fn duplicate_contract_is_explicit() {
    let mut graph = Graph::new(4);
    assert_eq!(
        graph.install(Vec::new(), vec![key("service", 1), key("service", 2)], None,),
        Err(GraphError::DuplicateProvided {
            name: "service".to_owned()
        })
    );
}
