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
/// Dropping the stream stops PipeWire and releases its descriptors. Pausing
/// stops production while retaining the stream for a panel that is temporarily
/// out of view; dismissal drops it instead.
pub trait MonitorStream {
    /// Returns the newest frame since the previous call and discards older frames.
    fn latest(&mut self) -> Option<CapturedFrame>;

    /// Returns counts of delivered, dropped, and refused frames.
    fn counts(&self) -> FrameCounts;

    /// Stops production without releasing the stream.
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
