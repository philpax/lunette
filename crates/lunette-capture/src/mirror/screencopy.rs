//! Linux-only: adapts the pinned WayVR screencopy backend without replacing its protocol.
//!
//! Upstream owns the request workers, including their pause, drop, and failure limitations.

use std::{convert::Infallible, sync::Arc};

use tracing::{info, warn};
use wlx_capture::{WlxCapture, frame::DmaExporter, wlr_screencopy::WlrScreencopyCapture};
pub use wlx_capture::{
    frame::{FramePlane, WlxFrame},
    wayland::WlxClient,
};

use crate::{
    mirror::{DirectOpen, MonitorStream, MonitorStreams, PipewireStreams},
    monitor::{Monitor, MonitorKey},
    portal::NodeId,
    stream::{CapturedFrame, DrmFormat, DrmFourcc, DrmModifier, FrameCounts, FrameQueue, Refusal},
};

/// The graphics-dependent half of WayVR's capture-buffer exporter.
pub trait CaptureExporter: Send {
    fn next_frame(
        &mut self,
        width: u32,
        height: u32,
        fourcc: DrmFourcc,
    ) -> Option<(FramePlane, DrmModifier)>;
    /// Converts upstream's implicit completion into the buffer supplied to it.
    fn completed(&self, frame: &WlxFrame) -> Option<CapturedFrame>;
}

/// Creates one exporter per direct stream after graphics initialization.
pub type ExporterFactory = Box<dyn Fn() -> Box<dyn CaptureExporter>>;

/// Preferred screencopy with the existing PipeWire source as its fallback.
pub struct PreferredStreams {
    client: fn() -> Option<WlxClient>,
    exporters: ExporterFactory,
    formats: Vec<DrmFormat>,
    pipewire: PipewireStreams,
    unavailable: Vec<MonitorKey>,
}

impl PreferredStreams {
    #[must_use]
    pub fn new(
        client: fn() -> Option<WlxClient>,
        exporters: ExporterFactory,
        formats: Vec<DrmFormat>,
    ) -> Self {
        Self {
            client,
            exporters,
            pipewire: PipewireStreams::new(formats.clone()),
            formats,
            unavailable: Vec::new(),
        }
    }
}

impl MonitorStreams for PreferredStreams {
    fn open_direct(&mut self, monitor: &Monitor) -> DirectOpen {
        if self.unavailable.contains(monitor.key()) {
            return DirectOpen::Unavailable;
        }
        let Some(client) = (self.client)() else {
            return self.unavailable(monitor, "the host client could not be opened");
        };
        if client.maybe_wlr_screencopy_mgr.is_none() {
            // Expected on compositors without wlroots protocols, so not a warning.
            info!(monitor = %monitor.key(), "direct capture: wlr-screencopy v3 is unavailable; using the portal");
            self.unavailable.push(monitor.key().clone());
            return DirectOpen::Unavailable;
        }
        let geometry = monitor.geometry();
        let (Ok(width), Ok(height)) = (
            i32::try_from(geometry.size.width),
            i32::try_from(geometry.size.height),
        ) else {
            return self.unavailable(monitor, "logical dimensions exceed upstream limits");
        };
        let mut matches = client.outputs.iter().filter(|(_, output)| {
            output.logical_pos == (geometry.position.x, geometry.position.y)
                && output.logical_size == (width, height)
        });
        let Some((id, _)) = matches.next() else {
            return self.unavailable(monitor, "no upstream output matches the monitor");
        };
        let id = *id;
        if matches.next().is_some() {
            return self.unavailable(monitor, "output geometry is ambiguous");
        }
        let frames = Arc::new(FrameQueue::new(
            std::num::NonZeroUsize::MIN.saturating_add(1),
        ));
        let mut capture = WlrScreencopyCapture::new(client, id);
        capture.init(
            &self.formats,
            Delivery {
                exporter: (self.exporters)(),
                frames: Arc::clone(&frames),
            },
            deliver,
        );
        capture.resume();
        info!(monitor = %monitor.key(), "started direct wlr-screencopy capture");
        DirectOpen::Opened(Box::new(DirectStream { capture, frames }))
    }

    fn open(&mut self, name: &str, node: NodeId) -> Option<Box<dyn MonitorStream>> {
        self.pipewire.open(name, node)
    }
}

impl PreferredStreams {
    /// Records that direct capture cannot serve `monitor`, which then uses the portal.
    fn unavailable(&mut self, monitor: &Monitor, reason: &str) -> DirectOpen {
        warn!(monitor = %monitor.key(), "direct capture: {reason}; using the portal");
        self.unavailable.push(monitor.key().clone());
        DirectOpen::Unavailable
    }
}

struct Delivery {
    exporter: Box<dyn CaptureExporter>,
    frames: Arc<FrameQueue<CapturedFrame>>,
}

impl DmaExporter for Delivery {
    fn next_frame(
        &mut self,
        width: u32,
        height: u32,
        fourcc: DrmFourcc,
    ) -> Option<(FramePlane, DrmModifier)> {
        self.exporter.next_frame(width, height, fourcc)
    }
}

fn deliver(delivery: &Delivery, frame: WlxFrame) -> Option<Infallible> {
    let captured = match &frame {
        WlxFrame::Implicit(_) => delivery.exporter.completed(&frame),
        _ => match CapturedFrame::from_wlx(&frame) {
            Ok(frame) => Some(frame),
            Err(error) => {
                if delivery.frames.record_refusal() == Refusal::First {
                    warn!(%error, "direct capture: a frame could not be converted");
                }
                None
            }
        },
    };
    if let Some(frame) = captured {
        delivery.frames.push(frame);
    }
    None
}

struct DirectStream {
    capture: WlrScreencopyCapture<Delivery, Infallible>,
    frames: Arc<FrameQueue<CapturedFrame>>,
}

impl MonitorStream for DirectStream {
    fn latest(&mut self) -> Option<CapturedFrame> {
        let frame = self.frames.take_latest();
        self.capture.request_new_frame();
        frame
    }

    fn counts(&self) -> FrameCounts {
        self.frames.counts()
    }
    fn pause(&mut self) {
        self.capture.pause();
    }
    fn resume(&mut self) {
        self.capture.resume();
    }
}
