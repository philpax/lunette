//! Shared worker graph orchestration over project-owned capture operations.

use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};

use lunette_compositor::protocol::{PipeWireGeneration, ProcessId};

use crate::audio::{
    AdditiveLink, AudioBackendEvent, CaptureId, CaptureState, MonitorTarget, NodeIdentity,
    NodeKind, ProcessCaptureStatus, RegistrySnapshot, Source, UnavailableReason, plan_graph,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct GraphObjectId(pub u64);
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GraphObjectState {
    Starting,
    Streaming,
    Unavailable {
        reason: UnavailableReason,
        detail: String,
    },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphFailure {
    pub reason: UnavailableReason,
    pub detail: String,
}
impl std::fmt::Display for GraphFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "audio graph {:?}: {}", self.reason, self.detail)
    }
}
impl std::error::Error for GraphFailure {}
impl GraphFailure {
    pub fn graph(detail: impl Into<String>) -> Self {
        Self {
            reason: UnavailableReason::GraphFailure,
            detail: detail.into(),
        }
    }
}

/// The adapter owns third-party objects. Removal accepts only ids returned by
/// these creation methods; the boundary has no operation for playback routing.
pub trait GraphOps {
    fn connect(&mut self, generation: PipeWireGeneration) -> Result<(), GraphFailure>;
    fn disconnect(&mut self);
    fn observe(&mut self) -> Result<RegistrySnapshot, GraphFailure>;
    fn create_adapter(&mut self, name: &str) -> Result<GraphObjectId, GraphFailure>;
    fn create_monitor(
        &mut self,
        capture: CaptureId,
        target: NodeIdentity,
        epoch: PipeWireGeneration,
    ) -> Result<GraphObjectId, GraphFailure>;
    fn create_link(
        &mut self,
        mixer: NodeIdentity,
        link: &AdditiveLink,
    ) -> Result<GraphObjectId, GraphFailure>;
    fn state(&mut self, object: GraphObjectId) -> GraphObjectState;
    fn remove(&mut self, object: GraphObjectId);
    fn publish_transport(
        &mut self,
        object: GraphObjectId,
        capture: CaptureId,
    ) -> Option<AudioBackendEvent>;
}

pub(crate) struct GraphDriver {
    pub(crate) registry: RegistrySnapshot,
    desired: BTreeMap<CaptureId, Source>,
    processes: BTreeMap<ProcessId, ProcessCaptureStatus>,
    captures: BTreeMap<CaptureId, CaptureGraph>,
    states: BTreeMap<CaptureId, CaptureState>,
    source_epochs: BTreeMap<CaptureId, PipeWireGeneration>,
    exhausted: bool,
    connection: ConnectionState,
    next_generation: u64,
    epoch: u64,
    owner_tag: String,
    retry_interval: Duration,
}

impl GraphDriver {
    pub(crate) fn new(owner_tag: String, retry_interval: Duration) -> Self {
        Self {
            registry: RegistrySnapshot::new(PipeWireGeneration(0)),
            desired: BTreeMap::new(),
            processes: BTreeMap::new(),
            captures: BTreeMap::new(),
            states: BTreeMap::new(),
            source_epochs: BTreeMap::new(),
            exhausted: false,
            connection: ConnectionState::Disconnected {
                retry_at: Duration::ZERO,
            },
            next_generation: 0,
            epoch: 0,
            owner_tag,
            retry_interval,
        }
    }
    pub(crate) fn start(&mut self, capture: CaptureId, source: Source) {
        self.desired.insert(capture, source);
        self.states.remove(&capture);
    }
    pub(crate) fn stop(&mut self, capture: CaptureId, ops: &mut dyn GraphOps) {
        self.desired.remove(&capture);
        self.states.remove(&capture);
        self.source_epochs.remove(&capture);
        if let Some(mut graph) = self.captures.remove(&capture) {
            graph.teardown(ops);
        }
    }
    pub(crate) fn process_status(&mut self, process: ProcessId, status: ProcessCaptureStatus) {
        if self.processes.get(&process) != Some(&ProcessCaptureStatus::Ended) {
            self.processes.insert(process, status);
        }
    }
    pub(crate) fn shutdown(&mut self, ops: &mut dyn GraphOps) {
        for graph in self.captures.values_mut() {
            graph.teardown(ops);
        }
        self.captures.clear();
        if matches!(self.connection, ConnectionState::Connected) {
            ops.disconnect();
        }
        self.connection = ConnectionState::Disconnected {
            retry_at: Duration::MAX,
        };
    }

    /// Production and recording tests call this same reconciliation path with a
    /// supplied monotonic time. Device events and registry updates enter via ops.
    #[cfg(test)]
    pub(crate) fn tick(&mut self, now: Duration, ops: &mut dyn GraphOps) -> Vec<AudioBackendEvent> {
        self.tick_with_registry(now, ops, &mut |_| {})
    }
    pub(crate) fn tick_with_registry(
        &mut self,
        now: Duration,
        ops: &mut dyn GraphOps,
        update: &mut dyn FnMut(&mut RegistrySnapshot),
    ) -> Vec<AudioBackendEvent> {
        let mut events = Vec::new();
        let active: BTreeMap<_, _> = self
            .desired
            .iter()
            .filter_map(|(capture, source)| {
                let state = match source {
                    Source::System => return Some((*capture, *source)),
                    Source::Process(process) => {
                        match self
                            .processes
                            .get(process)
                            .unwrap_or(&ProcessCaptureStatus::Pending)
                            .capture_override()
                        {
                            Some(state) => state,
                            None => return Some((*capture, *source)),
                        }
                    }
                };
                if self.states.get(capture) != Some(&state) {
                    events.push(state_event(
                        *capture,
                        self.source_epochs
                            .get(capture)
                            .copied()
                            .unwrap_or(PipeWireGeneration(0))
                            .0,
                        state.clone(),
                    ));
                    self.states.insert(*capture, state);
                }
                None
            })
            .collect();
        let stopped: Vec<_> = self
            .captures
            .keys()
            .filter(|capture| !active.contains_key(capture))
            .copied()
            .collect();
        for capture in stopped {
            if let Some(mut graph) = self.captures.remove(&capture) {
                graph.teardown(ops);
            }
        }
        if active.is_empty() {
            if matches!(self.connection, ConnectionState::Connected) {
                ops.disconnect();
            }
            self.connection = ConnectionState::Disconnected { retry_at: now };
            return events;
        }
        if let ConnectionState::Disconnected { retry_at } = self.connection {
            if now < retry_at {
                return events;
            }
            if self.exhausted {
                return events;
            }
            let Some(next) = self.next_generation.checked_add(1) else {
                self.exhausted = true;
                self.fail_connection(
                    now,
                    &active,
                    GraphFailure::graph("connection generation space exhausted"),
                    ops,
                    &mut events,
                );
                return events;
            };
            self.next_generation = next;
            let generation = PipeWireGeneration(self.next_generation);
            match ops.connect(generation) {
                Ok(()) => {
                    self.connection = ConnectionState::Connected;
                    self.registry = RegistrySnapshot::new(generation);
                }
                Err(failure) => {
                    self.fail_connection(now, &active, failure, ops, &mut events);
                    return events;
                }
            }
        }
        match ops.observe() {
            Ok(snapshot) => self.registry.update_observations(snapshot),
            Err(failure) => {
                self.fail_connection(now, &active, failure, ops, &mut events);
                return events;
            }
        }
        update(&mut self.registry);
        for (capture, source) in active {
            let graph = self
                .captures
                .entry(capture)
                .or_insert_with(|| CaptureGraph::new(source, PipeWireGeneration(self.epoch)));
            if now < graph.retry_at {
                continue;
            }
            let result = graph.reconcile(
                ReconcileContext {
                    capture,
                    snapshot: &self.registry,
                    tag: &self.owner_tag,
                    now,
                    epoch: &mut self.epoch,
                },
                ops,
            );
            let state = match result {
                Ok(state) => state,
                Err(failure) => {
                    graph.teardown(ops);
                    graph.retry_at = now.saturating_add(self.retry_interval);
                    unavailable(failure.reason, &failure.detail)
                }
            };
            if matches!(state, CaptureState::Active { .. })
                && let Some((object, _)) = graph.monitor
                && let Some(event) = ops.publish_transport(object, capture)
            {
                events.push(event);
            }
            self.source_epochs.insert(capture, graph.epoch);
            if self.states.get(&capture) != Some(&state) {
                events.push(state_event(capture, graph.epoch.0, state.clone()));
                self.states.insert(capture, state);
            }
        }
        events
    }

    fn fail_connection(
        &mut self,
        now: Duration,
        active: &BTreeMap<CaptureId, Source>,
        failure: GraphFailure,
        ops: &mut dyn GraphOps,
        events: &mut Vec<AudioBackendEvent>,
    ) {
        for graph in self.captures.values_mut() {
            graph.teardown(ops);
        }
        self.captures.clear();
        if matches!(self.connection, ConnectionState::Connected) {
            ops.disconnect();
        }
        self.connection = ConnectionState::Disconnected {
            retry_at: now.saturating_add(self.retry_interval),
        };
        self.registry = RegistrySnapshot::new(PipeWireGeneration(self.next_generation));
        if let Some(epoch) = self.epoch.checked_add(1) {
            self.epoch = epoch;
        } else {
            self.exhausted = true;
        }
        for capture in active.keys() {
            let state = unavailable(failure.reason, &failure.detail);
            self.source_epochs
                .insert(*capture, PipeWireGeneration(self.epoch));
            events.push(state_event(*capture, self.epoch, state.clone()));
            self.states.insert(*capture, state);
        }
    }
}

#[derive(Clone, Copy)]
enum ConnectionState {
    Disconnected { retry_at: Duration },
    Connected,
}
struct CaptureGraph {
    source: Source,
    epoch: PipeWireGeneration,
    adapter: Option<GraphObjectId>,
    monitor: Option<(GraphObjectId, NodeIdentity)>,
    links: BTreeMap<AdditiveLink, GraphObjectId>,
    retry_at: Duration,
}
struct ReconcileContext<'a> {
    capture: CaptureId,
    snapshot: &'a RegistrySnapshot,
    tag: &'a str,
    now: Duration,
    epoch: &'a mut u64,
}
impl CaptureGraph {
    fn new(source: Source, epoch: PipeWireGeneration) -> Self {
        Self {
            source,
            epoch,
            adapter: None,
            monitor: None,
            links: BTreeMap::new(),
            retry_at: Duration::ZERO,
        }
    }
    fn teardown(&mut self, ops: &mut dyn GraphOps) {
        self.remove_monitor(ops);
        if let Some(object) = self.adapter.take() {
            ops.remove(object);
        }
    }
    fn remove_monitor(&mut self, ops: &mut dyn GraphOps) {
        for object in std::mem::take(&mut self.links).into_values() {
            ops.remove(object);
        }
        if let Some((object, _)) = self.monitor.take() {
            ops.remove(object);
        }
    }
    fn reconcile(
        &mut self,
        context: ReconcileContext<'_>,
        ops: &mut dyn GraphOps,
    ) -> Result<CaptureState, GraphFailure> {
        let ReconcileContext {
            capture,
            snapshot,
            tag,
            now,
            epoch,
        } = context;
        for object in self
            .adapter
            .iter()
            .copied()
            .chain(self.links.values().copied())
            .chain(self.monitor.map(|monitor| monitor.0))
        {
            if let GraphObjectState::Unavailable { reason, detail } = ops.state(object) {
                return Err(GraphFailure { reason, detail });
            }
        }
        let name = format!("{tag}.mixer.{}", capture.0);
        if matches!(self.source, Source::Process(_)) && self.adapter.is_none() {
            self.adapter = Some(ops.create_adapter(&name)?);
        }
        let mixers: Vec<_> = snapshot
            .nodes
            .values()
            .filter(|node| node.kind == NodeKind::Owned && node.name == name)
            .collect();
        if mixers.len() > 1 {
            return Err(GraphFailure::graph("capture mixer name is ambiguous"));
        }
        let mixer = mixers.first().map(|node| node.identity);
        let plan = plan_graph(self.source, snapshot, mixer.map(|identity| identity.global));
        if !matches!(plan.state, CaptureState::Active { .. }) {
            self.remove_monitor(ops);
            return Ok(plan.state);
        }
        let target = match plan.monitor {
            Some(MonitorTarget::Sink(identity)) => Some(identity),
            Some(MonitorTarget::ProcessMixer) => mixer,
            None => None,
        };
        if self
            .monitor
            .is_some_and(|(_, identity)| Some(identity) != target)
        {
            self.remove_monitor(ops);
        }
        if self.monitor.is_none()
            && let Some(target) = target
        {
            *epoch = epoch
                .checked_add(1)
                .ok_or_else(|| GraphFailure::graph("monitor generation space exhausted"))?;
            let generation = PipeWireGeneration(*epoch);
            self.epoch = generation;
            self.monitor = Some((ops.create_monitor(capture, target, generation)?, target));
        }
        let removed: BTreeSet<_> = self
            .links
            .keys()
            .filter(|link| !plan.links.contains(*link))
            .cloned()
            .collect();
        for link in removed {
            if let Some(object) = self.links.remove(&link) {
                ops.remove(object);
            }
        }
        for link in plan.links {
            if !self.links.contains_key(&link)
                && let Some(mixer) = mixer
            {
                self.links
                    .insert(link.clone(), ops.create_link(mixer, &link)?);
            }
        }
        self.retry_at = now;
        let Some((monitor, _)) = self.monitor else {
            return Ok(CaptureState::Starting);
        };
        for object in self
            .adapter
            .iter()
            .copied()
            .chain(self.links.values().copied())
        {
            match ops.state(object) {
                GraphObjectState::Starting => return Ok(CaptureState::Starting),
                GraphObjectState::Unavailable { reason, detail } => {
                    return Err(GraphFailure { reason, detail });
                }
                GraphObjectState::Streaming => {}
            }
        }
        match ops.state(monitor) {
            GraphObjectState::Starting => Ok(CaptureState::Starting),
            GraphObjectState::Streaming => Ok(plan.state),
            GraphObjectState::Unavailable { reason, detail } => {
                Err(GraphFailure { reason, detail })
            }
        }
    }
}
fn unavailable(reason: UnavailableReason, detail: &str) -> CaptureState {
    CaptureState::Unavailable {
        reason,
        detail: detail.into(),
    }
}
fn state_event(capture: CaptureId, epoch: u64, state: CaptureState) -> AudioBackendEvent {
    AudioBackendEvent::State {
        capture,
        generation: PipeWireGeneration(epoch),
        state,
    }
}

#[cfg(test)]
mod tests;
