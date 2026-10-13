use super::*;
use crate::audio::{RecordedGraphOperation as Op, RecordingGraphOps, tests_support::*};

fn driver() -> GraphDriver {
    GraphDriver::new("test".into(), Duration::from_millis(10))
}
fn monitor(object: u64, capture: u64, target: u32, epoch: u64) -> Op {
    Op::CreateMonitor {
        object: GraphObjectId(object),
        capture: CaptureId(capture),
        target: identity(target),
        epoch: PipeWireGeneration(epoch),
    }
}
fn link(object: u64, output: u32, input: u32) -> Op {
    Op::CreateLink {
        object: GraphObjectId(object),
        mixer: identity(90),
        link: AdditiveLink {
            output_node: identity(output / 10),
            output_port: crate::audio::PortIdentity {
                global: output,
                serial: u64::from(output) + 2000,
            },
            input_port: crate::audio::PortIdentity {
                global: input,
                serial: u64::from(input) + 2000,
            },
        },
    }
}
fn untouched(ops: &RecordingGraphOps) {
    assert_eq!(
        ops.host_links,
        BTreeSet::from([(200, 100), (201, 101), (210, 100)])
    );
}
fn ops(snapshot: RegistrySnapshot) -> RecordingGraphOps {
    let mut ops = RecordingGraphOps::new(snapshot);
    ops.host_links = BTreeSet::from([(200, 100), (201, 101), (210, 100)]);
    ops
}
#[test]
fn system_monitor_graph_changes() {
    let mut ops = ops(system());
    let mut driver = driver();
    driver.start(CaptureId(1), Source::System);
    driver.tick(Duration::ZERO, &mut ops);
    ops.snapshot.default_sink = crate::audio::DefaultSink::Name("headphones".into());
    driver.tick(Duration::from_millis(1), &mut ops);
    if let Some(node) = ops.snapshot.nodes.get_mut(&11) {
        node.identity.serial.0 += 1;
    }
    driver.tick(Duration::from_millis(2), &mut ops);
    let replacement = ops.snapshot.nodes[&11].identity;
    ops.snapshot.default_sink = crate::audio::DefaultSink::Missing;
    driver.tick(Duration::from_millis(3), &mut ops);
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(PipeWireGeneration(1)),
            monitor(1, 1, 10, 1),
            Op::Remove(GraphObjectId(1)),
            monitor(2, 1, 11, 2),
            Op::Remove(GraphObjectId(2)),
            Op::CreateMonitor {
                object: GraphObjectId(3),
                capture: CaptureId(1),
                target: replacement,
                epoch: PipeWireGeneration(3)
            },
            Op::Remove(GraphObjectId(3))
        ]
    );
    untouched(&ops);
}
#[test]
fn process_monitor_additive_links() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL", "FR"]);
    playback(&mut snapshot, 21, &["MONO"]);
    mixer(&mut snapshot);
    let mut ops = ops(snapshot);
    let mut driver = driver();
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    driver.tick(Duration::ZERO, &mut ops);
    attribute(&mut driver.registry, 20);
    attribute(&mut driver.registry, 21);
    driver.tick(Duration::from_millis(1), &mut ops);
    ops.snapshot.ports.remove(&201);
    driver.tick(Duration::from_millis(2), &mut ops);
    port(&mut ops.snapshot, 205, 20, true, "FR");
    driver.tick(Duration::from_millis(3), &mut ops);
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(PipeWireGeneration(1)),
            Op::CreateAdapter {
                object: GraphObjectId(1),
                name: "test.mixer.1".into()
            },
            monitor(2, 1, 90, 1),
            link(3, 200, 901),
            link(4, 201, 902),
            link(5, 210, 901),
            link(6, 210, 902),
            Op::Remove(GraphObjectId(4)),
            link(7, 205, 902)
        ]
    );
    untouched(&ops);
}
#[test]
fn capture_graph_teardown() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL", "FR"]);
    mixer(&mut snapshot);
    let mut ops = ops(snapshot);
    let mut driver = driver();
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    driver.tick(Duration::ZERO, &mut ops);
    attribute(&mut driver.registry, 20);
    driver.tick(Duration::from_millis(1), &mut ops);
    driver.stop(CaptureId(1), &mut ops);
    driver.shutdown(&mut ops);
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(PipeWireGeneration(1)),
            Op::CreateAdapter {
                object: GraphObjectId(1),
                name: "test.mixer.1".into()
            },
            monitor(2, 1, 90, 1),
            link(3, 200, 901),
            link(4, 201, 902),
            Op::Remove(GraphObjectId(3)),
            Op::Remove(GraphObjectId(4)),
            Op::Remove(GraphObjectId(2)),
            Op::Remove(GraphObjectId(1)),
            Op::Disconnect
        ]
    );
    untouched(&ops);
}
#[test]
fn no_server_reconnect_and_stream_error_recover_with_fresh_generations() {
    let mut ops = ops(system());
    let mut driver = driver();
    driver.start(CaptureId(1), Source::System);
    ops.connect_results.push_back(Err(GraphFailure {
        reason: UnavailableReason::NoServer,
        detail: "scripted no server".into(),
    }));
    let events = driver.tick(Duration::ZERO, &mut ops);
    assert!(events.iter().any(|event| matches!(
        event,
        AudioBackendEvent::State {
            state: CaptureState::Unavailable {
                reason: UnavailableReason::NoServer,
                ..
            },
            ..
        }
    )));
    driver.tick(Duration::from_millis(9), &mut ops);
    assert_eq!(ops.operations.len(), 1);
    driver.tick(Duration::from_millis(10), &mut ops);
    ops.object_states.insert(
        GraphObjectId(1),
        GraphObjectState::Unavailable {
            reason: UnavailableReason::UnsupportedFormat,
            detail: "profile changed".into(),
        },
    );
    driver.tick(Duration::from_millis(11), &mut ops);
    driver.tick(Duration::from_millis(20), &mut ops);
    driver.tick(Duration::from_millis(21), &mut ops);
    ops.observation_errors.push_back(GraphFailure {
        reason: UnavailableReason::NoServer,
        detail: "connection lost".into(),
    });
    driver.tick(Duration::from_millis(22), &mut ops);
    driver.tick(Duration::from_millis(32), &mut ops);
    let target2 = NodeIdentity {
        generation: PipeWireGeneration(2),
        ..identity(10)
    };
    let target3 = NodeIdentity {
        generation: PipeWireGeneration(3),
        ..identity(10)
    };
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(PipeWireGeneration(1)),
            Op::Connect(PipeWireGeneration(2)),
            Op::CreateMonitor {
                object: GraphObjectId(1),
                capture: CaptureId(1),
                target: target2,
                epoch: PipeWireGeneration(2)
            },
            Op::Remove(GraphObjectId(1)),
            Op::CreateMonitor {
                object: GraphObjectId(2),
                capture: CaptureId(1),
                target: target2,
                epoch: PipeWireGeneration(3)
            },
            Op::Remove(GraphObjectId(2)),
            Op::Disconnect,
            Op::Connect(PipeWireGeneration(3)),
            Op::CreateMonitor {
                object: GraphObjectId(3),
                capture: CaptureId(1),
                target: target3,
                epoch: PipeWireGeneration(5)
            }
        ]
    );
    untouched(&ops);
}
#[test]
fn multiple_sources_keep_their_own_monitor_epoch_in_service_publications() {
    use crate::audio::{
        AudioFormat, AudioService, PcmPacket, RecordedAudioCommand, RecordingAudioBackend,
        SourceLimits, audio_transport,
    };
    let (backend, control) = RecordingAudioBackend::new();
    let mut service = AudioService::new(Box::new(backend), SourceLimits::default());
    let first = service
        .open(Source::System)
        .unwrap_or_else(|_| unreachable!());
    let second = service
        .open(Source::Process(process()))
        .unwrap_or_else(|_| unreachable!());
    let captures: Vec<_> = control
        .commands()
        .iter()
        .filter_map(|command| match command {
            RecordedAudioCommand::Start(capture, _) => Some(*capture),
            _ => None,
        })
        .collect();
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    let name = format!("test.mixer.{}", captures[1].0);
    mixer(&mut snapshot);
    snapshot
        .nodes
        .get_mut(&90)
        .unwrap_or_else(|| unreachable!())
        .name = name;
    let mut ops = ops(snapshot);
    let mut driver = driver();
    driver.start(captures[0], Source::System);
    driver.start(captures[1], Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    let mut events = driver.tick(Duration::ZERO, &mut ops);
    attribute(&mut driver.registry, 20);
    events.extend(driver.tick(Duration::from_millis(1), &mut ops));
    let epochs: Vec<_> = ops
        .operations
        .iter()
        .filter_map(|operation| match operation {
            Op::CreateMonitor { capture, epoch, .. } => Some((*capture, *epoch)),
            _ => None,
        })
        .collect();
    assert_eq!(
        epochs,
        vec![
            (captures[0], PipeWireGeneration(1)),
            (captures[1], PipeWireGeneration(2))
        ]
    );
    let mut producers = Vec::new();
    for (capture, epoch) in &epochs {
        let (producer, consumer) = audio_transport(*epoch);
        producers.push(producer);
        control.push_event(AudioBackendEvent::Transport {
            capture: *capture,
            generation: *epoch,
            consumer,
        });
    }
    for event in events {
        control.push_event(event);
    }
    service.begin_frame();
    // Starting/active events for source 1 after source 2 opens must still use epoch 1.
    ops.object_states
        .insert(GraphObjectId(1), GraphObjectState::Starting);
    for event in driver.tick(Duration::from_millis(2), &mut ops) {
        control.push_event(event);
    }
    service.begin_frame();
    ops.object_states
        .insert(GraphObjectId(1), GraphObjectState::Streaming);
    for event in driver.tick(Duration::from_millis(3), &mut ops) {
        control.push_event(event);
    }
    service.begin_frame();
    for producer in &mut producers {
        assert_eq!(
            producer.push(PcmPacket {
                bytes: &[0; 8],
                offset: 0,
                size: 8,
                stride: 8,
                format: Some(AudioFormat::STEREO_F32_48K)
            }),
            crate::audio::PacketResult::Accepted
        );
    }
    service.begin_frame();
    let one = service.snapshot(first).unwrap_or_else(|| unreachable!());
    let two = service.snapshot(second).unwrap_or_else(|| unreachable!());
    assert_eq!(one.connection_generation, PipeWireGeneration(1));
    assert_eq!(two.connection_generation, PipeWireGeneration(2));
    assert_eq!(one.blocks.len(), 1);
    assert_eq!(two.blocks.len(), 1);
}

#[test]
fn mixer_replacement_recreates_links_and_unnegotiated_objects_stay_starting() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    mixer(&mut snapshot);
    let mut ops = ops(snapshot);
    let mut driver = driver();
    driver.start(CaptureId(1), Source::Process(process()));
    driver.process_status(process(), ProcessCaptureStatus::Live);
    driver.tick(Duration::ZERO, &mut ops);
    attribute(&mut driver.registry, 20);
    ops.initial_state = GraphObjectState::Starting;
    let events = driver.tick(Duration::from_millis(1), &mut ops);
    assert!(events.iter().any(|event| matches!(
        event,
        AudioBackendEvent::State {
            state: CaptureState::Starting,
            ..
        }
    )));
    ops.object_states
        .insert(GraphObjectId(2), GraphObjectState::Streaming);
    ops.object_states
        .insert(GraphObjectId(3), GraphObjectState::Streaming);
    driver.tick(Duration::from_millis(2), &mut ops);
    ops.snapshot
        .nodes
        .get_mut(&90)
        .unwrap_or_else(|| unreachable!())
        .identity
        .serial
        .0 += 1;
    ops.initial_state = GraphObjectState::Streaming;
    driver.tick(Duration::from_millis(3), &mut ops);
    let mixer = ops.snapshot.nodes[&90].identity;
    let expected_link = AdditiveLink {
        output_node: identity(20),
        output_port: crate::audio::PortIdentity {
            global: 200,
            serial: 2200,
        },
        input_port: crate::audio::PortIdentity {
            global: 901,
            serial: 2901,
        },
    };
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(PipeWireGeneration(1)),
            Op::CreateAdapter {
                object: GraphObjectId(1),
                name: "test.mixer.1".into()
            },
            monitor(2, 1, 90, 1),
            link(3, 200, 901),
            Op::Remove(GraphObjectId(3)),
            Op::Remove(GraphObjectId(2)),
            Op::CreateMonitor {
                object: GraphObjectId(4),
                capture: CaptureId(1),
                target: mixer,
                epoch: PipeWireGeneration(2)
            },
            Op::CreateLink {
                object: GraphObjectId(5),
                mixer,
                link: expected_link
            }
        ]
    );
    untouched(&ops);
}

#[test]
fn driver_generation_exhaustion_never_reuses_identity() {
    let mut ops = ops(system());
    let mut driver = driver();
    driver.start(CaptureId(1), Source::System);
    driver.next_generation = u64::MAX;
    let events = driver.tick(Duration::ZERO, &mut ops);
    assert!(ops.operations.is_empty());
    assert!(driver.exhausted);
    assert!(events.iter().any(|event| matches!(
        event,
        AudioBackendEvent::State {
            state: CaptureState::Unavailable {
                reason: UnavailableReason::GraphFailure,
                ..
            },
            ..
        }
    )));
    driver.tick(Duration::from_millis(20), &mut ops);
    assert!(ops.operations.is_empty());
    let mut driver = super::GraphDriver::new("test".into(), Duration::from_millis(10));
    driver.start(CaptureId(1), Source::System);
    driver.epoch = u64::MAX;
    let events = driver.tick(Duration::ZERO, &mut ops);
    assert_eq!(ops.operations, vec![Op::Connect(PipeWireGeneration(1))]);
    assert!(events.iter().any(|event| matches!(
        event,
        AudioBackendEvent::State {
            state: CaptureState::Unavailable {
                reason: UnavailableReason::GraphFailure,
                ..
            },
            ..
        }
    )));
}

#[test]
fn process_lifecycle_gates_graph_and_ended_is_terminal() {
    let mut ops = ops(system());
    let mut driver = driver();
    driver.start(CaptureId(1), Source::Process(process()));
    driver.tick(Duration::ZERO, &mut ops);
    assert!(ops.operations.is_empty());
    driver.process_status(process(), ProcessCaptureStatus::Live);
    driver.tick(Duration::from_millis(1), &mut ops);
    driver.process_status(process(), ProcessCaptureStatus::Ended);
    driver.tick(Duration::from_millis(2), &mut ops);
    driver.process_status(process(), ProcessCaptureStatus::Live);
    driver.tick(Duration::from_millis(3), &mut ops);
    assert_eq!(
        ops.operations,
        vec![
            Op::Connect(PipeWireGeneration(1)),
            Op::CreateAdapter {
                object: GraphObjectId(1),
                name: "test.mixer.1".into()
            },
            Op::Remove(GraphObjectId(1)),
            Op::Disconnect
        ]
    );
}
