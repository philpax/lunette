//! Scripted project backend and recorded ownership commands for hardware-free tests.

use std::{collections::VecDeque, sync::Arc};

use lunette_compositor::protocol::{
    AudioAttributionReply, AudioAttributionRequest, ProcessObservation,
};
use parking_lot::Mutex;

use crate::audio::{
    AudioBackend, AudioBackendEvent, AudioError, AudioProcessCandidate, CaptureId, Source,
};

#[derive(Clone, Debug)]
pub enum RecordedAudioCommand {
    Start(CaptureId, Source),
    Stop(CaptureId),
    Observation(AudioProcessCandidate, ProcessObservation),
    Reply(AudioAttributionReply),
    ProcessStatus(
        lunette_compositor::protocol::ProcessId,
        crate::audio::ProcessCaptureStatus,
    ),
    Shutdown,
}

#[derive(Clone, Default)]
pub struct RecordingAudioControl {
    shared: Arc<Mutex<RecordingState>>,
}

pub struct RecordingAudioBackend {
    control: RecordingAudioControl,
}

impl RecordingAudioBackend {
    pub fn new() -> (Self, RecordingAudioControl) {
        let control = RecordingAudioControl::default();
        (
            Self {
                control: control.clone(),
            },
            control,
        )
    }
}

impl RecordingAudioControl {
    pub fn push_event(&self, event: AudioBackendEvent) {
        self.shared.lock().events.push_back(event);
    }
    pub fn push_candidate(&self, candidate: AudioProcessCandidate) {
        self.shared.lock().candidates.push(candidate);
    }
    pub fn push_request(&self, request: AudioAttributionRequest) {
        self.shared.lock().requests.push(request);
    }
    pub fn fail_next_start(&self, error: AudioError) {
        self.shared.lock().start_error = Some(error);
    }
    pub fn commands(&self) -> Vec<RecordedAudioCommand> {
        self.shared.lock().commands.clone()
    }
}

impl AudioBackend for RecordingAudioBackend {
    fn start(&mut self, id: CaptureId, source: Source) -> Result<(), AudioError> {
        let mut shared = self.control.shared.lock();
        if let Some(error) = shared.start_error.take() {
            return Err(error);
        }
        shared
            .commands
            .push(RecordedAudioCommand::Start(id, source));
        Ok(())
    }
    fn stop(&mut self, id: CaptureId) {
        self.control
            .shared
            .lock()
            .commands
            .push(RecordedAudioCommand::Stop(id));
    }
    fn poll(&mut self) -> Vec<AudioBackendEvent> {
        self.control.shared.lock().events.drain(..).collect()
    }
    fn take_process_candidates(&mut self) -> Vec<AudioProcessCandidate> {
        std::mem::take(&mut self.control.shared.lock().candidates)
    }
    fn observe_process(
        &mut self,
        candidate: AudioProcessCandidate,
        observation: ProcessObservation,
    ) -> Result<(), AudioError> {
        self.control
            .shared
            .lock()
            .commands
            .push(RecordedAudioCommand::Observation(candidate, observation));
        Ok(())
    }
    fn take_attribution_requests(&mut self) -> Vec<AudioAttributionRequest> {
        std::mem::take(&mut self.control.shared.lock().requests)
    }
    fn attribution_reply(&mut self, reply: AudioAttributionReply) -> Result<(), AudioError> {
        self.control
            .shared
            .lock()
            .commands
            .push(RecordedAudioCommand::Reply(reply));
        Ok(())
    }
    fn set_process_status(
        &mut self,
        process: lunette_compositor::protocol::ProcessId,
        status: crate::audio::ProcessCaptureStatus,
    ) -> Result<(), AudioError> {
        self.control
            .shared
            .lock()
            .commands
            .push(RecordedAudioCommand::ProcessStatus(process, status));
        Ok(())
    }
    fn shutdown(&mut self) {
        self.control
            .shared
            .lock()
            .commands
            .push(RecordedAudioCommand::Shutdown);
    }
}

#[derive(Default)]
struct RecordingState {
    commands: Vec<RecordedAudioCommand>,
    events: VecDeque<AudioBackendEvent>,
    candidates: Vec<AudioProcessCandidate>,
    requests: Vec<AudioAttributionRequest>,
    start_error: Option<AudioError>,
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests report failures through expectations"
)]
mod tests {
    use lunette_compositor::protocol::{PipeWireGeneration, ProcessId};

    use super::*;
    use crate::audio::{
        AudioFormat, AudioService, CaptureState, PacketResult, PcmPacket, SourceLimits,
        audio_transport,
    };

    #[test]
    fn source_sharing_and_capacity_teardown() {
        let (backend, control) = RecordingAudioBackend::new();
        let mut service = AudioService::new(Box::new(backend), SourceLimits::default());
        let first = service.open(Source::System).expect("source");
        let second = service.open(Source::System).expect("shared source");
        assert_eq!(control.commands().len(), 1);
        service.close(first);
        assert_eq!(control.commands().len(), 1);
        service.close(second);
        assert!(matches!(
            control.commands()[1],
            RecordedAudioCommand::Stop(_)
        ));
        for id in 1..=8 {
            service
                .open(Source::Process(ProcessId::new(id).expect("nonzero")))
                .expect("within limit");
        }
        assert_eq!(
            service.open(Source::System),
            Err(AudioError::CapacityExceeded)
        );
        drop(service);
        assert_eq!(
            control
                .commands()
                .iter()
                .filter(|command| matches!(command, RecordedAudioCommand::Stop(_)))
                .count(),
            9
        );
        assert!(matches!(
            control.commands().last(),
            Some(RecordedAudioCommand::Shutdown)
        ));
    }

    #[test]
    fn unavailable_and_ended_sources_discard_queued_pcm_and_old_events() {
        let (backend, control) = RecordingAudioBackend::new();
        let mut service = AudioService::new(Box::new(backend), SourceLimits::default());
        let process = ProcessId::new(1).expect("nonzero process");
        let reader = service.open(Source::Process(process)).expect("reader");
        let capture = match control.commands()[0] {
            RecordedAudioCommand::Start(id, _) => id,
            _ => panic!("start"),
        };
        let (mut producer, consumer) = audio_transport(PipeWireGeneration(4));
        control.push_event(AudioBackendEvent::Transport {
            capture,
            generation: PipeWireGeneration(4),
            consumer,
        });
        control.push_event(AudioBackendEvent::State {
            capture,
            generation: PipeWireGeneration(4),
            state: CaptureState::Active { provenance: None },
        });
        service.begin_frame();
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
        service
            .set_process_status(process, crate::audio::ProcessCaptureStatus::Ended)
            .expect("terminal observation");
        control.push_event(AudioBackendEvent::State {
            capture,
            generation: PipeWireGeneration(3),
            state: CaptureState::Active { provenance: None },
        });
        service.begin_frame();
        let snapshot = service.snapshot(reader).expect("snapshot");
        assert_eq!(snapshot.state, CaptureState::Ended);
        assert!(snapshot.blocks.is_empty());
        assert!(control.commands().iter().any(|command| matches!(
            command,
            RecordedAudioCommand::ProcessStatus(_, crate::audio::ProcessCaptureStatus::Ended)
        )));
    }

    #[test]
    fn shared_readers_observe_one_immutable_publication() {
        let (backend, control) = RecordingAudioBackend::new();
        let mut service = AudioService::new(Box::new(backend), SourceLimits::default());
        let first = service.open(Source::System).expect("source");
        let second = service.open(Source::System).expect("source");
        let capture = match control.commands()[0] {
            RecordedAudioCommand::Start(id, _) => id,
            _ => panic!("start command"),
        };
        let (mut producer, consumer) = audio_transport(PipeWireGeneration(2));
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
        service.begin_frame();
        let snapshot = service.snapshot(first).expect("snapshot");
        assert!(Arc::ptr_eq(
            &snapshot,
            &service.snapshot(second).expect("snapshot")
        ));
        service.begin_frame();
        assert_eq!(snapshot.blocks.len(), 1);
        assert!(
            service
                .snapshot(first)
                .expect("next frame")
                .blocks
                .is_empty()
        );
        assert_eq!(snapshot.frame_generation, 1);
    }
}
