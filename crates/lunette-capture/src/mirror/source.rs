//! Linux-only: opens PipeWire streams for nodes granted by the portal.
//!
//! [`CaptureStream`] owns the PipeWire thread for each stream. The source stays
//! behind a trait so lifecycle tests can use
//! [`crate::mirror::fake::RecordingSource`] without PipeWire, a portal, or a
//! display.

use tracing::debug;

use crate::{
    portal::NodeId,
    stream::{CaptureStream, CapturedFrame, DrmFormat, FrameCounts},
};

/// A monitor's captured frames and lifecycle controls.
///
/// PipeWire stops and joins on drop, and deactivates on pause. Direct screencopy
/// delegates these operations to the pinned backend: its pause is a no-op and
/// dropping it does not cancel or join an in-flight request worker.
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
/// The lifecycle stores implementations as `Box<dyn MonitorStreams>`, so this
/// trait must remain object-safe.
pub trait MonitorStreams {
    /// Tries direct host capture before requesting a portal session.
    fn open_direct(&mut self, _monitor: &crate::monitor::Monitor) -> DirectOpen {
        DirectOpen::Unavailable
    }

    /// Opens `node` and begins delivering frames, using `name` for logging.
    ///
    /// Returns `None` when the source is not ready. The lifecycle retains the
    /// monitor as wanted and retries from [`MirrorSet::poll`].
    ///
    /// A PipeWire stream negotiates against the DRM formats accepted by the
    /// importer. The entry point supplies those formats after device initialization,
    /// so opening is deferred until then.
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
/// [`MirrorSet`] uses this source until the entry point installs a
/// [`PipewireStreams`] through [`MirrorSet::set_streams`]. Monitors requested
/// before then remain wanted and open on a later poll after device initialization.
///
/// [`MirrorSet`]: crate::mirror::MirrorSet
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
/// Stores the DRM formats accepted by the importer. The entry point obtains
/// them from the graphics device because this crate does not depend on a graphics
/// API.
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
