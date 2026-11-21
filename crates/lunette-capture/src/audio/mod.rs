//! System-output and logical-process PCM capture types and backends.

#[cfg(target_os = "linux")]
mod driver;
#[cfg(any(test, feature = "test-fakes"))]
mod fake;
#[cfg(all(target_os = "linux", any(test, feature = "test-fakes")))]
mod fake_graph;
mod graph;
mod service;
#[cfg(test)]
mod tests_support;
mod transport;
mod types;
#[cfg(windows)]
mod windows;
#[cfg(target_os = "linux")]
mod worker;

#[cfg(target_os = "linux")]
pub use driver::{GraphFailure, GraphObjectId, GraphObjectState, GraphOps};
#[cfg(any(test, feature = "test-fakes"))]
pub use fake::{RecordedAudioCommand, RecordingAudioBackend, RecordingAudioControl};
#[cfg(all(target_os = "linux", any(test, feature = "test-fakes")))]
pub use fake_graph::{RecordedGraphOperation, RecordingGraphOps};
pub use graph::{
    AdditiveLink, AssertionStatus, ClientIdentity, ClientKind, ClientObservation, DefaultSink,
    GraphPlan, MonitorTarget, NodeIdentity, NodeKind, NodeObservation, PidAssertion, PortIdentity,
    PortObservation, RegistrySnapshot, parse_default_sink, plan_graph,
};
pub use service::{
    AudioBackend, AudioBackendEvent, AudioError, AudioProcessCandidate, AudioPublication,
    AudioReaderId, AudioService, CaptureId, ProcessCaptureStatus,
};
pub use transport::{
    AudioBlock, AudioConsumer, AudioCutoff, AudioProducer, PacketResult, PcmPacket, SampleTiming,
    TransportLoss, audio_transport,
};
pub use types::{
    AttributionProvenance, AudioFormat, CaptureState, Source, SourceLimits, UnavailableReason,
};
#[cfg(windows)]
pub use windows::{WasapiAudioBackend, WindowsAudioTargets};
#[cfg(target_os = "linux")]
pub use worker::{PipeWireAudioBackend, PipeWireAudioConfig};
