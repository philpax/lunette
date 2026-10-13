use std::{collections::VecDeque, io};

use lunette_compositor::protocol::{Pid, ProcessObservation, ProcessObservationFailure};
use parking_lot::Mutex;

use super::*;
use crate::audio::{
    GraphFailure, RecordedGraphOperation as Op, RecordingGraphOps, RegistrySnapshot,
    UnavailableReason, tests_support::*,
};

struct Inspector {
    observations: Mutex<VecDeque<ProcessObservation>>,
    calls: Mutex<Vec<Pid>>,
}
impl Inspector {
    fn new(values: &[ProcessObservation]) -> Self {
        Self {
            observations: Mutex::new(values.iter().copied().collect()),
            calls: Mutex::new(Vec::new()),
        }
    }
}
impl ProcessInspector for Inspector {
    fn observe(&self, pid: Pid) -> ProcessObservation {
        self.calls.lock().push(pid);
        self.observations
            .lock()
            .pop_front()
            .unwrap_or(ProcessObservation::Ended)
    }
    fn read_environment(&self, _pid: Pid, _key: &str) -> io::Result<Option<Vec<u8>>> {
        panic!("audio worker does not read process environments")
    }
}

#[test]
fn scripted_inspector_revalidates_replies_before_production_reconciliation() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL", "FR"]);
    mixer(&mut snapshot);
    let mut ops = RecordingGraphOps::new(snapshot);
    let mut driver = GraphDriver::new("test".into(), Duration::from_millis(10));
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    let denied = ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied);
    let inspector = Inspector::new(&[denied, live(1), live(2)]);
    let mut worker = AttributionWorker::default();
    let mut requests = Vec::new();
    driver.tick_with_registry(Duration::ZERO, &mut ops, &mut |registry| {
        requests.extend(worker.observe(
            registry,
            Duration::ZERO,
            Duration::from_millis(10),
            &inspector,
            8,
        ));
    });
    assert!(requests.is_empty(), "first denied observation can recover");
    driver.tick_with_registry(Duration::from_millis(10), &mut ops, &mut |registry| {
        requests.extend(worker.observe(
            registry,
            Duration::from_millis(10),
            Duration::from_millis(10),
            &inspector,
            8,
        ));
    });
    assert_eq!(requests.len(), 1);
    let reply = AudioAttributionReply {
        request: requests[0],
        process: Some(process()),
    };
    driver.tick_with_registry(Duration::from_millis(11), &mut ops, &mut |registry| {
        assert!(!worker.reply(registry, reply, &inspector));
    });
    assert!(driver.registry.attributions.is_empty());
    assert!(driver.registry.process_candidates().is_empty());
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(lunette_compositor::protocol::PipeWireGeneration(1)),
            Op::CreateAdapter {
                object: crate::audio::GraphObjectId(1),
                name: "test.mixer.1".into()
            }
        ]
    );
    assert_eq!(*inspector.calls.lock(), vec![pid(); 3]);
}

#[test]
fn fresh_registry_observation_rejects_reply_after_client_reuse() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    mixer(&mut snapshot);
    let mut ops = RecordingGraphOps::new(snapshot);
    let mut driver = GraphDriver::new("test".into(), Duration::from_millis(10));
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    let inspector = Inspector::new(&[live(1), live(1)]);
    let mut worker = AttributionWorker::default();
    let mut requests = Vec::new();
    driver.tick_with_registry(Duration::ZERO, &mut ops, &mut |registry| {
        requests = worker.observe(
            registry,
            Duration::ZERO,
            Duration::from_millis(10),
            &inspector,
            8,
        );
    });
    if let Some(client) = ops.snapshot.clients.get_mut(&40) {
        client.identity.serial += 1;
    }
    driver.tick_with_registry(Duration::from_millis(1), &mut ops, &mut |registry| {
        assert!(!worker.reply(
            registry,
            AudioAttributionReply {
                request: requests[0],
                process: Some(process())
            },
            &inspector
        ));
    });
    assert!(driver.registry.attributions.is_empty());
    assert_eq!(ops.operations.len(), 2);
}

#[test]
fn dropped_resolver_request_retries_the_same_node_and_rejects_the_old_reply() {
    recover_dropped_delivery(false);
}

#[test]
fn dropped_resolver_reply_retries_the_same_node_and_rejects_the_old_reply() {
    recover_dropped_delivery(true);
}

fn recover_dropped_delivery(drop_reply: bool) {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL", "FR"]);
    mixer(&mut snapshot);
    let mut ops = RecordingGraphOps::new(snapshot);
    let retry = Duration::from_millis(10);
    let mut driver = GraphDriver::new("test".into(), retry);
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    let inspector = Inspector::new(&[live(1); 4]);
    let mut worker = AttributionWorker::default();
    let mut requests = Vec::new();
    driver.tick_with_registry(Duration::ZERO, &mut ops, &mut |registry| {
        requests = worker.observe(registry, Duration::ZERO, retry, &inspector, 1);
    });
    assert_eq!(requests.len(), 1);
    let old = AudioAttributionReply {
        request: requests[0],
        process: Some(process()),
    };
    let (sender, receiver) = mpsc::sync_channel(1);
    sender.try_send(old).unwrap_or_else(|_| unreachable!());
    if drop_reply {
        assert!(matches!(sender.try_send(old), Err(TrySendError::Full(_))));
    } else {
        // A command batch can disappear after the request leaves the audio backend.
        drop(receiver);
    }
    driver.tick_with_registry(Duration::from_millis(9), &mut ops, &mut |registry| {
        assert!(
            worker
                .observe(registry, Duration::from_millis(9), retry, &inspector, 1)
                .is_empty()
        );
    });
    driver.tick_with_registry(retry, &mut ops, &mut |registry| {
        requests = worker.observe(registry, retry, retry, &inspector, 1);
    });
    assert_eq!(
        requests.len(),
        1,
        "undelivered attribution must become retryable"
    );
    let retried = requests[0];
    assert_ne!(retried.request, old.request.request);
    assert_eq!(retried.node, old.request.node);
    assert_eq!(retried.generation, old.request.generation);
    assert_eq!(retried.candidate, old.request.candidate);
    let events = driver.tick_with_registry(Duration::from_millis(11), &mut ops, &mut |registry| {
        assert!(!worker.reply(registry, old, &inspector));
        assert!(worker.reply(
            registry,
            AudioAttributionReply {
                request: retried,
                process: Some(process())
            },
            &inspector
        ));
    });
    assert!(events.iter().any(|event| matches!(
        event,
        AudioBackendEvent::State {
            state: crate::audio::CaptureState::Active { .. },
            ..
        }
    )));
    assert_eq!(driver.registry.nodes[&20].identity, identity(20));
    assert_eq!(
        driver.registry.clients[&40].identity,
        ops.snapshot.clients[&40].identity
    );
    assert_eq!(driver.registry.attributions.len(), 1);
}

#[test]
fn timeout_cannot_rebind_a_reused_pid_or_revive_an_old_reply() {
    let mut registry = system();
    playback(&mut registry, 20, &["FL"]);
    let mut worker = AttributionWorker::default();
    let retry = Duration::from_millis(10);
    let inspector = Inspector::new(&[live(1), live(2), live(2), live(1)]);
    let original = worker.observe(&mut registry, Duration::ZERO, retry, &inspector, 1)[0];
    assert!(
        worker
            .observe(&mut registry, retry, retry, &inspector, 1)
            .is_empty()
    );
    assert!(
        worker
            .observe(&mut registry, retry * 2, retry, &inspector, 1)
            .is_empty()
    );
    assert!(!worker.reply(
        &mut registry,
        AudioAttributionReply {
            request: original,
            process: Some(process())
        },
        &inspector
    ));
    assert!(registry.attributions.is_empty());
    assert!(registry.process_candidates().is_empty());
    assert!(
        worker
            .observe(&mut registry, retry * 3, retry, &inspector, 1)
            .is_empty()
    );
}

#[test]
fn zero_budget_does_not_extend_a_pending_deadline_or_accept_its_late_reply() {
    let mut registry = system();
    playback(&mut registry, 20, &["FL"]);
    let retry = Duration::from_millis(10);
    let inspector = Inspector::new(&[live(1); 3]);
    let mut worker = AttributionWorker::default();
    let request = worker.observe(&mut registry, Duration::ZERO, retry, &inspector, 1)[0];
    assert!(
        worker
            .observe(&mut registry, retry, retry, &inspector, 0)
            .is_empty()
    );
    assert!(!worker.reply(
        &mut registry,
        AudioAttributionReply {
            request,
            process: Some(process())
        },
        &inspector
    ));
    let retried = worker.observe(&mut registry, retry, retry, &inspector, 1);
    assert_eq!(retried.len(), 1);
    assert_ne!(retried[0].request, request.request);
}

#[test]
fn unavailable_nodes_cannot_starve_later_nodes_or_grow_timing_history() {
    let mut registry = system();
    for global in 20..24 {
        playback(&mut registry, global, &["FL"]);
    }
    let denied = ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied);
    let inspector = Inspector::new(&[denied; 9]);
    let retry = Duration::from_millis(10);
    let mut worker = AttributionWorker::default();
    for tick in 0..4 {
        let before = inspector.calls.lock().len();
        assert!(
            worker
                .observe(&mut registry, retry * tick, retry, &inspector, 1)
                .is_empty()
        );
        assert_eq!(inspector.calls.lock().len(), before + 1);
        assert_eq!(worker.last_observed.len(), tick as usize + 1);
    }
    assert_eq!(
        worker.last_observed.keys().copied().collect::<Vec<_>>(),
        (20..24)
            .map(|global| identity(global).serial)
            .collect::<Vec<_>>()
    );
    for global in 20..24 {
        registry.remove(global);
    }
    worker.observe(&mut registry, retry * 4, retry, &inspector, 1);
    assert!(worker.last_observed.is_empty());
}

#[test]
fn backend_poll_and_deferred_stops_remain_bounded_without_a_server() {
    let (commands, received) = mpsc::sync_channel(1);
    let (events, event_rx) = mpsc::sync_channel(64);
    let mut backend = PipeWireAudioBackend {
        commands,
        events: event_rx,
        deferred: VecDeque::new(),
        requests: Vec::new(),
        event_budget: 8,
        live_captures: BTreeSet::from([CaptureId(1)]),
        shutdown: Arc::new(AtomicBool::new(false)),
        join: None,
    };
    for _ in 0..20 {
        events
            .try_send(WorkerEvent::Backend(AudioBackendEvent::State {
                capture: CaptureId(1),
                generation: lunette_compositor::protocol::PipeWireGeneration(1),
                state: crate::audio::CaptureState::Idle,
            }))
            .unwrap_or_else(|_| unreachable!());
    }
    assert_eq!(backend.poll().len(), 8);
    assert_eq!(backend.poll().len(), 8);
    assert_eq!(backend.poll().len(), 4);
    backend
        .commands
        .try_send(Command::Start(CaptureId(1), Source::System))
        .unwrap_or_else(|_| unreachable!());
    for _ in 0..100 {
        backend.stop(CaptureId(1));
    }
    assert_eq!(backend.deferred.len(), 1);
    assert_eq!(
        backend.start(CaptureId(2), Source::System),
        Err(AudioError::CommandQueueFull)
    );
    let _ = received.try_recv();
    backend.poll();
    assert!(matches!(
        received.try_recv(),
        Ok(Command::Stop(CaptureId(1)))
    ));
}

#[test]
fn reconnect_resets_attribution_request_generation() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    let mut ops = RecordingGraphOps::new(snapshot);
    let mut driver = GraphDriver::new("test".into(), Duration::from_millis(10));
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    let inspector = Inspector::new(&[live(1), live(2)]);
    let mut worker = AttributionWorker::default();
    let mut requests = Vec::new();
    driver.tick_with_registry(Duration::ZERO, &mut ops, &mut |registry| {
        requests.extend(worker.observe(
            registry,
            Duration::ZERO,
            Duration::from_millis(10),
            &inspector,
            8,
        ));
    });
    ops.observation_errors.push_back(GraphFailure {
        reason: UnavailableReason::NoServer,
        detail: "scripted disconnect".into(),
    });
    driver.tick(Duration::from_millis(1), &mut ops);
    driver.tick_with_registry(Duration::from_millis(11), &mut ops, &mut |registry| {
        requests.extend(worker.observe(
            registry,
            Duration::from_millis(11),
            Duration::from_millis(10),
            &inspector,
            8,
        ));
    });
    assert_eq!(requests.len(), 2);
    assert_ne!(requests[0].generation, requests[1].generation);
    assert_ne!(requests[0].candidate, requests[1].candidate);
    let mut unrelated = RegistrySnapshot::new(requests[1].generation);
    unrelated.update_observations(driver.registry.clone());
    assert!(!unrelated.attribution_reply(
        AudioAttributionReply {
            request: requests[0],
            process: Some(process())
        },
        live(1)
    ));
}
