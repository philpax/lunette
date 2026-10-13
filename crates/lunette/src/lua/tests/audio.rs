//! Audio bindings through the real registry and a deterministic project-owned capture backend.

use std::{cell::RefCell, ops::Deref, rc::Rc, sync::Arc};

use lunette_capture::audio::{
    AttributionProvenance, AudioBackendEvent, AudioError, AudioFormat, AudioProducer, AudioService,
    CaptureId, CaptureState, PacketResult, PcmPacket, RecordedAudioCommand, RecordingAudioBackend,
    RecordingAudioControl, Source, SourceLimits, UnavailableReason, audio_transport,
};
use lunette_compositor::{
    protocol::{
        AudioAttributionRequest, Event, PipeWireGeneration, ProcessId, ProcessOutcome, Snapshot,
    },
    testing::FakeInspector,
};
use mlua::MultiValue;
use pretty_assertions::assert_eq;

use crate::{
    audio::{AudioCaptureId, AudioRegistry, AudioSnapshot, NativeAudioRegistry},
    control::{
        serialise::results,
        wire::{HandleId, HandleKind, Value as WireValue},
    },
    events::RecordingEventSink,
    host::NoHostSinks,
    layers::LayerPool,
    lua::{
        PoolRegistry, Process, Session,
        declarations::{Described, NullTexture, render},
        tests::{TestSession, error, layers::FakeLayers, lua, run, snapshot},
    },
    mirrors::NoMonitors,
};

#[test]
fn audio_sources_are_closed_descriptors() {
    let (session, registry, control) = audio_session();
    let lua = lua(&session);
    for (chunk, expected) in [
        ("lunette.openAudio(nil)", "source"),
        ("lunette.openAudio{}", "source kind"),
        (
            "lunette.openAudio(setmetatable({ kind = 'system' }, {}))",
            "without a metatable",
        ),
        (
            "lunette.openAudio(setmetatable({}, { __index = { kind = 'system' } }))",
            "without a metatable",
        ),
        (
            "lunette.openAudio{ kind = 'microphone' }",
            "not 'system' or 'process'",
        ),
        (
            "lunette.openAudio{ kind = 'system', process = 3 }",
            "takes only kind",
        ),
        (
            "lunette.openAudio{ kind = 'system', pid = 4242 }",
            "takes only kind",
        ),
        (
            "lunette.openAudio{ kind = 'system', [1] = true }",
            "takes only kind",
        ),
        ("lunette.openAudio{ kind = 'process' }", "Process handle"),
        (
            "lunette.openAudio{ kind = 'process', process = 4242 }",
            "Process handle",
        ),
        (
            "lunette.openAudio{ kind = 'process', process = {} }",
            "Process handle",
        ),
        (
            "lunette.openAudio{ kind = 'process', process = 3, pid = 4242 }",
            "takes only kind, process",
        ),
    ] {
        let message = error(&lua, chunk);
        assert!(
            message.contains(expected),
            "unexpected diagnostic: {message}"
        );
    }
    assert!(registry.readers.borrow().is_empty());
    assert!(control.commands().is_empty());
}

#[test]
fn audio_rejects_foreign_process_handles_even_when_their_ids_match() {
    let (session, registry, control) = audio_session();
    let (foreign, _, _) = audio_session();
    let lua = lua(&session);
    run::<()>(&lua, "process = lunette.spawn{ argv = { 'player' } }");
    let id = ProcessId::new(run(&lua, "return process.id")).expect("a process id");
    lua.globals()
        .set("foreign", Process::new(foreign.0, id))
        .expect("foreign handle");
    let message = error(
        &lua,
        "lunette.openAudio{ kind = 'process', process = foreign }",
    );
    assert!(message.contains("belongs to another session"), "{message}");
    assert!(registry.readers.borrow().is_empty());
    assert!(control.commands().is_empty());
}

#[test]
fn pending_audio_sources_remain_starting_and_preserve_fresh_process_handles() {
    let (session, registry, control) = audio_session();
    let lua = lua(&session);
    run::<()>(
        &lua,
        "process = lunette.spawn{ argv = { 'player' } }
        assert(process.dead)
        capture = lunette.openAudio{ kind = 'process', process = process }
        assert(not capture.dead and capture:snapshot().state.kind == 'starting')
        assert(capture:snapshot().source.process == process)
        assert(not rawequal(capture:snapshot().source.process, process))
        assert(not rawequal(capture:snapshot().source.process, capture:snapshot().source.process))",
    );
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(
        &lua,
        "assert(not capture.dead and capture:snapshot().state.kind == 'starting')",
    );
    assert_eq!(
        starts(&control),
        0,
        "a pending process opens no backend stream"
    );

    let process = ProcessId::new(run(&lua, "return process.id")).expect("a process id");
    registry.event(&Event::ProcessExited {
        process,
        outcome: ProcessOutcome::Exited { code: 0 },
    });
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(
        &lua,
        "local result = capture:snapshot()
        assert(capture.dead and result.state.kind == 'ended' and #result.blocks == 0)
        assert(result.source.kind == 'process' and result.source.process == process)
        assert(result.source.process.dead)
        local ended = lunette.openAudio{ kind = 'process', process = process }
        assert(ended.dead and ended:snapshot().state.kind == 'ended')
        capture:close()
        capture:close()",
    );
}

#[test]
fn snapshots_share_native_pcm_and_sample_copies_are_isolated() {
    let (session, registry, control) = audio_session();
    let lua = lua(&session);
    run::<()>(
        &lua,
        "first = lunette.openAudio{ kind = 'system' }
        second = lunette.openAudio{ kind = 'system' }
        assert(first.id ~= second.id and first ~= second)
        assert(not first.dead and first:snapshot().state.kind == 'starting')",
    );
    let capture = backend_capture(&control);
    assert_eq!(starts(&control), 1);
    let mut producer = transport(&control, capture, 7);
    push_samples(&mut producer, &[0.25, -0.5, 1.0, -1.0]);
    session.begin(snapshot(Vec::new(), Vec::new()));
    let reader = registry.readers.borrow()[0];
    let other = registry.readers.borrow()[1];
    let publication = registry.snapshot(reader).expect("a publication");
    assert!(Arc::ptr_eq(
        &publication,
        &registry.snapshot(other).expect("a shared publication")
    ));
    let samples = Arc::clone(&publication.blocks[0].samples);
    let before = Arc::strong_count(&samples);
    run::<()>(
        &lua,
        "a = first:snapshot()
        b = first:snapshot()
        c = second:snapshot()
        assert(a.frameGeneration == b.frameGeneration and b.frameGeneration == c.frameGeneration)
        assert(a.blocks[1] == b.blocks[1] and b.blocks[1] == c.blocks[1])
        assert(not rawequal(a.blocks[1], b.blocks[1]))
        block = a.blocks[1]
        assert(block.generation == 7 and block.frameCount == 2)
        assert(block.sampleRate == 48000 and block.channels == 2)
        assert(block.startFrame == 0 and block.timing == 'sample-frames')
        assert(not block.gap and block.droppedFrames == 0)
        x = block:copySamples()
        y = block:copySamples()
        assert(typeof(x) == 'buffer' and x ~= y and buffer.len(x) == 16)
        assert(buffer.readf32(x, 0) == 0.25 and buffer.readf32(x, 4) == -0.5)
        assert(buffer.readu8(x, 0) == 0 and buffer.readu8(x, 1) == 0)
        assert(buffer.readu8(x, 2) == 128 and buffer.readu8(x, 3) == 62)
        buffer.writef32(x, 0, 99)
        assert(buffer.readf32(y, 0) == 0.25)
        assert(buffer.readf32(c.blocks[1]:copySamples(), 0) == 0.25)",
    );
    assert_eq!(
        Arc::strong_count(&samples),
        before + 3,
        "snapshot wrappers share native samples"
    );
    assert_eq!(samples.as_ref(), [0.25, -0.5, 1.0, -1.0]);
    for chunk in [
        "a.frameGeneration = 0",
        "a.source.kind = 'process'",
        "a.state.kind = 'ended'",
        "a.blocks[1] = nil",
        "block.frameCount = 0",
        "block.samples = {}",
        "block.copySamples = nil",
    ] {
        error(&lua, chunk);
    }
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(
        &lua,
        "assert(#first:snapshot().blocks == 0)
        assert(first:snapshot().frameGeneration > a.frameGeneration)
        assert(buffer.readf32(block:copySamples(), 0) == 0.25)
        first:close()
        assert(first.dead and first:snapshot().state.kind == 'ended')
        assert(not second.dead)",
    );
    assert_eq!(stops(&control), 0);
    run::<()>(&lua, "second:close() second:close() assert(second.dead)");
    assert_eq!(stops(&control), 1);
}

#[test]
fn audio_capacity_refusal_returns_an_unavailable_reader_without_raising() {
    let (session, _, control) = audio_session();
    let lua = lua(&session);
    control.fail_next_start(AudioError::CapacityExceeded);
    run::<()>(
        &lua,
        "capture = lunette.openAudio{ kind = 'system' }
        local result = capture:snapshot()
        assert(not capture.dead and result.state.kind == 'unavailable')
        assert(result.state.reason == 'capacity-exceeded' and #result.state.detail > 0)
        assert(result.source.kind == 'system' and #result.blocks == 0)
        capture:close() capture:close()",
    );
    assert_eq!(starts(&control), 0);
    assert_eq!(stops(&control), 0);
}

#[test]
fn unavailable_idle_and_active_states_are_live_and_keep_their_variant_fields() {
    let (session, _, control) = audio_session();
    let lua = lua(&session);
    run::<()>(&lua, "capture = lunette.openAudio{ kind = 'system' }");
    let capture = backend_capture(&control);
    for (reason, name) in [
        (UnavailableReason::NoServer, "no-server"),
        (UnavailableReason::NoDefaultSink, "no-default-sink"),
        (
            UnavailableReason::InvalidDefaultSink,
            "invalid-default-sink",
        ),
        (UnavailableReason::PermissionDenied, "permission-denied"),
        (UnavailableReason::UnsupportedFormat, "unsupported-format"),
        (
            UnavailableReason::UnresolvedAttribution,
            "unresolved-attribution",
        ),
        (UnavailableReason::CapacityExceeded, "capacity-exceeded"),
        (UnavailableReason::GraphFailure, "graph-failure"),
    ] {
        state(
            &control,
            capture,
            7,
            CaptureState::Unavailable {
                reason,
                detail: "capture diagnostic".to_owned(),
            },
        );
        session.begin(snapshot(Vec::new(), Vec::new()));
        let observed: (bool, String, String, String) = run(
            &lua,
            "local s = capture:snapshot().state return capture.dead, s.kind, s.reason, s.detail",
        );
        assert_eq!(
            observed,
            (
                false,
                "unavailable".to_owned(),
                name.to_owned(),
                "capture diagnostic".to_owned()
            )
        );
    }
    state(&control, capture, 7, CaptureState::Idle);
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(
        &lua,
        "assert(not capture.dead and capture:snapshot().state.kind == 'idle')",
    );
    for (provenance, name) in [
        (None, None),
        (
            Some(AttributionProvenance::PipeWireClient),
            Some("pipewire-client"),
        ),
        (
            Some(AttributionProvenance::ApplicationMetadata),
            Some("application-metadata"),
        ),
    ] {
        state(&control, capture, 7, CaptureState::Active { provenance });
        session.begin(snapshot(Vec::new(), Vec::new()));
        let observed: (bool, String, Option<String>) = run(
            &lua,
            "local s = capture:snapshot().state return capture.dead, s.kind, s.provenance",
        );
        assert_eq!(
            observed,
            (false, "active".to_owned(), name.map(str::to_owned))
        );
    }
}

#[test]
fn stream_generation_changes_reset_sample_time_and_retained_blocks_remain_valid() {
    let (session, _, control) = audio_session();
    let lua = lua(&session);
    run::<()>(&lua, "capture = lunette.openAudio{ kind = 'system' }");
    let capture = backend_capture(&control);
    let mut old = transport(&control, capture, 3);
    push_samples(&mut old, &[0.5, -0.5]);
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(&lua, "kept = capture:snapshot().blocks[1]");
    push_samples(&mut old, &[0.75, -0.75]);
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(&lua, "local next = capture:snapshot().blocks[1]
        assert(next.generation == kept.generation and next.sequence > kept.sequence and next.startFrame == 1)");
    let mut new = transport(&control, capture, 4);
    push_samples(&mut new, &[0.125, -0.125]);
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(
        &lua,
        "local next = capture:snapshot().blocks[1]
        assert(next.generation == 4 and next.startFrame == 0)
        assert(kept.generation == 3 and buffer.readf32(kept:copySamples(), 0) == 0.5)",
    );
}

#[test]
fn audio_block_gaps_report_frames_lost_at_the_native_queue_boundary() {
    let (session, _, control) = audio_session();
    let lua = lua(&session);
    run::<()>(&lua, "capture = lunette.openAudio{ kind = 'system' }");
    let capture = backend_capture(&control);
    let mut producer = transport(&control, capture, 7);
    push_samples(&mut producer, &vec![0.0; 24_000]);
    assert_eq!(
        producer.push(PcmPacket {
            bytes: &[0; 16],
            offset: 0,
            size: 16,
            stride: 8,
            format: Some(AudioFormat::STEREO_F32_48K),
        }),
        PacketResult::Overrun
    );
    session.begin(snapshot(Vec::new(), Vec::new()));
    push_samples(&mut producer, &[0.25, -0.25]);
    session.begin(snapshot(Vec::new(), Vec::new()));
    run::<()>(
        &lua,
        "local block = capture:snapshot().blocks[1]
        assert(block.gap and block.droppedFrames == 2 and block.startFrame == 12002)",
    );
}

#[test]
fn actual_audio_userdata_serializes_reader_ids_but_refuses_pcm_and_buffers() {
    let (session, _, control) = audio_session();
    let lua = lua(&session);
    run::<()>(&lua, "capture = lunette.openAudio{ kind = 'system' }");
    let capture = backend_capture(&control);
    let mut producer = transport(&control, capture, 7);
    push_samples(&mut producer, &[0.5, -0.5]);
    session.begin(snapshot(Vec::new(), Vec::new()));
    let converted =
        results(run::<MultiValue>(&lua, "return capture")).expect("a capture has a wire identity");
    let WireValue::Handle(handle) = &converted[0] else {
        panic!("expected a reader handle")
    };
    assert_eq!(handle.kind, HandleKind::AudioCapture);
    assert_eq!(
        handle.id,
        Some(HandleId::Number(run(&lua, "return capture.id")))
    );
    for chunk in [
        "return capture:snapshot().blocks[1]",
        "return capture:snapshot().blocks[1]:copySamples()",
    ] {
        let message = results(run::<MultiValue>(&lua, chunk))
            .expect_err("PCM has no wire representation")
            .to_string();
        assert!(
            message.contains("result 1"),
            "the diagnostic names its path: {message}"
        );
    }
}

#[test]
fn missing_readers_return_ended_readonly_snapshots_with_the_original_source() {
    let (session, registry, _) = audio_session();
    let lua = lua(&session);
    run::<()>(&lua, "capture = lunette.openAudio{ kind = 'system' }");
    registry.native.close(registry.readers.borrow()[0]);
    run::<()>(
        &lua,
        "local result = capture:snapshot()
        assert(capture.dead and result.source.kind == 'system')
        assert(result.state.kind == 'ended' and #result.blocks == 0)
        assert(not pcall(function() result.source.kind = 'process' end))
        assert(not pcall(function() result.blocks[1] = {} end))
        capture:close() capture:close()",
    );
}

#[test]
fn collecting_an_audio_handle_does_not_release_its_reader() {
    let (session, registry, control) = audio_session();
    let lua = lua(&session);
    run::<()>(
        &lua,
        "local capture = lunette.openAudio{ kind = 'system' } assert(not capture.dead)",
    );
    lua.gc_collect().expect("collect discarded userdata");
    assert!(registry.snapshot(registry.readers.borrow()[0]).is_some());
    assert_eq!(stops(&control), 0);
    registry.close(registry.readers.borrow()[0]);
    assert_eq!(stops(&control), 1);
}

#[test]
fn audio_declarations_include_closed_readonly_unions_and_buffer_copies() {
    let declarations = render();
    for expected in [
        "export type AudioSource = { read kind: 'system' } | { read kind: 'process', read process: Process }",
        "export type AudioState = { read kind: 'starting' } | { read kind: 'active', read provenance:",
        "read blocks: { read [number]: AudioBlock }",
        "export type AudioCapture = {",
        "read snapshot: (self: AudioCapture) -> AudioSnapshot",
        "read openAudio: (source: AudioSource) -> AudioCapture",
        "read copySamples: (self: AudioBlock) -> buffer",
        "read timing: 'sample-frames'",
    ] {
        assert!(
            declarations.contains(expected),
            "missing declaration: {expected}"
        );
    }
    assert_eq!(<crate::lua::audio::AudioBlock as Described>::KIND, None);
    assert!(<crate::lua::audio::AudioCapture<NullTexture> as Described>::KIND.is_some());
}

struct AudioTestSession(TestSession);

impl AudioTestSession {
    fn begin(&self, snapshot: Arc<Snapshot>) {
        self.0.begin(Arc::clone(&snapshot));
        self.0.audio().begin_frame(snapshot.as_ref());
    }
}

impl Deref for AudioTestSession {
    type Target = TestSession;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

fn audio_session() -> (
    AudioTestSession,
    Rc<RecordingRegistry>,
    RecordingAudioControl,
) {
    let (backend, control) = RecordingAudioBackend::new();
    let registry = Rc::new(RecordingRegistry {
        native: NativeAudioRegistry::new(
            AudioService::new(Box::new(backend), SourceLimits::default()),
            Box::new(FakeInspector::default()),
        )
        .expect("the observation worker starts"),
        readers: RefCell::new(Vec::new()),
    });
    let session = Session::new_with_audio(
        Box::new(RecordingEventSink::default()),
        Rc::new(PoolRegistry::new(LayerPool::new(FakeLayers::new(128)))),
        Rc::new(NoMonitors),
        Rc::new(NoHostSinks),
        Rc::clone(&registry) as Rc<_>,
    );
    let session = AudioTestSession(session);
    session.begin(snapshot(Vec::new(), Vec::new()));
    (session, registry, control)
}

#[derive(Debug)]
struct RecordingRegistry {
    native: NativeAudioRegistry,
    readers: RefCell<Vec<AudioCaptureId>>,
}

impl AudioRegistry for RecordingRegistry {
    fn pending_process(&self, process: ProcessId) {
        self.native.pending_process(process);
    }
    fn event(&self, event: &Event) {
        self.native.event(event);
    }
    fn begin_frame(&self, snapshot: &Snapshot) {
        self.native.begin_frame(snapshot);
    }
    fn take_requests(&self) -> Vec<AudioAttributionRequest> {
        self.native.take_requests()
    }
    fn open(&self, source: Source) -> AudioCaptureId {
        let id = self.native.open(source);
        self.readers.borrow_mut().push(id);
        id
    }
    fn close(&self, id: AudioCaptureId) {
        self.native.close(id);
    }
    fn snapshot(&self, id: AudioCaptureId) -> Option<Arc<AudioSnapshot>> {
        self.native.snapshot(id)
    }
}

fn starts(control: &RecordingAudioControl) -> usize {
    control
        .commands()
        .iter()
        .filter(|command| matches!(command, RecordedAudioCommand::Start(_, _)))
        .count()
}

fn stops(control: &RecordingAudioControl) -> usize {
    control
        .commands()
        .iter()
        .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
        .count()
}

fn backend_capture(control: &RecordingAudioControl) -> CaptureId {
    control
        .commands()
        .into_iter()
        .find_map(|command| match command {
            RecordedAudioCommand::Start(capture, _) => Some(capture),
            _ => None,
        })
        .expect("an opened backend stream")
}

fn transport(
    control: &RecordingAudioControl,
    capture: CaptureId,
    generation: u64,
) -> AudioProducer {
    let (producer, consumer) = audio_transport(PipeWireGeneration(generation));
    control.push_event(AudioBackendEvent::Transport {
        capture,
        generation: PipeWireGeneration(generation),
        consumer,
    });
    state(
        control,
        capture,
        generation,
        CaptureState::Active { provenance: None },
    );
    producer
}

fn state(
    control: &RecordingAudioControl,
    capture: CaptureId,
    generation: u64,
    state: CaptureState,
) {
    control.push_event(AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(generation),
        state,
    });
}

fn push_samples(producer: &mut AudioProducer, samples: &[f32]) {
    let bytes: Vec<u8> = samples
        .iter()
        .flat_map(|sample| sample.to_le_bytes())
        .collect();
    assert_eq!(
        producer.push(PcmPacket {
            bytes: &bytes,
            offset: 0,
            size: bytes.len(),
            stride: 8,
            format: Some(AudioFormat::STEREO_F32_48K)
        }),
        PacketResult::Accepted
    );
}
