//! Linux-only: turning a captured monitor frame into a `VkImage`.
//!
//! The frame thread calls this, on the main thread, with a frame PipeWire
//! produced on its own. The capture thread converts and forwards, and every
//! Vulkan import in the process happens here, through the same
//! [`DmabufImporter`] a Wayland client's buffer goes through. WayVR imports
//! inside PipeWire's receive callback and needs a second GPU queue; lunette has
//! one, and makes no assumption about LÖVR's queue topology.
//!
//! # Building and keeping a `Dmabuf`
//!
//! [`DmabufImporter`] caches on the identity of the `Dmabuf` it receives, so
//! a client cycling three buffers imports three images and then imports nothing
//! further. A capture frame arrives as descriptors, not as a `Dmabuf`, so one
//! is built here. A fresh one per frame would defeat that cache, creating and
//! destroying an image every frame for a picture whose dimensions do not
//! change.
//!
//! The built `Dmabuf` is kept, keyed on the buffer object behind plane zero
//! together with the format it was built with.
//!
//! # Retention per stream
//!
//! PipeWire negotiates its own pool per stream. A budget shared across every
//! mirrored monitor would be overrun by three eight-buffer pools. Evicting
//! under that pressure releases the buffer the next frame will use, so
//! the next frame from it rebuilds the `Dmabuf`, recreates the image, and
//! re-imports the memory. That is the per-frame cost the retention prevents,
//! and it is invisible from outside because every frame still renders. The map
//! is keyed by [`MonitorKey`] first, each stream carrying its own
//! [`RETAINED_BUFFERS_PER_STREAM`], and eviction within a stream is
//! least-recently-used, not insertion-order.
//!
//! # Retention of the installed image
//!
//! Dropping a retained `Dmabuf` lets [`DmabufImporter`] retire the image
//! behind it, and a retired image is destroyed two frames later. That is sound
//! for a client's buffer because the compositor retires one after the client
//! destroyed it, and the client destroys a buffer after committing a
//! replacement. That does not hold here: lunette's own budget controls
//! retirement, not the producer, so an image a `MonitorTextures` entry still
//! wraps could be freed underneath a live `VkImageView`. The monitor's
//! installed image is passed in on every import, and eviction skips that
//! entry.
//!
//! [`MonitorTextures`]: crate::texture::MonitorTextures

use std::{
    collections::{HashMap, VecDeque},
    fmt,
    sync::Arc,
};

use lunette_capture::{
    monitor::MonitorKey,
    stream::{CaptureFormat, CapturedFrame, MAX_PLANES},
};
use lunette_compositor::protocol::{ImageHandle, ImportedImage};
use smithay::backend::allocator::dmabuf::{Dmabuf, DmabufFlags};
use tracing::{debug, warn};

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
    streams: HashMap<MonitorKey, StreamBuffers>,
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
            streams: HashMap::new(),
        }
    }

    /// Imports a frame, or returns the image a previous frame from the same
    /// buffer produced.
    ///
    /// Takes the frame by value. On a first encounter its descriptors become the
    /// retained `Dmabuf`. On a repeat they are released here, which is correct
    /// in either case, because the buffer behind them is already held.
    ///
    /// `installed` is the image this monitor's texture currently wraps, or
    /// `None` while it holds none. Eviction refuses to release the installed
    /// image, for the reason the module note states.
    ///
    /// # Errors
    ///
    /// For a frame whose layout cannot be described, and for anything the
    /// underlying dmabuf import refuses: an unsupported format, a disjoint
    /// buffer, a driver failure.
    pub fn import(
        &mut self,
        monitor: &MonitorKey,
        frame: CapturedFrame,
        installed: Option<ImageHandle>,
    ) -> Result<ImportedImage, CaptureImportError> {
        let key = BufferKey::of(&frame)?;
        let stream = self.streams.entry(monitor.clone()).or_default();

        // Answer from the stored image, not by a second trip through the
        // importer. The strong `Dmabuf` held here keeps the importer's weak
        // cache entry alive, and the same strong reference also keeps the
        // buffer's inode from being reused for a different buffer, so the key
        // cannot alias another entry while this one exists.
        if let Some(image) = stream.touch(&key) {
            return Ok(image);
        }

        let dmabuf = build_dmabuf(frame)?;
        let image = self
            .dmabuf
            .import(&dmabuf)
            .map_err(CaptureImportError::Import)?;

        stream.retain(monitor, key, RetainedBuffer { dmabuf, image }, installed);
        self.dmabuf.evict_gone_buffers();
        Ok(image)
    }

    /// Releases every buffer held for one monitor's stream.
    ///
    /// Called from wherever the stream itself is dropped: a dismissed mirror, a
    /// monitor unplugged. Nothing else makes these collectable. The retained
    /// `Dmabuf` is a strong reference, so the importer's weak cache never
    /// observes the buffer's release, and the image and its imported memory
    /// would stay in the arena for the rest of the process.
    ///
    /// The caller releases the monitor's texture first. Dropping the `Dmabuf`
    /// retires the image behind it, and an image retired while a live texture
    /// still wraps it is freed underneath a recorded command buffer.
    pub fn forget_stream(&mut self, monitor: &MonitorKey) {
        let Some(stream) = self.streams.remove(monitor) else {
            return;
        };

        debug!(
            %monitor,
            held = stream.len(),
            "released the buffers retained for a monitor that stopped producing frames",
        );
        drop(stream);
        self.dmabuf.evict_gone_buffers();
    }

    /// Releases every buffer held for every stream, for teardown.
    pub fn forget_buffers(&mut self) {
        debug!(held = self.held(), "released the retained capture buffers");
        self.streams.clear();
        self.dmabuf.evict_gone_buffers();
    }

    /// Which monitors have buffers retained for them.
    ///
    /// The frame loop's sweep for mirrors that have stopped reads this
    /// list and the monitors holding a texture, because the two sets are not
    /// the same. A frame whose image imports but whose texture the device
    /// refuses retains a buffer here and is never recorded in [`MonitorTextures`], so
    /// a sweep reading the ledger alone would leave every buffer that monitor
    /// retained alive for the rest of the process.
    ///
    /// [`MonitorTextures`]: crate::texture::MonitorTextures
    #[must_use]
    pub fn streams(&self) -> Vec<MonitorKey> {
        self.streams.keys().cloned().collect()
    }

    /// How many buffers are held across every stream.
    ///
    /// Diagnostic. A number that keeps growing means the key is not identifying
    /// a recurring buffer as the same one. The frame loop logs it beside each
    /// monitor that produced a new texture.
    #[must_use]
    pub fn held(&self) -> usize {
        self.streams.values().map(StreamBuffers::len).sum()
    }
}

impl fmt::Debug for CaptureImporter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CaptureImporter")
            .field("streams", &self.streams.len())
            .field("held", &self.held())
            .finish_non_exhaustive()
    }
}

/// Why a captured frame could not be imported.
#[derive(Debug)]
pub enum CaptureImportError {
    /// A plane's descriptor could not be identified, so the frame cannot be
    /// distinguished from any other.
    Identify(std::io::Error),
    /// A plane's descriptor could not be duplicated into the buffer.
    Duplicate(std::io::Error),
    /// The frame reported more planes than a dmabuf can hold.
    TooManyPlanes {
        planes: usize,
    },
    /// The frame reported none, so there is nothing to import.
    NoPlanes,
    /// The frame's dimensions are outside what a dmabuf can be built for.
    ///
    /// Refused, not clamped. A buffer created for a smaller extent than
    /// the one the descriptors cover is read past its rows, which produces a
    /// picture, not an error.
    UnrepresentableSize {
        width: u32,
        height: u32,
    },
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
            Self::UnrepresentableSize { width, height } => write!(
                f,
                "a frame of {width}x{height} is larger than a dmabuf's extent can describe"
            ),
            Self::Import(cause) => write!(f, "{cause}"),
        }
    }
}

impl std::error::Error for CaptureImportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Identify(cause) | Self::Duplicate(cause) => Some(cause),
            Self::Import(cause) => Some(cause),
            Self::TooManyPlanes { .. } | Self::NoPlanes | Self::UnrepresentableSize { .. } => None,
        }
    }
}

/// How many buffers one stream holds before its least recently used is released.
///
/// PipeWire negotiates a small fixed pool per stream, four to eight in
/// practice, so a stream stays well below this and evicts nothing. The
/// headroom is for the renegotiation case, where the whole pool is replaced
/// and every entry of the previous pool has to be evicted.
const RETAINED_BUFFERS_PER_STREAM: usize = 16;

/// The buffers retained for one capture stream.
///
/// Plain data, with the whole of the eviction rule: the budget, the recency
/// order, and the installed image it refuses to release. It holds no device,
/// so the tests below exercise the rule with no Vulkan involved.
#[derive(Default)]
struct StreamBuffers {
    entries: HashMap<BufferKey, RetainedBuffer>,
    /// The keys least recently used first, in eviction order.
    order: VecDeque<BufferKey>,
    /// Whether this stream has already reported an eviction, once per stream.
    /// The condition is a pool larger than the budget, which does not resolve,
    /// so a line per eviction would be a line per frame.
    reported_eviction: bool,
}

impl StreamBuffers {
    /// The image a retained buffer already produced, marking it most recently
    /// used.
    fn touch(&mut self, key: &BufferKey) -> Option<ImportedImage> {
        let image = self.entries.get(key)?.image;

        if let Some(index) = self.order.iter().position(|held| held == key)
            && let Some(key) = self.order.remove(index)
        {
            self.order.push_back(key);
        }
        Some(image)
    }

    /// Records a newly imported buffer, releasing what the budget displaces.
    fn retain(
        &mut self,
        monitor: &MonitorKey,
        key: BufferKey,
        buffer: RetainedBuffer,
        installed: Option<ImageHandle>,
    ) {
        while self.entries.len() >= RETAINED_BUFFERS_PER_STREAM {
            let Some(evicted) = self.take_least_recently_used(installed) else {
                // Everything left is the installed image, which is never
                // released here. One entry over budget is better than a frame
                // drawn from freed memory.
                break;
            };
            self.entries.remove(&evicted);

            if !self.reported_eviction {
                self.reported_eviction = true;
                warn!(
                    %monitor,
                    budget = RETAINED_BUFFERS_PER_STREAM,
                    "this monitor cycles more capture buffers than lunette retains, so a recurring \
                     buffer is imported again each time it comes round",
                );
            }
        }

        self.order.push_back(key.clone());
        self.entries.insert(key, buffer);
    }

    /// The least recently used key that is not the installed image.
    fn take_least_recently_used(&mut self, installed: Option<ImageHandle>) -> Option<BufferKey> {
        let index = self.order.iter().position(|key| {
            self.entries
                .get(key)
                .is_some_and(|entry| Some(entry.image.image) != installed)
        })?;
        self.order.remove(index)
    }

    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// One retained buffer, and the image it was imported with.
///
/// Eviction compares the entry's image against the one a monitor's texture
/// wraps. The texture ledger names the image, not the `Dmabuf`'s identity.
struct RetainedBuffer {
    /// Held for its drop, not for its value. Closing the descriptors lets
    /// [`DmabufImporter`]'s weak cache retire the image behind them.
    #[expect(
        dead_code,
        reason = "the field is the strong reference; nothing reads it"
    )]
    dmabuf: Dmabuf,
    image: ImportedImage,
}

/// What identifies a captured frame's buffer across frames.
///
/// The buffer object behind plane zero, plus the format the image was created
/// with. The format is in the key because a renegotiation can in principle
/// return a buffer object at an address the kernel has reused, and importing
/// at the wrong format produces a picture, not an error.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct BufferKey {
    buffer: BufferIdentity,
    format: CaptureFormat,
}

impl BufferKey {
    fn of(frame: &CapturedFrame) -> Result<Self, CaptureImportError> {
        let first = frame
            .planes()
            .and_then(<[_]>::first)
            .ok_or(CaptureImportError::NoPlanes)?;

        Ok(Self {
            buffer: identify_buffer(first.descriptor()).map_err(CaptureImportError::Identify)?,
            format: frame.format(),
        })
    }
}

/// Turns a frame's descriptors into the buffer the importer consumes.
///
/// Runs once per buffer object, not once per frame, and the second
/// duplication here stays cheap because of it: the copy that matters was made
/// on the capture thread, and PipeWire's own descriptors are valid inside its
/// callback only.
fn build_dmabuf(frame: CapturedFrame) -> Result<Dmabuf, CaptureImportError> {
    let format = frame.format();
    let planes = frame
        .planes()
        .filter(|planes| !planes.is_empty())
        .ok_or(CaptureImportError::NoPlanes)?;
    if planes.len() > MAX_PLANES {
        return Err(CaptureImportError::TooManyPlanes {
            planes: planes.len(),
        });
    }

    let extent = |value: u32| {
        i32::try_from(value).map_err(|_| CaptureImportError::UnrepresentableSize {
            width: format.size.width(),
            height: format.size.height(),
        })
    };
    let mut builder = Dmabuf::builder(
        (extent(format.size.width())?, extent(format.size.height())?),
        format.fourcc,
        format.modifier,
        DmabufFlags::empty(),
    );

    for (index, plane) in planes.iter().enumerate() {
        let descriptor = plane
            .descriptor()
            .try_clone_to_owned()
            .map_err(CaptureImportError::Duplicate)?;
        // Refused rather than clamped, as the extent above is. The check over
        // `MAX_PLANES` already bounds this, so the failure is unreachable and
        // is written out rather than asserted away.
        let index = u32::try_from(index).map_err(|_| CaptureImportError::TooManyPlanes {
            planes: planes.len(),
        })?;

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

    use lunette_capture::{
        monitor::{ConnectorKind, ConnectorName},
        stream::{FrameSize, FrameTransform},
    };
    use lunette_compositor::protocol::PixelSize;
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

    fn monitor(index: u32) -> MonitorKey {
        MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, index))
    }

    fn image(raw: u64) -> ImageHandle {
        ImageHandle::new(raw).expect("a non-zero image handle")
    }

    /// A retained entry over a real buffer, and the key identifying it.
    ///
    /// The buffer is real because dropping it is the event the eviction rule
    /// handles, and because a real one gives the key a distinct inode. The
    /// caller keeps the returned pipe ends open for the duration: a closed
    /// pipe's inode is reusable, and two entries sharing one would collide.
    fn retained(handle: u64) -> (BufferKey, RetainedBuffer, Vec<OwnedFd>) {
        let (captured, owners) = frame(1);
        let key = BufferKey::of(&captured).expect("a frame with a plane");
        let dmabuf = build_dmabuf(captured).expect("a well-formed frame");

        (
            key,
            RetainedBuffer {
                dmabuf,
                image: ImportedImage {
                    image: image(handle),
                    size: PixelSize::new(1920, 1080),
                    format: Fourcc::Argb8888,
                    modifier: Modifier::Linear,
                },
            },
            owners,
        )
    }

    /// Fills a stream to its budget, returning the keys in insertion order and
    /// the pipe ends keeping the buffers' descriptors alive.
    ///
    /// The first entry is image 1, which is what a test naming an installed
    /// image passes.
    fn filled(installed: Option<ImageHandle>) -> (StreamBuffers, Vec<BufferKey>, Vec<OwnedFd>) {
        let mut stream = StreamBuffers::default();
        let mut keys = Vec::new();
        let mut owners = Vec::new();

        for index in 0..RETAINED_BUFFERS_PER_STREAM {
            let handle = u64::try_from(index).expect("a small index") + 1;
            let (key, buffer, mut held) = retained(handle);
            stream.retain(&monitor(1), key.clone(), buffer, installed);
            keys.push(key);
            owners.append(&mut held);
        }

        (stream, keys, owners)
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
    fn a_frame_with_more_planes_than_a_dmabuf_holds_is_refused() {
        let (captured, _owners) = frame(MAX_PLANES + 1);

        assert!(matches!(
            build_dmabuf(captured),
            Err(CaptureImportError::TooManyPlanes { planes: 5 }),
        ));
    }

    #[test]
    fn two_frames_from_one_buffer_share_a_key() {
        // The buffer identity answers for every frame that carries a
        // duplicate of this descriptor, so a recurring PipeWire buffer is not
        // imported again on every frame it appears in.
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
        // Importing at the previous format would produce a picture, not an
        // error, which is the outcome the format in the key rules out.
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

    #[test]
    fn the_image_a_monitors_texture_wraps_is_never_evicted() {
        // The use-after-free this rule exists for: releasing the retained
        // `Dmabuf` retires the image behind it, and an image retired while a
        // `MonitorTextures` entry still names it is destroyed two frames
        // later, underneath a live `VkImageView`. A paused mirror reaches this
        // without contrivance: it keeps its texture while producing no frames,
        // so its buffer is the least recently used one for as long as the
        // pause lasts.
        let installed = image(1);
        let (mut stream, keys, _owners) = filled(Some(installed));
        let oldest = keys.first().expect("the budget is not zero").clone();

        let (key, buffer, _held) = retained(9_999);
        stream.retain(&monitor(1), key, buffer, Some(installed));

        assert!(
            stream.entries.contains_key(&oldest),
            "the least recently used entry is the installed image, and evicting it would free the \
             image the monitor's texture wraps",
        );
        assert_eq!(
            stream.entries.len(),
            RETAINED_BUFFERS_PER_STREAM,
            "one other entry went instead, so the budget still holds",
        );
    }

    #[test]
    fn the_least_recently_used_buffer_is_the_one_released() {
        // Insertion-order eviction releases the buffer that has been resident
        // longest, which for a steadily cycling pool is the one about to come
        // round again.
        let (mut stream, keys, _owners) = filled(None);
        let oldest = keys.first().expect("the budget is not zero").clone();
        let next = keys.get(1).expect("the budget is more than one").clone();

        assert!(stream.touch(&oldest).is_some());
        let (key, buffer, _held) = retained(9_001);
        stream.retain(&monitor(1), key, buffer, None);

        assert!(
            stream.entries.contains_key(&oldest),
            "it was used most recently, so it is the last thing to release",
        );
        assert!(!stream.entries.contains_key(&next));
    }

    #[test]
    fn a_recurring_buffer_answers_with_the_image_it_already_produced() {
        let mut stream = StreamBuffers::default();
        let (key, buffer, _held) = retained(7);
        let (absent, _buffer, _held) = retained(8);
        stream.retain(&monitor(1), key.clone(), buffer, None);

        assert_eq!(stream.touch(&key).map(|held| held.image), Some(image(7)));
        assert_eq!(stream.touch(&absent).map(|held| held.image), None);
    }
}
