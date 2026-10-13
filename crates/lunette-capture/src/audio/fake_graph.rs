//! Recording graph operations for hardware-free production-driver tests.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use lunette_compositor::protocol::PipeWireGeneration;

use crate::audio::{
    AdditiveLink, AudioBackendEvent, CaptureId, GraphFailure, GraphObjectId, GraphObjectState,
    GraphOps, NodeIdentity, RegistrySnapshot,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordedGraphOperation {
    Connect(PipeWireGeneration),
    Disconnect,
    CreateAdapter {
        object: GraphObjectId,
        name: String,
    },
    CreateMonitor {
        object: GraphObjectId,
        capture: CaptureId,
        target: NodeIdentity,
        epoch: PipeWireGeneration,
    },
    CreateLink {
        object: GraphObjectId,
        mixer: NodeIdentity,
        link: AdditiveLink,
    },
    Remove(GraphObjectId),
}

/// Only owned capture objects are mutable through GraphOps. Existing host links
/// are retained separately so tests can assert that reconciliation preserves them.
pub struct RecordingGraphOps {
    pub snapshot: RegistrySnapshot,
    pub operations: Vec<RecordedGraphOperation>,
    pub host_links: BTreeSet<(u32, u32)>,
    pub connect_results: VecDeque<Result<(), GraphFailure>>,
    pub observation_errors: VecDeque<GraphFailure>,
    pub creation_errors: VecDeque<GraphFailure>,
    pub object_states: BTreeMap<GraphObjectId, GraphObjectState>,
    pub initial_state: GraphObjectState,
    next_object: u64,
}
impl RecordingGraphOps {
    pub fn new(snapshot: RegistrySnapshot) -> Self {
        Self {
            snapshot,
            operations: Vec::new(),
            host_links: BTreeSet::new(),
            connect_results: VecDeque::new(),
            observation_errors: VecDeque::new(),
            creation_errors: VecDeque::new(),
            object_states: BTreeMap::new(),
            initial_state: GraphObjectState::Streaming,
            next_object: 0,
        }
    }
    fn allocate(&mut self) -> Result<GraphObjectId, GraphFailure> {
        if let Some(error) = self.creation_errors.pop_front() {
            return Err(error);
        }
        self.next_object = self
            .next_object
            .checked_add(1)
            .ok_or_else(|| GraphFailure::graph("recording object identifier space exhausted"))?;
        let object = GraphObjectId(self.next_object);
        self.object_states
            .insert(object, self.initial_state.clone());
        Ok(object)
    }
}
impl GraphOps for RecordingGraphOps {
    fn connect(&mut self, generation: PipeWireGeneration) -> Result<(), GraphFailure> {
        self.operations
            .push(RecordedGraphOperation::Connect(generation));
        let result = self.connect_results.pop_front().unwrap_or(Ok(()));
        if result.is_ok() {
            self.snapshot.generation = generation;
            for node in self.snapshot.nodes.values_mut() {
                node.identity.generation = generation;
            }
            for client in self.snapshot.clients.values_mut() {
                client.identity.generation = generation;
            }
        }
        result
    }
    fn disconnect(&mut self) {
        assert!(
            self.object_states.is_empty(),
            "driver removes all owned objects before disconnect"
        );
        self.operations.push(RecordedGraphOperation::Disconnect);
    }
    fn observe(&mut self) -> Result<RegistrySnapshot, GraphFailure> {
        if let Some(error) = self.observation_errors.pop_front() {
            return Err(error);
        }
        Ok(self.snapshot.clone())
    }
    fn create_adapter(&mut self, name: &str) -> Result<GraphObjectId, GraphFailure> {
        let object = self.allocate()?;
        self.operations.push(RecordedGraphOperation::CreateAdapter {
            object,
            name: name.into(),
        });
        Ok(object)
    }
    fn create_monitor(
        &mut self,
        capture: CaptureId,
        target: NodeIdentity,
        epoch: PipeWireGeneration,
    ) -> Result<GraphObjectId, GraphFailure> {
        let object = self.allocate()?;
        self.operations.push(RecordedGraphOperation::CreateMonitor {
            object,
            capture,
            target,
            epoch,
        });
        Ok(object)
    }
    fn create_link(
        &mut self,
        mixer: NodeIdentity,
        link: &AdditiveLink,
    ) -> Result<GraphObjectId, GraphFailure> {
        let object = self.allocate()?;
        self.operations.push(RecordedGraphOperation::CreateLink {
            object,
            mixer,
            link: link.clone(),
        });
        Ok(object)
    }
    fn state(&mut self, object: GraphObjectId) -> GraphObjectState {
        self.object_states
            .get(&object)
            .cloned()
            .unwrap_or(GraphObjectState::Unavailable {
                reason: crate::audio::UnavailableReason::GraphFailure,
                detail: "unknown recording object".into(),
            })
    }
    fn remove(&mut self, object: GraphObjectId) {
        assert!(
            self.object_states.remove(&object).is_some(),
            "only live owned objects can be removed"
        );
        self.operations.push(RecordedGraphOperation::Remove(object));
    }
    fn publish_transport(
        &mut self,
        _object: GraphObjectId,
        _capture: CaptureId,
    ) -> Option<AudioBackendEvent> {
        None
    }
}
