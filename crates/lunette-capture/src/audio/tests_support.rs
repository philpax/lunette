//! Shared deterministic graph observations for audio tests.

use lunette_compositor::protocol::{
    AudioNodeSerial, Pid, PipeWireGeneration, ProcessId, ProcessInstance, ProcessObservation,
};

use crate::audio::{
    AttributionProvenance, ClientIdentity, ClientKind, ClientObservation, DefaultSink,
    NodeIdentity, NodeKind, NodeObservation, PortIdentity, PortObservation, RegistrySnapshot,
};

pub(super) fn process() -> ProcessId {
    ProcessId::new(1).unwrap_or_else(|| unreachable!())
}
pub(super) fn pid() -> Pid {
    Pid::new(100).unwrap_or_else(|| unreachable!())
}
pub(super) fn live(start: u64) -> ProcessObservation {
    ProcessObservation::Live {
        instance: ProcessInstance::new(pid(), start),
        parent: None,
    }
}
pub(super) fn identity(global: u32) -> NodeIdentity {
    NodeIdentity {
        generation: PipeWireGeneration(1),
        serial: AudioNodeSerial(u64::from(global) + 1000),
        global,
    }
}
pub(super) fn node(snapshot: &mut RegistrySnapshot, global: u32, kind: NodeKind, name: &str) {
    snapshot.nodes.insert(
        global,
        NodeObservation {
            identity: identity(global),
            name: name.into(),
            kind,
            client: None,
            application_pid: None,
            client_api: None,
        },
    );
}
pub(super) fn port(
    snapshot: &mut RegistrySnapshot,
    global: u32,
    node: u32,
    output: bool,
    channel: &str,
) {
    snapshot.ports.insert(
        global,
        PortObservation {
            identity: PortIdentity {
                global,
                serial: u64::from(global) + 2000,
            },
            node,
            output,
            channel: channel.into(),
        },
    );
}
pub(super) fn system() -> RegistrySnapshot {
    let mut snapshot = RegistrySnapshot::new(PipeWireGeneration(1));
    node(&mut snapshot, 10, NodeKind::Sink, "speakers");
    node(&mut snapshot, 11, NodeKind::Sink, "headphones");
    node(&mut snapshot, 12, NodeKind::Other, "microphone");
    snapshot.default_sink = DefaultSink::Name("speakers".into());
    snapshot
}
pub(super) fn playback(snapshot: &mut RegistrySnapshot, global: u32, channels: &[&str]) {
    node(snapshot, global, NodeKind::Playback, "player");
    if let Some(node) = snapshot.nodes.get_mut(&global) {
        node.client = Some(40);
        node.application_pid = Some(pid());
    }
    snapshot.clients.insert(
        40,
        ClientObservation {
            identity: ClientIdentity {
                generation: snapshot.generation,
                serial: 4000,
                global: 40,
            },
            pid: Some(pid()),
            kind: ClientKind::Native,
        },
    );
    for (index, channel) in channels.iter().enumerate() {
        port(snapshot, global * 10 + index as u32, global, true, channel);
    }
}
pub(super) fn mixer(snapshot: &mut RegistrySnapshot) {
    node(snapshot, 90, NodeKind::Owned, "test.mixer.1");
    port(snapshot, 901, 90, false, "FL");
    port(snapshot, 902, 90, false, "FR");
}
pub(super) fn attribute(snapshot: &mut RegistrySnapshot, global: u32) {
    let serial = identity(global).serial;
    let Some(candidate) = snapshot
        .process_candidates()
        .into_iter()
        .find(|candidate| candidate.node == serial)
    else {
        unreachable!()
    };
    let Some(request) = snapshot.observe_process(candidate, live(1)) else {
        unreachable!()
    };
    assert!(snapshot.attribution_reply(
        lunette_compositor::protocol::AudioAttributionReply {
            request,
            process: Some(process())
        },
        live(1)
    ));
    assert_eq!(
        snapshot.attributions[&serial].1,
        AttributionProvenance::PipeWireClient
    );
}
