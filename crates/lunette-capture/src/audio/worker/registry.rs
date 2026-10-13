//! Linux-only: receives PipeWire registry lifetimes and live property updates.

use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

use lunette_compositor::protocol::{AudioNodeSerial, Pid, PipeWireGeneration};
use pipewire::{self as pw, properties::properties, spa::utils::dict::DictRef};

use crate::audio::{
    ClientIdentity, ClientKind, ClientObservation, GraphFailure, NodeIdentity, NodeKind,
    NodeObservation, PortIdentity, PortObservation, RegistrySnapshot, UnavailableReason,
    parse_default_sink, worker::PipeWireAudioConfig,
};

pub(super) struct Session {
    _registry_listener: pw::registry::Listener,
    _core_listener: pw::core::Listener,
    _bindings: Rc<RefCell<BTreeMap<u32, Binding>>>,
    pub(super) registry: Rc<RefCell<RegistrySnapshot>>,
    pub(super) failure: Rc<RefCell<Option<GraphFailure>>>,
    pub(super) core: pw::core::CoreRc,
    pub(super) main_loop: pw::main_loop::MainLoopRc,
}

impl Session {
    pub(super) fn new(
        config: &PipeWireAudioConfig,
        generation: PipeWireGeneration,
    ) -> Result<Self, GraphFailure> {
        let main_loop = pw::main_loop::MainLoopRc::new(None).map_err(no_server)?;
        let context = pw::context::ContextRc::new(&main_loop, None).map_err(no_server)?;
        let mut props = properties! { "application.name" => "lunette audio capture" };
        if let Some(remote) = &config.remote_name {
            props.insert("remote.name", remote.as_str());
        }
        let core = context.connect_rc(Some(props)).map_err(no_server)?;
        let pw_registry = core.get_registry_rc().map_err(no_server)?;
        let registry = Rc::new(RefCell::new(RegistrySnapshot::new(generation)));
        let bindings = Rc::new(RefCell::new(BTreeMap::new()));
        let failure = Rc::new(RefCell::new(None));
        let failed = failure.clone();
        let core_listener = core
            .add_listener_local()
            .error(move |_, _, code, detail| {
                let reason = if code == -libc::EACCES || code == -libc::EPERM {
                    UnavailableReason::PermissionDenied
                } else if code == -libc::EPIPE || code == -libc::ECONNRESET || code == -libc::ENOENT
                {
                    UnavailableReason::NoServer
                } else {
                    UnavailableReason::GraphFailure
                };
                *failed.borrow_mut() = Some(GraphFailure {
                    reason,
                    detail: detail.into(),
                });
            })
            .register();
        let snapshot = registry.clone();
        let bound = bindings.clone();
        let bind_registry = pw_registry.clone();
        let tag = config.owner_tag.clone();
        let removed_snapshot = registry.clone();
        let removed_bindings = bindings.clone();
        let bind_failure = failure.clone();
        let registry_listener = pw_registry
            .add_listener_local()
            .global(move |global| {
                let Some(props) = global.props else { return };
                let id = global.id;
                let result = match global.type_ {
                    pw::types::ObjectType::Metadata
                        if props.get("metadata.name") == Some("default") =>
                    {
                        bind_registry
                            .bind::<pw::metadata::Metadata, _>(global)
                            .map(|proxy| {
                                let state = snapshot.clone();
                                let listener = proxy
                                    .add_listener_local()
                                    .property(move |subject, key, _, value| {
                                        if subject == 0
                                            && (key == Some("default.audio.sink") || key.is_none())
                                        {
                                            state.borrow_mut().default_sink =
                                                parse_default_sink(if key.is_none() {
                                                    None
                                                } else {
                                                    value
                                                });
                                        }
                                        0
                                    })
                                    .register();
                                Binding::Metadata {
                                    _listener: listener,
                                    _proxy: proxy,
                                }
                            })
                    }
                    pw::types::ObjectType::Node => {
                        update_node(&mut snapshot.borrow_mut(), id, props, &tag);
                        if snapshot
                            .borrow()
                            .nodes
                            .get(&id)
                            .is_some_and(|node| node.kind == NodeKind::Other)
                        {
                            return;
                        }
                        bind_registry
                            .bind::<pw::node::Node, _>(global)
                            .map(|proxy| {
                                let state = snapshot.clone();
                                let owner = tag.clone();
                                let listener = proxy
                                    .add_listener_local()
                                    .info(move |info| {
                                        node_info(
                                            &mut state.borrow_mut(),
                                            id,
                                            info.change_mask(),
                                            info.props(),
                                            &owner,
                                        );
                                    })
                                    .register();
                                Binding::Node {
                                    _listener: listener,
                                    _proxy: proxy,
                                }
                            })
                    }
                    pw::types::ObjectType::Client => {
                        update_client(&mut snapshot.borrow_mut(), id, props);
                        bind_registry
                            .bind::<pw::client::Client, _>(global)
                            .map(|proxy| {
                                let state = snapshot.clone();
                                let listener = proxy
                                    .add_listener_local()
                                    .info(move |info| {
                                        client_info(
                                            &mut state.borrow_mut(),
                                            id,
                                            info.change_mask(),
                                            info.props(),
                                        );
                                    })
                                    .register();
                                Binding::Client {
                                    _listener: listener,
                                    _proxy: proxy,
                                }
                            })
                    }
                    pw::types::ObjectType::Port => {
                        update_port(&mut snapshot.borrow_mut(), id, props);
                        bind_registry
                            .bind::<pw::port::Port, _>(global)
                            .map(|proxy| {
                                let state = snapshot.clone();
                                let listener = proxy
                                    .add_listener_local()
                                    .info(move |info| {
                                        port_info(
                                            &mut state.borrow_mut(),
                                            id,
                                            info.change_mask(),
                                            info.props(),
                                        );
                                    })
                                    .register();
                                Binding::Port {
                                    _listener: listener,
                                    _proxy: proxy,
                                }
                            })
                    }
                    _ => return,
                };
                match result {
                    Ok(binding) => {
                        bound.borrow_mut().insert(id, binding);
                    }
                    Err(error) => {
                        *bind_failure.borrow_mut() = Some(GraphFailure::graph(format!(
                            "registry global {id}: {error}"
                        )));
                    }
                }
            })
            .global_remove(move |id| {
                let metadata = matches!(
                    removed_bindings.borrow_mut().remove(&id),
                    Some(Binding::Metadata { .. })
                );
                let mut snapshot = removed_snapshot.borrow_mut();
                snapshot.remove(id);
                if metadata {
                    snapshot.default_sink = parse_default_sink(None);
                }
            })
            .register();
        Ok(Self {
            _registry_listener: registry_listener,
            _core_listener: core_listener,
            _bindings: bindings,
            registry,
            failure,
            core,
            main_loop,
        })
    }
}

enum Binding {
    Metadata {
        _listener: pw::metadata::MetadataListener,
        _proxy: pw::metadata::Metadata,
    },
    Node {
        _listener: pw::node::NodeListener,
        _proxy: pw::node::Node,
    },
    Client {
        _listener: pw::client::ClientListener,
        _proxy: pw::client::Client,
    },
    Port {
        _listener: pw::port::PortListener,
        _proxy: pw::port::Port,
    },
}
fn no_server(error: pw::Error) -> GraphFailure {
    GraphFailure {
        reason: UnavailableReason::NoServer,
        detail: error.to_string(),
    }
}

#[cfg(test)]
#[path = "registry/tests.rs"]
mod tests;

// PipeWire sends an info event's property dictionary only when the change mask
// names properties. A state or parameter change carries an empty dictionary,
// which describes nothing and must not clear the properties already observed.
fn node_info(
    snapshot: &mut RegistrySnapshot,
    id: u32,
    mask: pw::node::NodeChangeMask,
    props: Option<&DictRef>,
    tag: &str,
) {
    if mask.contains(pw::node::NodeChangeMask::PROPS)
        && let Some(props) = props
    {
        update_node(snapshot, id, props, tag);
    }
}
fn client_info(
    snapshot: &mut RegistrySnapshot,
    id: u32,
    mask: pw::client::ClientChangeMask,
    props: Option<&DictRef>,
) {
    if mask.contains(pw::client::ClientChangeMask::PROPS)
        && let Some(props) = props
    {
        update_client(snapshot, id, props);
    }
}
fn port_info(
    snapshot: &mut RegistrySnapshot,
    id: u32,
    mask: pw::port::PortChangeMask,
    props: Option<&DictRef>,
) {
    if mask.contains(pw::port::PortChangeMask::PROPS)
        && let Some(props) = props
    {
        update_port(snapshot, id, props);
    }
}

// A property dictionary that an info event marks as changed is authoritative for
// mutable properties. Object serial and port parent identify their lifetime and
// can be absent from later info dictionaries.
fn update_node(snapshot: &mut RegistrySnapshot, id: u32, props: &DictRef, tag: &str) {
    let old = snapshot.nodes.get(&id);
    let Some(serial) = props
        .get("object.serial")
        .and_then(|v| v.parse().ok())
        .or_else(|| old.map(|node| node.identity.serial.0))
    else {
        return;
    };
    let kind = if props.get("lunette.audio.owner") == Some(tag) {
        NodeKind::Owned
    } else {
        match props.get("media.class") {
            Some("Audio/Sink") => NodeKind::Sink,
            Some("Stream/Output/Audio") => NodeKind::Playback,
            _ => NodeKind::Other,
        }
    };
    let node = NodeObservation {
        identity: NodeIdentity {
            generation: snapshot.generation,
            serial: AudioNodeSerial(serial),
            global: id,
        },
        name: props.get("node.name").unwrap_or_default().to_owned(),
        kind,
        client: props.get("client.id").and_then(|value| value.parse().ok()),
        application_pid: props
            .get("application.process.id")
            .and_then(|value| value.parse().ok())
            .and_then(Pid::new),
        client_api: props.get("client.api").map(str::to_owned),
    };
    if old.is_some_and(|old| old.identity != node.identity) {
        snapshot.remove(id);
    }
    snapshot.nodes.insert(id, node);
}
fn update_client(snapshot: &mut RegistrySnapshot, id: u32, props: &DictRef) {
    let old = snapshot.clients.get(&id);
    let Some(serial) = props
        .get("object.serial")
        .and_then(|v| v.parse().ok())
        .or_else(|| old.map(|client| client.identity.serial))
    else {
        return;
    };
    // The Pulse protocol sets this marker on its native client properties.
    // application.name is display metadata and does not identify the protocol.
    let kind = if props.get("client.api") == Some("pipewire-pulse") {
        ClientKind::Pulse
    } else {
        ClientKind::Native
    };
    let client = ClientObservation {
        identity: ClientIdentity {
            generation: snapshot.generation,
            serial,
            global: id,
        },
        pid: props
            .get("pipewire.sec.pid")
            .and_then(|value| value.parse().ok())
            .and_then(Pid::new),
        kind,
    };
    snapshot.clients.insert(id, client);
}
fn update_port(snapshot: &mut RegistrySnapshot, id: u32, props: &DictRef) {
    let old = snapshot.ports.get(&id);
    let Some(node) = props
        .get("node.id")
        .and_then(|v| v.parse().ok())
        .or_else(|| old.map(|port| port.node))
    else {
        return;
    };
    let Some(serial) = props
        .get("object.serial")
        .and_then(|v| v.parse().ok())
        .or_else(|| old.map(|port| port.identity.serial))
    else {
        return;
    };
    snapshot.ports.insert(
        id,
        PortObservation {
            identity: PortIdentity { global: id, serial },
            node,
            output: props.get("port.direction") == Some("out"),
            channel: props.get("audio.channel").unwrap_or_default().to_owned(),
        },
    );
}
