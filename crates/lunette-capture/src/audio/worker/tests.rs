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
