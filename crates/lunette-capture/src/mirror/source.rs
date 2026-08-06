//! Linux-only: what opens a PipeWire stream on a node the portal granted.
//!
//! Opening one spawns PipeWire's own thread and connects to a real node, so the
//! lifecycle above reaches it through a seam rather than calling
//! [`CaptureStream::start`] directly. The production implementation is
//! [`PipewireSource`]; the tests substitute
//! [`crate::mirror::fake::RecordingSource`], which is why the transitions in
//! [`crate::mirror`] are exercised without PipeWire, without a portal, and
//! without a display.

use crate::{
    portal::NodeId,
    stream::{CaptureStream, CapturedFrame, FrameCounts},
};

/// One monitor's frames, as the lifecycle consumes them.
///
/// Stopping is dropping. There is no `stop` method because there is no state a
/// stopped stream should still be able to answer from: releasing the value
/// stops PipeWire's thread and closes the descriptors, which is what
/// `lunette-v1.AC3.5` asks for and what a `pause` deliberately does not do.
pub trait MonitorStream {
    /// The newest frame produced since the last call, discarding older ones.
    fn latest(&mut self) -> Option<CapturedFrame>;

    /// What this stream has done with the frames it produced.
    fn counts(&self) -> FrameCounts;

    /// Stops the stream producing, keeping everything it holds.
    ///
    /// For a panel that is temporarily out of view. A dismissed monitor is
    /// dropped instead.
    fn pause(&mut self);

    fn resume(&mut self);
}

impl MonitorStream for CaptureStream {
    fn latest(&mut self) -> Option<CapturedFrame> {
        Self::latest(self)
    }

    fn counts(&self) -> FrameCounts {
        Self::counts(self)
    }

    fn pause(&mut self) {
        Self::pause(self);
    }

    fn resume(&mut self) {
        Self::resume(self);
    }
}

/// What opens a stream on a granted node.
///
/// Dyn-safe, and boxing the stream rather than carrying it as an associated
/// type: the lifecycle holds one of these behind a `Box`, and an associated
/// type would make that impossible without a second parameter on every type
/// that owns a lifecycle.
pub trait MonitorStreams {
    /// Connects to `node` and starts delivering frames.
    ///
    /// `name` is the monitor's identity, for the stream's own logging.
    fn open(&mut self, name: &str, node: NodeId) -> Box<dyn MonitorStream>;
}

/// The production source: one PipeWire stream per granted node.
///
/// Holds the DRM formats the importer accepts, because this crate must not
/// depend on a graphics API and so cannot decide them. The entry point asks the
/// device and passes the answer in.
#[derive(Clone, Debug)]
pub struct PipewireStreams {
    formats: Vec<wlx_capture::DrmFormat>,
}

impl PipewireStreams {
    #[must_use]
    pub fn new(formats: Vec<wlx_capture::DrmFormat>) -> Self {
        Self { formats }
    }
}

impl MonitorStreams for PipewireStreams {
    fn open(&mut self, name: &str, node: NodeId) -> Box<dyn MonitorStream> {
        Box::new(CaptureStream::start(name, node, &self.formats))
    }
}
