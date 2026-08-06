//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/mod.rs (the surface-buffer fragments), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! What a client last committed to a surface, and who owns the buffer behind
//! it.
//!
//! Three concerns live here, all of them per-surface bookkeeping the commit
//! path in [`crate::state`] reaches for.
//!
//! [`SurfaceRegistry`] names surfaces. The protocol identifies a `wl_surface`
//! by an `ObjectId`, which is meaningless outside this thread, so every surface
//! the compositor reports on is given a [`SurfaceId`] the main thread can hold.
//!
//! [`RetainedBuffers`] implements the release rule. WayVR keeps the current
//! dmabuf's `wl_buffer` alive in surface user data and releases the previous
//! one on the next commit (`mod.rs:1351-1383`, released at `comp.rs:255-258`).
//! Lunette keeps the same rule but in ordinary compositor state rather than
//! `UserData`: `UserData` records the inserting thread and only drops a
//! non-threadsafe payload on that thread, leaking otherwise
//! (`smithay-0.7.0/src/utils/user_data.rs:91-102`), which for a surface
//! destroyed off-thread would leak the retained buffer. The compositor thread
//! is the only writer either way, so the `RefCell` upstream needs is gone.
//!
//! Losing the rule is not a cosmetic regression: a client that is not told a
//! buffer is finished with reuses it, and lunette then samples a buffer being
//! drawn into.
//!
//! [`BufferImporter`] is the seam between a committed buffer and an image on
//! the graphics device. The implementation lives in `lunette`, because this
//! crate must not gain a graphics dependency; a fake stands in for it in tests,
//! which is what keeps the suite runnable with no device present.

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

/// Names every surface the compositor has reported on.
///
/// Identifiers are minted in order and never reused, so a stale [`SurfaceId`]
/// held by the main thread cannot come to mean a different surface. The
/// counter is 64-bit and advances once per surface, so exhausting it is not a
/// case worth handling.
#[derive(Debug, Default)]
pub(crate) struct SurfaceRegistry {
    ids: HashMap<ObjectId, SurfaceId>,
    minted: u64,
}

impl SurfaceRegistry {
    /// The surface's identifier, minting one if this is the first sighting.
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

    /// The surface's identifier, if it has one. Does not mint.
    pub(crate) fn get(&self, surface: &WlSurface) -> Option<SurfaceId> {
        self.ids.get(&surface.id()).copied()
    }

    /// Drops a destroyed surface's identifier, returning what it was.
    pub(crate) fn forget(&mut self, surface: &WlSurface) -> Option<SurfaceId> {
        self.ids.remove(&surface.id())
    }
}

/// Something a client can be told it may draw into again.
///
/// A trait rather than `WlBuffer` directly so the release rule can be tested
/// without a connected client. The rule is the part worth testing; the protocol
/// call is one line.
pub(crate) trait ReleasableBuffer {
    fn release(&self);
}

impl ReleasableBuffer for WlBuffer {
    fn release(&self) {
        WlBuffer::release(self);
    }
}

/// The buffers lunette is still reading from, one per surface.
///
/// Holding one is what stops a client reusing it. Every path that stops reading
/// goes through this type, so there is no way to drop a retained buffer without
/// telling the client.
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

impl<B: ReleasableBuffer> RetainedBuffers<B> {
    /// Takes ownership of a surface's new buffer and releases the one it
    /// replaces.
    ///
    /// The release happens here rather than at the call site because a caller
    /// that forgets it produces a client drawing into a buffer lunette is
    /// sampling, which shows up as tearing rather than as an error.
    pub(crate) fn retain(&mut self, surface: SurfaceId, buffer: B) {
        if let Some(previous) = self.retained.insert(surface, buffer) {
            previous.release();
        }
    }

    /// Releases a surface's buffer and stops tracking it.
    ///
    /// Called when the surface is destroyed, when its client disconnects, and
    /// when a commit removes the buffer without attaching another.
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

/// Turns a committed client buffer into an image on the graphics device.
///
/// The implementation lives in `lunette`, which owns the device; this crate
/// only knows that an import either produced a handle or did not. Keeping the
/// graphics code on the far side of this trait is what lets the compositor's
/// tests run with no device, no runtime, and no headset (`AC9.4`).
///
/// The compositor thread calls this, so an implementation may create images and
/// allocate memory but must not submit work to a queue: the queue belongs to
/// the frame thread.
pub trait BufferImporter: Send {
    /// Imports a client's dmabuf.
    ///
    /// The `Dmabuf` owns its file descriptors and closes them when it drops, so
    /// an implementation that hands one to the graphics API duplicates it
    /// first.
    fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, ImportFailed>;

    /// Imports a client's shared-memory buffer.
    ///
    /// `pixels` is a mapping of the client's pool and is valid only for the
    /// duration of the call. An implementation that defers the upload copies
    /// first.
    fn import_shm(
        &mut self,
        pixels: &[u8],
        layout: ShmLayout,
    ) -> Result<ImportedImage, ImportFailed>;
}

/// Why a buffer could not be imported.
///
/// A message rather than a category, because every case is reported the same
/// way — the buffer is released, the surface keeps its previous contents, and
/// the reason is logged — and inventing categories nothing branches on would be
/// a guess.
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

/// How a shared-memory buffer's bytes are arranged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShmLayout {
    pub size: PixelSize,
    /// Bytes per row, which the client may pad beyond the row's own width.
    pub stride: u32,
    pub format: ShmFormat,
}

/// A shared-memory pixel format lunette accepts.
///
/// Only the two `wl_shm` mandates. Anything further is a client opting into a
/// format the importer would have to be taught, and WayVR restricts this path
/// the same way (`image_importer.rs:66-72`) while accepting more for dmabuf.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ShmFormat {
    /// Little-endian `[B, G, R, A]`.
    Argb8888,
    /// Little-endian `[B, G, R, X]`. The fourth byte carries no alpha, so a
    /// consumer forces it to one rather than sampling it.
    Xrgb8888,
}

impl ShmFormat {
    /// Four for both variants, and named so a stride calculation does not
    /// hard-code it.
    pub const BYTES_PER_PIXEL: u32 = 4;

    /// Recognises a protocol format, rejecting the ones lunette does not
    /// import.
    #[must_use]
    pub fn from_protocol(format: wl_shm::Format) -> Option<Self> {
        match format {
            wl_shm::Format::Argb8888 => Some(Self::Argb8888),
            wl_shm::Format::Xrgb8888 => Some(Self::Xrgb8888),
            _ => None,
        }
    }
}

/// How a client asked its buffer to be interpreted before it is displayed.
///
/// Ported from `wl_transform_to_frame_transform` (`comp.rs:696-710`), which
/// converts to `wlx_capture`'s enum. Lunette does not depend on `wlx-capture`
/// here, so the same eight cases land on a type of this crate's own.
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
    /// Recognises a protocol transform.
    ///
    /// `wl_output::Transform` is non-exhaustive, so a value from a future
    /// protocol version has no meaning here and is reported as such rather than
    /// silently becoming `Normal`.
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

    /// Whether the transform exchanges the buffer's width and height.
    #[must_use]
    pub const fn swaps_axes(self) -> bool {
        matches!(
            self,
            Self::Rotated90 | Self::Rotated270 | Self::Flipped90 | Self::Flipped270
        )
    }
}

/// The integer scale a client says its buffer is drawn at.
///
/// `wl_surface.set_buffer_scale` is a positive integer by protocol, and a
/// surface that has never set one is at 1. Zero and negatives are a protocol
/// error rather than a value to clamp, which is why construction rejects them
/// instead of taking WayVR's `.max(1)` (`comp.rs:186`).
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

/// What a client last committed to a surface.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SurfaceContent {
    /// The buffer's size in its own pixels, before the scale is applied.
    pub(crate) size: PixelSize,
    pub(crate) transform: BufferTransform,
    pub(crate) scale: BufferScale,
}

impl SurfaceContent {
    /// The size the surface occupies in logical pixels.
    ///
    /// A rotating transform exchanges the axes, and the scale divides both.
    /// WayVR computes this at `comp.rs:182-191` without the transform, which is
    /// correct only while every client is unrotated.
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

    /// Records which buffers were released, in order, so a test can assert the
    /// rule rather than the protocol call.
    #[derive(Clone, Debug)]
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
