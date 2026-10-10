//! Per-surface state for the compositor's commit path.
//!
//! [`SurfaceRegistry`] maps compositor-thread `wl_surface` objects to stable
//! [`SurfaceId`] values that can cross to the main thread, and keeps a weak
//! handle to each so the graphics handover can find the buffers they retain.
//!
//! [`BufferImporter`] separates Wayland buffer handling from graphics-device
//! imports. The graphics implementation is in `lunette`, while this crate
//! supplies the seam used by device-free compositor tests.
//!
//! The bookkeeping a commit does for lunette's windows and the frame thread is
//! here too: the content-type hint, the committed size, and the reports when a
//! surface loses its content.

use std::collections::HashMap;

use smithay::{
    backend::allocator::dmabuf::Dmabuf,
    reexports::wayland_server::{
        Resource, Weak,
        backend::ObjectId,
        protocol::{wl_output, wl_shm, wl_surface::WlSurface},
    },
    wayland::{compositor::with_states, shell::xdg::XdgToplevelSurfaceData},
};

use crate::{
    config::DEFAULT_OUTPUT,
    protocol::{ContentType, Event, ImportedImage, PixelSize, SourceCrop, SurfaceId},
    wayvr::{SurfaceBufWithImage, comp::Application},
};

/// Maps compositor-thread surface objects to stable identifiers.
///
/// Identifiers are minted in order and never reused, so a stale [`SurfaceId`]
/// cannot refer to a different surface.
#[derive(Debug, Default)]
pub(crate) struct SurfaceRegistry {
    ids: HashMap<ObjectId, (SurfaceId, Weak<WlSurface>)>,
    minted: u64,
}

impl SurfaceRegistry {
    /// Returns the stable identifier for a surface, minting one on first sight.
    pub(crate) fn id_for(&mut self, surface: &WlSurface) -> SurfaceId {
        if let Some((id, _)) = self.ids.get(&surface.id()) {
            return *id;
        }

        self.minted += 1;
        let id = SurfaceId::new(self.minted).unwrap_or_else(|| {
            unreachable!("the counter starts at one and only increases, so it is never zero")
        });
        self.ids.insert(surface.id(), (id, surface.downgrade()));
        id
    }

    /// Whether an identifier still names a live surface.
    #[must_use]
    pub(crate) fn knows(&self, id: SurfaceId) -> bool {
        self.ids.values().any(|(known, _)| *known == id)
    }

    /// Removes a destroyed surface's identifier and returns it.
    pub(crate) fn forget(&mut self, surface: &WlSurface) -> Option<SurfaceId> {
        self.ids.remove(&surface.id()).map(|(id, _)| id)
    }

    /// The live surfaces with their identifiers.
    pub(crate) fn live(&self) -> impl Iterator<Item = (SurfaceId, WlSurface)> + '_ {
        self.ids
            .values()
            .filter_map(|(id, surface)| Some((*id, surface.upgrade().ok()?)))
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
    /// The compositor copies `pixels` from the client's pool mapping before this
    /// call and does not pass the mapping to the importer. The slice does not
    /// outlive this call, and the frame thread uploads the returned pixels
    /// because it owns the graphics queue.
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
/// this implementation and does not use an optional importer, so every call follows
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
/// Lunette accepts the two formats required by `wl_shm`; other protocol
/// formats are rejected, since an importer without support for them cannot
/// accept them.
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
    /// Unknown values are rejected; a value unknown to this implementation is
    /// not treated as `Normal`.
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

impl Application {
    /// Records the client's content-type hint for Lua's throttling policy.
    pub(crate) fn remember_content_type(&mut self, id: SurfaceId, content_type: ContentType) {
        if let Some(window) = self.windows.by_surface_mut(id)
            && window.remember_content_type(content_type)
        {
            self.touch();
        }
    }

    /// Records a window's committed size and source crop, mapping it on its
    /// first content.
    pub(crate) fn remember_committed_size(&mut self, surface: &WlSurface, id: SurfaceId) {
        let Some((size, source_uv)) = with_states(surface, |states| {
            SurfaceBufWithImage::get_from_surface(states)
                .map(|buf| (buf.logical_size(states), buf.source_uv(states)))
        }) else {
            return;
        };
        let [left, top, right, bottom] = source_uv.map(f64::from);
        // `source_uv` clamps each edge into the buffer, and smithay refuses a
        // source rectangle without a positive size, so the edges are ordered.
        // The full buffer stands in if they ever were not.
        let source_crop = SourceCrop::new(left, top, right, bottom).unwrap_or(SourceCrop::FULL);
        let bounds = self.output_bounds(
            self.windows
                .by_surface(id)
                .map_or(DEFAULT_OUTPUT, |window| window.output),
        );
        let Some(window) = self.windows.by_surface_mut(id) else {
            return;
        };

        // Size limits can change at any commit, so refresh them before sizing.
        window.refresh_constraints(bounds);
        // Only a commit that acknowledged the pending configure settles it.
        let configure_serial = with_states(window.toplevel.wl_surface(), |states| {
            states
                .data_map
                .get::<XdgToplevelSurfaceData>()
                .and_then(|data| data.lock().ok().and_then(|data| data.current_serial))
        });
        let opened = window.map().then_some(window.id);
        let resized = window.remember_committed_size(size, configure_serial);
        let cropped = window.remember_source_crop(source_crop);

        if opened.is_some() || resized || cropped {
            self.touch();
        }
        if let Some(window) = opened {
            self.report(Event::WindowOpened { window });
        }
    }

    /// Unmaps a surface after a null-buffer commit. A later commit may remap the
    /// same window, so its identifier remains stable. Reports `WindowClosed`
    /// before `SurfaceGone` so consumers observe the window before its texture
    /// is dropped.
    pub(crate) fn unmap_surface(&mut self, id: SurfaceId) {
        self.touch();

        if let Some(window) = self.windows.by_surface_mut(id)
            && window.unmap()
        {
            let window = window.id;
            self.report(Event::WindowClosed { window });
        }

        self.report(Event::SurfaceGone { surface: id });
    }

    /// Releases the state retained for a destroyed surface. Releasing its
    /// retained `wl_buffer` lets the client's dmabuf be collected.
    pub(crate) fn forget_surface(&mut self, surface: &WlSurface) {
        let Some(id) = self.surfaces.forget(surface) else {
            return;
        };

        // The surface's callbacks are destroyed with it; answering them would
        // be a protocol error.
        self.pending_frame_callbacks.remove(&id);
        self.forget_pacing(id);
        if let Some(buffer) = with_states(surface, SurfaceBufWithImage::remove_from_surface) {
            buffer.release();
        }
        self.report(Event::SurfaceGone { surface: id });
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

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
