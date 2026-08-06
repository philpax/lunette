//! Linux-only: turning a captured monitor frame into a `VkImage`.
//!
//! The frame thread calls this, on the main thread, with a frame PipeWire
//! produced on its own. That is the whole point of the arrangement: the capture
//! thread converts and forwards, and every Vulkan import in the process happens
//! here, through the same [`DmabufImporter`] a Wayland client's buffer goes
//! through. WayVR imports inside PipeWire's receive callback and therefore needs
//! a second GPU queue; lunette has one, and makes no assumption about LÖVR's
//! queue topology.
//!
//! # Why a `Dmabuf` is built and kept
//!
//! [`DmabufImporter`] caches on the identity of the `Dmabuf` it was handed, so
//! a client cycling three buffers imports three images and then imports nothing
//! further. A capture frame arrives as descriptors rather than as a `Dmabuf`, so
//! one is built here — and building a fresh one per frame would defeat that
//! cache, creating and destroying an image every frame for a picture that never
//! changed shape.
//!
//! So the built `Dmabuf` is kept, keyed on the buffer object behind plane zero
//! together with the format it was built for. PipeWire cycles a small fixed pool
//! per stream, so the map reaches that size and stops. A renegotiation replaces
//! the pool, which is what [`RETAINED_BUFFERS`] bounds: the oldest entries are
//! evicted, releasing the descriptors and letting the importer retire the images
//! behind them.

use std::{
    collections::{HashMap, VecDeque},
    fmt,
    sync::Arc,
};

use lunette_capture::stream::{CaptureFormat, CapturedFrame, MAX_PLANES};
use lunette_compositor::protocol::ImportedImage;
use smithay::backend::allocator::dmabuf::{Dmabuf, DmabufFlags};
use tracing::debug;

use crate::import::{
    device::GraphicsDevice,
    dmabuf::{BufferIdentity, DmabufError, DmabufImporter, ImageArena, identify_buffer},
};

/// Imports captured monitor frames on the main thread.
///
/// Holds its own [`DmabufImporter`] against the same device and the same image
/// arena the compositor thread's one uses, so images created here are retired
/// and destroyed by exactly the same machinery.
pub struct CaptureImporter {
    dmabuf: DmabufImporter,
    buffers: HashMap<BufferKey, Dmabuf>,
    /// Insertion order, so the oldest entry is the one evicted.
    order: VecDeque<BufferKey>,
}

impl CaptureImporter {
    /// Builds an importer against the device and the arena the compositor
    /// thread's [`Importer`] already uses.
    ///
    /// [`Importer`]: crate::import::Importer
    #[must_use]
    pub fn new(device: Arc<GraphicsDevice>, arena: ImageArena) -> Self {
        Self {
            dmabuf: DmabufImporter::new(device, arena),
            buffers: HashMap::new(),
            order: VecDeque::new(),
        }
    }

    /// Imports a frame, or returns the image a previous frame from the same
    /// buffer produced.
    ///
    /// Takes the frame by value: on a first sighting its descriptors become the
    /// retained `Dmabuf`, and on a repeat they are released here, which is
    /// correct either way because the buffer behind them is already held.
    ///
    /// # Errors
    ///
    /// For a frame whose layout cannot be described, and for anything the
    /// underlying dmabuf import refuses — an unsupported format, a disjoint
    /// buffer, a driver failure.
    pub fn import(&mut self, frame: CapturedFrame) -> Result<ImportedImage, CaptureImportError> {
        let key = BufferKey::of(&frame)?;

        if let Some(dmabuf) = self.buffers.get(&key) {
            return self
                .dmabuf
                .import(dmabuf)
                .map_err(CaptureImportError::Import);
        }

        let dmabuf = build_dmabuf(frame)?;
        let image = self
            .dmabuf
            .import(&dmabuf)
            .map_err(CaptureImportError::Import)?;

        self.retain(key, dmabuf);
        Ok(image)
    }

    /// Releases every buffer held for a stream that has stopped.
    ///
    /// Dropping the `Dmabuf`s closes their descriptors, which is what lets the
    /// importer's own weak cache retire the images behind them.
    pub fn forget_buffers(&mut self) {
        debug!(
            held = self.buffers.len(),
            "released the retained capture buffers"
        );
        self.buffers.clear();
        self.order.clear();
        self.dmabuf.evict_gone_buffers();
    }

    /// How many buffers are held. Diagnostic: a number that only grows means the
    /// key is not identifying a recurring buffer as the same one.
    #[must_use]
    pub fn held(&self) -> usize {
        self.buffers.len()
    }

    fn retain(&mut self, key: BufferKey, dmabuf: Dmabuf) {
        while self.order.len() >= RETAINED_BUFFERS {
            if let Some(evicted) = self.order.pop_front() {
                self.buffers.remove(&evicted);
            }
        }

        self.order.push_back(key.clone());
        self.buffers.insert(key, dmabuf);
        self.dmabuf.evict_gone_buffers();
    }
}

impl fmt::Debug for CaptureImporter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CaptureImporter")
            .field("held", &self.buffers.len())
            .finish_non_exhaustive()
    }
}

/// Why a captured frame could not be imported.
#[derive(Debug)]
pub enum CaptureImportError {
    /// A plane's descriptor could not be identified, so the frame cannot be
    /// told apart from any other.
    Identify(std::io::Error),
    /// A plane's descriptor could not be duplicated into the buffer.
    Duplicate(std::io::Error),
    /// The frame reported more planes than a dmabuf can hold.
    TooManyPlanes {
        planes: usize,
    },
    /// The frame reported none, so there is nothing to import.
    NoPlanes,
    Import(DmabufError),
}

impl fmt::Display for CaptureImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "capture import: ")?;
        match self {
            Self::Identify(_) => f.write_str("a plane's descriptor could not be identified"),
            Self::Duplicate(_) => f.write_str("a plane's descriptor could not be duplicated"),
            Self::TooManyPlanes { planes } => write!(
                f,
                "the frame carries {planes} planes, and a dmabuf holds at most {MAX_PLANES}"
            ),
            Self::NoPlanes => f.write_str("the frame carries no planes"),
            Self::Import(cause) => write!(f, "{cause}"),
        }
    }
}

impl std::error::Error for CaptureImportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Identify(cause) | Self::Duplicate(cause) => Some(cause),
            Self::Import(cause) => Some(cause),
            Self::TooManyPlanes { .. } | Self::NoPlanes => None,
        }
    }
}

/// How many capture buffers are held before the oldest is released.
///
/// PipeWire negotiates a small fixed pool per stream, so the map settles well
/// below this. The bound exists for the renegotiation case, where the whole pool
/// is replaced and the previous one has to go.
const RETAINED_BUFFERS: usize = 16;

/// What identifies a captured frame's buffer across frames.
///
/// The buffer object behind plane zero, plus the format the image was created
/// for. The format is in the key because a renegotiation can in principle hand
/// back a buffer object at an address the kernel has reused, and importing at
/// the wrong format produces a picture rather than an error.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct BufferKey {
    buffer: BufferIdentity,
    format: CaptureFormat,
}

impl BufferKey {
    fn of(frame: &CapturedFrame) -> Result<Self, CaptureImportError> {
        let first = frame.planes().first().ok_or(CaptureImportError::NoPlanes)?;

        Ok(Self {
            buffer: identify_buffer(first.descriptor()).map_err(CaptureImportError::Identify)?,
            format: frame.format(),
        })
    }
}

/// Turns a frame's descriptors into the buffer the importer consumes.
///
/// Once per buffer object rather than once per frame, which is what makes the
/// second duplication here cheap: the copy that matters was made on the capture
/// thread, because PipeWire's own descriptors are valid only inside its
/// callback.
fn build_dmabuf(frame: CapturedFrame) -> Result<Dmabuf, CaptureImportError> {
    let format = frame.format();
    let planes = frame.planes();

    if planes.is_empty() {
        return Err(CaptureImportError::NoPlanes);
    }

    let mut builder = Dmabuf::builder(
        (
            i32::try_from(format.size.width()).unwrap_or(i32::MAX),
            i32::try_from(format.size.height()).unwrap_or(i32::MAX),
        ),
        format.fourcc,
        format.modifier,
        DmabufFlags::empty(),
    );

    for (index, plane) in planes.iter().enumerate() {
        let descriptor = plane
            .descriptor()
            .try_clone_to_owned()
            .map_err(CaptureImportError::Duplicate)?;
        let index = u32::try_from(index).unwrap_or(u32::MAX);

        if !builder.add_plane(descriptor, index, plane.offset(), plane.stride()) {
            return Err(CaptureImportError::TooManyPlanes {
                planes: planes.len(),
            });
        }
    }

    builder.build().ok_or(CaptureImportError::NoPlanes)
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::os::fd::OwnedFd;

    use lunette_capture::stream::{FrameSize, FrameTransform};
    use pretty_assertions::assert_eq;
    use smithay::backend::allocator::{Buffer as _, Fourcc, Modifier};

    use super::*;

    /// A descriptor to hand around, and the write end that keeps its pipe alive.
    fn pipe() -> (OwnedFd, OwnedFd) {
        let (read, write) = std::io::pipe().expect("a pipe can be created");
        (OwnedFd::from(read), OwnedFd::from(write))
    }

    fn format() -> CaptureFormat {
        CaptureFormat {
            size: FrameSize::new(1920, 1080).expect("a non-empty frame"),
            fourcc: Fourcc::Argb8888,
            modifier: Modifier::Linear,
            transform: FrameTransform::Normal,
        }
    }

    /// A frame over `planes` descriptors, and the pipe ends behind them.
    fn frame(planes: usize) -> (CapturedFrame, Vec<OwnedFd>) {
        let mut owners = Vec::new();
        let mut parts = Vec::new();

        for index in 0..planes {
            let (read, write) = pipe();
            let index = u32::try_from(index).expect("a small plane index");
            parts.push((read, index * 4096, 7680));
            owners.push(write);
        }

        (CapturedFrame::from_parts(format(), parts), owners)
    }

    #[test]
    fn a_captured_frame_becomes_a_buffer_with_every_plane_intact() {
        let (captured, _owners) = frame(3);

        let dmabuf = build_dmabuf(captured).expect("a well-formed frame");

        assert_eq!(dmabuf.num_planes(), 3);
        assert_eq!(dmabuf.offsets().collect::<Vec<_>>(), vec![0, 4096, 8192]);
        assert_eq!(dmabuf.strides().collect::<Vec<_>>(), vec![7680, 7680, 7680]);
    }

    #[test]
    fn the_buffer_carries_the_frame_s_own_size_and_format() {
        let (captured, _owners) = frame(1);

        let dmabuf = build_dmabuf(captured).expect("a well-formed frame");

        assert_eq!(dmabuf.size(), (1920, 1080).into());
        assert_eq!(dmabuf.format().code, Fourcc::Argb8888);
        assert_eq!(dmabuf.format().modifier, Modifier::Linear);
    }

    #[test]
    fn a_frame_with_no_planes_produces_no_buffer() {
        let (captured, _owners) = frame(0);

        assert!(matches!(
            build_dmabuf(captured),
            Err(CaptureImportError::NoPlanes),
        ));
    }

    #[test]
    fn two_frames_from_one_buffer_share_a_key() {
        // This is what keeps a recurring PipeWire buffer from being imported
        // again on every frame it appears in.
        let (read, _write) = pipe();
        let duplicate = read.try_clone().expect("a descriptor can be duplicated");

        let first = CapturedFrame::from_parts(format(), [(read, 0, 7680)]);
        let second = CapturedFrame::from_parts(format(), [(duplicate, 0, 7680)]);

        assert_eq!(
            BufferKey::of(&first).expect("a frame with a plane"),
            BufferKey::of(&second).expect("a frame with a plane"),
        );
    }

    #[test]
    fn two_frames_from_different_buffers_do_not_share_a_key() {
        let (first, _owners) = frame(1);
        let (second, _owners) = frame(1);

        assert_ne!(
            BufferKey::of(&first).expect("a frame with a plane"),
            BufferKey::of(&second).expect("a frame with a plane"),
        );
    }

    #[test]
    fn one_buffer_renegotiated_to_another_format_does_not_share_a_key() {
        // Importing at the previous format would produce a picture rather than
        // an error, which is the outcome the format in the key rules out.
        let (read, _write) = pipe();
        let duplicate = read.try_clone().expect("a descriptor can be duplicated");

        let before = CapturedFrame::from_parts(format(), [(read, 0, 7680)]);
        let after = CapturedFrame::from_parts(
            CaptureFormat {
                fourcc: Fourcc::Xrgb8888,
                ..format()
            },
            [(duplicate, 0, 7680)],
        );

        assert_ne!(
            BufferKey::of(&before).expect("a frame with a plane"),
            BufferKey::of(&after).expect("a frame with a plane"),
        );
    }
}
