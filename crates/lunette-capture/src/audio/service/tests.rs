use super::*;
use crate::audio::{
    AudioFormat, PacketResult, PcmPacket, RecordedAudioCommand, RecordingAudioBackend,
    RecordingAudioControl, UnavailableReason, audio_transport,
};

fn setup() -> (
    AudioService,
    RecordingAudioControl,
    AudioReaderId,
    CaptureId,
) {
    let (backend, control) = RecordingAudioBackend::new();
    let mut service = AudioService::new(Box::new(backend), SourceLimits::default());
    let reader = service
        .open(Source::System)
        .unwrap_or_else(|_| unreachable!());
    let capture = match control.commands()[0] {
        RecordedAudioCommand::Start(id, _) => id,
        _ => unreachable!(),
    };
    (service, control, reader, capture)
}
fn state(control: &RecordingAudioControl, capture: CaptureId, state: CaptureState) {
    control.push_event(AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(1),
        state,
    });
}
fn push(producer: &mut crate::audio::AudioProducer, value: f32) {
    let mut bytes = [0; 8];
    bytes[..4].copy_from_slice(&value.to_le_bytes());
    bytes[4..].copy_from_slice(&value.to_le_bytes());
    assert_eq!(
        producer.push(PcmPacket {
            bytes: &bytes,
            offset: 0,
            size: 8,
            stride: 8,
            format: Some(AudioFormat::STEREO_F32_48K)
        }),
        PacketResult::Accepted
    );
}

#[test]
fn every_inactive_state_discards_pcm_with_gap_and_same_epoch_recovery_never_replays() {
    for inactive in [
        CaptureState::Starting,
        CaptureState::Idle,
        CaptureState::Unavailable {
            reason: UnavailableReason::PermissionDenied,
            detail: "denied".into(),
        },
    ] {
        let (mut service, control, reader, capture) = setup();
        let (mut producer, consumer) = audio_transport(PipeWireGeneration(1));
        control.push_event(AudioBackendEvent::Transport {
            capture,
            generation: PipeWireGeneration(1),
            consumer,
        });
        state(&control, capture, CaptureState::Active { provenance: None });
        service.begin_frame();
        push(&mut producer, 1.0);
        state(&control, capture, inactive.clone());
        service.begin_frame();
        let publication = service.snapshot(reader).unwrap_or_else(|| unreachable!());
        assert_eq!(publication.state, inactive);
        assert!(publication.blocks.is_empty());
        assert_eq!(publication.loss.frames, 1);
        push(&mut producer, 2.0);
        service.begin_frame();
        assert!(
            service
                .snapshot(reader)
                .unwrap_or_else(|| unreachable!())
                .blocks
                .is_empty()
        );
        push(&mut producer, 3.0);
        state(&control, capture, CaptureState::Active { provenance: None });
        service.begin_frame();
        assert!(
            service
                .snapshot(reader)
                .unwrap_or_else(|| unreachable!())
                .blocks
                .is_empty(),
            "recovery transition discards pre-recovery packets"
        );
        push(&mut producer, 4.0);
        service.begin_frame();
        let publication = service.snapshot(reader).unwrap_or_else(|| unreachable!());
        assert_eq!(publication.blocks.len(), 1);
        assert_eq!(publication.blocks[0].samples.as_ref(), &[4.0, 4.0]);
        assert_eq!(publication.blocks[0].gap_frames, 3);
        assert_eq!(publication.loss.frames, 3);
    }
}
#[test]
fn replacement_transport_carries_discard_loss_and_old_epoch_cannot_override() {
    let (mut service, control, reader, capture) = setup();
    let (mut old, consumer) = audio_transport(PipeWireGeneration(1));
    control.push_event(AudioBackendEvent::Transport {
        capture,
        generation: PipeWireGeneration(1),
        consumer,
    });
    state(&control, capture, CaptureState::Active { provenance: None });
    service.begin_frame();
    push(&mut old, 1.0);
    let (mut current, consumer) = audio_transport(PipeWireGeneration(2));
    control.push_event(AudioBackendEvent::Transport {
        capture,
        generation: PipeWireGeneration(2),
        consumer,
    });
    control.push_event(AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(2),
        state: CaptureState::Active { provenance: None },
    });
    state(
        &control,
        capture,
        CaptureState::Unavailable {
            reason: UnavailableReason::NoServer,
            detail: "stale".into(),
        },
    );
    push(&mut current, 2.0);
    service.begin_frame();
    let publication = service.snapshot(reader).unwrap_or_else(|| unreachable!());
    assert_eq!(publication.connection_generation, PipeWireGeneration(2));
    assert_eq!(publication.blocks.len(), 1);
    assert_eq!(publication.blocks[0].samples.as_ref(), &[2.0, 2.0]);
    assert_eq!(publication.blocks[0].gap_frames, 1);
    assert_eq!(publication.loss.frames, 1);
}
#[test]
fn source_and_reader_identifiers_fail_before_reuse() {
    let (mut service, control, _, _) = setup();
    service.next_id = u64::MAX;
    assert_eq!(
        service.open(Source::System),
        Err(AudioError::IdentifierExhausted)
    );
    assert_eq!(control.commands().len(), 1);
}
#[test]
fn queued_active_reply_cannot_override_new_process_unavailability() {
    let (backend, control) = RecordingAudioBackend::new();
    let mut service = AudioService::new(Box::new(backend), SourceLimits::default());
    let process = crate::audio::tests_support::process();
    let reader = service
        .open(Source::Process(process))
        .unwrap_or_else(|_| unreachable!());
    let capture = match control.commands()[0] {
        RecordedAudioCommand::Start(id, _) => id,
        _ => unreachable!(),
    };
    service
        .set_process_status(process, ProcessCaptureStatus::Live)
        .unwrap_or_else(|_| unreachable!());
    let (mut producer, consumer) = audio_transport(PipeWireGeneration(1));
    control.push_event(AudioBackendEvent::Transport {
        capture,
        generation: PipeWireGeneration(1),
        consumer,
    });
    state(&control, capture, CaptureState::Active { provenance: None });
    service
        .set_process_status(
            process,
            ProcessCaptureStatus::Unavailable {
                reason: UnavailableReason::PermissionDenied,
                detail: "new denied observation".into(),
            },
        )
        .unwrap_or_else(|_| unreachable!());
    push(&mut producer, 1.0);
    service.begin_frame();
    let publication = service.snapshot(reader).unwrap_or_else(|| unreachable!());
    assert!(matches!(
        publication.state,
        CaptureState::Unavailable {
            reason: UnavailableReason::PermissionDenied,
            ..
        }
    ));
    assert!(publication.blocks.is_empty());
    assert_eq!(publication.loss.frames, 1);
    service
        .set_process_status(process, ProcessCaptureStatus::Live)
        .unwrap_or_else(|_| unreachable!());
    state(&control, capture, CaptureState::Active { provenance: None });
    service.begin_frame();
    push(&mut producer, 2.0);
    service.begin_frame();
    assert_eq!(
        service
            .snapshot(reader)
            .unwrap_or_else(|| unreachable!())
            .blocks[0]
            .samples
            .as_ref(),
        &[2.0, 2.0]
    );
}

#[test]
fn ended_source_ignores_same_and_newer_epoch_active_events() {
    let (mut service, control, reader, capture) = setup();
    state(&control, capture, CaptureState::Ended);
    service.begin_frame();
    control.push_event(AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(2),
        state: CaptureState::Active { provenance: None },
    });
    service.begin_frame();
    assert_eq!(
        service
            .snapshot(reader)
            .unwrap_or_else(|| unreachable!())
            .state,
        CaptureState::Ended
    );
}
