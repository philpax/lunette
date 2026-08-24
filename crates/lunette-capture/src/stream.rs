//! Linux-only: PipeWire's frames, carried raw to the main thread.
//!
//! PipeWire delivers on its own thread through a bare `fn` pointer. The callback
//! converts each frame into a plain owned message and queues it. Vulkan imports
//! happen on the main thread through the same path as Wayland client buffers.
//! This gives lunette one import path without assuming a particular GPU queue
//! topology. The cost is one channel hop per frame.
//!
//! # Who is allowed to block
//!
//! Nobody. [`FrameQueue`] is bounded and drops the oldest frame when it is full,
//! so the PipeWire thread is never held up by a main thread that is busy
//! drawing, and the main thread is never held up by a stream that has stopped
//! producing. An overlay wants the newest frame rather than a backlog:
//! `WlxCapture::receive` is a `try_iter().last()` for the same reason, and
//! [`FrameQueue::take_latest`] keeps that behaviour.
//!
//! Dropping is counted rather than silent. A stream that drops most of what it
//! produces is working as designed; a stream that drops all of it is a symptom,
//! and the two are only distinguishable from a number.
//!
//! # The descriptors
//!
//! A `FramePlane`'s descriptor belongs to the PipeWire buffer it came from and
//! is valid for the duration of the callback. It is duplicated on the way into
//! the message, because the message outlives the callback by design.

use std::{
    collections::VecDeque,
    error::Error,
    fmt,
    num::{NonZeroU32, NonZeroUsize},
    os::fd::{AsFd, BorrowedFd, OwnedFd},
    sync::Arc,
};

use parking_lot::Mutex;
use smallvec::SmallVec;
use tracing::{debug, info, warn};
// Re-exported so a consumer can say which DRM formats its importer accepts
// without taking a direct dependency on `wlx-capture`. `CaptureFormat` already
// exposes both types by value, so this states an existing coupling rather than
// creating one.
pub use wlx_capture::{DrmFormat, DrmFourcc, DrmModifier};
use wlx_capture::{
    WlxCapture,
    frame::{DmabufFrame, FrameFormat, FramePlane, Transform, WlxFrame},
    pipewire::capture::PipewireCapture,
};

use crate::portal::NodeId;

/// The most planes a frame may carry, as `wlx-capture`'s own array allows.
pub const MAX_PLANES: usize = 4;

/// One captured monitor, from the portal's node to the main thread's queue.
///
/// Owns the PipeWire thread: dropping this stops it and joins it.
pub struct CaptureStream {
    name: Arc<str>,
    capture: PipewireCapture<Never>,
    frames: Arc<FrameQueue<CapturedFrame>>,
}

impl CaptureStream {
    /// Connects to a PipeWire node and starts delivering frames.
    ///
    /// `formats` is what the importer can accept, passed in rather than decided
    /// here: this crate must not depend on a graphics API, so which DRM formats
    /// and modifiers are determined by the importer.
    #[must_use]
    pub fn start(name: impl Into<Arc<str>>, node: NodeId, formats: &[DrmFormat]) -> Self {
        let name = name.into();
        let frames = Arc::new(FrameQueue::new(QUEUE_DEPTH));

        let mut capture = PipewireCapture::new(name.clone(), node.get());
        control(&mut capture).init(formats, Delivery(Arc::clone(&frames)), deliver);

        info!(stream = %name, %node, "started a capture stream");
        Self {
            name,
            capture,
            frames,
        }
    }

    /// The newest frame produced since the last call, discarding any older ones.
    ///
    /// `None` means nothing new arrived, which is ordinary: a monitor showing a
    /// still desktop produces no frames at all.
    #[must_use]
    pub fn latest(&self) -> Option<CapturedFrame> {
        self.frames.take_latest()
    }

    /// How many frames this stream has dropped and refused.
    #[must_use]
    pub fn counts(&self) -> FrameCounts {
        self.frames.counts()
    }

    /// Stops the stream producing without releasing the portal session.
    ///
    /// Distinct from dropping the stream: this is the temporarily-invisible
    /// panel, not the dismissed monitor.
    pub fn pause(&mut self) {
        control(&mut self.capture).pause();
        debug!(stream = %self.name, "paused a capture stream");
    }

    pub fn resume(&mut self) {
        control(&mut self.capture).resume();
        debug!(stream = %self.name, "resumed a capture stream");
    }
}

impl fmt::Debug for CaptureStream {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CaptureStream")
            .field("name", &self.name)
            .field("counts", &self.counts())
            .finish_non_exhaustive()
    }
}

/// A frame on its way to the importer.
///
/// Plain owned data with no graphics type in it: descriptors, offsets, strides,
/// a DRM format, and a modifier. That is what lets this crate stay free of a
/// graphics dependency while still carrying everything the import needs.
#[derive(Debug)]
pub struct CapturedFrame {
    format: CaptureFormat,
    planes: SmallVec<[CapturedPlane; MAX_PLANES]>,
}

impl CapturedFrame {
    /// Converts a `wlx-capture` frame, duplicating its descriptors.
    ///
    /// # Errors
    ///
    /// For a frame lunette cannot import, and for a dmabuf whose layout cannot
    /// be described. Every case is named rather than collapsed, because "the
    /// mirror is black" is not a diagnosis.
    pub fn from_wlx(frame: &WlxFrame) -> Result<Self, FrameError> {
        match frame {
            WlxFrame::Dmabuf(dmabuf) => Self::from_dmabuf(dmabuf),
            // The frame was blitted into a buffer lunette supplied. Nothing here
            // supplies one, so a frame arriving this way means the capture was
            // configured against a path v1 does not use.
            WlxFrame::Implicit(_) => Err(FrameError::Implicit),
            WlxFrame::MemFd(_) => Err(FrameError::SharedMemory { kind: "a memfd" }),
            WlxFrame::MemPtr(_) => Err(FrameError::SharedMemory {
                kind: "a mapped pointer",
            }),
        }
    }

    #[must_use]
    pub const fn format(&self) -> CaptureFormat {
        self.format
    }

    #[must_use]
    pub fn planes(&self) -> &[CapturedPlane] {
        &self.planes
    }

    /// Builds a frame from parts, for tests that have no PipeWire to get one
    /// from.
    ///
    /// Test scaffolding rather than an API: the production path is
    /// [`Self::from_wlx`], and this exists so the consumer in `lunette` can be
    /// exercised without a portal, a session, or a graphics device.
    #[cfg(any(test, feature = "test-fakes"))]
    #[must_use]
    pub fn from_parts(
        format: CaptureFormat,
        planes: impl IntoIterator<Item = (OwnedFd, u32, u32)>,
    ) -> Self {
        Self {
            format,
            planes: planes
                .into_iter()
                .map(|(descriptor, offset, stride)| CapturedPlane {
                    descriptor,
                    offset,
                    stride,
                })
                .collect(),
        }
    }

    fn from_dmabuf(frame: &DmabufFrame) -> Result<Self, FrameError> {
        let format = CaptureFormat::from_wlx(&frame.format)?;

        if frame.num_planes == 0 {
            return Err(FrameError::NoPlanes);
        }
        if frame.num_planes > MAX_PLANES {
            return Err(FrameError::TooManyPlanes {
                planes: frame.num_planes,
            });
        }

        let planes = frame.planes[..frame.num_planes]
            .iter()
            .enumerate()
            .map(|(index, plane)| CapturedPlane::from_wlx(index, plane))
            .collect::<Result<_, _>>()?;

        Ok(Self { format, planes })
    }
}

/// One plane's descriptor and layout.
#[derive(Debug)]
pub struct CapturedPlane {
    descriptor: OwnedFd,
    offset: u32,
    stride: u32,
}

impl CapturedPlane {
    /// The plane's memory. Borrowed: the frame owns it until it is imported.
    #[must_use]
    pub fn descriptor(&self) -> BorrowedFd<'_> {
        self.descriptor.as_fd()
    }

    #[must_use]
    pub const fn offset(&self) -> u32 {
        self.offset
    }

    #[must_use]
    pub const fn stride(&self) -> u32 {
        self.stride
    }

    fn from_wlx(index: usize, plane: &FramePlane) -> Result<Self, FrameError> {
        let raw = plane
            .fd
            .ok_or(FrameError::MissingDescriptor { plane: index })?;

        // A negative stride means the rows run bottom-up. Vulkan's
        // `VkSubresourceLayout::rowPitch` is unsigned and has no way to say so,
        // and widening it would describe a buffer nothing wrote.
        let stride = u32::try_from(plane.stride).map_err(|_| FrameError::NegativeStride {
            plane: index,
            stride: plane.stride,
        })?;

        // SAFETY: the descriptor belongs to the PipeWire buffer and is valid for
        // the callback this runs inside; the borrow does not outlive the call,
        // and the duplicate is what outlives it.
        let borrowed = unsafe { BorrowedFd::borrow_raw(raw) };
        let descriptor =
            borrowed
                .try_clone_to_owned()
                .map_err(|cause| FrameError::DuplicateDescriptor {
                    plane: index,
                    cause,
                })?;

        Ok(Self {
            descriptor,
            offset: plane.offset,
            stride,
        })
    }
}

/// What a captured frame is, in the terms the importer needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct CaptureFormat {
    pub size: FrameSize,
    pub fourcc: DrmFourcc,
    pub modifier: DrmModifier,
    pub transform: FrameTransform,
}

impl CaptureFormat {
    fn from_wlx(format: &FrameFormat) -> Result<Self, FrameError> {
        Ok(Self {
            size: FrameSize::new(format.width, format.height).ok_or(FrameError::EmptyFrame {
                width: format.width,
                height: format.height,
            })?,
            fourcc: format.drm_format.code,
            modifier: format.drm_format.modifier,
            transform: FrameTransform::from_wlx(format.transform),
        })
    }
}

/// A frame's dimensions, which are at least one pixel each.
///
/// Zero is representable in the wire format and describes no image, so it is
/// rejected at the boundary rather than reaching an image creation that would
/// fail with less to say about why.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FrameSize {
    width: NonZeroU32,
    height: NonZeroU32,
}

impl FrameSize {
    #[must_use]
    pub const fn new(width: u32, height: u32) -> Option<Self> {
        match (NonZeroU32::new(width), NonZeroU32::new(height)) {
            (Some(width), Some(height)) => Some(Self { width, height }),
            _ => None,
        }
    }

    #[must_use]
    pub const fn width(self) -> u32 {
        self.width.get()
    }

    #[must_use]
    pub const fn height(self) -> u32 {
        self.height.get()
    }
}

impl fmt::Display for FrameSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.width, self.height)
    }
}

/// How the compositor says the frame is oriented.
///
/// lunette's own enum rather than `wlx-capture`'s, so the message crossing the
/// thread boundary is written entirely in this crate's vocabulary. `Undefined`
/// is not a variant: a stream that reported no transform is treated as
/// [`Self::Normal`], which is what it means, rather than carrying an absence
/// every consumer would have to answer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum FrameTransform {
    #[default]
    Normal,
    Rotated90,
    Rotated180,
    Rotated270,
    Flipped,
    Flipped90,
    Flipped180,
    Flipped270,
}

impl FrameTransform {
    fn from_wlx(transform: Transform) -> Self {
        match transform {
            Transform::Undefined | Transform::Normal => Self::Normal,
            Transform::Rotated90 => Self::Rotated90,
            Transform::Rotated180 => Self::Rotated180,
            Transform::Rotated270 => Self::Rotated270,
            Transform::Flipped => Self::Flipped,
            Transform::Flipped90 => Self::Flipped90,
            Transform::Flipped180 => Self::Flipped180,
            Transform::Flipped270 => Self::Flipped270,
        }
    }
}

/// A bounded queue that drops the oldest entry rather than blocking a producer.
///
/// The producer is PipeWire's own thread inside a `process` callback, which must
/// return promptly, and the consumer is the frame loop. Neither may wait on the
/// other, so the capacity is spent on the newest frames and the rest are
/// counted.
#[derive(Debug)]
pub struct FrameQueue<T> {
    capacity: NonZeroUsize,
    inner: Mutex<QueueInner<T>>,
}

impl<T> FrameQueue<T> {
    #[must_use]
    pub fn new(capacity: NonZeroUsize) -> Self {
        Self {
            capacity,
            inner: Mutex::new(QueueInner {
                entries: VecDeque::with_capacity(capacity.get()),
                counts: FrameCounts::default(),
                refused_before: false,
            }),
        }
    }

    /// Queues an entry, discarding the oldest if the queue is full.
    pub fn push(&self, entry: T) -> Pushed {
        let mut inner = self.inner.lock();

        let pushed = if inner.entries.len() >= self.capacity.get() {
            inner.entries.pop_front();
            inner.counts.dropped = inner.counts.dropped.saturating_add(1);
            Pushed::DroppedOldest
        } else {
            Pushed::Accepted
        };

        inner.entries.push_back(entry);
        inner.counts.delivered = inner.counts.delivered.saturating_add(1);
        pushed
    }

    /// Takes the newest entry, discarding whatever was queued behind it.
    ///
    /// The discarded ones are counted as dropped: a frame that was produced and
    /// never drawn is a dropped frame whether the queue overflowed or the frame
    /// loop was slow.
    #[must_use]
    pub fn take_latest(&self) -> Option<T> {
        let mut inner = self.inner.lock();
        let newest = inner.entries.pop_back()?;

        let stale = u64::try_from(inner.entries.len()).unwrap_or(u64::MAX);
        inner.entries.clear();
        inner.counts.dropped = inner.counts.dropped.saturating_add(stale);

        Some(newest)
    }

    /// Records a frame that could not be converted. Reports whether it is the
    /// first, so the stream reports the condition once rather than every frame.
    pub fn record_refusal(&self) -> Refusal {
        let mut inner = self.inner.lock();
        inner.counts.refused = inner.counts.refused.saturating_add(1);

        if inner.refused_before {
            Refusal::Again
        } else {
            inner.refused_before = true;
            Refusal::First
        }
    }

    #[must_use]
    pub fn counts(&self) -> FrameCounts {
        self.inner.lock().counts
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.inner.lock().entries.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// What a push did to the queue.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pushed {
    Accepted,
    /// The queue was full, so the oldest frame was discarded to make room. The
    /// newest frame is the one worth keeping.
    DroppedOldest,
}

/// Whether a refusal is the first this stream has seen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    First,
    Again,
}

/// What a stream has done with the frames it produced.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameCounts {
    /// Frames converted and queued.
    pub delivered: u64,
    /// Frames queued and then discarded without being drawn.
    pub dropped: u64,
    /// Frames that could not be converted at all.
    pub refused: u64,
}

/// Why a captured frame could not be carried to the importer.
#[derive(Debug)]
pub enum FrameError {
    /// The frame was blitted into a buffer lunette supplied. lunette supplies
    /// none, so this path is not one v1 uses.
    Implicit,
    /// The stream negotiated shared memory rather than a dmabuf.
    SharedMemory {
        kind: &'static str,
    },
    EmptyFrame {
        width: u32,
        height: u32,
    },
    NoPlanes,
    TooManyPlanes {
        planes: usize,
    },
    MissingDescriptor {
        plane: usize,
    },
    NegativeStride {
        plane: usize,
        stride: i32,
    },
    DuplicateDescriptor {
        plane: usize,
        cause: std::io::Error,
    },
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "capture: ")?;
        match self {
            Self::Implicit => f.write_str(
                "the frame was blitted into a buffer lunette supplied, and lunette supplies none",
            ),
            Self::SharedMemory { kind } => write!(
                f,
                "the stream delivered {kind} rather than a dmabuf, which v1 does not import"
            ),
            Self::EmptyFrame { width, height } => {
                write!(f, "a frame of {width}x{height} has no image in it")
            }
            Self::NoPlanes => f.write_str("the frame carries no planes"),
            Self::TooManyPlanes { planes } => write!(
                f,
                "the frame carries {planes} planes, and a dmabuf has at most {MAX_PLANES}"
            ),
            Self::MissingDescriptor { plane } => {
                write!(f, "plane {plane} carries no descriptor")
            }
            Self::NegativeStride { plane, stride } => write!(
                f,
                "plane {plane} has a stride of {stride}, so its rows run bottom-up and no image \
                 layout can describe it"
            ),
            Self::DuplicateDescriptor { plane, .. } => {
                write!(f, "plane {plane}'s descriptor could not be duplicated")
            }
        }
    }
}

impl Error for FrameError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::DuplicateDescriptor { cause, .. } => Some(cause),
            Self::Implicit
            | Self::SharedMemory { .. }
            | Self::EmptyFrame { .. }
            | Self::NoPlanes
            | Self::TooManyPlanes { .. }
            | Self::MissingDescriptor { .. }
            | Self::NegativeStride { .. } => None,
        }
    }
}

/// How many frames a stream holds before the oldest is discarded.
///
/// Two, matching `wlx-capture`'s own channel: one being drawn and one arriving.
/// A deeper queue buys latency rather than throughput, which is the wrong
/// direction for an overlay.
const QUEUE_DEPTH: NonZeroUsize = NonZeroUsize::MIN.saturating_add(1);

/// What PipeWire's callback is handed.
///
/// A named type rather than the `Arc` itself, because the callback is a bare
/// `fn` and its user-data parameter are the only channel through which data
/// reaches it.
struct Delivery(Arc<FrameQueue<CapturedFrame>>);

/// The type the receive callback never returns.
///
/// `WlxCapture` routes the callback's return value through a channel of its own
/// that drops the *newest* frame when full. lunette wants the newest, so it
/// keeps nothing there: the callback queues into [`FrameQueue`] and returns
/// `None`, and an uninhabited type is how that is said once rather than
/// asserted at each return.
type Never = std::convert::Infallible;

/// Names which `WlxCapture` implementation a call is reaching.
///
/// `PipewireCapture<R>` implements `WlxCapture<U, R>` for every `U`, so a bare
/// method call on it is ambiguous. This pins `U` once rather than at each call
/// site.
fn control(capture: &mut PipewireCapture<Never>) -> &mut impl WlxCapture<Delivery, Never> {
    capture
}

/// Runs on PipeWire's thread, once per frame.
///
/// A bare `fn` because that is what `WlxCapture::init` takes; everything it needs
/// arrives through [`Delivery`].
fn deliver(delivery: &Delivery, frame: WlxFrame) -> Option<Never> {
    let queue = &delivery.0;

    match CapturedFrame::from_wlx(&frame) {
        Ok(frame) => {
            if queue.push(frame) == Pushed::DroppedOldest {
                debug!("the frame queue was full, so an undrawn frame was discarded");
            }
        }
        Err(error) => match queue.record_refusal() {
            // Once at warn, then quietly: a stream that refuses one frame
            // refuses every frame, and a per-frame warning drowns the log it
            // was meant to appear in.
            Refusal::First => {
                warn!(%error, "a captured frame could not be carried to the importer")
            }
            Refusal::Again => debug!(%error, "a captured frame could not be carried again"),
        },
    }

    None
}

#[derive(Debug)]
struct QueueInner<T> {
    entries: VecDeque<T>,
    counts: FrameCounts,
    refused_before: bool,
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};

    use pretty_assertions::assert_eq;
    use wlx_capture::frame::MemPtrFrame;

    use super::*;

    fn queue(capacity: usize) -> FrameQueue<u32> {
        FrameQueue::new(NonZeroUsize::new(capacity).expect("a positive capacity"))
    }

    /// A descriptor to hand around, and the write end that keeps its pipe alive.
    ///
    /// A pipe rather than a file, so no filesystem is touched.
    fn pipe() -> (OwnedFd, OwnedFd) {
        let (read, write) = std::io::pipe().expect("a pipe can be created");
        (OwnedFd::from(read), OwnedFd::from(write))
    }

    fn format() -> FrameFormat {
        FrameFormat {
            width: 1920,
            height: 1080,
            drm_format: DrmFormat {
                code: DrmFourcc::Argb8888,
                modifier: DrmModifier::Linear,
            },
            transform: Transform::Undefined,
        }
    }

    /// A dmabuf frame over `planes` descriptors, and the pipe ends behind them.
    ///
    /// The frame borrows raw descriptors, exactly as PipeWire's callback hands
    /// them over, so the owners have to outlive the conversion.
    fn dmabuf_frame(planes: usize) -> (DmabufFrame, Vec<OwnedFd>) {
        let mut owned = Vec::new();
        let mut frame = DmabufFrame {
            format: format(),
            num_planes: planes,
            planes: Default::default(),
            mouse: None,
        };

        for index in 0..planes {
            let (read, write) = pipe();
            frame.planes[index] = FramePlane {
                fd: Some(read.as_raw_fd()),
                offset: u32::try_from(index).expect("a small plane index") * 4096,
                stride: 7680,
            };
            owned.push(read);
            owned.push(write);
        }

        (frame, owned)
    }

    #[test]
    fn a_dmabuf_frame_converts_with_every_plane_intact() {
        let (frame, _owners) = dmabuf_frame(3);

        let captured =
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)).expect("a well-formed dmabuf frame");

        assert_eq!(captured.planes().len(), 3);
        assert_eq!(
            captured
                .planes()
                .iter()
                .map(|plane| (plane.offset(), plane.stride()))
                .collect::<Vec<_>>(),
            vec![(0, 7680), (4096, 7680), (8192, 7680)],
        );
        assert_eq!(
            captured.format().size,
            FrameSize::new(1920, 1080).expect("non-zero")
        );
        assert_eq!(captured.format().fourcc, DrmFourcc::Argb8888);
        assert_eq!(captured.format().modifier, DrmModifier::Linear);
    }

    #[test]
    fn a_converted_frame_holds_its_own_descriptors() {
        // The frame outlives the callback the descriptors belong to, so it has
        // to duplicate them rather than borrow them.
        let (frame, owners) = dmabuf_frame(1);
        let borrowed = frame.planes[0].fd.expect("the plane has a descriptor");

        let captured =
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)).expect("a well-formed dmabuf frame");

        assert_ne!(
            captured.planes()[0].descriptor().as_raw_fd(),
            borrowed,
            "the frame kept the callback's own descriptor number, which PipeWire may close",
        );
        drop(owners);
    }

    #[test]
    fn a_stream_that_reported_no_transform_is_treated_as_unrotated() {
        let (frame, _owners) = dmabuf_frame(1);

        let captured =
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)).expect("a well-formed dmabuf frame");

        assert_eq!(captured.format().transform, FrameTransform::Normal);
    }

    #[test]
    fn every_transform_the_stream_can_report_is_carried_across() {
        for (reported, expected) in [
            (Transform::Rotated90, FrameTransform::Rotated90),
            (Transform::Rotated180, FrameTransform::Rotated180),
            (Transform::Rotated270, FrameTransform::Rotated270),
            (Transform::Flipped, FrameTransform::Flipped),
            (Transform::Flipped90, FrameTransform::Flipped90),
            (Transform::Flipped180, FrameTransform::Flipped180),
            (Transform::Flipped270, FrameTransform::Flipped270),
        ] {
            let (mut frame, _owners) = dmabuf_frame(1);
            frame.format.transform = reported;

            let captured = CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame))
                .expect("a well-formed dmabuf frame");

            assert_eq!(captured.format().transform, expected, "{reported:?}");
        }
    }

    #[test]
    fn an_implicit_frame_is_rejected_rather_than_ignored() {
        // lunette supplies no buffer for the capture to blit into, so a frame
        // arriving this way means the stream was configured against a path v1
        // does not use.
        let error = CapturedFrame::from_wlx(&WlxFrame::Implicit(Transform::Normal))
            .expect_err("lunette supplies no buffer to blit into");

        assert!(matches!(error, FrameError::Implicit), "{error}");
        assert!(
            error.to_string().contains("lunette supplies none"),
            "{error}"
        );
    }

    #[test]
    fn a_shared_memory_frame_is_rejected_by_name() {
        let error = CapturedFrame::from_wlx(&WlxFrame::MemPtr(MemPtrFrame {
            format: format(),
            ptr: 0,
            size: 0,
            mouse: None,
        }))
        .expect_err("v1 imports dmabufs only");

        assert!(
            error.to_string().contains("a mapped pointer"),
            "the diagnosis has to name which shared-memory path arrived: {error}",
        );
    }

    #[test]
    fn a_frame_with_no_planes_is_rejected() {
        let (frame, _owners) = dmabuf_frame(0);

        assert!(matches!(
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)),
            Err(FrameError::NoPlanes),
        ));
    }

    #[test]
    fn a_plane_with_no_descriptor_is_rejected_rather_than_skipped() {
        let (mut frame, _owners) = dmabuf_frame(2);
        frame.planes[1].fd = None;

        assert!(matches!(
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)),
            Err(FrameError::MissingDescriptor { plane: 1 }),
        ));
    }

    #[test]
    fn a_bottom_up_plane_is_rejected_rather_than_widened() {
        // Widening a negative stride describes a buffer nothing wrote, which
        // produces a picture rather than an error.
        let (mut frame, _owners) = dmabuf_frame(1);
        frame.planes[0].stride = -7680;

        assert!(matches!(
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)),
            Err(FrameError::NegativeStride {
                plane: 0,
                stride: -7680,
            }),
        ));
    }

    #[test]
    fn a_frame_with_no_pixels_in_it_is_rejected() {
        let (mut frame, _owners) = dmabuf_frame(1);
        frame.format.height = 0;

        assert!(matches!(
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)),
            Err(FrameError::EmptyFrame {
                width: 1920,
                height: 0,
            }),
        ));
    }

    #[test]
    fn a_rejected_frame_leaks_no_descriptor() {
        // The second plane fails, so the first plane's duplicate has to be
        // released on the way out rather than left open per refused frame.
        let (read, write) = pipe();
        let raw = read.into_raw_fd();
        let mut frame = DmabufFrame {
            format: format(),
            num_planes: 2,
            planes: Default::default(),
            mouse: None,
        };
        frame.planes[0] = FramePlane {
            fd: Some(raw),
            offset: 0,
            stride: 7680,
        };
        frame.planes[1] = FramePlane {
            fd: None,
            offset: 0,
            stride: 7680,
        };

        assert!(CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)).is_err());

        // SAFETY: the conversion borrowed the descriptor and duplicated it; the
        // original is still this test's to close.
        drop(unsafe { OwnedFd::from_raw_fd(raw) });
        drop(write);
    }

    #[test]
    fn a_full_queue_discards_the_oldest_and_counts_it() {
        let queue = queue(2);

        assert_eq!(queue.push(1), Pushed::Accepted);
        assert_eq!(queue.push(2), Pushed::Accepted);
        assert_eq!(queue.push(3), Pushed::DroppedOldest);

        assert_eq!(queue.len(), 2);
        assert_eq!(
            queue.counts(),
            FrameCounts {
                delivered: 3,
                dropped: 1,
                refused: 0,
            },
        );
    }

    #[test]
    fn the_newest_frame_is_the_one_that_survives_a_full_queue() {
        // An overlay wants the newest frame, not the front of a backlog.
        let queue = queue(2);
        for entry in 1..=5 {
            let _ = queue.push(entry);
        }

        assert_eq!(queue.take_latest(), Some(5));
    }

    #[test]
    fn taking_the_latest_frame_discards_the_ones_behind_it_and_counts_them() {
        let queue = queue(4);
        for entry in 1..=3 {
            assert_eq!(queue.push(entry), Pushed::Accepted);
        }

        assert_eq!(queue.take_latest(), Some(3));
        assert!(queue.is_empty());
        assert_eq!(queue.counts().dropped, 2);
        assert_eq!(queue.take_latest(), None);
    }

    #[test]
    fn an_empty_queue_yields_nothing_and_counts_nothing() {
        let queue = queue(2);

        assert_eq!(queue.take_latest(), None);
        assert_eq!(queue.counts(), FrameCounts::default());
    }

    #[test]
    fn a_queue_of_one_keeps_only_the_newest() {
        let queue = queue(1);
        let _ = queue.push(1);
        let _ = queue.push(2);

        assert_eq!(queue.len(), 1);
        assert_eq!(queue.take_latest(), Some(2));
    }

    #[test]
    fn only_the_first_refusal_is_worth_saying_out_loud() {
        // A stream that refuses one frame refuses every frame, and a per-frame
        // warning drowns the log it was meant to appear in.
        let queue = queue(2);

        assert_eq!(queue.record_refusal(), Refusal::First);
        assert_eq!(queue.record_refusal(), Refusal::Again);
        assert_eq!(queue.record_refusal(), Refusal::Again);
        assert_eq!(queue.counts().refused, 3);
    }
}
