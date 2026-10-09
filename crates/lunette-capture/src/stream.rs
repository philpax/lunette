//! Linux-only: carries captured frames from backend callbacks to the main thread.
//!
//! The main thread performs every Vulkan import, so this crate does not depend on a graphics API.

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
// Re-exported so callers can provide importer formats without naming `wlx-capture`.
pub use wlx_capture::{DrmFormat, DrmFourcc, DrmModifier};
use wlx_capture::{
    WlxCapture,
    frame::{DmabufFrame, FrameFormat, FramePlane, Transform, WlxFrame},
    pipewire::capture::PipewireCapture,
};

use crate::portal::NodeId;

/// The maximum number of planes accepted from `wlx-capture`.
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
    /// `formats` contains the DRM formats and modifiers the caller's importer accepts.
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

    /// Returns the newest frame produced since the last call and discards older
    /// queued frames. Returns `None` when no converted frame is queued.
    #[must_use]
    pub fn latest(&self) -> Option<CapturedFrame> {
        self.frames.take_latest()
    }

    /// Returns counts for converted, dropped, and refused frames.
    #[must_use]
    pub fn counts(&self) -> FrameCounts {
        self.frames.counts()
    }

    /// Stops the stream producing without releasing the portal session.
    ///
    /// Pausing hides the panel temporarily, while dropping the stream dismisses the monitor.
    pub fn pause(&mut self) {
        control(&mut self.capture).pause();
        debug!(stream = %self.name, "paused a capture stream");
    }

    /// Resumes production after [`Self::pause`] without requesting a new portal session.
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

/// A captured frame ready for import or upload.
///
/// It crosses the thread boundary without a graphics dependency.
#[derive(Debug)]
pub enum CapturedFrame {
    /// Dmabuf planes, imported as an image.
    Dmabuf {
        format: CaptureFormat,
        planes: SmallVec<[CapturedPlane; MAX_PLANES]>,
    },
    /// Packed shared-memory pixels, owned independently of the capture callback.
    ///
    /// The format is little-endian `Argb8888` or `Xrgb8888` with no row padding, and an `Xrgb8888` frame has its unused byte set opaque.
    Pixels {
        format: CaptureFormat,
        pixels: Vec<u8>,
    },
}

impl CapturedFrame {
    /// Converts a `wlx-capture` frame and duplicates its descriptors.
    ///
    /// # Errors
    ///
    /// Returns an error when the frame type or dmabuf layout is not representable by the importer.
    pub fn from_wlx(frame: &WlxFrame) -> Result<Self, FrameError> {
        match frame {
            WlxFrame::Dmabuf(dmabuf) => Self::from_dmabuf(dmabuf),
            WlxFrame::Implicit(_) => Err(FrameError::Implicit),
            WlxFrame::MemFd(frame) => Self::from_memfd(frame),
            WlxFrame::MemPtr(_) => Err(FrameError::SharedMemory {
                kind: "a mapped pointer",
            }),
        }
    }

    #[must_use]
    pub const fn format(&self) -> CaptureFormat {
        match self {
            Self::Dmabuf { format, .. } | Self::Pixels { format, .. } => *format,
        }
    }

    /// The dmabuf planes, or `None` for a shared-memory frame.
    #[must_use]
    pub fn planes(&self) -> Option<&[CapturedPlane]> {
        match self {
            Self::Dmabuf { planes, .. } => Some(planes),
            Self::Pixels { .. } => None,
        }
    }

    /// Builds a frame from an exported destination whose descriptor stays live for the call.
    ///
    /// # Errors
    ///
    /// Returns [`FrameError::DuplicateDescriptor`] if the descriptor cannot be retained.
    pub fn from_exported(
        format: CaptureFormat,
        descriptor: BorrowedFd<'_>,
        offset: u32,
        stride: u32,
    ) -> Result<Self, FrameError> {
        let descriptor = descriptor
            .try_clone_to_owned()
            .map_err(|cause| FrameError::DuplicateDescriptor { plane: 0, cause })?;
        Ok(Self::Dmabuf {
            format,
            planes: [CapturedPlane {
                descriptor,
                offset,
                stride,
            }]
            .into_iter()
            .collect(),
        })
    }

    /// Copies shared-memory pixels out during the callback, converting them to
    /// the layout [`Self::Pixels`] states in the same pass.
    fn from_memfd(frame: &wlx_capture::frame::MemFdFrame) -> Result<Self, FrameError> {
        let stride = u32::try_from(frame.plane.stride).map_err(|_| FrameError::NegativeStride {
            plane: 0,
            stride: frame.plane.stride,
        })?;
        let mut format = CaptureFormat::from_wlx(&frame.format)?;
        let packing = Packing::of(format.fourcc).ok_or(UNSUPPORTED_SHARED_MEMORY)?;
        let length = pixel_length(&frame.format, stride)?;
        let raw = frame
            .plane
            .fd
            .ok_or(FrameError::MissingDescriptor { plane: 0 })?;
        // SAFETY: upstream holds the descriptor throughout its callback.
        let borrowed = unsafe { BorrowedFd::borrow_raw(raw) };
        let descriptor = borrowed
            .try_clone_to_owned()
            .map_err(|cause| FrameError::DuplicateDescriptor { plane: 0, cause })?;
        let file = std::fs::File::from(descriptor);
        let mut source = vec![0; length];
        std::os::unix::fs::FileExt::read_exact_at(
            &file,
            &mut source,
            u64::from(frame.plane.offset),
        )
        .map_err(FrameError::ReadPixels)?;
        let row = frame.format.width as usize * 4;
        let mut pixels = Vec::with_capacity(row * frame.format.height as usize);
        for line in source.chunks_exact(stride as usize) {
            for &[blue, green, red, alpha] in line[..row].as_chunks::<4>().0 {
                let (blue, red) = if packing.swap {
                    (red, blue)
                } else {
                    (blue, red)
                };
                let alpha = if packing.opaque { u8::MAX } else { alpha };
                pixels.extend_from_slice(&[blue, green, red, alpha]);
            }
        }
        format.fourcc = packing.fourcc;
        Ok(Self::Pixels { format, pixels })
    }

    /// Builds a frame from parts for tests that do not run PipeWire.
    #[cfg(any(test, feature = "test-fakes"))]
    #[must_use]
    pub fn from_parts(
        format: CaptureFormat,
        planes: impl IntoIterator<Item = (OwnedFd, u32, u32)>,
    ) -> Self {
        Self::Dmabuf {
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

        Ok(Self::Dmabuf { format, planes })
    }
}

const UNSUPPORTED_SHARED_MEMORY: FrameError = FrameError::SharedMemory {
    kind: "an unsupported shared-memory layout",
};

/// How a shared-memory format converts to the packed layout.
struct Packing {
    fourcc: DrmFourcc,
    /// Whether the red and blue bytes trade places.
    swap: bool,
    /// Whether the fourth byte is padding to be set opaque.
    opaque: bool,
}

impl Packing {
    const fn of(fourcc: DrmFourcc) -> Option<Self> {
        let (fourcc, swap, opaque) = match fourcc {
            DrmFourcc::Argb8888 => (DrmFourcc::Argb8888, false, false),
            DrmFourcc::Xrgb8888 => (DrmFourcc::Xrgb8888, false, true),
            DrmFourcc::Abgr8888 => (DrmFourcc::Argb8888, true, false),
            DrmFourcc::Xbgr8888 => (DrmFourcc::Xrgb8888, true, true),
            _ => return None,
        };
        Some(Self {
            fourcc,
            swap,
            opaque,
        })
    }
}

/// The bytes a shared-memory frame occupies from its offset.
fn pixel_length(format: &FrameFormat, stride: u32) -> Result<usize, FrameError> {
    let row = format
        .width
        .checked_mul(4)
        .ok_or(UNSUPPORTED_SHARED_MEMORY)?;
    if stride < row {
        return Err(UNSUPPORTED_SHARED_MEMORY);
    }
    let length = usize::try_from(stride)
        .ok()
        .and_then(|stride| stride.checked_mul(format.height as usize))
        .ok_or(UNSUPPORTED_SHARED_MEMORY)?;
    if length > isize::MAX as usize {
        return Err(UNSUPPORTED_SHARED_MEMORY);
    }
    Ok(length)
}

/// An owned descriptor and layout for one dmabuf plane.
#[derive(Debug)]
pub struct CapturedPlane {
    descriptor: OwnedFd,
    offset: u32,
    stride: u32,
}

impl CapturedPlane {
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

        // Vulkan's row pitch is unsigned, so a negative stride cannot describe
        // the bottom-up layout without misrepresenting the buffer.
        let stride = u32::try_from(plane.stride).map_err(|_| FrameError::NegativeStride {
            plane: index,
            stride: plane.stride,
        })?;

        // SAFETY: PipeWire keeps the descriptor valid for this callback, and the duplicate owns the descriptor the queued frame uses.
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

/// The format and transform required to import a captured frame.
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

/// A frame's non-empty dimensions.
///
/// An empty frame cannot produce an image, so the capture boundary rejects it.
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

/// The frame orientation carried across the capture boundary.
///
/// Undefined samples identically to Normal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum FrameTransform {
    Undefined,
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
    pub fn from_wlx(transform: Transform) -> Self {
        match transform {
            Transform::Undefined => Self::Undefined,
            Transform::Normal => Self::Normal,
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

/// A bounded queue that discards old entries and never blocks the producer.
///
/// PipeWire's process callback and the frame loop must not wait for each other.
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

    /// Queues an entry and discards the oldest entry when full.
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

    /// Returns the newest entry and discards older queued entries, counting them as dropped.
    #[must_use]
    pub fn take_latest(&self) -> Option<T> {
        let mut inner = self.inner.lock();
        let newest = inner.entries.pop_back()?;

        let stale = u64::try_from(inner.entries.len()).unwrap_or(u64::MAX);
        inner.entries.clear();
        inner.counts.dropped = inner.counts.dropped.saturating_add(stale);

        Some(newest)
    }

    /// Records a conversion refusal and reports whether it is the first for this stream.
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

/// The result of pushing an entry into the queue.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pushed {
    Accepted,
    /// The queue was full, so the oldest frame was discarded to retain the newest.
    DroppedOldest,
}

/// Whether a frame conversion refusal is the first for this stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    First,
    Again,
}

/// Counts for frames produced by a stream.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameCounts {
    /// Frames converted and queued.
    pub delivered: u64,
    /// Frames queued and discarded before being drawn.
    pub dropped: u64,
    /// Frames rejected during conversion.
    pub refused: u64,
}

/// Why a captured frame could not reach the importer.
#[derive(Debug)]
pub enum FrameError {
    /// The generic conversion has no exporter to identify the completed buffer.
    Implicit,
    /// The shared-memory frame has no supported descriptor-backed pixel layout.
    SharedMemory {
        kind: &'static str,
    },
    ReadPixels(std::io::Error),
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
            Self::Implicit => f.write_str("the completed buffer requires its capture exporter"),
            Self::SharedMemory { kind } => {
                write!(f, "the stream delivered {kind}, which cannot be copied")
            }
            Self::ReadPixels(_) => f.write_str("the shared-memory pixels could not be read"),
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
            Self::DuplicateDescriptor { cause, .. } | Self::ReadPixels(cause) => Some(cause),
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

/// The number of frames held before the oldest is discarded.
///
/// Two entries cover one frame being drawn and one arriving, and a deeper queue adds only latency.
const QUEUE_DEPTH: NonZeroUsize = NonZeroUsize::MIN.saturating_add(1);

/// Data passed to the PipeWire callback through its user-data parameter, because the callback has a bare `fn` type.
struct Delivery(Arc<FrameQueue<CapturedFrame>>);

/// The callback's channel payload type.
///
/// Frames go to [`FrameQueue`] instead, because `WlxCapture`'s channel discards the newest frames when full.
type Never = std::convert::Infallible;

/// Selects the `WlxCapture` implementation used by a call.
///
/// `PipewireCapture<R>` implements `WlxCapture<U, R>` for every `U`, so fixing `U` avoids ambiguous method calls.
fn control(capture: &mut PipewireCapture<Never>) -> &mut impl WlxCapture<Delivery, Never> {
    capture
}

/// Converts one frame on PipeWire's callback thread.
fn deliver(delivery: &Delivery, frame: WlxFrame) -> Option<Never> {
    let queue = &delivery.0;

    match CapturedFrame::from_wlx(&frame) {
        Ok(frame) => {
            if queue.push(frame) == Pushed::DroppedOldest {
                debug!("the frame queue was full, so an undrawn frame was discarded");
            }
        }
        Err(error) => match queue.record_refusal() {
            // Warn once per stream, because a persistent refusal would warn every frame.
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

    /// Creates descriptors for tests without touching the filesystem.
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

    /// Creates a dmabuf frame whose raw descriptors remain valid during conversion.
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

        let planes = captured.planes().expect("a dmabuf frame has planes");
        assert_eq!(
            planes
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
        let (frame, owners) = dmabuf_frame(1);
        let borrowed = frame.planes[0].fd.expect("the plane has a descriptor");

        let captured =
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)).expect("a well-formed dmabuf frame");

        assert_ne!(
            captured.planes().expect("a dmabuf frame has planes")[0]
                .descriptor()
                .as_raw_fd(),
            borrowed,
            "the frame kept the callback's own descriptor number, which PipeWire may close",
        );
        drop(owners);
    }

    #[test]
    fn a_stream_that_reports_no_transform_leaves_the_frame_undefined() {
        let (frame, _owners) = dmabuf_frame(1);

        let captured =
            CapturedFrame::from_wlx(&WlxFrame::Dmabuf(frame)).expect("a well-formed dmabuf frame");

        assert_eq!(captured.format().transform, FrameTransform::Undefined);
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
        let error = CapturedFrame::from_wlx(&WlxFrame::Implicit(Transform::Normal))
            .expect_err("generic conversion cannot identify the exporter's buffer");

        assert!(matches!(error, FrameError::Implicit), "{error}");
        assert!(
            error.to_string().contains("requires its capture exporter"),
            "{error}"
        );
    }

    #[test]
    fn shared_memory_pixels_are_copied_packed_and_converted_before_the_callback_returns() {
        let file = smithay_free_memfd();
        let bytes = [
            99, 99, 1, 2, 3, 4, 80, 80, 80, 80, 5, 6, 7, 8, 90, 90, 90, 90,
        ];
        std::os::unix::fs::FileExt::write_all_at(&file, &bytes, 0).expect("pixels can be written");
        let mut format = format();
        format.width = 1;
        format.height = 2;
        format.drm_format.code = DrmFourcc::Xbgr8888;
        let frame = CapturedFrame::from_wlx(&WlxFrame::MemFd(wlx_capture::frame::MemFdFrame {
            format,
            plane: FramePlane {
                fd: Some(file.as_raw_fd()),
                offset: 2,
                stride: 8,
            },
            mouse: None,
        }))
        .expect("padded shared memory is supported");
        drop(file);

        let CapturedFrame::Pixels { format, pixels } = frame else {
            panic!("a shared-memory frame carries pixels");
        };
        assert_eq!(format.fourcc, DrmFourcc::Xrgb8888);
        assert_eq!(pixels, [3, 2, 1, 255, 7, 6, 5, 255]);
    }

    #[test]
    fn a_truncated_shared_memory_frame_reports_a_pixel_read_failure() {
        let file = smithay_free_memfd();
        let mut format = format();
        format.width = 1;
        format.height = 1;
        let error = CapturedFrame::from_wlx(&WlxFrame::MemFd(wlx_capture::frame::MemFdFrame {
            format,
            plane: FramePlane {
                fd: Some(file.as_raw_fd()),
                offset: 0,
                stride: 4,
            },
            mouse: None,
        }))
        .expect_err("the descriptor contains no pixels");
        assert!(matches!(error, FrameError::ReadPixels(_)));
    }

    fn smithay_free_memfd() -> std::fs::File {
        // SAFETY: the literal is NUL-terminated and the descriptor is owned on success.
        let raw = unsafe { libc::memfd_create(c"capture-test".as_ptr(), libc::MFD_CLOEXEC) };
        assert!(raw >= 0, "memfd_create succeeds");
        // SAFETY: memfd_create returned a new owned descriptor.
        unsafe { std::fs::File::from_raw_fd(raw) }
    }

    #[test]
    fn a_shared_memory_frame_is_rejected_by_name() {
        let error = CapturedFrame::from_wlx(&WlxFrame::MemPtr(MemPtrFrame {
            format: format(),
            ptr: 0,
            size: 0,
            mouse: None,
        }))
        .expect_err("safe conversion does not dereference arbitrary mapped pointers");

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

        // SAFETY: conversion duplicated the descriptor, and this test still owns the original.
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
        let queue = queue(2);

        assert_eq!(queue.record_refusal(), Refusal::First);
        assert_eq!(queue.record_refusal(), Refusal::Again);
        assert_eq!(queue.record_refusal(), Refusal::Again);
        assert_eq!(queue.counts().refused, 3);
    }
}
