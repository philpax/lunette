//! Linux-only: coordinates the audio worker; PipeWire objects stay on that thread.

#[path = "worker/objects.rs"]
mod objects;
#[path = "worker/registry.rs"]
mod registry;
#[path = "worker/stream.rs"]
mod stream;

use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use lunette_compositor::{
    protocol::{
        AudioAttributionReply, AudioAttributionRequest, AudioNodeSerial, ProcessId,
        ProcessObservation,
    },
    spawn::{ProcFilesystem, ProcessInspector},
};

use crate::audio::{
    AudioBackend, AudioBackendEvent, AudioError, AudioProcessCandidate, CaptureId,
    ProcessCaptureStatus, Source, driver::GraphDriver, worker::objects::PipeWireGraphOps,
};

#[derive(Clone, Debug)]
pub struct PipeWireAudioConfig {
    pub remote_name: Option<String>,
    pub owner_tag: String,
    /// A nonempty session identifier injected by the binary. It makes owned
    /// object names distinct across concurrent hosts and is not read from env.
    pub session_id: String,
    pub command_capacity: usize,
    pub event_capacity: usize,
    pub poll_interval: Duration,
    pub retry_interval: Duration,
}
impl Default for PipeWireAudioConfig {
    fn default() -> Self {
        Self {
            remote_name: None,
            owner_tag: "lunette-audio".into(),
            session_id: String::new(),
            command_capacity: 64,
            event_capacity: 256,
            poll_interval: Duration::from_millis(5),
            retry_interval: Duration::from_millis(500),
        }
    }
}

pub struct PipeWireAudioBackend {
    commands: SyncSender<Command>,
    events: Receiver<WorkerEvent>,
    deferred: VecDeque<Command>,
    requests: Vec<AudioAttributionRequest>,
    event_budget: usize,
    live_captures: BTreeSet<CaptureId>,
    shutdown: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}
impl PipeWireAudioBackend {
    pub fn new(config: PipeWireAudioConfig) -> Result<Self, AudioError> {
        Self::with_inspector(config, Box::new(ProcFilesystem))
    }
    /// Both candidate observation and reply revalidation run on the worker, never
    /// in the frame callback. The same project inspector can be scripted in tests.
    pub fn with_inspector(
        mut config: PipeWireAudioConfig,
        inspector: Box<dyn ProcessInspector>,
    ) -> Result<Self, AudioError> {
        if config.owner_tag.is_empty()
            || config.owner_tag.contains('\0')
            || config.session_id.is_empty()
            || !config
                .session_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
            || config
                .remote_name
                .as_ref()
                .is_some_and(|name| name.contains('\0'))
            || config.command_capacity == 0
            || config.event_capacity < 32
            || config.poll_interval.is_zero()
            || config.poll_interval > Duration::from_secs(1)
            || config.retry_interval.is_zero()
        {
            return Err(AudioError::InvalidConfiguration);
        }
        config.owner_tag = format!("{}.{}", config.owner_tag, config.session_id);
        let (commands, command_rx) = mpsc::sync_channel(config.command_capacity);
        let (event_tx, events) = mpsc::sync_channel(config.event_capacity);
        let event_budget = config.event_capacity;
        let shutdown = Arc::new(AtomicBool::new(false));
        let stopped = shutdown.clone();
        let join = thread::Builder::new()
            .name("lunette-audio".into())
            .spawn(move || worker(config, inspector, command_rx, event_tx, stopped))
            .map_err(|error| AudioError::WorkerStart(error.to_string()))?;
        Ok(Self {
            commands,
            events,
            deferred: VecDeque::new(),
            requests: Vec::new(),
            event_budget,
            live_captures: BTreeSet::new(),
            shutdown,
            join: Some(join),
        })
    }
    fn command(&self, command: Command) -> Result<(), AudioError> {
        self.commands
            .try_send(command)
            .map_err(|error| match error {
                TrySendError::Full(_) => AudioError::CommandQueueFull,
                TrySendError::Disconnected(_) => AudioError::WorkerStopped,
            })
    }
}
impl AudioBackend for PipeWireAudioBackend {
    fn start(&mut self, capture: CaptureId, source: Source) -> Result<(), AudioError> {
        if !self.deferred.is_empty() {
            return Err(AudioError::CommandQueueFull);
        }
        if self.live_captures.len() >= 8 {
            return Err(AudioError::CapacityExceeded);
        }
        if self.live_captures.contains(&capture) {
            return Err(AudioError::InvalidConfiguration);
        }
        self.command(Command::Start(capture, source))?;
        self.live_captures.insert(capture);
        Ok(())
    }
    fn stop(&mut self, capture: CaptureId) {
        if !self.live_captures.remove(&capture) {
            return;
        }
        if let Err(TrySendError::Full(command)) = self.commands.try_send(Command::Stop(capture)) {
            self.deferred.push_back(command);
        }
    }
    fn poll(&mut self) -> Vec<AudioBackendEvent> {
        while let Some(command) = self.deferred.pop_front() {
            if let Err(TrySendError::Full(command)) = self.commands.try_send(command) {
                self.deferred.push_front(command);
                break;
            }
        }
        let mut events = Vec::new();
        for _ in 0..self.event_budget {
            if self.requests.len() >= self.event_budget {
                break;
            }
            let Ok(event) = self.events.try_recv() else {
                break;
            };
            match event {
                WorkerEvent::Backend(event) => events.push(event),
                WorkerEvent::Request(request) => self.requests.push(request),
            }
        }
        events
    }
    fn take_process_candidates(&mut self) -> Vec<AudioProcessCandidate> {
        Vec::new()
    }
    fn observe_process(
        &mut self,
        candidate: AudioProcessCandidate,
        observation: ProcessObservation,
    ) -> Result<(), AudioError> {
        self.command(Command::Observation(candidate, observation))
    }
    fn take_attribution_requests(&mut self) -> Vec<AudioAttributionRequest> {
        std::mem::take(&mut self.requests)
    }
    fn attribution_reply(&mut self, reply: AudioAttributionReply) -> Result<(), AudioError> {
        self.command(Command::Reply(reply))
    }
    fn set_process_status(
        &mut self,
        process: ProcessId,
        status: ProcessCaptureStatus,
    ) -> Result<(), AudioError> {
        self.command(Command::ProcessStatus(process, status))
    }
    fn shutdown(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        if let Some(join) = self.join.take()
            && join.join().is_err()
        {
            tracing::error!("audio worker panicked during shutdown");
        }
    }
}
impl Drop for PipeWireAudioBackend {
    fn drop(&mut self) {
        self.shutdown();
    }
}

enum Command {
    Start(CaptureId, Source),
    Stop(CaptureId),
    Observation(AudioProcessCandidate, ProcessObservation),
    Reply(AudioAttributionReply),
    ProcessStatus(ProcessId, ProcessCaptureStatus),
}
enum WorkerEvent {
    Backend(AudioBackendEvent),
    Request(AudioAttributionRequest),
}
fn worker(
    config: PipeWireAudioConfig,
    inspector: Box<dyn ProcessInspector>,
    commands: Receiver<Command>,
    events: SyncSender<WorkerEvent>,
    shutdown: Arc<AtomicBool>,
) {
    pipewire::init();
    let mut driver = GraphDriver::new(config.owner_tag.clone(), config.retry_interval);
    let mut ops = PipeWireGraphOps::new(config.clone());
    let mut attribution = AttributionWorker::default();
    let mut outbox = VecDeque::new();
    let mut replies = Vec::new();
    let mut observations = Vec::new();
    let origin = Instant::now();
    while !shutdown.load(Ordering::Acquire) {
        let now = origin.elapsed();
        for _ in 0..config.command_capacity {
            if replies.len() >= config.command_capacity
                || observations.len() >= config.command_capacity
            {
                break;
            }
            let Ok(command) = commands.try_recv() else {
                break;
            };
            match command {
                Command::Start(capture, source) => driver.start(capture, source),
                Command::Stop(capture) => driver.stop(capture, &mut ops),
                Command::ProcessStatus(process, status) => driver.process_status(process, status),
                Command::Reply(reply) => replies.push(reply),
                Command::Observation(candidate, observation) => {
                    observations.push((candidate, observation))
                }
            }
        }
        while let Some(event) = outbox.pop_front() {
            match events.try_send(event) {
                Ok(()) => {}
                Err(TrySendError::Full(event)) => {
                    outbox.push_front(event);
                    break;
                }
                Err(TrySendError::Disconnected(_)) => {
                    driver.shutdown(&mut ops);
                    return;
                }
            }
        }
        ops.iterate();
        if outbox.len() < config.event_capacity {
            let mut requests = Vec::new();
            let budget = config.event_capacity - outbox.len();
            let backend_events = driver.tick_with_registry(now, &mut ops, &mut |registry| {
                for reply in replies.drain(..) {
                    attribution.reply(registry, reply, inspector.as_ref());
                }
                for (candidate, observation) in observations.drain(..) {
                    let current = inspector.observe(candidate.pid);
                    if current == observation
                        && let Some(request) = registry.observe_process(candidate, current)
                    {
                        requests.push(request);
                    }
                }
                requests.extend(attribution.observe(
                    registry,
                    now,
                    config.retry_interval,
                    inspector.as_ref(),
                    budget.saturating_sub(requests.len()),
                ));
            });
            outbox.extend(backend_events.into_iter().map(WorkerEvent::Backend));
            outbox.extend(requests.into_iter().map(WorkerEvent::Request));
            // A disconnected or inactive driver cannot validate deferred replies.
            // Their generation is no longer live, so no old observations survive.
            replies.clear();
            observations.clear();
        }
        if !ops.connected() {
            thread::park_timeout(config.poll_interval);
        }
    }
    driver.shutdown(&mut ops);
}

#[cfg(test)]
#[path = "worker/tests.rs"]
mod tests;

#[derive(Default)]
pub(crate) struct AttributionWorker {
    last_observed: BTreeMap<AudioNodeSerial, Duration>,
    generation: u64,
}
impl AttributionWorker {
    pub(crate) fn observe(
        &mut self,
        registry: &mut crate::audio::RegistrySnapshot,
        now: Duration,
        retry: Duration,
        inspector: &dyn ProcessInspector,
        budget: usize,
    ) -> Vec<AudioAttributionRequest> {
        if self.generation != registry.generation.0 {
            self.generation = registry.generation.0;
            self.last_observed.clear();
        }
        for (serial, instance) in registry.known_instances() {
            if self.due(serial, now, retry) {
                registry.revalidate_instance(serial, inspector.observe(instance.pid()));
                self.last_observed.insert(serial, now);
            }
        }
        let mut requests = Vec::new();
        for candidate in registry.process_candidates() {
            if requests.len() >= budget {
                break;
            }
            if !self.due(candidate.node, now, retry) {
                continue;
            }
            self.last_observed.insert(candidate.node, now);
            if let Some(request) =
                registry.observe_process(candidate, inspector.observe(candidate.pid))
            {
                requests.push(request);
            }
        }
        requests
    }
    pub(crate) fn reply(
        &mut self,
        registry: &mut crate::audio::RegistrySnapshot,
        reply: AudioAttributionReply,
        inspector: &dyn ProcessInspector,
    ) -> bool {
        registry.attribution_reply(reply, inspector.observe(reply.request.candidate.pid()))
    }
    fn due(&self, serial: AudioNodeSerial, now: Duration, retry: Duration) -> bool {
        self.last_observed
            .get(&serial)
            .is_none_or(|last| now.saturating_sub(*last) >= retry)
    }
}
