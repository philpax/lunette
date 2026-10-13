//! Registry lifetimes, attribution assertions, and pure non-routing graph decisions.

use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};

use lunette_compositor::protocol::{
    AudioAttributionReply, AudioAttributionRequest, AudioAttributionRequestId, AudioNodeSerial,
    Pid, PipeWireGeneration, ProcessId, ProcessInstance, ProcessObservation,
};

use crate::audio::{
    AttributionProvenance, AudioProcessCandidate, CaptureState, Source, UnavailableReason,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct NodeIdentity {
    pub generation: PipeWireGeneration,
    pub serial: AudioNodeSerial,
    pub global: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct PortIdentity {
    pub global: u32,
    pub serial: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClientIdentity {
    pub generation: PipeWireGeneration,
    pub serial: u64,
    pub global: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClientKind {
    Native,
    Pulse,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClientObservation {
    pub identity: ClientIdentity,
    pub pid: Option<Pid>,
    pub kind: ClientKind,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NodeKind {
    Sink,
    Playback,
    Owned,
    Other,
}
#[derive(Clone, Debug)]
pub struct NodeObservation {
    pub identity: NodeIdentity,
    pub name: String,
    pub kind: NodeKind,
    pub client: Option<u32>,
    pub application_pid: Option<Pid>,
    pub client_api: Option<String>,
}
#[derive(Clone, Debug)]
pub struct PortObservation {
    pub identity: PortIdentity,
    pub node: u32,
    pub output: bool,
    pub channel: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DefaultSink {
    Missing,
    Invalid,
    Name(String),
}

/// Records the live registry assertions used by one attribution attempt. A
/// reusable client global id alone cannot identify the asserting client.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PidAssertion {
    pub node: NodeIdentity,
    pub client: Option<ClientIdentity>,
    pub pid: Pid,
    pub provenance: AttributionProvenance,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AssertionStatus {
    Missing,
    Ambiguous,
    Live(PidAssertion),
}

#[derive(Clone, Debug)]
pub struct RegistrySnapshot {
    pub generation: PipeWireGeneration,
    pub nodes: BTreeMap<u32, NodeObservation>,
    pub ports: BTreeMap<u32, PortObservation>,
    pub clients: BTreeMap<u32, ClientObservation>,
    pub default_sink: DefaultSink,
    pub attributions: BTreeMap<AudioNodeSerial, (ProcessId, AttributionProvenance)>,
    attempts: BTreeMap<AudioNodeSerial, AttributionAttempt>,
    instances: BTreeMap<AudioNodeSerial, (NodeIdentity, ProcessInstance)>,
    next_request: u64,
    attribution_time: Duration,
    attribution_retry: Duration,
}

impl RegistrySnapshot {
    pub fn new(generation: PipeWireGeneration) -> Self {
        Self {
            generation,
            nodes: BTreeMap::new(),
            ports: BTreeMap::new(),
            clients: BTreeMap::new(),
            default_sink: DefaultSink::Missing,
            attributions: BTreeMap::new(),
            attempts: BTreeMap::new(),
            instances: BTreeMap::new(),
            next_request: 0,
            attribution_time: Duration::ZERO,
            attribution_retry: Duration::from_millis(500),
        }
    }

    /// Retains the pinned instance for the complete node lifetime. Mutable client
    /// and PID assertions invalidate requests, but cannot clear instance history.
    pub fn update_observations(&mut self, mut incoming: Self) {
        if self.generation != incoming.generation {
            *self = incoming;
            return;
        }
        self.instances.retain(|_, (identity, _)| {
            incoming
                .nodes
                .get(&identity.global)
                .is_some_and(|node| node.identity == *identity)
        });
        self.attempts.retain(|serial, attempt| {
            incoming.assertion(*serial) == AssertionStatus::Live(attempt.assertion)
        });
        incoming.instances = std::mem::take(&mut self.instances);
        self.attributions
            .retain(|serial, _| self.attempts.contains_key(serial));
        incoming.attempts = std::mem::take(&mut self.attempts);
        incoming.attributions = std::mem::take(&mut self.attributions);
        incoming.next_request = self.next_request;
        incoming.attribution_time = self.attribution_time;
        incoming.attribution_retry = self.attribution_retry;
        *self = incoming;
    }

    pub fn remove(&mut self, global: u32) {
        if let Some(node) = self.nodes.remove(&global) {
            self.invalidate_attribution(node.identity.serial);
            self.instances.remove(&node.identity.serial);
            self.ports.retain(|_, port| port.node != global);
        }
        self.ports.remove(&global);
        if self.clients.remove(&global).is_some() {
            let serials: Vec<_> = self
                .nodes
                .values()
                .filter(|node| node.client == Some(global))
                .map(|node| node.identity.serial)
                .collect();
            for serial in serials {
                self.invalidate_attribution(serial);
            }
        }
    }

    pub fn assertion(&self, serial: AudioNodeSerial) -> AssertionStatus {
        let Some(node) = self
            .nodes
            .values()
            .find(|node| node.identity.serial == serial && node.kind == NodeKind::Playback)
        else {
            return AssertionStatus::Missing;
        };
        let client = node.client.and_then(|id| self.clients.get(&id));
        if node.client.is_some() && client.is_none() {
            return AssertionStatus::Missing;
        }
        let pulse = client.is_some_and(|client| client.kind == ClientKind::Pulse)
            || node.client_api.as_deref() == Some("pipewire-pulse");
        let (pid, provenance) = match (client, node.application_pid) {
            (Some(_), Some(pid)) if pulse => (pid, AttributionProvenance::ApplicationMetadata),
            // A Pulse client's security PID is the pipewire-pulse daemon's own,
            // so only the node's application metadata can name the producer.
            (Some(_), None) if pulse => return AssertionStatus::Missing,
            (Some(client), metadata) => match client.pid {
                Some(pid) if metadata.is_none_or(|metadata| metadata == pid) => {
                    (pid, AttributionProvenance::PipeWireClient)
                }
                Some(_) if metadata.is_some() => return AssertionStatus::Ambiguous,
                _ => return AssertionStatus::Missing,
            },
            (None, Some(pid)) => (pid, AttributionProvenance::ApplicationMetadata),
            _ => return AssertionStatus::Missing,
        };
        AssertionStatus::Live(PidAssertion {
            node: node.identity,
            client: client.map(|client| client.identity),
            pid,
            provenance,
        })
    }

    /// Advances delivery deadlines without clearing the node's pinned OS instance.
    /// A timeout only permits a fresh observation; it never authorizes PID reuse.
    pub fn attribution_tick(&mut self, now: Duration, retry: Duration) {
        self.attribution_time = self.attribution_time.max(now);
        self.attribution_retry = retry;
        for attempt in self.attempts.values_mut() {
            if let AttemptState::Pending { retry_at, .. } = attempt.state
                && self.attribution_time >= retry_at
            {
                attempt.state = AttemptState::Ready;
            }
        }
    }

    pub fn process_candidates(&self) -> Vec<AudioProcessCandidate> {
        self.nodes
            .values()
            .filter_map(|node| {
                let AssertionStatus::Live(assertion) = self.assertion(node.identity.serial) else {
                    return None;
                };
                if let Some(attempt) = self.attempts.get(&node.identity.serial)
                    && attempt.assertion == assertion
                    && !matches!(attempt.state, AttemptState::Ready)
                {
                    return None;
                }
                Some(AudioProcessCandidate {
                    generation: self.generation,
                    node: node.identity.serial,
                    pid: assertion.pid,
                    assertion,
                })
            })
            .collect()
    }

    pub fn observe_process(
        &mut self,
        candidate: AudioProcessCandidate,
        observation: ProcessObservation,
    ) -> Option<AudioAttributionRequest> {
        if candidate.generation != self.generation {
            return None;
        }
        let AssertionStatus::Live(assertion) = self.assertion(candidate.node) else {
            return None;
        };
        if assertion.pid != candidate.pid || assertion != candidate.assertion {
            return None;
        }
        if self
            .attempts
            .get(&candidate.node)
            .is_some_and(|attempt| attempt.assertion != assertion)
        {
            self.invalidate_attribution(candidate.node);
        }
        let instance = observation.instance()?;
        if instance.pid() != assertion.pid {
            return None;
        }
        if self
            .instances
            .get(&candidate.node)
            .is_some_and(|(_, pinned)| *pinned != instance)
        {
            if let Some(attempt) = self.attempts.get_mut(&candidate.node) {
                attempt.state = AttemptState::Blocked;
            }
            self.attributions.remove(&candidate.node);
            return None;
        }
        self.instances
            .insert(candidate.node, (assertion.node, instance));
        if let Some(attempt) = self.attempts.get_mut(&candidate.node) {
            if attempt.instance != instance {
                attempt.state = AttemptState::Blocked;
                self.attributions.remove(&candidate.node);
                return None;
            }
            if !matches!(attempt.state, AttemptState::Ready) {
                return None;
            }
        }
        let request = AudioAttributionRequest {
            request: AudioAttributionRequestId(self.next_request),
            generation: self.generation,
            node: candidate.node,
            candidate: instance,
        };
        self.next_request = self.next_request.checked_add(1)?;
        self.attempts.insert(
            candidate.node,
            AttributionAttempt {
                assertion,
                instance,
                state: AttemptState::Pending {
                    request,
                    retry_at: self.attribution_time.saturating_add(self.attribution_retry),
                },
            },
        );
        Some(request)
    }

    pub fn cancel_attribution(&mut self, request: AudioAttributionRequest) {
        if let Some(attempt) = self.attempts.get_mut(&request.node)
            && matches!(attempt.state, AttemptState::Pending { request: pending, .. } if pending == request)
        {
            attempt.state = AttemptState::Ready;
        }
    }

    pub fn invalidate_attribution(&mut self, serial: AudioNodeSerial) {
        self.attempts.remove(&serial);
        self.attributions.remove(&serial);
    }

    /// The caller obtains this new observation on the worker immediately before
    /// consuming the reply. Neither its cached PID nor its old stat is sufficient.
    pub fn attribution_reply(
        &mut self,
        reply: AudioAttributionReply,
        current: ProcessObservation,
    ) -> bool {
        let Some(attempt) = self.attempts.get(&reply.request.node).copied() else {
            return false;
        };
        if reply.request.generation != self.generation
            || !matches!(attempt.state, AttemptState::Pending { request, .. } if request == reply.request)
            || self.assertion(reply.request.node) != AssertionStatus::Live(attempt.assertion)
        {
            return false;
        }
        match current {
            ProcessObservation::Live { instance, .. } if instance == attempt.instance => {}
            ProcessObservation::Unavailable(_) => {
                self.cancel_attribution(reply.request);
                return false;
            }
            _ => {
                if let Some(attempt) = self.attempts.get_mut(&reply.request.node) {
                    attempt.state = AttemptState::Blocked;
                }
                self.attributions.remove(&reply.request.node);
                return false;
            }
        }
        if let Some(process) = reply.process {
            self.attributions
                .insert(reply.request.node, (process, attempt.assertion.provenance));
        }
        if let Some(attempt) = self.attempts.get_mut(&reply.request.node) {
            attempt.state = if reply.process.is_some() {
                AttemptState::Resolved
            } else {
                AttemptState::Ready
            };
        }
        true
    }

    pub fn known_instances(&self) -> Vec<(AudioNodeSerial, ProcessInstance)> {
        self.attempts
            .iter()
            .filter(|(_, attempt)| matches!(attempt.state, AttemptState::Resolved))
            .map(|(serial, attempt)| (*serial, attempt.instance))
            .collect()
    }
    pub fn revalidate_instance(&mut self, serial: AudioNodeSerial, current: ProcessObservation) {
        let Some(attempt) = self.attempts.get_mut(&serial) else {
            return;
        };
        if current.instance() == Some(attempt.instance) {
            return;
        }
        self.attributions.remove(&serial);
        attempt.state = match current {
            ProcessObservation::Unavailable(_) => AttemptState::Ready,
            _ => AttemptState::Blocked,
        };
    }
}

#[derive(Clone, Copy, Debug)]
struct AttributionAttempt {
    assertion: PidAssertion,
    instance: ProcessInstance,
    state: AttemptState,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AttemptState {
    Ready,
    Pending {
        request: AudioAttributionRequest,
        retry_at: Duration,
    },
    Resolved,
    Blocked,
}

pub fn parse_default_sink(value: Option<&str>) -> DefaultSink {
    let Some(value) = value else {
        return DefaultSink::Missing;
    };
    match serde_json::from_str::<serde_json::Value>(value) {
        Ok(json) => match json.get("name").and_then(serde_json::Value::as_str) {
            Some(name) if !name.is_empty() && !name.contains('\0') => {
                DefaultSink::Name(name.to_owned())
            }
            _ => DefaultSink::Invalid,
        },
        Err(_) => DefaultSink::Invalid,
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MonitorTarget {
    Sink(NodeIdentity),
    ProcessMixer,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphPlan {
    pub monitor: Option<MonitorTarget>,
    pub links: BTreeSet<AdditiveLink>,
    pub state: CaptureState,
}
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct AdditiveLink {
    pub output_node: NodeIdentity,
    pub output_port: PortIdentity,
    pub input_port: PortIdentity,
}

pub fn plan_graph(source: Source, registry: &RegistrySnapshot, mixer: Option<u32>) -> GraphPlan {
    match source {
        Source::System => plan_system(registry),
        Source::Process(process) => plan_process(process, registry, mixer),
    }
}
fn plan_system(registry: &RegistrySnapshot) -> GraphPlan {
    let name = match &registry.default_sink {
        DefaultSink::Missing => {
            return unavailable(
                UnavailableReason::NoDefaultSink,
                "default sink metadata is absent",
            );
        }
        DefaultSink::Invalid => {
            return unavailable(
                UnavailableReason::InvalidDefaultSink,
                "default sink metadata is invalid",
            );
        }
        DefaultSink::Name(name) => name,
    };
    let mut sinks = registry
        .nodes
        .values()
        .filter(|node| node.kind == NodeKind::Sink && &node.name == name);
    let Some(sink) = sinks.next() else {
        return unavailable(
            UnavailableReason::NoDefaultSink,
            "default sink has no live audio sink",
        );
    };
    if sinks.next().is_some() {
        return unavailable(
            UnavailableReason::InvalidDefaultSink,
            "default sink name is ambiguous",
        );
    }
    GraphPlan {
        monitor: Some(MonitorTarget::Sink(sink.identity)),
        links: BTreeSet::new(),
        state: CaptureState::Active { provenance: None },
    }
}
fn plan_process(process: ProcessId, registry: &RegistrySnapshot, mixer: Option<u32>) -> GraphPlan {
    let inputs: Vec<_> = registry
        .ports
        .values()
        .filter(|port| Some(port.node) == mixer && !port.output)
        .collect();
    let mut links = BTreeSet::new();
    let mut provenance = None;
    let mut attributed = false;
    let mut incomplete = false;
    for node in registry
        .nodes
        .values()
        .filter(|node| node.kind == NodeKind::Playback)
    {
        let Some((owner, origin)) = registry.attributions.get(&node.identity.serial) else {
            continue;
        };
        if *owner != process {
            continue;
        }
        attributed = true;
        provenance = Some(match (provenance, origin) {
            (Some(AttributionProvenance::ApplicationMetadata), _)
            | (_, AttributionProvenance::ApplicationMetadata) => {
                AttributionProvenance::ApplicationMetadata
            }
            _ => AttributionProvenance::PipeWireClient,
        });
        let outputs: Vec<_> = registry
            .ports
            .values()
            .filter(|port| port.node == node.identity.global && port.output)
            .collect();
        incomplete |= outputs.is_empty() || mixer.is_none() || inputs.is_empty();
        for output in outputs {
            let Some(channels) = downmix_channels(&output.channel) else {
                return unavailable(
                    UnavailableReason::UnsupportedFormat,
                    "playback channel has no defined stereo downmix",
                );
            };
            if mixer.is_none() || inputs.is_empty() {
                continue;
            }
            for channel in channels {
                let mut matching = inputs.iter().filter(|input| input.channel == *channel);
                let Some(input) = matching.next() else {
                    return unavailable(
                        UnavailableReason::UnsupportedFormat,
                        "capture mixer lacks a required stereo input",
                    );
                };
                if matching.next().is_some() {
                    return unavailable(
                        UnavailableReason::UnsupportedFormat,
                        "capture mixer input channel is ambiguous",
                    );
                }
                links.insert(AdditiveLink {
                    output_node: node.identity,
                    output_port: output.identity,
                    input_port: input.identity,
                });
            }
        }
    }
    let state = if attributed && incomplete {
        CaptureState::Starting
    } else if !links.is_empty() {
        CaptureState::Active { provenance }
    } else if registry.nodes.values().any(|node| {
        node.kind == NodeKind::Playback
            && !registry.attributions.contains_key(&node.identity.serial)
    }) {
        CaptureState::Unavailable {
            reason: UnavailableReason::UnresolvedAttribution,
            detail: "audio producers are not attributed to this process".into(),
        }
    } else {
        CaptureState::Idle
    };
    GraphPlan {
        monitor: Some(MonitorTarget::ProcessMixer),
        links,
        state,
    }
}
/// This is a defined unity-gain fold, not a position approximation: left channels
/// sum into FL, right channels into FR, and centre/mono/LFE channels into both.
/// Unknown/AUX positions fail the complete source instead of dropping channels.
fn downmix_channels(channel: &str) -> Option<&'static [&'static str]> {
    match channel {
        "FL" | "RL" | "SL" | "FLC" | "TFL" | "TRL" => Some(&["FL"]),
        "FR" | "RR" | "SR" | "FRC" | "TFR" | "TRR" => Some(&["FR"]),
        "MONO" | "FC" | "RC" | "LFE" | "LFE2" | "TC" | "TFC" | "TRC" => Some(&["FL", "FR"]),
        _ => None,
    }
}
fn unavailable(reason: UnavailableReason, detail: &str) -> GraphPlan {
    GraphPlan {
        monitor: None,
        links: BTreeSet::new(),
        state: CaptureState::Unavailable {
            reason,
            detail: detail.into(),
        },
    }
}

#[cfg(test)]
mod tests;
