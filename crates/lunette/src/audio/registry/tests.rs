use std::{
    io,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use lunette_capture::audio::{
    AttributionProvenance, AudioBackendEvent, AudioFormat, CaptureId, NodeIdentity, PacketResult,
    PcmPacket, PidAssertion, RecordedAudioCommand, RecordingAudioBackend, RecordingAudioControl,
    SourceLimits, audio_transport,
};
use lunette_compositor::protocol::{
    AudioAttributionReply, AudioAttributionRequestId, AudioNodeSerial, Pid, PipeWireGeneration,
    ProcessOutcome,
};

#[path = "delivery_tests.rs"]
mod delivery_tests;

use super::*;

struct Inspector(ProcessObservation);

impl ProcessInspector for Inspector {
    fn read_environment(&self, _: Pid, _: &str) -> io::Result<Option<Vec<u8>>> {
        panic!("the audio registry never reads authentication environments")
    }
    fn observe(&self, _: Pid) -> ProcessObservation {
        self.0
    }
}

fn process(id: u64) -> ProcessId {
    ProcessId::new(id).expect("nonzero id")
}
fn instance(start: u64) -> ProcessInstance {
    ProcessInstance::new(Pid::new(400).expect("positive PID"), start)
}
fn live(start: u64) -> ProcessObservation {
    ProcessObservation::Live {
        instance: instance(start),
        parent: None,
    }
}
fn snapshot(
    id: ProcessId,
    observation: ProcessObservation,
    registered: Option<ProcessInstance>,
) -> Snapshot {
    Snapshot {
        processes: vec![ProcessSnapshot {
            process: id,
            pid: Some(instance(1).pid()),
            instance: registered,
            observation,
            alive: true,
            external: false,
        }],
        ..Snapshot::default()
    }
}
fn registry() -> (NativeAudioRegistry, RecordingAudioControl) {
    let (backend, control) = RecordingAudioBackend::new();
    let registry = NativeAudioRegistry::new(
        AudioService::new(Box::new(backend), SourceLimits::default()),
        Box::new(Inspector(live(1))),
    )
    .expect("observer starts");
    (registry, control)
}
fn starts(control: &RecordingAudioControl) -> Vec<(CaptureId, Source)> {
    control
        .commands()
        .into_iter()
        .filter_map(|command| match command {
            RecordedAudioCommand::Start(capture, source) => Some((capture, source)),
            _ => None,
        })
        .collect()
}
fn state(registry: &dyn AudioRegistry, capture: AudioCaptureId) -> CaptureState {
    registry
        .snapshot(capture)
        .expect("reader exists")
        .state
        .clone()
}

#[test]
fn pending_spawn_survives_absent_snapshots_and_starts_after_registration() {
    let (registry, control) = registry();
    let id = process(1);
    registry.pending_process(id);
    let reader = registry.open(Source::Process(id));
    for _ in 0..3 {
        registry.begin_frame(&Snapshot::default());
    }
    assert_eq!(state(&registry, reader), CaptureState::Starting);
    assert!(starts(&control).is_empty());
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    assert_eq!(starts(&control).len(), 1);
    let commands = control.commands();
    let live_position = commands
        .iter()
        .position(|command| {
            matches!(
                command,
                RecordedAudioCommand::ProcessStatus(_, ProcessCaptureStatus::Live)
            )
        })
        .expect("live status");
    let start_position = commands
        .iter()
        .position(|command| matches!(command, RecordedAudioCommand::Start(_, _)))
        .expect("capture start");
    assert!(live_position < start_position);
    registry.begin_frame(&Snapshot::default());
    assert_ne!(state(&registry, reader), CaptureState::Ended);
}

#[test]
fn failed_spawn_and_exit_before_registration_are_terminal() {
    for outcome in [
        ProcessOutcome::Exited { code: 0 },
        ProcessOutcome::SpawnFailed {
            message: "program unavailable".into(),
        },
    ] {
        let (registry, control) = registry();
        let id = process(1);
        registry.pending_process(id);
        let reader = registry.open(Source::Process(id));
        registry.event(&Event::ProcessExited {
            process: id,
            outcome,
        });
        registry.begin_frame(&Snapshot::default());
        assert_eq!(state(&registry, reader), CaptureState::Ended);
        registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
        assert_eq!(state(&registry, reader), CaptureState::Ended);
        assert!(starts(&control).is_empty());
    }
}

#[test]
fn denied_registration_never_binds_a_later_reusable_pid() {
    let (registry, control) = registry();
    let id = process(1);
    registry.pending_process(id);
    let reader = registry.open(Source::Process(id));
    registry.begin_frame(&snapshot(
        id,
        ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied),
        None,
    ));
    assert!(matches!(
        state(&registry, reader),
        CaptureState::Unavailable {
            reason: UnavailableReason::PermissionDenied,
            ..
        }
    ));
    registry.begin_frame(&snapshot(id, live(2), Some(instance(2))));
    assert!(matches!(
        state(&registry, reader),
        CaptureState::Unavailable { .. }
    ));
    assert!(starts(&control).is_empty());
}

#[test]
fn process_observation_failures_preserve_distinct_public_reasons() {
    for (failure, expected) in [
        (
            ProcessObservationFailure::AccessDenied,
            UnavailableReason::PermissionDenied,
        ),
        (
            ProcessObservationFailure::InvalidData,
            UnavailableReason::UnresolvedAttribution,
        ),
        (
            ProcessObservationFailure::Other,
            UnavailableReason::UnresolvedAttribution,
        ),
    ] {
        for registered in [None, Some(instance(1))] {
            let (registry, control) = registry();
            let id = process(1);
            registry.pending_process(id);
            let reader = registry.open(Source::Process(id));
            registry.begin_frame(&snapshot(
                id,
                ProcessObservation::Unavailable(failure),
                registered,
            ));
            assert!(
                matches!(state(&registry, reader), CaptureState::Unavailable { reason, .. } if reason == expected)
            );
            assert!(control.commands().iter().any(|command| matches!(command,
                RecordedAudioCommand::ProcessStatus(_, ProcessCaptureStatus::Unavailable { reason, .. }) if *reason == expected)));
        }
    }
}

#[test]
fn process_end_overrides_unavailability_and_cannot_be_revived_by_later_events() {
    let (registry, control) = registry();
    let id = process(1);
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    let reader = registry.open(Source::Process(id));
    let denied = ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied);
    registry.begin_frame(&snapshot(id, denied, Some(instance(1))));
    assert!(matches!(
        state(&registry, reader),
        CaptureState::Unavailable {
            reason: UnavailableReason::PermissionDenied,
            ..
        }
    ));
    registry.event(&Event::ProcessExited {
        process: id,
        outcome: ProcessOutcome::Exited { code: 0 },
    });
    registry.begin_frame(&snapshot(id, denied, Some(instance(1))));
    assert_eq!(state(&registry, reader), CaptureState::Ended);
    registry.event(&Event::ProcessObservationChanged {
        process: id,
        observation: denied,
    });
    registry.event(&Event::ProcessObservationChanged {
        process: id,
        observation: live(1),
    });
    registry.pending_process(id);
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    assert_eq!(state(&registry, reader), CaptureState::Ended);
    assert_eq!(
        control
            .commands()
            .iter()
            .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
            .count(),
        1
    );
}

#[test]
fn exhausted_frame_generation_retains_the_last_immutable_publication() {
    let (registry, control) = registry();
    let reader = registry.open(Source::System);
    registry.state.borrow_mut().frame_generation = u64::MAX - 1;
    registry.begin_frame(&Snapshot::default());
    let retained = registry.snapshot(reader).expect("last publication");
    assert_eq!(retained.frame_generation, u64::MAX);
    control.push_event(AudioBackendEvent::State {
        capture: starts(&control)[0].0,
        generation: PipeWireGeneration(1),
        state: CaptureState::Idle,
    });
    for _ in 0..2 {
        registry.begin_frame(&Snapshot::default());
        let frozen = registry.snapshot(reader).expect("retained publication");
        assert!(Arc::ptr_eq(&retained, &frozen));
        assert_eq!(frozen.state, CaptureState::Starting);
        assert_eq!(frozen.frame_generation, u64::MAX);
    }
}

#[test]
fn reader_identifier_exhaustion_panics_before_inserting_a_colliding_reader() {
    let registry = NoAudioRegistry::default();
    let reader = registry.open(Source::System);
    let retained = registry.snapshot(reader).expect("reader");
    registry.0.state.borrow_mut().next_id = u64::MAX;
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        registry.open(Source::System)
    }));
    assert!(result.is_err());
    assert_eq!(registry.0.state.borrow().readers.len(), 1);
    assert!(Arc::ptr_eq(
        &retained,
        &registry.snapshot(reader).expect("original reader")
    ));
}

#[test]
fn temporary_inspection_denial_can_recover_only_the_registered_instance() {
    let (registry, control) = registry();
    let id = process(1);
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    let reader = registry.open(Source::Process(id));
    registry.begin_frame(&snapshot(
        id,
        ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied),
        Some(instance(1)),
    ));
    assert!(matches!(
        state(&registry, reader),
        CaptureState::Unavailable { .. }
    ));
    control.push_event(AudioBackendEvent::State {
        capture: starts(&control)[0].0,
        generation: PipeWireGeneration(1),
        state: CaptureState::Idle,
    });
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    assert_eq!(state(&registry, reader), CaptureState::Idle);
    assert_eq!(starts(&control).len(), 1);
    registry.begin_frame(&snapshot(id, live(2), Some(instance(2))));
    assert_eq!(state(&registry, reader), CaptureState::Ended);
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    assert_eq!(state(&registry, reader), CaptureState::Ended);
    assert_eq!(
        control
            .commands()
            .iter()
            .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
            .count(),
        1
    );
}

#[test]
fn shared_readers_use_one_stream_and_one_immutable_frame_publication() {
    let (registry, control) = registry();
    let first = registry.open(Source::System);
    let second = registry.open(Source::System);
    assert_eq!(starts(&control).len(), 1);
    let capture = starts(&control)[0].0;
    let (mut producer, consumer) = audio_transport(PipeWireGeneration(1));
    control.push_event(AudioBackendEvent::Transport {
        capture,
        generation: PipeWireGeneration(1),
        consumer,
    });
    control.push_event(AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(1),
        state: CaptureState::Active { provenance: None },
    });
    assert_eq!(
        producer.push(PcmPacket {
            bytes: &[0; 8],
            offset: 0,
            size: 8,
            stride: 8,
            format: Some(AudioFormat::STEREO_F32_48K),
        }),
        PacketResult::Accepted
    );
    registry.begin_frame(&Snapshot::default());
    let retained = registry.snapshot(first).expect("publication");
    assert!(Arc::ptr_eq(
        &retained,
        &registry.snapshot(second).expect("same publication")
    ));
    assert_eq!(retained.blocks.len(), 1);
    let third = registry.open(Source::System);
    assert!(Arc::ptr_eq(
        &retained,
        &registry.snapshot(first).expect("unchanged frame")
    ));
    assert!(Arc::ptr_eq(
        &retained,
        &registry.snapshot(third).expect("new shared reader")
    ));
    registry.close(third);
    registry.close(first);
    registry.close(first);
    assert!(
        control
            .commands()
            .iter()
            .all(|command| !matches!(command, RecordedAudioCommand::Stop(_)))
    );
    registry.begin_frame(&Snapshot::default());
    assert_eq!(retained.blocks.len(), 1);
    assert!(
        registry
            .snapshot(second)
            .expect("next frame")
            .blocks
            .is_empty()
    );
    registry.close(second);
    assert_eq!(
        control
            .commands()
            .iter()
            .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
            .count(),
        1
    );
    assert!(registry.snapshot(second).is_none());
}

#[test]
fn open_failure_is_not_retried_and_does_not_change_an_unrelated_source() {
    let (registry, control) = registry();
    let system = registry.open(Source::System);
    let id = process(1);
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    control.fail_next_start(AudioError::CommandQueueFull);
    let failed = registry.open(Source::Process(id));
    for _ in 0..3 {
        registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    }
    assert!(matches!(
        state(&registry, failed),
        CaptureState::Unavailable { .. }
    ));
    assert_eq!(state(&registry, system), CaptureState::Starting);
    assert_eq!(starts(&control).len(), 1);
    registry.close(failed);
    registry.open(Source::Process(id));
    assert_eq!(starts(&control).len(), 2);
}

#[test]
fn source_limit_counts_shared_streams_and_capacity_failure_remains_terminal() {
    let (registry, control) = registry();
    let processes: Vec<_> = (1..=8)
        .map(|id| ProcessSnapshot {
            process: process(id),
            pid: Some(instance(id).pid()),
            instance: Some(instance(id)),
            observation: live(id),
            alive: true,
            external: true,
        })
        .collect();
    registry.begin_frame(&Snapshot {
        processes,
        ..Snapshot::default()
    });
    let readers: Vec<_> = (1..=8)
        .map(|id| registry.open(Source::Process(process(id))))
        .collect();
    registry.open(Source::Process(process(1)));
    assert_eq!(starts(&control).len(), 8);
    let refused = registry.open(Source::System);
    assert!(matches!(
        state(&registry, refused),
        CaptureState::Unavailable {
            reason: UnavailableReason::CapacityExceeded,
            ..
        }
    ));
    registry.close(readers[1]);
    registry.begin_frame(&Snapshot::default());
    assert!(matches!(
        state(&registry, refused),
        CaptureState::Unavailable {
            reason: UnavailableReason::CapacityExceeded,
            ..
        }
    ));
    registry.close(refused);
    let reopened = registry.open(Source::System);
    assert_eq!(state(&registry, reopened), CaptureState::Starting);
}

#[test]
fn process_exit_discards_pcm_without_stopping_the_system_source() {
    let (registry, control) = registry();
    let id = process(1);
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    let system = registry.open(Source::System);
    let reader = registry.open(Source::Process(id));
    let capture = starts(&control)
        .into_iter()
        .find_map(|(capture, source)| (source == Source::Process(id)).then_some(capture))
        .expect("process stream");
    let (mut producer, consumer) = audio_transport(PipeWireGeneration(1));
    control.push_event(AudioBackendEvent::Transport {
        capture,
        generation: PipeWireGeneration(1),
        consumer,
    });
    control.push_event(AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(1),
        state: CaptureState::Active { provenance: None },
    });
    registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
    assert_eq!(
        producer.push(PcmPacket {
            bytes: &[0; 8],
            offset: 0,
            size: 8,
            stride: 8,
            format: Some(AudioFormat::STEREO_F32_48K)
        }),
        PacketResult::Accepted
    );
    registry.event(&Event::ProcessExited {
        process: id,
        outcome: ProcessOutcome::Exited { code: 0 },
    });
    registry.begin_frame(&Snapshot::default());
    let ended = registry.snapshot(reader).expect("ended reader");
    assert_eq!(ended.state, CaptureState::Ended);
    assert!(ended.blocks.is_empty());
    assert_eq!(state(&registry, system), CaptureState::Starting);
    assert_eq!(
        control
            .commands()
            .iter()
            .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
            .count(),
        1
    );
}

#[test]
fn no_backend_is_explicitly_unavailable_and_unknown_processes_are_ended() {
    let registry = NoAudioRegistry::default();
    let system = registry.open(Source::System);
    let unknown = registry.open(Source::Process(process(1)));
    registry.begin_frame(&Snapshot::default());
    assert!(matches!(
        state(&registry, system),
        CaptureState::Unavailable {
            reason: UnavailableReason::NoServer,
            ..
        }
    ));
    assert_eq!(state(&registry, unknown), CaptureState::Ended);
    registry.close(system);
    assert!(registry.snapshot(system).is_none());
    assert!(registry.take_requests().is_empty());
}

struct ControlledInspector {
    observed: mpsc::SyncSender<Pid>,
    answer: parking_lot::Mutex<mpsc::Receiver<ProcessObservation>>,
}
impl ProcessInspector for ControlledInspector {
    fn read_environment(&self, _: Pid, _: &str) -> io::Result<Option<Vec<u8>>> {
        panic!("not used")
    }
    fn observe(&self, pid: Pid) -> ProcessObservation {
        self.observed.send(pid).expect("test observes request");
        self.answer
            .lock()
            .recv()
            .expect("test releases observation")
    }
}

#[test]
fn candidate_inspection_and_reply_revalidation_never_block_the_frame() {
    let (backend, control) = RecordingAudioBackend::new();
    let (observed, observations) = mpsc::sync_channel(1);
    let (answer, answers) = mpsc::channel();
    let registry = NativeAudioRegistry::new(
        AudioService::new(Box::new(backend), SourceLimits::default()),
        Box::new(ControlledInspector {
            observed,
            answer: parking_lot::Mutex::new(answers),
        }),
    )
    .expect("observer starts");
    let id = process(1);
    let source = snapshot(id, live(1), Some(instance(1)));
    registry.begin_frame(&source);
    let candidate = lunette_capture::audio::AudioProcessCandidate {
        generation: PipeWireGeneration(1),
        node: AudioNodeSerial(9),
        pid: instance(1).pid(),
        assertion: PidAssertion {
            node: NodeIdentity {
                generation: PipeWireGeneration(1),
                serial: AudioNodeSerial(9),
                global: 9,
            },
            client: None,
            pid: instance(1).pid(),
            provenance: AttributionProvenance::ApplicationMetadata,
        },
    };
    control.push_candidate(candidate);
    registry.begin_frame(&source);
    observations
        .recv_timeout(Duration::from_secs(2))
        .expect("worker inspects candidate");
    // The worker cannot answer until the test releases it. This frame must still return.
    registry.begin_frame(&source);
    answer.send(live(1)).expect("candidate reply");
    poll_until(|| {
        registry.begin_frame(&source);
        control
            .commands()
            .iter()
            .any(|command| matches!(command, RecordedAudioCommand::Observation(_, _)))
    });
    let reply = AudioAttributionReply {
        request: AudioAttributionRequest {
            request: AudioAttributionRequestId(1),
            generation: candidate.generation,
            node: candidate.node,
            candidate: instance(1),
        },
        process: Some(id),
    };
    registry.event(&Event::AudioProcessResolved(reply));
    observations
        .recv_timeout(Duration::from_secs(2))
        .expect("worker revalidates reply");
    registry.event(&Event::ProcessExited {
        process: id,
        outcome: ProcessOutcome::Exited { code: 0 },
    });
    answer.send(live(1)).expect("revalidated candidate");
    poll_until(|| {
        registry.begin_frame(&source);
        control
            .commands()
            .iter()
            .any(|command| matches!(command, RecordedAudioCommand::Reply(_)))
    });
    assert!(control.commands().iter().any(
        |command| matches!(command, RecordedAudioCommand::Reply(reply) if reply.process.is_none())
    ));
}

#[test]
fn attribution_reply_accepts_the_same_live_candidate_and_root() {
    let (registry, control) = registry();
    let id = process(1);
    let snapshot = snapshot(id, live(1), Some(instance(1)));
    registry.begin_frame(&snapshot);
    let reply = AudioAttributionReply {
        request: AudioAttributionRequest {
            request: AudioAttributionRequestId(1),
            generation: PipeWireGeneration(1),
            node: AudioNodeSerial(9),
            candidate: instance(1),
        },
        process: Some(id),
    };
    registry.event(&Event::AudioProcessResolved(reply));
    poll_until(|| {
        registry.begin_frame(&snapshot);
        control
            .commands()
            .iter()
            .any(|command| matches!(command, RecordedAudioCommand::Reply(_)))
    });
    assert!(
        control.commands().iter().any(
            |command| matches!(command, RecordedAudioCommand::Reply(actual) if *actual == reply)
        )
    );
}

#[test]
fn attribution_reply_rejects_replaced_candidates_and_inaccessible_roots() {
    for (root_observation, candidate_observation) in [
        (live(1), live(2)),
        (
            ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied),
            live(1),
        ),
    ] {
        let (backend, control) = RecordingAudioBackend::new();
        let registry = NativeAudioRegistry::new(
            AudioService::new(Box::new(backend), SourceLimits::default()),
            Box::new(Inspector(candidate_observation)),
        )
        .expect("observer starts");
        let id = process(1);
        registry.begin_frame(&snapshot(id, live(1), Some(instance(1))));
        registry.event(&Event::AudioProcessResolved(AudioAttributionReply {
            request: AudioAttributionRequest {
                request: AudioAttributionRequestId(1),
                generation: PipeWireGeneration(1),
                node: AudioNodeSerial(9),
                candidate: instance(1),
            },
            process: Some(id),
        }));
        poll_until(|| {
            registry.begin_frame(&snapshot(id, root_observation, Some(instance(1))));
            control
                .commands()
                .iter()
                .any(|command| matches!(command, RecordedAudioCommand::Reply(_)))
        });
        assert!(control.commands().iter().any(|command| matches!(command,
            RecordedAudioCommand::Reply(reply) if reply.process.is_none())));
    }
}

#[test]
fn dropping_registry_releases_each_shared_stream_once_and_shuts_down() {
    let (registry, control) = registry();
    registry.open(Source::System);
    registry.open(Source::System);
    drop(registry);
    assert_eq!(
        control
            .commands()
            .iter()
            .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
            .count(),
        1
    );
    assert_eq!(
        control
            .commands()
            .iter()
            .filter(|command| matches!(command, RecordedAudioCommand::Shutdown))
            .count(),
        1
    );
}

fn poll_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "audio worker condition did not arrive"
        );
        thread::yield_now();
    }
}
