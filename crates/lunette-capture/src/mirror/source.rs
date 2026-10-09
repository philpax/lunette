//! Linux-only: opens PipeWire streams for nodes granted by the portal.
//!
//! The source sits behind a trait so lifecycle tests run without PipeWire, a portal, or a display.

use tracing::debug;

use crate::{
    portal::NodeId,
    stream::{CaptureStream, CapturedFrame, DrmFormat, FrameCounts},
};

/// A monitor's captured frames and lifecycle controls.
///
/// Direct screencopy delegates these operations to the pinned backend, whose pause is a no-op and whose drop does not join an in-flight request worker.
pub trait MonitorStream {
    /// Returns the newest frame since the previous call and discards older frames.
    fn latest(&mut self) -> Option<CapturedFrame>;

    /// Returns counts of delivered, dropped, and refused frames.
    fn counts(&self) -> FrameCounts;

    /// Requests a pause without releasing the stream; backend support varies.
    fn pause(&mut self);

    /// Resumes production after [`Self::pause`].
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

/// Opens monitor streams for nodes granted by the portal.
///
/// The lifecycle stores implementations as `Box<dyn MonitorStreams>`, so this trait must remain object-safe.
pub trait MonitorStreams {
    /// Tries direct host capture before requesting a portal session.
    fn open_direct(&mut self, _monitor: &crate::monitor::Monitor) -> DirectOpen {
        DirectOpen::Unavailable
    }

    /// Opens `node` and begins delivering frames, using `name` for logging.
    ///
    /// Returns `None` when the source is not ready, and the lifecycle retries from [`MirrorSet::poll`]. Opening waits for the importer's DRM formats, which arrive after device initialization.
    ///
    /// [`MirrorSet::poll`]: crate::mirror::MirrorSet::poll
    fn open(&mut self, name: &str, node: NodeId) -> Option<Box<dyn MonitorStream>>;
}

/// The result of trying the preferred direct backend.
pub enum DirectOpen {
    Opened(Box<dyn MonitorStream>),
    /// Graphics initialization has not supplied capture resources yet.
    Deferred,
    /// The protocol or direct setup cannot be used; the portal remains available.
    Unavailable,
}

/// A source that is not ready to open streams.
///
/// Monitors requested before [`MirrorSet::set_streams`] installs a [`PipewireStreams`] remain wanted and open on a later poll.
///
/// [`MirrorSet::set_streams`]: crate::mirror::MirrorSet::set_streams
#[derive(Clone, Copy, Debug, Default)]
pub struct NoStreams;

impl MonitorStreams for NoStreams {
    fn open_direct(&mut self, _monitor: &crate::monitor::Monitor) -> DirectOpen {
        DirectOpen::Deferred
    }

    fn open(&mut self, name: &str, node: NodeId) -> Option<Box<dyn MonitorStream>> {
        debug!(
            stream = name,
            %node,
            "a capture stream was wanted before anything could open one",
        );
        None
    }
}

/// The production source, with one PipeWire stream per granted node.
///
/// Stores the importer's DRM formats, which the entry point supplies because this crate does not depend on a graphics API.
#[derive(Clone, Debug)]
pub struct PipewireStreams {
    formats: Vec<DrmFormat>,
}

impl PipewireStreams {
    #[must_use]
    pub fn new(formats: Vec<DrmFormat>) -> Self {
        Self { formats }
    }
}

impl MonitorStreams for PipewireStreams {
    fn open(&mut self, name: &str, node: NodeId) -> Option<Box<dyn MonitorStream>> {
        Some(Box::new(CaptureStream::start(name, node, &self.formats)))
    }
}
