//! Frame-facing source sharing and the project-owned capture backend boundary.

use std::{collections::HashMap, error::Error, fmt, sync::Arc};

use lunette_compositor::protocol::{
    AudioAttributionReply, AudioAttributionRequest, AudioNodeSerial, Pid, PipeWireGeneration,
    ProcessObservation,
};

use crate::audio::{AudioBlock, AudioConsumer, CaptureState, Source, SourceLimits, TransportLoss};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AudioReaderId(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CaptureId(pub u64);

/// A registry PID assertion that needs an asynchronous process-instance observation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioProcessCandidate {
    pub generation: PipeWireGeneration,
    pub node: AudioNodeSerial,
    pub pid: Pid,
    pub assertion: crate::audio::PidAssertion,
}

#[derive(Clone, Debug)]
pub struct AudioPublication {
    pub source: Source,
    pub state: CaptureState,
    pub frame_generation: u64,
    pub connection_generation: PipeWireGeneration,
    pub blocks: Arc<[AudioBlock]>,
    pub queued_packets: usize,
    pub queued_frames: usize,
    pub loss: TransportLoss,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AudioError {
    CapacityExceeded,
    CommandQueueFull,
    WorkerStopped,
    InvalidConfiguration,
    WorkerStart(String),
    IdentifierExhausted,
}

impl fmt::Display for AudioError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "audio capture: ")?;
        match self {
            Self::CapacityExceeded => f.write_str("source capacity exceeded"),
            Self::CommandQueueFull => f.write_str("worker command queue is full"),
            Self::WorkerStopped => f.write_str("worker stopped"),
            Self::InvalidConfiguration => f.write_str("invalid worker configuration"),
            Self::WorkerStart(detail) => write!(f, "worker startup: {detail}"),
            Self::IdentifierExhausted => f.write_str("reader identifier space exhausted"),
        }
    }
}
impl Error for AudioError {}

/// Events are collected outside the realtime callback. A replacement transport
/// invalidates all PCM from the previous monitor connection.
pub enum AudioBackendEvent {
    State {
        capture: CaptureId,
        generation: PipeWireGeneration,
        state: CaptureState,
    },
    Transport {
        capture: CaptureId,
        generation: PipeWireGeneration,
        consumer: AudioConsumer,
    },
}

/// Project-owned seam. Every method is nonblocking except final shutdown/join.
pub trait AudioBackend: Send {
    fn start(&mut self, capture: CaptureId, source: Source) -> Result<(), AudioError>;
    fn stop(&mut self, capture: CaptureId);
    fn poll(&mut self) -> Vec<AudioBackendEvent>;
    fn take_process_candidates(&mut self) -> Vec<AudioProcessCandidate>;
    fn observe_process(
        &mut self,
        candidate: AudioProcessCandidate,
        observation: ProcessObservation,
    ) -> Result<(), AudioError>;
    fn take_attribution_requests(&mut self) -> Vec<AudioAttributionRequest>;
    fn attribution_reply(&mut self, reply: AudioAttributionReply) -> Result<(), AudioError>;
    fn set_process_status(
        &mut self,
        process: lunette_compositor::protocol::ProcessId,
        status: ProcessCaptureStatus,
    ) -> Result<(), AudioError>;
    fn shutdown(&mut self);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProcessCaptureStatus {
    Pending,
    Live,
    Unavailable {
        reason: crate::audio::UnavailableReason,
        detail: String,
    },
    Ended,
}

pub struct AudioService {
    backend: Box<dyn AudioBackend>,
    limits: SourceLimits,
    next_id: u64,
    frame_generation: u64,
    readers: HashMap<AudioReaderId, Source>,
    sources: HashMap<Source, SourceEntry>,
}

impl AudioService {
    pub fn new(backend: Box<dyn AudioBackend>, limits: SourceLimits) -> Self {
        Self {
            backend,
            limits,
            next_id: 0,
            frame_generation: 0,
            readers: HashMap::new(),
            sources: HashMap::new(),
        }
    }

    pub fn open(&mut self, source: Source) -> Result<AudioReaderId, AudioError> {
        let next_id = self
            .next_id
            .checked_add(1)
            .ok_or(AudioError::IdentifierExhausted)?;
        if !self.sources.contains_key(&source) {
            if self.sources.len() >= self.limits.simultaneous_sources.min(8) {
                return Err(AudioError::CapacityExceeded);
            }
            let capture = CaptureId(self.next_id);
            self.backend.start(capture, source)?;
            self.sources.insert(
                source,
                SourceEntry {
                    capture,
                    readers: 0,
                    generation: PipeWireGeneration(0),
                    state: CaptureState::Starting,
                    consumer: None,
                    previous_loss: TransportLoss::default(),
                    pending_gap: TransportLoss::default(),
                    suspended: false,
                    terminal: false,
                    lifecycle: None,
                    publication: Arc::new(AudioPublication {
                        source,
                        state: CaptureState::Starting,
                        frame_generation: self.frame_generation,
                        connection_generation: PipeWireGeneration(0),
                        blocks: Arc::from([]),
                        queued_packets: 0,
                        queued_frames: 0,
                        loss: TransportLoss::default(),
                    }),
                },
            );
        }
        let reader = AudioReaderId(self.next_id);
        self.next_id = next_id;
        if let Some(entry) = self.sources.get_mut(&source) {
            entry.readers += 1;
        }
        self.readers.insert(reader, source);
        Ok(reader)
    }

    pub fn close(&mut self, reader: AudioReaderId) {
        let Some(source) = self.readers.remove(&reader) else {
            return;
        };
        let Some(entry) = self.sources.get_mut(&source) else {
            return;
        };
        entry.readers -= 1;
        if entry.readers == 0 {
            self.backend.stop(entry.capture);
            self.sources.remove(&source);
        }
    }

    /// Called once at the frame boundary. Every reader of a source sees the same
    /// immutable publication, regardless of its order of access within the frame.
    pub fn begin_frame(&mut self) {
        for event in self.backend.poll() {
            self.apply_event(event);
        }
        let Some(generation) = self.frame_generation.checked_add(1) else {
            // No new publication can reuse a frame identity after exhaustion.
            for entry in self.sources.values_mut() {
                entry.retire_transport();
            }
            return;
        };
        self.frame_generation = generation;
        for (source, entry) in &mut self.sources {
            let (blocks, queued_packets, queued_frames, loss) = if let Some(consumer) =
                &mut entry.consumer
            {
                if !matches!(entry.state, CaptureState::Active { .. }) {
                    consumer.discard();
                    entry.suspended = true;
                }
                let cutoff = consumer.snapshot();
                let occupancy = (
                    cutoff.queued_packets,
                    cutoff.queued_frames,
                    cutoff.loss.combined(entry.previous_loss),
                );
                let mut blocks = if matches!(entry.state, CaptureState::Active { .. }) {
                    consumer.drain(cutoff, entry.generation)
                } else {
                    Vec::new()
                };
                if let Some(block) = blocks.first_mut() {
                    block.gap_packets = block.gap_packets.saturating_add(entry.pending_gap.packets);
                    block.gap_frames = block.gap_frames.saturating_add(entry.pending_gap.frames);
                    entry.pending_gap = TransportLoss::default();
                }
                (blocks, occupancy.0, occupancy.1, occupancy.2)
            } else {
                (Vec::new(), 0, 0, entry.previous_loss)
            };
            entry.publication = Arc::new(AudioPublication {
                source: *source,
                state: entry.state.clone(),
                frame_generation: self.frame_generation,
                connection_generation: entry.generation,
                blocks: blocks.into(),
                queued_packets,
                queued_frames,
                loss,
            });
        }
    }

    pub fn snapshot(&self, reader: AudioReaderId) -> Option<Arc<AudioPublication>> {
        let source = self.readers.get(&reader)?;
        Some(self.sources.get(source)?.publication.clone())
    }

    pub fn take_process_candidates(&mut self) -> Vec<AudioProcessCandidate> {
        self.backend.take_process_candidates()
    }
    pub fn observe_process(
        &mut self,
        candidate: AudioProcessCandidate,
        observation: ProcessObservation,
    ) -> Result<(), AudioError> {
        self.backend.observe_process(candidate, observation)
    }
    pub fn take_attribution_requests(&mut self) -> Vec<AudioAttributionRequest> {
        self.backend.take_attribution_requests()
    }
    pub fn attribution_reply(&mut self, reply: AudioAttributionReply) -> Result<(), AudioError> {
        self.backend.attribution_reply(reply)
    }

    pub fn set_process_status(
        &mut self,
        process: lunette_compositor::protocol::ProcessId,
        status: ProcessCaptureStatus,
    ) -> Result<(), AudioError> {
        self.backend.set_process_status(process, status.clone())?;
        if let Some(entry) = self.sources.get_mut(&Source::Process(process)) {
            if entry.terminal {
                return Ok(());
            }
            entry.lifecycle = Some(status.clone());
            let state = match status {
                ProcessCaptureStatus::Live => None,
                ProcessCaptureStatus::Pending => Some(CaptureState::Starting),
                ProcessCaptureStatus::Unavailable { reason, detail } => {
                    Some(CaptureState::Unavailable { reason, detail })
                }
                ProcessCaptureStatus::Ended => Some(CaptureState::Ended),
            };
            if let Some(state) = state {
                entry.terminal |= matches!(state, CaptureState::Ended);
                entry.state = state;
                entry.suspend_transport();
            }
        }
        Ok(())
    }

    fn apply_event(&mut self, event: AudioBackendEvent) {
        let capture = match &event {
            AudioBackendEvent::State { capture, .. }
            | AudioBackendEvent::Transport { capture, .. } => *capture,
        };
        let Some(entry) = self
            .sources
            .values_mut()
            .find(|entry| entry.capture == capture)
        else {
            return;
        };
        match event {
            AudioBackendEvent::State {
                generation, state, ..
            } if generation >= entry.generation => {
                if entry.terminal
                    || (matches!(state, CaptureState::Active { .. } | CaptureState::Idle)
                        && entry
                            .lifecycle
                            .as_ref()
                            .is_some_and(|status| !matches!(status, ProcessCaptureStatus::Live)))
                {
                    return;
                }
                if generation != entry.generation {
                    entry.retire_transport();
                }
                if !matches!(state, CaptureState::Active { .. }) || entry.suspended {
                    entry.suspend_transport();
                }
                entry.suspended = !matches!(state, CaptureState::Active { .. });
                entry.terminal |= matches!(state, CaptureState::Ended);
                entry.generation = generation;
                entry.state = state;
            }
            AudioBackendEvent::Transport {
                generation,
                consumer,
                ..
            } if generation >= entry.generation => {
                if entry.terminal {
                    return;
                }
                entry.retire_transport();
                entry.generation = generation;
                entry.consumer = Some(consumer);
                entry.suspended = false;
            }
            _ => {}
        }
    }
}

impl fmt::Debug for AudioService {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AudioService")
            .field("readers", &self.readers.len())
            .field("sources", &self.sources.len())
            .field("frame_generation", &self.frame_generation)
            .finish_non_exhaustive()
    }
}

impl Drop for AudioService {
    fn drop(&mut self) {
        for entry in self.sources.values() {
            self.backend.stop(entry.capture);
        }
        self.backend.shutdown();
    }
}

struct SourceEntry {
    capture: CaptureId,
    readers: usize,
    generation: PipeWireGeneration,
    state: CaptureState,
    consumer: Option<AudioConsumer>,
    previous_loss: TransportLoss,
    pending_gap: TransportLoss,
    suspended: bool,
    terminal: bool,
    lifecycle: Option<ProcessCaptureStatus>,
    publication: Arc<AudioPublication>,
}
#[cfg(test)]
mod tests;

impl SourceEntry {
    fn suspend_transport(&mut self) {
        if let Some(consumer) = &mut self.consumer {
            consumer.discard();
        }
        self.suspended = true;
    }
    fn retire_transport(&mut self) {
        if let Some(mut consumer) = self.consumer.take() {
            consumer.discard();
            self.previous_loss = self.previous_loss.combined(consumer.snapshot().loss);
            self.pending_gap = self.pending_gap.combined(consumer.pending_gap());
        }
    }
}
