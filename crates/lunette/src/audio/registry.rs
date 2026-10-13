//! Main-thread ownership and logical-process lifetime for native audio handles.

use std::{cell::RefCell, collections::HashMap, fmt, sync::Arc};

use lunette_capture::audio::{
    AudioBlock, AudioError, AudioPublication, AudioReaderId, AudioService, CaptureState,
    ProcessCaptureStatus, Source, UnavailableReason,
};
use lunette_compositor::{
    protocol::{
        AudioAttributionRequest, Event, ProcessId, ProcessInstance, ProcessObservation,
        ProcessObservationFailure, ProcessSnapshot, Snapshot,
    },
    spawn::ProcessInspector,
};

use crate::audio::observer::{CandidateObserver, ObservationJob};

/// A native reader identity; the underlying stream may have several readers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AudioCaptureId(u64);

impl AudioCaptureId {
    pub const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug)]
pub struct AudioSnapshot {
    pub source: Source,
    pub state: CaptureState,
    pub frame_generation: u64,
    pub blocks: Arc<[AudioBlock]>,
}

/// Project-owned seam injected into sessions, including logic-only sessions.
pub trait AudioRegistry: fmt::Debug {
    fn pending_process(&self, process: ProcessId);
    fn event(&self, event: &Event);
    fn begin_frame(&self, snapshot: &Snapshot);
    fn take_requests(&self) -> Vec<AudioAttributionRequest>;
    fn open(&self, source: Source) -> AudioCaptureId;
    fn close(&self, capture: AudioCaptureId);
    fn snapshot(&self, capture: AudioCaptureId) -> Option<Arc<AudioSnapshot>>;
}

pub struct NativeAudioRegistry {
    state: RefCell<RegistryState>,
}

impl NativeAudioRegistry {
    /// Moves process inspection to a bounded worker. Frame and Lua calls never inspect `/proc`.
    pub fn new(
        service: AudioService,
        inspector: Box<dyn ProcessInspector>,
    ) -> Result<Self, AudioError> {
        Ok(Self {
            state: RefCell::new(RegistryState::new(
                Some(service),
                Some(CandidateObserver::new(inspector)?),
                String::new(),
            )),
        })
    }

    fn unavailable(detail: String) -> Self {
        Self {
            state: RefCell::new(RegistryState::new(None, None, detail)),
        }
    }
}

impl fmt::Debug for NativeAudioRegistry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NativeAudioRegistry")
            .finish_non_exhaustive()
    }
}

/// A registry with no backend or worker, used by logic sessions and failed startup.
#[derive(Debug)]
pub struct NoAudioRegistry(NativeAudioRegistry);

impl NoAudioRegistry {
    pub fn new(detail: impl Into<String>) -> Self {
        Self(NativeAudioRegistry::unavailable(detail.into()))
    }
}

impl Default for NoAudioRegistry {
    fn default() -> Self {
        Self::new("audio capture has no backend in this session")
    }
}

impl AudioRegistry for NoAudioRegistry {
    fn pending_process(&self, process: ProcessId) {
        self.0.pending_process(process);
    }
    fn event(&self, event: &Event) {
        self.0.event(event);
    }
    fn begin_frame(&self, snapshot: &Snapshot) {
        self.0.begin_frame(snapshot);
    }
    fn take_requests(&self) -> Vec<AudioAttributionRequest> {
        Vec::new()
    }
    fn open(&self, source: Source) -> AudioCaptureId {
        self.0.open(source)
    }
    fn close(&self, capture: AudioCaptureId) {
        self.0.close(capture);
    }
    fn snapshot(&self, capture: AudioCaptureId) -> Option<Arc<AudioSnapshot>> {
        self.0.snapshot(capture)
    }
}

impl AudioRegistry for NativeAudioRegistry {
    fn pending_process(&self, process: ProcessId) {
        self.state
            .borrow_mut()
            .processes
            .entry(process)
            .or_insert(ProcessEntry {
                state: ProcessState::Pending,
                sent: None,
                observation: None,
            });
    }

    fn event(&self, event: &Event) {
        let mut state = self.state.borrow_mut();
        match event {
            Event::ProcessExited { process, .. } => state.end_process(*process),
            Event::ProcessObservationChanged {
                process,
                observation,
            } => {
                if *observation == ProcessObservation::Ended {
                    state.end_process(*process);
                } else {
                    let entry = state.processes.entry(*process).or_insert(ProcessEntry {
                        state: ProcessState::Pending,
                        sent: None,
                        observation: None,
                    });
                    entry.state.refresh(*observation);
                    entry.observation = Some(*observation);
                }
            }
            Event::AudioProcessResolved(reply) => {
                if let Some(observer) = &state.observer
                    && let Err(error) = observer.submit(ObservationJob::Reply(*reply))
                {
                    state.command_error(error);
                }
            }
            _ => {}
        }
    }

    fn begin_frame(&self, snapshot: &Snapshot) {
        let mut state = self.state.borrow_mut();
        let Some(next_generation) = state.frame_generation.checked_add(1) else {
            return;
        };
        for process in &snapshot.processes {
            let entry = state
                .processes
                .entry(process.process)
                .or_insert(ProcessEntry {
                    state: ProcessState::Pending,
                    sent: None,
                    observation: None,
                });
            entry.state.register(process);
        }
        for entry in state.processes.values_mut() {
            if let Some(observation) = entry.observation.take() {
                entry.state.refresh(observation);
            }
        }
        // A queued spawn may not have reached the compositor. Absence is not an exit report.
        state.frame_generation = next_generation;
        state.sync_process_statuses();
        state.reconcile_readers();
        state.poll_backend();
        state.reconcile_readers();
        state.publish();
    }

    fn take_requests(&self) -> Vec<AudioAttributionRequest> {
        self.state
            .borrow_mut()
            .service
            .as_mut()
            .map_or_else(Vec::new, AudioService::take_attribution_requests)
    }

    fn open(&self, source: Source) -> AudioCaptureId {
        let mut state = self.state.borrow_mut();
        let id = AudioCaptureId(state.next_id);
        state.next_id = state
            .next_id
            .checked_add(1)
            .unwrap_or_else(|| panic!("audio capture: reader identifier space exhausted"));
        let lifecycle = state.source_state(source);
        let reader_state = if matches!(lifecycle, Some(CaptureState::Ended)) {
            ReaderState::Terminal(CaptureState::Ended)
        } else if state.service.is_none() {
            ReaderState::Terminal(state.no_backend_state())
        } else if state.process_unregistered(source) {
            ReaderState::Terminal(lifecycle.clone().unwrap_or(CaptureState::Ended))
        } else {
            ReaderState::Waiting
        };
        let initial = match &reader_state {
            ReaderState::Terminal(state) => state.clone(),
            _ => lifecycle.unwrap_or(CaptureState::Starting),
        };
        let frame_generation = state.frame_generation;
        state.readers.insert(
            id,
            Reader {
                source,
                state: reader_state,
                publication: Arc::new(AudioSnapshot {
                    source,
                    state: initial,
                    frame_generation,
                    blocks: Arc::from([]),
                }),
            },
        );
        // Readers opened during Lua callbacks see the current publication until the next frame.
        state.sync_process_statuses();
        state.reconcile_readers();
        let current = state.readers.get(&id).and_then(|reader| {
            let publication = match &reader.state {
                ReaderState::Terminal(capture_state) => AudioSnapshot {
                    source,
                    state: capture_state.clone(),
                    frame_generation,
                    blocks: Arc::from([]),
                },
                ReaderState::Native(native) => {
                    if let Some(shared) = state.readers.iter().find_map(|(other, reader)| {
                        (*other != id
                            && reader.source == source
                            && matches!(reader.state, ReaderState::Native(_)))
                        .then(|| Arc::clone(&reader.publication))
                    }) {
                        return Some(shared);
                    }
                    let mut publication =
                        convert_publication(state.service.as_ref()?.snapshot(*native)?.as_ref());
                    publication.frame_generation = frame_generation;
                    publication
                }
                ReaderState::Waiting => return None,
            };
            Some(Arc::new(publication))
        });
        if let Some(publication) = current
            && let Some(reader) = state.readers.get_mut(&id)
        {
            reader.publication = publication;
        }
        id
    }

    fn close(&self, capture: AudioCaptureId) {
        let mut state = self.state.borrow_mut();
        if let Some(reader) = state.readers.remove(&capture)
            && let ReaderState::Native(native) = reader.state
            && let Some(service) = &mut state.service
        {
            service.close(native);
        }
    }

    fn snapshot(&self, capture: AudioCaptureId) -> Option<Arc<AudioSnapshot>> {
        self.state
            .borrow()
            .readers
            .get(&capture)
            .map(|reader| Arc::clone(&reader.publication))
    }
}

struct RegistryState {
    service: Option<AudioService>,
    observer: Option<CandidateObserver>,
    no_backend_detail: String,
    backend_stopped: bool,
    next_id: u64,
    frame_generation: u64,
    processes: HashMap<ProcessId, ProcessEntry>,
    readers: HashMap<AudioCaptureId, Reader>,
}

struct ProcessEntry {
    state: ProcessState,
    sent: Option<ProcessCaptureStatus>,
    // Events drained after the frame snapshot override its older observation.
    observation: Option<ProcessObservation>,
}

#[derive(Clone, Copy)]
enum ProcessState {
    Pending,
    Registered {
        instance: Option<ProcessInstance>,
        observation: ProcessObservation,
    },
    Ended,
}

impl ProcessState {
    fn register(&mut self, snapshot: &ProcessSnapshot) {
        if !snapshot.alive || snapshot.observation == ProcessObservation::Ended {
            *self = Self::Ended;
            return;
        }
        if matches!(self, Self::Pending) {
            *self = Self::Registered {
                instance: snapshot.instance,
                observation: if snapshot.instance.is_none() {
                    match snapshot.observation {
                        ProcessObservation::Unavailable(reason) => {
                            ProcessObservation::Unavailable(reason)
                        }
                        _ => {
                            ProcessObservation::Unavailable(ProcessObservationFailure::InvalidData)
                        }
                    }
                } else {
                    snapshot.observation
                },
            };
        } else {
            self.refresh(snapshot.observation);
        }
    }

    fn refresh(&mut self, next: ProcessObservation) {
        match self {
            Self::Ended | Self::Pending => {}
            Self::Registered {
                instance,
                observation,
            } => match next {
                ProcessObservation::Live {
                    instance: observed, ..
                } => match instance {
                    Some(captured) if *captured == observed => *observation = next,
                    Some(_) => *self = Self::Ended,
                    None => {}
                },
                ProcessObservation::Ended => *self = Self::Ended,
                ProcessObservation::Unavailable(_) => *observation = next,
            },
        }
    }

    fn status(self) -> ProcessCaptureStatus {
        match self {
            Self::Pending => ProcessCaptureStatus::Pending,
            Self::Ended
            | Self::Registered {
                observation: ProcessObservation::Ended,
                ..
            } => ProcessCaptureStatus::Ended,
            Self::Registered {
                observation: ProcessObservation::Live { .. },
                ..
            } => ProcessCaptureStatus::Live,
            Self::Registered {
                observation: ProcessObservation::Unavailable(reason),
                ..
            } => ProcessCaptureStatus::Unavailable {
                reason: match reason {
                    ProcessObservationFailure::AccessDenied => UnavailableReason::PermissionDenied,
                    ProcessObservationFailure::InvalidData | ProcessObservationFailure::Other => {
                        UnavailableReason::UnresolvedAttribution
                    }
                },
                detail: format!("process identity observation is unavailable: {reason:?}"),
            },
        }
    }
}

struct Reader {
    source: Source,
    state: ReaderState,
    publication: Arc<AudioSnapshot>,
}

enum ReaderState {
    Waiting,
    Native(AudioReaderId),
    Terminal(CaptureState),
}

impl RegistryState {
    fn new(
        service: Option<AudioService>,
        observer: Option<CandidateObserver>,
        detail: String,
    ) -> Self {
        Self {
            service,
            observer,
            no_backend_detail: detail,
            backend_stopped: false,
            next_id: 0,
            frame_generation: 0,
            processes: HashMap::new(),
            readers: HashMap::new(),
        }
    }

    fn end_process(&mut self, process: ProcessId) {
        let entry = self.processes.entry(process).or_insert(ProcessEntry {
            state: ProcessState::Ended,
            sent: None,
            observation: None,
        });
        entry.state = ProcessState::Ended;
        entry.observation = None;
    }

    fn source_state(&self, source: Source) -> Option<CaptureState> {
        let Source::Process(process) = source else {
            return None;
        };
        match self
            .processes
            .get(&process)
            .map(|entry| entry.state.status())
        {
            Some(ProcessCaptureStatus::Pending) => Some(CaptureState::Starting),
            Some(ProcessCaptureStatus::Live) => None,
            Some(ProcessCaptureStatus::Unavailable { reason, detail }) => {
                Some(CaptureState::Unavailable { reason, detail })
            }
            Some(ProcessCaptureStatus::Ended) | None => Some(CaptureState::Ended),
        }
    }

    fn process_unregistered(&self, source: Source) -> bool {
        match source {
            Source::System => false,
            Source::Process(process) => matches!(
                self.processes.get(&process).map(|entry| entry.state),
                Some(ProcessState::Registered { instance: None, .. })
            ),
        }
    }

    fn no_backend_state(&self) -> CaptureState {
        CaptureState::Unavailable {
            reason: UnavailableReason::NoServer,
            detail: self.no_backend_detail.clone(),
        }
    }

    fn sync_process_statuses(&mut self) {
        let Some(service) = &mut self.service else {
            return;
        };
        if self.backend_stopped {
            return;
        }
        for (process, entry) in &mut self.processes {
            if !self
                .readers
                .values()
                .any(|reader| reader.source == Source::Process(*process))
            {
                continue;
            }
            let status = entry.state.status();
            if entry.sent.as_ref() == Some(&status) {
                continue;
            }
            match service.set_process_status(*process, status.clone()) {
                Ok(()) => entry.sent = Some(status),
                Err(error) => {
                    tracing::warn!(%error, %process, "audio process status was not delivered");
                    if error == AudioError::WorkerStopped {
                        self.backend_stopped = true;
                        break;
                    }
                }
            }
        }
    }

    fn reconcile_readers(&mut self) {
        let choices: Vec<_> = self
            .readers
            .iter()
            .map(|(id, reader)| {
                (
                    *id,
                    self.source_state(reader.source),
                    self.process_unregistered(reader.source),
                )
            })
            .collect();
        for (id, lifecycle, unregistered) in choices {
            let Some(reader) = self.readers.get_mut(&id) else {
                continue;
            };
            if matches!(lifecycle, Some(CaptureState::Ended)) || unregistered {
                if let ReaderState::Native(native) = reader.state
                    && let Some(service) = &mut self.service
                {
                    service.close(native);
                }
                reader.state = ReaderState::Terminal(lifecycle.unwrap_or(CaptureState::Ended));
                continue;
            }
            if self.backend_stopped && !matches!(reader.state, ReaderState::Terminal(_)) {
                if let ReaderState::Native(native) = reader.state
                    && let Some(service) = &mut self.service
                {
                    service.close(native);
                }
                reader.state = ReaderState::Terminal(error_state(&AudioError::WorkerStopped));
            }
            if !matches!(reader.state, ReaderState::Waiting) || lifecycle.is_some() {
                continue;
            }
            if let Some(service) = &mut self.service {
                reader.state = match service.open(reader.source) {
                    Ok(native) => ReaderState::Native(native),
                    Err(error) => ReaderState::Terminal(error_state(&error)),
                };
            }
        }
    }

    fn poll_backend(&mut self) {
        let Some(service) = &mut self.service else {
            return;
        };
        service.begin_frame();
        if let Some(observer) = &self.observer {
            for candidate in service.take_process_candidates() {
                if let Err(error) = observer.submit(ObservationJob::Candidate(candidate)) {
                    tracing::warn!(%error, "audio producer observation was not queued");
                    if let Err(error) = service.observe_process(
                        candidate,
                        ProcessObservation::Unavailable(ProcessObservationFailure::Other),
                    ) {
                        tracing::warn!(%error, "audio producer observation failure was not delivered");
                    }
                }
            }
            for (job, observation) in observer.poll() {
                let result = match job {
                    ObservationJob::Candidate(candidate) => {
                        service.observe_process(candidate, observation)
                    }
                    ObservationJob::Reply(mut reply) => {
                        let candidate_live =
                            observation.instance() == Some(reply.request.candidate);
                        let process_live = reply.process.is_some_and(|process| {
                            self.processes.get(&process).is_some_and(|entry| {
                                entry.state.status() == ProcessCaptureStatus::Live
                            })
                        });
                        if !candidate_live || !process_live {
                            reply.process = None;
                        }
                        service.attribution_reply(reply)
                    }
                };
                if let Err(error) = result {
                    tracing::warn!(%error, "audio process observation was not delivered");
                    if error == AudioError::WorkerStopped {
                        self.backend_stopped = true;
                    }
                }
            }
        }
    }

    fn publish(&mut self) {
        let mut publications: HashMap<Source, Arc<AudioSnapshot>> = HashMap::new();
        for reader in self.readers.values() {
            if publications.contains_key(&reader.source) {
                continue;
            }
            let lifecycle = self.source_state(reader.source);
            let publication = match &reader.state {
                ReaderState::Native(native) if lifecycle.is_none() && !self.backend_stopped => self
                    .service
                    .as_ref()
                    .and_then(|service| service.snapshot(*native))
                    .map(|publication| {
                        let mut publication = convert_publication(publication.as_ref());
                        publication.frame_generation = self.frame_generation;
                        Arc::new(publication)
                    }),
                ReaderState::Terminal(_) => None,
                _ => None,
            };
            if let Some(publication) = publication {
                publications.insert(reader.source, publication);
            }
        }
        for reader in self.readers.values_mut() {
            let lifecycle = match reader.source {
                Source::System => None,
                Source::Process(process) => self
                    .processes
                    .get(&process)
                    .map(|entry| entry.state.status()),
            };
            let state = match &reader.state {
                ReaderState::Terminal(state) => Some(state.clone()),
                _ => match lifecycle {
                    Some(ProcessCaptureStatus::Pending) => Some(CaptureState::Starting),
                    Some(ProcessCaptureStatus::Ended) => Some(CaptureState::Ended),
                    Some(ProcessCaptureStatus::Unavailable { reason, detail }) => {
                        Some(CaptureState::Unavailable { reason, detail })
                    }
                    _ if self.backend_stopped => Some(error_state(&AudioError::WorkerStopped)),
                    _ => None,
                },
            };
            if let Some(state) = state {
                reader.publication = Arc::new(AudioSnapshot {
                    source: reader.source,
                    state,
                    frame_generation: self.frame_generation,
                    blocks: Arc::from([]),
                });
            } else if let Some(publication) = publications.get(&reader.source) {
                reader.publication = Arc::clone(publication);
            }
        }
    }

    fn command_error(&mut self, error: AudioError) {
        tracing::warn!(%error, "audio attribution reply was not delivered");
        if error == AudioError::WorkerStopped {
            self.backend_stopped = true;
        }
    }
}

fn convert_publication(publication: &AudioPublication) -> AudioSnapshot {
    AudioSnapshot {
        source: publication.source,
        state: publication.state.clone(),
        frame_generation: publication.frame_generation,
        blocks: Arc::clone(&publication.blocks),
    }
}

fn error_state(error: &AudioError) -> CaptureState {
    CaptureState::Unavailable {
        reason: if matches!(error, AudioError::CapacityExceeded) {
            UnavailableReason::CapacityExceeded
        } else {
            UnavailableReason::GraphFailure
        },
        detail: error.to_string(),
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests report failures through expectations"
)]
mod tests;
