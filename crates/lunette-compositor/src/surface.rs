//! Adapted from WayVR's `backend/wayvr/mod.rs` surface-buffer fragments at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Per-surface state for the compositor's commit path.
//!
//! [`SurfaceRegistry`] maps compositor-thread `wl_surface` object IDs to stable
//! [`SurfaceId`] values that can cross to the main thread.
//!
//! [`RetainedBuffers`] holds each surface's client buffer while lunette samples it.
//! It releases a buffer when the surface stops using it, so the client can reuse it
//! only after sampling ends.
//!
//! [`BufferImporter`] separates Wayland buffer handling from graphics-device
//! imports. The graphics implementation lives in `lunette`, while this crate
//! supplies the seam used by device-free compositor tests.

use std::collections::HashMap;

use smithay::{
    backend::allocator::dmabuf::Dmabuf,
    reexports::wayland_server::{
        Resource,
        backend::ObjectId,
        protocol::{wl_buffer::WlBuffer, wl_output, wl_shm, wl_surface::WlSurface},
    },
};

use crate::protocol::{ImportedImage, PixelSize, SurfaceId};

/// Maps compositor-thread surface objects to stable identifiers.
///
/// Identifiers are minted in order and never reused, so a stale [`SurfaceId`]
/// cannot refer to a different surface.
#[derive(Debug, Default)]
pub(crate) struct SurfaceRegistry {
    ids: HashMap<ObjectId, SurfaceId>,
    minted: u64,
}

impl SurfaceRegistry {
    /// Returns the stable identifier for a surface, minting one on first sight.
    pub(crate) fn id_for(&mut self, surface: &WlSurface) -> SurfaceId {
        if let Some(id) = self.ids.get(&surface.id()) {
            return *id;
        }

        self.minted += 1;
        let id = SurfaceId::new(self.minted).unwrap_or_else(|| {
            unreachable!("the counter starts at one and only increases, so it is never zero")
        });
        self.ids.insert(surface.id(), id);
        id
    }

    /// Returns a surface's identifier without minting one.
    pub(crate) fn get(&self, surface: &WlSurface) -> Option<SurfaceId> {
        self.ids.get(&surface.id()).copied()
    }

    /// Whether an identifier still names a live surface.
    #[must_use]
    pub(crate) fn knows(&self, id: SurfaceId) -> bool {
        self.ids.values().any(|known| *known == id)
    }

    /// Removes a destroyed surface's identifier and returns it.
    pub(crate) fn forget(&mut self, surface: &WlSurface) -> Option<SurfaceId> {
        self.ids.remove(&surface.id())
    }
}

/// A buffer that can be released to its client.
///
/// This seam lets tests verify buffer lifetime without a Wayland connection.
pub(crate) trait ReleasableBuffer {
    fn release(&self);
}

impl ReleasableBuffer for WlBuffer {
    fn release(&self) {
        WlBuffer::release(self);
    }
}

/// The buffer lunette is still sampling for each surface.
///
/// A retained buffer is not released until sampling stops, which prevents the
/// client from drawing into memory that lunette is still reading.
#[derive(Debug)]
pub(crate) struct RetainedBuffers<B> {
    retained: HashMap<SurfaceId, B>,
}

impl<B> Default for RetainedBuffers<B> {
    fn default() -> Self {
        Self {
            retained: HashMap::new(),
        }
    }
}

impl<B: ReleasableBuffer + PartialEq> RetainedBuffers<B> {
    /// Retains a surface's buffer and releases the buffer it replaces.
    ///
    /// Retaining the same buffer is a no-op. Re-importing a retained buffer during
    /// a graphics restart must not release it while lunette still samples it.
    pub(crate) fn retain(&mut self, surface: SurfaceId, buffer: B) {
        let Some(previous) = self.retained.insert(surface, buffer) else {
            return;
        };
        if self.retained.get(&surface) != Some(&previous) {
            previous.release();
        }
    }

    /// Iterates retained buffers with their surface identifiers.
    ///
    /// The graphics restart uses these buffers to re-import content without a new
    /// client commit.
    pub(crate) fn entries(&self) -> impl Iterator<Item = (SurfaceId, &B)> {
        self.retained
            .iter()
            .map(|(surface, buffer)| (*surface, buffer))
    }

    pub(crate) fn forget(&mut self, surface: SurfaceId) {
        if let Some(buffer) = self.retained.remove(&surface) {
            buffer.release();
        }
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.retained.len()
    }
}

/// Imports committed client buffers without coupling the compositor to graphics APIs.
///
/// Implementations run on the compositor thread. They may create images and allocate
/// memory, but must not submit queue work because the frame thread owns the queue.
/// This seam also lets compositor tests run without a graphics device.
pub trait BufferImporter: Send + std::fmt::Debug {
    /// Imports a client's dmabuf.
    ///
    /// The `Dmabuf` owns its file descriptors and closes them on drop. An
    /// implementation that transfers a descriptor to the graphics API must duplicate it.
    fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, ImportFailed>;

    /// Copies a client's shared-memory buffer into tightly packed pixels.
    ///
    /// The compositor copies `pixels` from the client's pool mapping before this call;
    /// the mapping is not passed to the importer. The slice is valid only for this call,
    /// and the frame thread uploads the returned pixels because it owns the graphics queue.
    fn import_shm(&mut self, pixels: &[u8], layout: ShmLayout)
    -> Result<PixelBuffer, ImportFailed>;

    /// Whether the importer can accept dmabuf objects from the client.
    ///
    /// A graphics restart returns `false` while no device is available. The dmabuf
    /// protocol must still acknowledge buffer creation: rejecting the import there
    /// disconnects the client, while rejecting the buffer at commit lets it redraw.
    fn accepts_imports(&self) -> bool;

    /// Drops cached imports whose client buffers are no longer alive.
    ///
    /// Implementations with weak cache keys must sweep after dispatch and when a
    /// surface releases content, because dropping a `wl_buffer` does not sweep the cache.
    fn sweep(&mut self);
}

/// An importer used while a graphics restart has no device available.
///
/// It rejects imports so the commit path releases the client buffer and preserves
/// the surface's previous content until the client draws again. The compositor keeps
/// this implementation instead of using an optional importer, so every call follows
/// the same stateful interface.
#[derive(Debug)]
pub(crate) struct NoGraphics;

impl BufferImporter for NoGraphics {
    fn accepts_imports(&self) -> bool {
        false
    }

    fn import_dmabuf(&mut self, _dmabuf: &Dmabuf) -> Result<ImportedImage, ImportFailed> {
        Err(ImportFailed::new(NO_DEVICE))
    }

    fn import_shm(
        &mut self,
        _pixels: &[u8],
        _layout: ShmLayout,
    ) -> Result<PixelBuffer, ImportFailed> {
        Err(ImportFailed::new(NO_DEVICE))
    }

    fn sweep(&mut self) {}
}

const NO_DEVICE: &str = "lunette has no graphics device while a restart is in progress";

/// Compositor-owned pixels packed as `width * height * 4` bytes for texture upload.
///
/// Construction rejects any other length, so consumers can use the dimensions without
/// repeating the size check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PixelBuffer {
    size: PixelSize,
    format: ShmFormat,
    pixels: Vec<u8>,
}

impl PixelBuffer {
    #[must_use]
    pub fn new(size: PixelSize, format: ShmFormat, pixels: Vec<u8>) -> Option<Self> {
        let expected = usize::try_from(size.width)
            .ok()?
            .checked_mul(usize::try_from(size.height).ok()?)?
            .checked_mul(ShmFormat::BYTES_PER_PIXEL as usize)?;

        (pixels.len() == expected).then_some(Self {
            size,
            format,
            pixels,
        })
    }

    #[must_use]
    pub fn size(&self) -> PixelSize {
        self.size
    }

    #[must_use]
    pub fn format(&self) -> ShmFormat {
        self.format
    }

    #[must_use]
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportFailed {
    message: String,
}

impl ImportFailed {
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for ImportFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "import: {}", self.message)
    }
}

impl std::error::Error for ImportFailed {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShmLayout {
    pub size: PixelSize,
    /// Bytes per row, including any client padding.
    pub stride: u32,
    pub format: ShmFormat,
}

/// A shared-memory pixel format supported by lunette.
///
/// Lunette accepts the two formats required by `wl_shm`; other protocol formats
/// are rejected rather than passed to an importer without support for them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ShmFormat {
    /// Little-endian bytes in `[B, G, R, A]` order.
    Argb8888,
    /// Little-endian bytes in `[B, G, R, X]` order. The importer sets the fourth
    /// byte to opaque alpha before upload.
    Xrgb8888,
}

impl ShmFormat {
    pub const BYTES_PER_PIXEL: u32 = 4;

    #[must_use]
    pub fn from_protocol(format: wl_shm::Format) -> Option<Self> {
        match format {
            wl_shm::Format::Argb8888 => Some(Self::Argb8888),
            wl_shm::Format::Xrgb8888 => Some(Self::Xrgb8888),
            _ => None,
        }
    }
}

/// A client's requested buffer transform before display.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum BufferTransform {
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

impl BufferTransform {
    /// Converts a protocol transform when it is known to this implementation.
    ///
    /// Unknown values are rejected rather than silently treated as `Normal`.
    #[must_use]
    pub fn from_protocol(transform: wl_output::Transform) -> Option<Self> {
        match transform {
            wl_output::Transform::Normal => Some(Self::Normal),
            wl_output::Transform::_90 => Some(Self::Rotated90),
            wl_output::Transform::_180 => Some(Self::Rotated180),
            wl_output::Transform::_270 => Some(Self::Rotated270),
            wl_output::Transform::Flipped => Some(Self::Flipped),
            wl_output::Transform::Flipped90 => Some(Self::Flipped90),
            wl_output::Transform::Flipped180 => Some(Self::Flipped180),
            wl_output::Transform::Flipped270 => Some(Self::Flipped270),
            _ => None,
        }
    }

    #[must_use]
    pub const fn swaps_axes(self) -> bool {
        matches!(
            self,
            Self::Rotated90 | Self::Rotated270 | Self::Flipped90 | Self::Flipped270
        )
    }
}

/// A positive integer buffer scale from `wl_surface.set_buffer_scale`.
///
/// A surface that has not set a scale uses 1. Zero and negative values are
/// rejected as protocol errors rather than clamped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct BufferScale(u32);

impl BufferScale {
    pub const ONE: Self = Self(1);

    #[must_use]
    pub const fn from_protocol(scale: i32) -> Option<Self> {
        if scale > 0 {
            #[expect(
                clippy::cast_sign_loss,
                reason = "the branch above establishes that the value is positive"
            )]
            Some(Self(scale as u32))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get(self) -> u32 {
        self.0
    }
}

impl Default for BufferScale {
    fn default() -> Self {
        Self::ONE
    }
}

/// The size, transform, and scale from a surface's last committed buffer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SurfaceContent {
    /// The buffer's size in its own pixels, before scaling.
    pub(crate) size: PixelSize,
    pub(crate) transform: BufferTransform,
    pub(crate) scale: BufferScale,
}

impl SurfaceContent {
    /// Returns the surface size in logical pixels.
    ///
    /// Quarter-turn transforms exchange the axes before the positive buffer scale
    /// divides both dimensions.
    pub(crate) fn logical_size(self) -> PixelSize {
        let (width, height) = if self.transform.swaps_axes() {
            (self.size.height, self.size.width)
        } else {
            (self.size.width, self.size.height)
        };

        PixelSize::new(width / self.scale.get(), height / self.scale.get())
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::{cell::RefCell, rc::Rc};

    use pretty_assertions::assert_eq;

    use super::*;

    /// Records releases in order for buffer-lifetime assertions.
    #[derive(Clone, Debug, PartialEq)]
    struct CountedBuffer {
        name: &'static str,
        released: Rc<RefCell<Vec<&'static str>>>,
    }

    impl ReleasableBuffer for CountedBuffer {
        fn release(&self) {
            self.released.borrow_mut().push(self.name);
        }
    }

    fn surface(raw: u64) -> SurfaceId {
        SurfaceId::new(raw).expect("non-zero")
    }

    #[test]
    fn the_first_buffer_for_a_surface_releases_nothing() {
        let released = Rc::new(RefCell::new(Vec::new()));
        let mut buffers = RetainedBuffers::default();

        buffers.retain(
            surface(1),
            CountedBuffer {
                name: "first",
                released: Rc::clone(&released),
            },
        );

        assert!(released.borrow().is_empty());
        assert_eq!(buffers.len(), 1);
    }

    #[test]
    fn a_new_buffer_releases_the_one_it_replaces() {
        let released = Rc::new(RefCell::new(Vec::new()));
        let mut buffers = RetainedBuffers::default();
        let buffer = |name| CountedBuffer {
            name,
            released: Rc::clone(&released),
        };

        buffers.retain(surface(1), buffer("first"));
        buffers.retain(surface(1), buffer("second"));
        buffers.retain(surface(1), buffer("third"));

        assert_eq!(*released.borrow(), ["first", "second"]);
        assert_eq!(
            buffers.len(),
            1,
            "only the newest buffer is held, whatever the client's cycle length"
        );
    }

    /// Retaining the same buffer must not release it while sampling continues.
    #[test]
    fn retaining_the_buffer_already_held_releases_nothing() {
        let released = Rc::new(RefCell::new(Vec::new()));
        let mut buffers = RetainedBuffers::default();
        let buffer = CountedBuffer {
            name: "held",
            released: Rc::clone(&released),
        };

        buffers.retain(surface(1), buffer.clone());
        buffers.retain(surface(1), buffer);

        assert!(
            released.borrow().is_empty(),
            "the buffer is still being sampled, so the client must not be told it is free"
        );
        assert_eq!(buffers.len(), 1);
    }

    #[test]
    fn the_retained_buffers_can_be_enumerated_for_re_import() {
        let released = Rc::new(RefCell::new(Vec::new()));
        let mut buffers = RetainedBuffers::default();
        let buffer = |name| CountedBuffer {
            name,
            released: Rc::clone(&released),
        };

        buffers.retain(surface(1), buffer("one"));
        buffers.retain(surface(2), buffer("two"));

        let mut named: Vec<_> = buffers
            .entries()
            .map(|(surface, buffer)| (surface, buffer.name))
            .collect();
        named.sort_unstable();
        assert_eq!(named, [(surface(1), "one"), (surface(2), "two")]);
    }

    #[test]
    fn surfaces_do_not_release_each_others_buffers() {
        let released = Rc::new(RefCell::new(Vec::new()));
        let mut buffers = RetainedBuffers::default();
        let buffer = |name| CountedBuffer {
            name,
            released: Rc::clone(&released),
        };

        buffers.retain(surface(1), buffer("one"));
        buffers.retain(surface(2), buffer("two"));

        assert!(released.borrow().is_empty());
        assert_eq!(buffers.len(), 2);
    }

    #[test]
    fn forgetting_a_surface_releases_its_buffer_and_is_idempotent() {
        let released = Rc::new(RefCell::new(Vec::new()));
        let mut buffers = RetainedBuffers::default();

        buffers.retain(
            surface(1),
            CountedBuffer {
                name: "held",
                released: Rc::clone(&released),
            },
        );
        buffers.forget(surface(1));
        buffers.forget(surface(1));

        assert_eq!(
            *released.borrow(),
            ["held"],
            "a second forget must not release the same buffer twice"
        );
        assert_eq!(buffers.len(), 0);
    }

    #[test]
    fn forgetting_a_surface_that_never_committed_does_nothing() {
        let mut buffers = RetainedBuffers::<CountedBuffer>::default();
        buffers.forget(surface(9));
        assert_eq!(buffers.len(), 0);
    }

    #[test]
    fn a_scale_rejects_what_the_protocol_forbids() {
        assert_eq!(BufferScale::from_protocol(0), None);
        assert_eq!(BufferScale::from_protocol(-2), None);
        assert_eq!(BufferScale::from_protocol(i32::MIN), None);
        assert_eq!(BufferScale::from_protocol(1), Some(BufferScale::ONE));
        assert_eq!(BufferScale::from_protocol(3).map(BufferScale::get), Some(3));
    }

    #[test]
    fn an_unrotated_surface_divides_by_its_scale() {
        let content = SurfaceContent {
            size: PixelSize::new(1920, 1080),
            transform: BufferTransform::Normal,
            scale: BufferScale::from_protocol(2).expect("positive"),
        };

        assert_eq!(content.logical_size(), PixelSize::new(960, 540));
    }

    #[test]
    fn a_rotated_surface_exchanges_its_axes() {
        for transform in [
            BufferTransform::Rotated90,
            BufferTransform::Rotated270,
            BufferTransform::Flipped90,
            BufferTransform::Flipped270,
        ] {
            let content = SurfaceContent {
                size: PixelSize::new(1920, 1080),
                transform,
                scale: BufferScale::ONE,
            };

            assert_eq!(
                content.logical_size(),
                PixelSize::new(1080, 1920),
                "{transform:?} rotates by a quarter turn"
            );
        }

        for transform in [
            BufferTransform::Normal,
            BufferTransform::Rotated180,
            BufferTransform::Flipped,
            BufferTransform::Flipped180,
        ] {
            assert!(!transform.swaps_axes(), "{transform:?} keeps its axes");
        }
    }

    #[test]
    fn a_transform_from_a_later_protocol_version_is_not_mistaken_for_normal() {
        let unknown = wl_output::Transform::try_from(64);
        assert!(
            unknown.is_err() || BufferTransform::from_protocol(unknown.expect("checked")).is_none(),
            "an unrecognised transform must not silently become Normal"
        );
    }

    #[test]
    fn a_pixel_buffer_accepts_only_its_own_declared_length() {
        let size = PixelSize::new(3, 2);
        assert!(PixelBuffer::new(size, ShmFormat::Argb8888, vec![0; 24]).is_some());
        assert!(PixelBuffer::new(size, ShmFormat::Argb8888, vec![0; 23]).is_none());
        assert!(PixelBuffer::new(size, ShmFormat::Argb8888, vec![0; 25]).is_none());
    }

    #[test]
    fn a_pixel_buffer_of_no_pixels_is_representable_but_only_when_empty() {
        let size = PixelSize::new(0, 0);
        assert!(PixelBuffer::new(size, ShmFormat::Argb8888, Vec::new()).is_some());
        assert!(PixelBuffer::new(size, ShmFormat::Argb8888, vec![0; 4]).is_none());
    }

    #[test]
    fn a_pixel_buffer_reports_what_it_was_built_from() {
        let buffer = PixelBuffer::new(
            PixelSize::new(1, 1),
            ShmFormat::Xrgb8888,
            vec![1, 2, 3, 255],
        )
        .expect("one pixel of four bytes");

        assert_eq!(buffer.size(), PixelSize::new(1, 1));
        assert_eq!(buffer.format(), ShmFormat::Xrgb8888);
        assert_eq!(buffer.pixels(), &[1, 2, 3, 255]);
    }

    #[test]
    fn only_the_two_mandatory_shm_formats_are_accepted() {
        assert_eq!(
            ShmFormat::from_protocol(wl_shm::Format::Argb8888),
            Some(ShmFormat::Argb8888)
        );
        assert_eq!(
            ShmFormat::from_protocol(wl_shm::Format::Xrgb8888),
            Some(ShmFormat::Xrgb8888)
        );
        assert_eq!(ShmFormat::from_protocol(wl_shm::Format::Rgb332), None);
        assert_eq!(ShmFormat::from_protocol(wl_shm::Format::Abgr16161616), None);
    }
}
