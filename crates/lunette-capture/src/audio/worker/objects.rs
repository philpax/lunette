//! Linux-only: adapts owned PipeWire objects to the project graph boundary.

use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

use lunette_compositor::protocol::PipeWireGeneration;
use pipewire::{self as pw, properties::properties, proxy::ProxyT};

use crate::audio::{
    AdditiveLink, AudioBackendEvent, CaptureId, GraphFailure, GraphObjectId, GraphObjectState,
    GraphOps, NodeIdentity, RegistrySnapshot, UnavailableReason,
    worker::{PipeWireAudioConfig, registry::Session, stream::Monitor},
};

pub(super) struct PipeWireGraphOps {
    objects: BTreeMap<GraphObjectId, OwnedObject>,
    session: Option<Session>,
    config: PipeWireAudioConfig,
    next_object: u64,
}
impl PipeWireGraphOps {
    pub(super) fn new(config: PipeWireAudioConfig) -> Self {
        Self {
            objects: BTreeMap::new(),
            session: None,
            config,
            next_object: 0,
        }
    }
    pub(super) fn iterate(&self) {
        if let Some(session) = &self.session {
            session
                .main_loop
                .loop_()
                .iterate(pw::loop_::Timeout::Finite(self.config.poll_interval));
        }
    }
    pub(super) fn connected(&self) -> bool {
        self.session.is_some()
    }
    fn core(&self) -> Result<&pw::core::CoreRc, GraphFailure> {
        self.session
            .as_ref()
            .map(|session| &session.core)
            .ok_or(GraphFailure {
                reason: UnavailableReason::NoServer,
                detail: "no connected PipeWire core".into(),
            })
    }
    fn insert(&mut self, object: OwnedObject) -> Result<GraphObjectId, GraphFailure> {
        self.next_object = self
            .next_object
            .checked_add(1)
            .ok_or_else(|| GraphFailure::graph("owned object identifier space exhausted"))?;
        let id = GraphObjectId(self.next_object);
        self.objects.insert(id, object);
        Ok(id)
    }
}
impl GraphOps for PipeWireGraphOps {
    fn connect(&mut self, generation: PipeWireGeneration) -> Result<(), GraphFailure> {
        self.session = Some(Session::new(&self.config, generation)?);
        Ok(())
    }
    fn disconnect(&mut self) {
        self.objects.clear();
        self.session = None;
    }
    fn observe(&mut self) -> Result<RegistrySnapshot, GraphFailure> {
        let session = self.session.as_ref().ok_or(GraphFailure {
            reason: UnavailableReason::NoServer,
            detail: "no connected PipeWire core".into(),
        })?;
        if let Some(failure) = session.failure.borrow_mut().take() {
            return Err(failure);
        }
        Ok(session.registry.borrow().clone())
    }
    fn create_adapter(&mut self, name: &str) -> Result<GraphObjectId, GraphFailure> {
        let proxy = self.core()?.create_object::<pw::node::Node>("adapter", &properties! {
            "factory.name" => "support.null-audio-sink", "node.name" => name,
            "media.class" => "Stream/Input/Audio", "node.virtual" => "true", "node.autoconnect" => "false",
            "audio.position" => "[ FL FR ]", "audio.channels" => "2", "audio.rate" => "48000",
            "monitor.channel-volumes" => "false", "object.linger" => "false", "lunette.audio.owner" => self.config.owner_tag.as_str(),
            "adapter.auto-port-config" => "{ mode = dsp monitor = true position = preserve }"
        }).map_err(|error| GraphFailure::graph(error.to_string()))?;
        let owned = OwnedProxy::new(proxy);
        let status = owned.status.clone();
        let info = owned
            ._proxy
            .add_listener_local()
            .info(move |info| {
                *status.borrow_mut() = match info.state() {
                    pw::node::NodeState::Error(detail) => GraphObjectState::Unavailable {
                        reason: UnavailableReason::GraphFailure,
                        detail: detail.into(),
                    },
                    pw::node::NodeState::Creating => GraphObjectState::Starting,
                    _ => GraphObjectState::Streaming,
                };
            })
            .register();
        self.insert(OwnedObject::Adapter {
            proxy: owned,
            _info: info,
        })
    }
    fn create_monitor(
        &mut self,
        _capture: CaptureId,
        target: NodeIdentity,
        epoch: PipeWireGeneration,
    ) -> Result<GraphObjectId, GraphFailure> {
        let monitor =
            Monitor::new(self.core()?, target, &self.config, epoch).map_err(GraphFailure::graph)?;
        self.insert(OwnedObject::Monitor(monitor))
    }
    fn create_link(
        &mut self,
        mixer: NodeIdentity,
        link: &AdditiveLink,
    ) -> Result<GraphObjectId, GraphFailure> {
        let proxy = self.core()?.create_object::<pw::link::Link>("link-factory", &properties! {
            "link.output.node" => link.output_node.global.to_string(), "link.output.port" => link.output_port.global.to_string(),
            "link.input.node" => mixer.global.to_string(), "link.input.port" => link.input_port.global.to_string(),
            "object.linger" => "false", "link.passive" => "true", "lunette.audio.owner" => self.config.owner_tag.as_str()
        }).map_err(|error| GraphFailure::graph(error.to_string()))?;
        let owned = OwnedProxy::new(proxy);
        let status = owned.status.clone();
        let info = owned
            ._proxy
            .add_listener_local()
            .info(move |info| {
                *status.borrow_mut() = match info.state() {
                    pw::link::LinkState::Error(detail) => GraphObjectState::Unavailable {
                        reason: UnavailableReason::GraphFailure,
                        detail: detail.into(),
                    },
                    pw::link::LinkState::Paused | pw::link::LinkState::Active => {
                        GraphObjectState::Streaming
                    }
                    _ => GraphObjectState::Starting,
                };
            })
            .register();
        self.insert(OwnedObject::Link {
            proxy: owned,
            _info: info,
        })
    }
    fn state(&mut self, object: GraphObjectId) -> GraphObjectState {
        match self.objects.get(&object) {
            Some(OwnedObject::Adapter { proxy, .. }) => proxy.state(),
            Some(OwnedObject::Link { proxy, .. }) => proxy.state(),
            Some(OwnedObject::Monitor(monitor)) => monitor.state(),
            None => GraphObjectState::Unavailable {
                reason: UnavailableReason::GraphFailure,
                detail: "owned capture object no longer exists".into(),
            },
        }
    }
    fn remove(&mut self, object: GraphObjectId) {
        let Some(object) = self.objects.remove(&object) else {
            return;
        };
        let Some(session) = &self.session else { return };
        let result = match object {
            OwnedObject::Adapter { _info, proxy } => {
                drop(_info);
                session.core.destroy_object(proxy._proxy)
            }
            OwnedObject::Link { _info, proxy } => {
                drop(_info);
                session.core.destroy_object(proxy._proxy)
            }
            OwnedObject::Monitor(monitor) => {
                drop(monitor);
                return;
            }
        };
        if let Err(error) = result {
            *session.failure.borrow_mut() = Some(GraphFailure::graph(format!(
                "owned object removal: {error}"
            )));
        }
    }
    fn publish_transport(
        &mut self,
        object: GraphObjectId,
        capture: CaptureId,
    ) -> Option<AudioBackendEvent> {
        match self.objects.get_mut(&object) {
            Some(OwnedObject::Monitor(monitor)) => monitor.take_transport(capture),
            _ => None,
        }
    }
}

enum OwnedObject {
    Adapter {
        _info: pw::node::NodeListener,
        proxy: OwnedProxy<pw::node::Node>,
    },
    Monitor(Monitor),
    Link {
        _info: pw::link::LinkListener,
        proxy: OwnedProxy<pw::link::Link>,
    },
}
struct OwnedProxy<P: ProxyT> {
    _listener: pw::proxy::ProxyListener,
    _proxy: P,
    failure: Rc<RefCell<Option<GraphFailure>>>,
    status: Rc<RefCell<GraphObjectState>>,
}
impl<P: ProxyT> OwnedProxy<P> {
    fn new(proxy: P) -> Self {
        let failure = Rc::new(RefCell::new(None));
        let removed = failure.clone();
        let rejected = failure.clone();
        let listener = proxy
            .upcast_ref()
            .add_listener_local()
            .removed(move || {
                *removed.borrow_mut() =
                    Some(GraphFailure::graph("owned capture object was removed"));
            })
            .error(move |_, code, detail| {
                let reason = if code == -libc::EPERM || code == -libc::EACCES {
                    UnavailableReason::PermissionDenied
                } else {
                    UnavailableReason::GraphFailure
                };
                *rejected.borrow_mut() = Some(GraphFailure {
                    reason,
                    detail: format!("owned capture object error {code}: {detail}"),
                });
            })
            .register();
        Self {
            _listener: listener,
            _proxy: proxy,
            failure,
            status: Rc::new(RefCell::new(GraphObjectState::Starting)),
        }
    }
    fn state(&self) -> GraphObjectState {
        match self.failure.borrow().as_ref() {
            Some(failure) => GraphObjectState::Unavailable {
                reason: failure.reason,
                detail: failure.detail.clone(),
            },
            None => self.status.borrow().clone(),
        }
    }
}
