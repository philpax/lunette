use std::{cell::RefCell, sync::Arc, time::Duration};

use lunette_capture::audio::{
    AudioBackend, AudioBackendEvent, AudioProcessCandidate, CaptureId, ClientIdentity, ClientKind,
    ClientObservation, NodeIdentity, NodeKind, NodeObservation, PortIdentity, PortObservation,
    RegistrySnapshot, plan_graph,
};
use lunette_compositor::protocol::{AudioAttributionReply, AudioNodeSerial, PipeWireGeneration};
use parking_lot::Mutex;

use super::*;
use crate::audio::observer::{ObservationJob, tests_support::controlled};

struct DeliveryBackend(Arc<Mutex<DeliveryState>>);
struct DeliveryState {
    graph: RegistrySnapshot,
    now: Duration,
    request: Option<AudioAttributionRequest>,
    capture: Option<CaptureId>,
    reply_queue: Vec<AudioAttributionReply>,
    other_commands: usize,
    undelivered: Vec<AudioAttributionReply>,
    accepted: Vec<AudioAttributionReply>,
    rejected: Vec<AudioAttributionReply>,
}

impl DeliveryState {
    fn new() -> Self {
        let generation = PipeWireGeneration(1);
        let mut graph = RegistrySnapshot::new(generation);
        graph.nodes.insert(
            9,
            NodeObservation {
                identity: NodeIdentity {
                    generation,
                    serial: AudioNodeSerial(9),
                    global: 9,
                },
                name: "playback".into(),
                kind: NodeKind::Playback,
                client: Some(40),
                application_pid: Some(instance(1).pid()),
                client_api: None,
            },
        );
        graph.clients.insert(
            40,
            ClientObservation {
                identity: ClientIdentity {
                    generation,
                    serial: 40,
                    global: 40,
                },
                pid: Some(instance(1).pid()),
                kind: ClientKind::Native,
            },
        );
        for (global, node, output) in [(10, 9, true), (91, 90, false)] {
            graph.ports.insert(
                global,
                PortObservation {
                    identity: PortIdentity {
                        global,
                        serial: u64::from(global),
                    },
                    node,
                    output,
                    channel: "FL".into(),
                },
            );
        }
        Self {
            graph,
            now: Duration::ZERO,
            request: None,
            capture: None,
            reply_queue: Vec::new(),
            other_commands: 0,
            undelivered: Vec::new(),
            accepted: Vec::new(),
            rejected: Vec::new(),
        }
    }
}

impl AudioBackend for DeliveryBackend {
    fn start(&mut self, capture: CaptureId, _: Source) -> Result<(), AudioError> {
        self.0.lock().capture = Some(capture);
        Ok(())
    }
    fn stop(&mut self, _: CaptureId) {}
    fn poll(&mut self) -> Vec<AudioBackendEvent> {
        let mut state = self.0.lock();
        let now = state.now;
        state.graph.attribution_tick(now, Duration::from_millis(10));
        for reply in std::mem::take(&mut state.reply_queue) {
            if state.graph.attribution_reply(reply, live(1)) {
                state.accepted.push(reply);
            } else {
                state.rejected.push(reply);
            }
        }
        if let Some(candidate) = state.graph.process_candidates().first().copied() {
            state.request = state.graph.observe_process(candidate, live(1));
        }
        state.capture.map_or_else(Vec::new, |capture| {
            vec![AudioBackendEvent::State {
                capture,
                generation: PipeWireGeneration(1),
                state: plan_graph(Source::Process(process(1)), &state.graph, Some(90)).state,
            }]
        })
    }
    fn take_process_candidates(&mut self) -> Vec<AudioProcessCandidate> {
        Vec::new()
    }
    fn observe_process(
        &mut self,
        _: AudioProcessCandidate,
        _: ProcessObservation,
    ) -> Result<(), AudioError> {
        Ok(())
    }
    fn take_attribution_requests(&mut self) -> Vec<AudioAttributionRequest> {
        self.0.lock().request.take().into_iter().collect()
    }
    fn attribution_reply(&mut self, reply: AudioAttributionReply) -> Result<(), AudioError> {
        let mut state = self.0.lock();
        if state.reply_queue.len() + state.other_commands == 64 {
            state.undelivered.push(reply);
            return Err(AudioError::CommandQueueFull);
        }
        state.reply_queue.push(reply);
        Ok(())
    }
    fn set_process_status(
        &mut self,
        _: ProcessId,
        _: ProcessCaptureStatus,
    ) -> Result<(), AudioError> {
        Ok(())
    }
    fn shutdown(&mut self) {}
}

#[derive(Clone, Copy, Debug)]
enum LostDelivery {
    ObserverSubmission,
    ObserverResult,
    BackendReply,
    ResolverCommand,
}

#[test]
fn full_observer_queue_recovers_the_same_capture_after_request_retry() {
    recover(LostDelivery::ObserverSubmission);
}
#[test]
fn dropped_observer_result_recovers_the_same_capture_after_request_retry() {
    recover(LostDelivery::ObserverResult);
}
#[test]
fn full_backend_reply_queue_recovers_the_same_capture_after_request_retry() {
    recover(LostDelivery::BackendReply);
}
#[test]
fn dropped_compositor_command_recovers_the_same_capture_after_request_retry() {
    recover(LostDelivery::ResolverCommand);
}

fn recover(loss: LostDelivery) {
    let backend = Arc::new(Mutex::new(DeliveryState::new()));
    let (observer, control) = controlled();
    let registry = NativeAudioRegistry {
        state: RefCell::new(RegistryState::new(
            Some(AudioService::new(
                Box::new(DeliveryBackend(Arc::clone(&backend))),
                SourceLimits::default(),
            )),
            Some(observer),
            String::new(),
        )),
    };
    let root = snapshot(process(1), live(1), Some(instance(1)));
    registry.begin_frame(&root);
    let reader = registry.open(Source::Process(process(1)));
    registry.begin_frame(&root);
    let old = AudioAttributionReply {
        request: registry.take_requests()[0],
        process: Some(process(1)),
    };
    let node = backend.lock().graph.nodes[&9].identity;
    let client = backend.lock().graph.clients[&40].identity;
    match loss {
        LostDelivery::ObserverSubmission => {
            let state = registry.state.borrow();
            let observer = state.observer.as_ref().expect("controlled observer");
            for _ in 0..64 {
                observer
                    .submit(ObservationJob::Reply(old))
                    .expect("queue slot");
            }
            assert_eq!(
                observer.submit(ObservationJob::Reply(old)),
                Err(AudioError::CommandQueueFull)
            );
            drop(state);
            registry.event(&Event::AudioProcessResolved(old));
            assert_eq!(control.jobs.try_iter().count(), 64);
        }
        LostDelivery::ObserverResult => {
            registry.event(&Event::AudioProcessResolved(old));
            let job = control.jobs.try_recv().expect("observer job");
            // Results are bounded too; loss before frame delivery leaves the graph pending.
            for _ in 0..64 {
                control
                    .results
                    .try_send((job, live(1)))
                    .expect("result slot");
            }
            assert!(matches!(
                control.results.try_send((job, live(1))),
                Err(std::sync::mpsc::TrySendError::Full(_))
            ));
            // Consume the injected saturation without forwarding any stale result.
            assert_eq!(
                registry
                    .state
                    .borrow()
                    .observer
                    .as_ref()
                    .expect("observer")
                    .poll()
                    .len(),
                64
            );
        }
        LostDelivery::BackendReply => {
            backend.lock().other_commands = 64;
            registry.event(&Event::AudioProcessResolved(old));
            let job = control.jobs.try_recv().expect("observer job");
            control
                .results
                .try_send((job, live(1)))
                .expect("observer result");
            registry.begin_frame(&root);
            assert_eq!(backend.lock().undelivered, vec![old]);
            backend.lock().other_commands = 0;
        }
        LostDelivery::ResolverCommand => {}
    }
    assert!(!matches!(
        state(&registry, reader),
        CaptureState::Active { .. }
    ));
    backend.lock().now = Duration::from_millis(10);
    registry.begin_frame(&root);
    let retry = registry.take_requests();
    assert_eq!(
        retry.len(),
        1,
        "{loss:?} must recover after capacity returns"
    );
    let retry = AudioAttributionReply {
        request: retry[0],
        process: Some(process(1)),
    };
    assert_ne!(retry.request.request, old.request.request);
    assert_eq!(retry.request.node, old.request.node);
    assert_eq!(retry.request.generation, old.request.generation);
    assert_eq!(retry.request.candidate, old.request.candidate);
    for reply in [old, retry] {
        registry.event(&Event::AudioProcessResolved(reply));
        let job = control.jobs.try_recv().expect("revalidation job");
        control
            .results
            .try_send((job, live(1)))
            .expect("observation result");
    }
    registry.begin_frame(&root);
    registry.begin_frame(&root);
    assert!(matches!(
        state(&registry, reader),
        CaptureState::Active { .. }
    ));
    let state = backend.lock();
    assert_eq!(state.graph.nodes[&9].identity, node);
    assert_eq!(state.graph.clients[&40].identity, client);
    assert_eq!(state.accepted.last(), Some(&retry));
    assert!(state.rejected.contains(&old));
}
