//! Linux-only: wrapping what the compositor imported as a LÖVR texture.
//!
//! The frame thread owns everything here. The compositor thread creates images
//! and repacks pixels; this module turns either into a `Texture` LÖVR can
//! sample, records the barriers around reading it, and destroys it afterwards.
//!
//! # What LÖVR believes about a foreign image
//!
//! `gpu_texture_init`'s handle branch (`gpu_vk.c:687-695`) creates nothing and
//! binds nothing. Every assumption it makes is the caller's to satisfy, and
//! four of them are load-bearing here.
//!
//! - **Usage.** LÖVR builds a `VkImageViewUsageCreateInfo` from the declared
//!   usage without checking the image (`gpu_vk.c:838-846`), so the declaration
//!   below and [`crate::import::device::IMPORT_USAGE`] have to agree.
//! - **Layout.** `texture->layout = getNaturalLayout(info->usage)`
//!   (`gpu_vk.c:673`) is set at creation and never questioned again. Declaring
//!   `TEXTURE_SAMPLE | TEXTURE_TRANSFER` makes it `VK_IMAGE_LAYOUT_GENERAL`,
//!   which is the layout an image written outside Vulkan is in and the one
//!   `lovrTextureCopy` needs.
//! - **Format.** LÖVR takes `convertFormat(info->format, info->srgb)` to be the
//!   image's real format and has no way to detect otherwise.
//! - **Memory.** LÖVR sets `texture->memory = NULL` and `imported = true`, and
//!   `gpu_texture_destroy` (`gpu_vk.c:879-885`) returns after destroying the
//!   view. So `vkDestroyImage` and `vkFreeMemory` are lunette's, and the
//!   [`Morgue`] is what keeps them from running while the view is still in
//!   LÖVR's own deferred queue.
//!
//! # The two unknowns this module leaves open
//!
//! Neither the layout to acquire from nor the queue family to acquire from is
//! settled, and both are what milestone 0 exists to measure. They are therefore
//! runtime settings on [`BarrierPolicy`] rather than constants, so a run can
//! answer the question without a rebuild.

use std::{collections::HashMap, ffi::c_void, fmt, ptr::NonNull, sync::Arc};

use ash::vk;
use lunette_compositor::{
    protocol::{ImageHandle, ImportedBuffer, ImportedImage, PixelSize, SurfaceId},
    surface::{PixelBuffer, ShmFormat},
};
use lunette_lovr::raw::{
    TEXTURE_SAMPLE, TEXTURE_TRANSFER, Texture, TextureFormat, TextureFormat_FORMAT_BGRA8,
    TextureInfo, TextureType_TEXTURE_2D, lovrImageCreateRaw, lovrImageDestroy,
    lovrImageGetLayerData, lovrRelease, lovrTextureCreate, lovrTextureDestroy,
    lovrTextureImportAcquire, lovrTextureImportRelease, lovrTextureSetPixels,
};
use tracing::warn;

use crate::import::{
    GraphicsDevice, ImageArena,
    formats::{Alpha, FormatMapping, mapping_for},
};

/// Which frame is being drawn.
///
/// A texture handle is only valid within the frame it was obtained in, and this
/// is what makes that checkable rather than merely documented.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FrameGeneration(u64);

impl FrameGeneration {
    /// Before the first frame has begun.
    pub const INITIAL: Self = Self(0);

    /// The next frame, saturating rather than wrapping.
    ///
    /// Wrapping would make a handle from long ago compare equal to a current
    /// one, which is the single thing this counter exists to prevent. At one
    /// frame per display refresh, saturation is unreachable.
    #[must_use]
    pub const fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl fmt::Display for FrameGeneration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A reference to a surface's texture, valid for one frame.
///
/// `window:getTexture()` hands one of these out. Textures rotate as the client
/// cycles its buffers, so a handle kept across a frame boundary names something
/// that no longer exists — and rather than documenting that and hoping, the
/// generation is carried along and checked at every use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureRef {
    surface: SurfaceId,
    generation: FrameGeneration,
}

impl TextureRef {
    #[must_use]
    pub const fn new(surface: SurfaceId, generation: FrameGeneration) -> Self {
        Self {
            surface,
            generation,
        }
    }

    #[must_use]
    pub const fn surface(self) -> SurfaceId {
        self.surface
    }

    #[must_use]
    pub const fn generation(self) -> FrameGeneration {
        self.generation
    }
}

/// Why a [`TextureRef`] resolved to nothing.
///
/// The three cases are answered differently in Lua, which is why they are
/// distinguished here rather than collapsed into an absence. A dead handle
/// returns `false` without raising, because a client exiting mid-frame is a
/// race and taking the session down over it is worse than doing nothing. A
/// stale one raises, because it is a defect in the caller's code and silence
/// would leave it undiagnosed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureUnavailable {
    /// The surface has never committed a buffer, or was forgotten.
    Unknown,
    /// The client is gone. Reads return last-known values; nothing raises.
    Dead,
    /// The handle was obtained in an earlier frame.
    Stale {
        obtained: FrameGeneration,
        current: FrameGeneration,
    },
}

impl fmt::Display for TextureUnavailable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "texture: ")?;
        match self {
            Self::Unknown => write!(f, "the surface has no texture"),
            Self::Dead => write!(f, "the client is gone"),
            Self::Stale { obtained, current } => write!(
                f,
                "the handle was obtained in frame {obtained} and this is frame {current}; a \
                 window's texture rotates as its client cycles buffers, so call getTexture again \
                 rather than caching it"
            ),
        }
    }
}

impl std::error::Error for TextureUnavailable {}

/// Which surface holds which texture, and what is waiting to be destroyed.
///
/// Generic over the texture so the bookkeeping — the rotation, the frame
/// check, the dead-handle rule, the retirement schedule — can be exercised
/// without a graphics device. `T` is [`LovrTexture`] in the binary and a plain
/// integer in the tests.
#[derive(Debug)]
pub struct TextureLedger<T> {
    entries: HashMap<SurfaceId, Entry<T>>,
    morgue: Morgue,
}

impl<T> Default for TextureLedger<T> {
    fn default() -> Self {
        Self {
            entries: HashMap::new(),
            morgue: Morgue::default(),
        }
    }
}

impl<T> TextureLedger<T> {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Records a surface's new texture, returning the one it replaces.
    ///
    /// The caller destroys what comes back. It is returned rather than dropped
    /// because destroying a LÖVR texture is an FFI call this type cannot make,
    /// and because the underlying image has to be retired at the same moment —
    /// which is the second thing this does.
    pub fn install(
        &mut self,
        surface: SurfaceId,
        texture: T,
        description: TextureDescription,
    ) -> Option<T> {
        let previous = self.entries.insert(
            surface,
            Entry {
                texture: Some(texture),
                description,
                dead: false,
            },
        );

        previous.and_then(|entry| entry.texture)
    }

    /// Marks a surface's client as gone.
    ///
    /// The description survives, so reads keep returning last-known values, and
    /// the texture is handed back for destruction: an image whose client has
    /// exited is not going to be redrawn.
    pub fn mark_dead(&mut self, surface: SurfaceId) -> Option<T> {
        let entry = self.entries.get_mut(&surface)?;
        entry.dead = true;
        entry.texture.take()
    }

    /// Drops everything known about a surface, returning its texture.
    pub fn forget(&mut self, surface: SurfaceId) -> Option<T> {
        self.entries
            .remove(&surface)
            .and_then(|entry| entry.texture)
    }

    /// Resolves a handle against the frame it is being used in.
    ///
    /// Death is checked before staleness. A handle to a window whose client
    /// exited two frames ago is both, and answering `Dead` is what makes the
    /// documented "every method returns false without raising" hold for the
    /// case a caller is most likely to hit.
    ///
    /// # Errors
    ///
    /// See [`TextureUnavailable`].
    pub fn lookup(
        &self,
        reference: TextureRef,
        current: FrameGeneration,
    ) -> Result<&T, TextureUnavailable> {
        let Some(entry) = self.entries.get(&reference.surface) else {
            return Err(TextureUnavailable::Unknown);
        };
        if entry.dead {
            return Err(TextureUnavailable::Dead);
        }
        if reference.generation != current {
            return Err(TextureUnavailable::Stale {
                obtained: reference.generation,
                current,
            });
        }

        entry.texture.as_ref().ok_or(TextureUnavailable::Unknown)
    }

    /// What is known about a surface, alive or dead.
    ///
    /// Available after death on purpose: `docs/decisions.md` records that a
    /// dead handle reports last-known values rather than nothing, so a Lua
    /// layout does not collapse the frame a window closes on.
    #[must_use]
    pub fn describe(&self, surface: SurfaceId) -> Option<TextureDescription> {
        self.entries.get(&surface).map(|entry| entry.description)
    }

    #[must_use]
    pub fn is_dead(&self, surface: SurfaceId) -> bool {
        self.entries.get(&surface).is_some_and(|entry| entry.dead)
    }

    /// Schedules an image for destruction.
    pub fn retire_image(&mut self, image: ImageHandle, now: FrameGeneration) {
        self.morgue.retire(image, now);
    }

    /// The images whose deferral has elapsed.
    pub fn collect_due_images(&mut self, now: FrameGeneration) -> Vec<ImageHandle> {
        self.morgue.collect_due(now)
    }
}

/// What a surface's texture is, kept whether or not the texture still exists.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextureDescription {
    pub size: PixelSize,
    /// Whether the fourth component is alpha or padding. An
    /// [`Alpha::Opaque`] texture is drawn with alpha forced to one; sampling it
    /// renders the surface with whatever the client happened to leave there.
    pub alpha: Alpha,
}

#[derive(Debug)]
struct Entry<T> {
    /// Absent once the client is gone, and while a replacement is being
    /// installed.
    texture: Option<T>,
    description: TextureDescription,
    dead: bool,
}

/// Images waiting out their deferral before being destroyed.
///
/// `gpu_texture_destroy` puts the image *view* into LÖVR's own morgue and
/// returns without touching the image. The image is lunette's, and freeing it
/// while a command buffer LÖVR has already recorded still names the view is a
/// use-after-free that a driver reports, at best, as a device loss several
/// frames later.
#[derive(Debug, Default)]
struct Morgue {
    pending: Vec<(ImageHandle, FrameGeneration)>,
}

impl Morgue {
    fn retire(&mut self, image: ImageHandle, now: FrameGeneration) {
        self.pending.push((image, now));
    }

    /// The images retired long enough ago to be destroyed.
    fn collect_due(&mut self, now: FrameGeneration) -> Vec<ImageHandle> {
        let mut due = Vec::new();
        self.pending.retain(|(image, retired)| {
            if now.get().saturating_sub(retired.get()) >= DESTROY_DELAY {
                due.push(*image);
                false
            } else {
                true
            }
        });
        due
    }
}

/// How many frames an image waits before it is destroyed.
///
/// One would be the minimum: LÖVR retires the view at the end of the tick the
/// texture was destroyed in. Two is used because the minimum leaves no margin
/// for a frame that submits twice, and an image is a few megabytes held for
/// sixteen milliseconds longer — a trade heavily in favour of the margin.
const DESTROY_DELAY: u64 = 2;

/// How the barrier around an imported texture is recorded.
///
/// Both fields are open questions rather than settled ones, which is why they
/// are runtime settings. `docs/milestone-0-findings.md` is where the answers
/// go, and a run has to be able to try the other value without a rebuild to
/// produce them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BarrierPolicy {
    pub source_family: QueueFamilyMode,
    pub old_layout: ForeignLayout,
}

impl BarrierPolicy {
    /// Reads a policy from two optional settings, falling back to the default
    /// for anything unrecognised.
    ///
    /// Unrecognised rather than rejected: this is a diagnostic switch, and a
    /// typo in it should not stop a session starting. The fallback is reported
    /// so a run that thought it was measuring the other value finds out.
    #[must_use]
    pub fn from_settings(family: Option<&str>, layout: Option<&str>) -> Self {
        let source_family = family.map_or_else(QueueFamilyMode::default, |value| {
            QueueFamilyMode::parse(value).unwrap_or_else(|| {
                warn!(value, "unrecognised queue family mode; using the default");
                QueueFamilyMode::default()
            })
        });
        let old_layout = layout.map_or_else(ForeignLayout::default, |value| {
            ForeignLayout::parse(value).unwrap_or_else(|| {
                warn!(value, "unrecognised foreign layout; using the default");
                ForeignLayout::default()
            })
        });

        Self {
            source_family,
            old_layout,
        }
    }
}

/// Which queue family an imported image is acquired from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum QueueFamilyMode {
    /// `VK_QUEUE_FAMILY_FOREIGN_EXT`: a real ownership transfer from a producer
    /// outside Vulkan, which is what a client's dmabuf is. The default because
    /// it is what the specification describes.
    #[default]
    Foreign,
    /// `VK_QUEUE_FAMILY_IGNORED`: no ownership transfer at all. What WayVR does,
    /// and it works on Mesa; whether that is the driver being lenient is the
    /// question.
    Ignored,
}

impl QueueFamilyMode {
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "foreign" => Some(Self::Foreign),
            "ignored" => Some(Self::Ignored),
            _ => None,
        }
    }

    #[must_use]
    fn index(self) -> u32 {
        match self {
            Self::Foreign => vk::QUEUE_FAMILY_FOREIGN_EXT,
            Self::Ignored => vk::QUEUE_FAMILY_IGNORED,
        }
    }
}

/// The layout an imported image is taken to be in before the acquire.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ForeignLayout {
    /// `VK_IMAGE_LAYOUT_GENERAL`. The default: a DRM-modifier image written by
    /// a producer outside Vulkan has no other meaningful layout, and an
    /// ownership acquire from a non-`UNDEFINED` layout preserves its contents.
    #[default]
    General,
    /// `VK_IMAGE_LAYOUT_UNDEFINED`. Legal, and permits the driver to discard
    /// the client's rendered content — which is the whole reason
    /// `TextureInfo.foreign` exists. Available only so a run can confirm the
    /// discard happens rather than assuming it.
    Undefined,
}

impl ForeignLayout {
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "general" => Some(Self::General),
            "undefined" => Some(Self::Undefined),
            _ => None,
        }
    }

    #[must_use]
    fn layout(self) -> vk::ImageLayout {
        match self {
            Self::General => vk::ImageLayout::GENERAL,
            Self::Undefined => vk::ImageLayout::UNDEFINED,
        }
    }
}

/// A LÖVR `Texture` lunette owns a reference to.
///
/// Reference, not ownership of the underlying image: for an imported texture
/// LÖVR holds only a view, and [`ImageArena`] holds the image. Dropping this
/// without calling [`LovrTexture::release`] leaks the reference, which is why
/// it is `#[must_use]` in the places that produce one.
#[derive(Debug)]
pub struct LovrTexture {
    raw: NonNull<Texture>,
    /// The image behind it, absent for a texture LÖVR allocated itself.
    image: Option<ImageHandle>,
}

impl LovrTexture {
    /// Wraps an imported image.
    ///
    /// # Safety
    ///
    /// LÖVR's graphics module must be initialised and this must be the thread
    /// that owns it. `image` must name an image created with
    /// [`crate::import::device::IMPORT_USAGE`] and still alive.
    pub unsafe fn import(image: &ImportedImage) -> Result<Self, TextureError> {
        let mapping = mapping_for(image.format).ok_or(TextureError::UnknownFormat)?;
        let info = texture_info(image.size, mapping.texture, image.image.get(), true);

        // SAFETY: the caller guarantees the thread and the image; `info` is a
        // live local for the duration of the call and LÖVR copies what it
        // keeps.
        let raw = unsafe { lovrTextureCreate(&raw const info) };
        let raw = NonNull::new(raw).ok_or(TextureError::Create)?;

        Ok(Self {
            raw,
            image: Some(image.image),
        })
    }

    /// Allocates a texture LÖVR owns and fills it with a client's pixels.
    ///
    /// The shared-memory path. LÖVR's own upload machinery is what does the
    /// work, so the copy is batched into the frame's stream rather than
    /// submitted on its own — which is the departure from WayVR's blocking
    /// submit at `image_importer.rs:96-97`.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::import`], minus the image.
    pub unsafe fn upload(pixels: &PixelBuffer) -> Result<Self, TextureError> {
        let size = pixels.size();
        let format = shm_texture_format(pixels.format());
        let info = texture_info(size, format, 0, false);

        // SAFETY: as above.
        let raw = unsafe { lovrTextureCreate(&raw const info) };
        let raw = NonNull::new(raw).ok_or(TextureError::Create)?;
        let texture = Self { raw, image: None };

        // SAFETY: as above; the image is released before returning either way.
        unsafe { texture.write(pixels, size, format) }.inspect_err(|_| texture.release_ref())?;

        Ok(texture)
    }

    /// Replaces the texture's contents, when the new pixels have the same
    /// shape.
    ///
    /// Returns whether they did. A client that resizes gets a new texture
    /// instead, because a LÖVR texture's dimensions are fixed at creation.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::upload`].
    pub unsafe fn refill(&self, pixels: &PixelBuffer, description: TextureDescription) -> bool {
        if self.image.is_some() || pixels.size() != description.size {
            return false;
        }

        let format = shm_texture_format(pixels.format());
        // SAFETY: the caller's guarantee, and the shapes were just checked to
        // match.
        unsafe { self.write(pixels, description.size, format) }.is_ok()
    }

    /// Copies pixels into the texture through a temporary LÖVR `Image`.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::upload`].
    unsafe fn write(
        &self,
        pixels: &PixelBuffer,
        size: PixelSize,
        format: TextureFormat,
    ) -> Result<(), TextureError> {
        // SAFETY: the caller's guarantee. A raw image is an allocation and a
        // header; nothing about it depends on a device.
        let image = unsafe { lovrImageCreateRaw(size.width, size.height, format, false) };
        let Some(image) = NonNull::new(image) else {
            return Err(TextureError::AllocateStagingImage);
        };

        // SAFETY: the image was created with exactly these dimensions and this
        // format, so its single layer is `width * height * 4` bytes — the same
        // invariant `PixelBuffer` carries. The regions cannot overlap: the
        // image was allocated in this call.
        let written = unsafe {
            let destination = lovrImageGetLayerData(image.as_ptr(), 0, 0);
            if destination.is_null() {
                false
            } else {
                destination
                    .cast::<u8>()
                    .copy_from_nonoverlapping(pixels.pixels().as_ptr(), pixels.pixels().len());

                let mut offset = [0u32; 4];
                let mut extent = [size.width, size.height, 1];
                lovrTextureSetPixels(
                    self.raw.as_ptr(),
                    image.as_ptr(),
                    offset.as_mut_ptr(),
                    offset.as_mut_ptr(),
                    extent.as_mut_ptr(),
                )
            }
        };

        // SAFETY: the staging image is this call's, and nothing else holds a
        // reference to it.
        unsafe { lovrRelease(image.as_ptr().cast::<c_void>(), Some(lovrImageDestroy)) };

        if written {
            Ok(())
        } else {
            Err(TextureError::Upload)
        }
    }

    /// Records the barrier that makes the imported image readable this frame.
    ///
    /// A no-op for a texture LÖVR allocated itself: there is no foreign
    /// producer to acquire from, and `lovrTextureImportAcquire` rejects a
    /// texture that was not created with `foreign` anyway.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::import`], and this must run before any read of the
    /// texture within the frame.
    pub unsafe fn acquire(&self, policy: BarrierPolicy) -> bool {
        if self.image.is_none() {
            return true;
        }

        // SAFETY: the caller's guarantee. The two values are plain integers
        // LÖVR passes through to the barrier.
        unsafe {
            lovrTextureImportAcquire(
                self.raw.as_ptr(),
                policy.old_layout.layout().as_raw().unsigned_abs(),
                policy.source_family.index(),
            )
        }
    }

    /// Records the barrier that hands the image back after the frame's reads.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::acquire`], and this must run after them.
    pub unsafe fn release(&self, policy: BarrierPolicy) -> bool {
        if self.image.is_none() {
            return true;
        }

        // SAFETY: as above.
        unsafe {
            lovrTextureImportRelease(
                self.raw.as_ptr(),
                policy.old_layout.layout().as_raw().unsigned_abs(),
                policy.source_family.index(),
            )
        }
    }

    /// The image behind the texture, for a texture that wraps one.
    #[must_use]
    pub fn image(&self) -> Option<ImageHandle> {
        self.image
    }

    /// The raw pointer, for the draw path that has to name it to LÖVR.
    #[must_use]
    pub fn as_raw(&self) -> *mut Texture {
        self.raw.as_ptr()
    }

    /// Drops lunette's reference to the texture.
    ///
    /// The image behind it is not touched: LÖVR retires only the view, and the
    /// image goes through [`TextureLedger::retire_image`] so it is destroyed a
    /// frame later rather than under a command buffer that still names it.
    pub fn release_ref(&self) {
        // SAFETY: the reference this type holds is the one being dropped, and
        // LÖVR's own reference counting decides whether that is the last.
        unsafe { lovrRelease(self.raw.as_ptr().cast::<c_void>(), Some(lovrTextureDestroy)) };
    }
}

/// The `TextureInfo` an imported or uploaded texture is created with.
///
/// `TEXTURE_SAMPLE | TEXTURE_TRANSFER` rather than `TEXTURE_SAMPLE` alone, for
/// two reasons that both matter. It makes `getNaturalLayout` return
/// `VK_IMAGE_LAYOUT_GENERAL` (`gpu_vk.c:4286-4295`), which is the layout a
/// foreign image is actually in. And it takes the texture out of the
/// sample-only exemption at `graphics.c:2647-2657`, giving it a real `Sync`
/// object so it participates in `syncStream` — which is what a `lovrTextureCopy`
/// source needs, and `surface:stabilize()` is exactly that copy.
fn texture_info(size: PixelSize, format: TextureFormat, handle: u64, foreign: bool) -> TextureInfo {
    TextureInfo {
        type_: TextureType_TEXTURE_2D,
        format,
        width: size.width,
        height: size.height,
        layers: 1,
        mipmaps: 1,
        samples: 1,
        usage: TEXTURE_SAMPLE | TEXTURE_TRANSFER,
        // The client's buffer holds the values it wrote. Declaring sRGB would
        // have the sampler apply a transfer function to content that has
        // already had one applied.
        srgb: false,
        xr: false,
        imageCount: 0,
        images: std::ptr::null_mut(),
        label: std::ptr::null_mut(),
        handle: handle as usize,
        foreign,
    }
}

/// How a `wl_shm` format is spelled to LÖVR.
///
/// Both variants are little-endian `[B, G, R, _]`, which is `FORMAT_BGRA8`. The
/// difference between them is whether the fourth byte means anything, and
/// [`crate::import::shm`] has already resolved that by forcing it to one.
fn shm_texture_format(format: ShmFormat) -> TextureFormat {
    match format {
        ShmFormat::Argb8888 | ShmFormat::Xrgb8888 => TextureFormat_FORMAT_BGRA8,
    }
}

/// What a buffer of either kind says about the texture it becomes.
#[must_use]
pub fn describe(buffer: &ImportedBuffer) -> TextureDescription {
    match buffer {
        ImportedBuffer::Image(image) => TextureDescription {
            size: image.size,
            alpha: mapping_for(image.format)
                .map_or(Alpha::Present, |mapping: FormatMapping| mapping.alpha),
        },
        ImportedBuffer::Pixels(pixels) => TextureDescription {
            size: pixels.size(),
            // The repack forced the padding byte to one, so what arrives here
            // carries alpha whichever format the client used.
            alpha: Alpha::Present,
        },
    }
}

/// Destroys the images whose deferral has elapsed.
///
/// # Safety
///
/// This must run once per frame, and after the frame's events have been drained
/// into the ledger — after every [`TextureLedger::install`], [`mark_dead`], and
/// [`forget`] the frame is going to perform, and after the texture each of those
/// handed back has been released. That ordering is what the deferral counts
/// from: the compositor retires an image only once the client has destroyed the
/// buffer behind it, which it can only have done after committing a replacement,
/// so the event installing that replacement is drained in this frame or an
/// earlier one. LÖVR then retires the view at the end of this tick, and
/// [`DESTROY_DELAY`] frames of margin follow.
///
/// Calling this before the drain inverts that and frees an image a recorded
/// command buffer still names.
///
/// [`mark_dead`]: TextureLedger::mark_dead
/// [`forget`]: TextureLedger::forget
pub unsafe fn destroy_due_images<T>(
    ledger: &mut TextureLedger<T>,
    arena: &ImageArena,
    device: &Arc<GraphicsDevice>,
    now: FrameGeneration,
) {
    for image in arena.take_retired() {
        ledger.retire_image(image, now);
    }

    for image in ledger.collect_due_images(now) {
        // SAFETY: the caller's guarantee, established by the deferral.
        unsafe { arena.destroy(image, device) };
    }
}

/// Why a texture could not be created.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextureError {
    UnknownFormat,
    Create,
    AllocateStagingImage,
    Upload,
}

impl fmt::Display for TextureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "texture: ")?;
        match self {
            Self::UnknownFormat => write!(
                f,
                "the imported image's format has no LÖVR equivalent, which means the import \
                 accepted a format this module does not know"
            ),
            Self::Create => write!(f, "LÖVR refused to wrap the image"),
            Self::AllocateStagingImage => {
                write!(f, "the staging image for an upload could not be allocated")
            }
            Self::Upload => write!(f, "the pixels could not be uploaded"),
        }
    }
}

impl std::error::Error for TextureError {}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// Stands in for a LÖVR texture. The ledger never dereferences what it
    /// holds, which is the property that makes this substitution honest.
    type FakeTexture = u32;

    fn surface(raw: u64) -> SurfaceId {
        SurfaceId::new(raw).expect("non-zero")
    }

    fn image(raw: u64) -> ImageHandle {
        ImageHandle::new(raw).expect("non-zero")
    }

    fn frame(raw: u64) -> FrameGeneration {
        let mut generation = FrameGeneration::INITIAL;
        for _ in 0..raw {
            generation = generation.next();
        }
        generation
    }

    fn description(width: u32, height: u32) -> TextureDescription {
        TextureDescription {
            size: PixelSize::new(width, height),
            alpha: Alpha::Present,
        }
    }

    fn ledger() -> TextureLedger<FakeTexture> {
        TextureLedger::new()
    }

    #[test]
    fn a_frame_generation_increases_and_never_wraps() {
        assert_eq!(FrameGeneration::INITIAL.get(), 0);
        assert_eq!(FrameGeneration::INITIAL.next().get(), 1);

        let last = FrameGeneration(u64::MAX);
        assert_eq!(
            last.next(),
            last,
            "wrapping would make an ancient handle compare equal to a current one"
        );
    }

    #[test]
    fn a_handle_from_this_frame_resolves() {
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(64, 32));

        let reference = TextureRef::new(surface(1), frame(3));
        assert_eq!(ledger.lookup(reference, frame(3)), Ok(&7));
    }

    #[test]
    fn a_handle_from_an_earlier_frame_is_refused() {
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(64, 32));

        let reference = TextureRef::new(surface(1), frame(3));
        assert_eq!(
            ledger.lookup(reference, frame(4)),
            Err(TextureUnavailable::Stale {
                obtained: frame(3),
                current: frame(4),
            }),
            "the texture rotates as the client cycles buffers, so a cached handle is not merely \
             stale bookkeeping"
        );
    }

    #[test]
    fn a_handle_from_a_later_frame_is_refused_too() {
        // Not reachable through the public API, but the check is an equality
        // rather than an ordering, and stating that keeps it one.
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(64, 32));

        assert!(
            ledger
                .lookup(TextureRef::new(surface(1), frame(9)), frame(4))
                .is_err()
        );
    }

    #[test]
    fn a_handle_to_an_unknown_surface_resolves_to_nothing() {
        assert_eq!(
            ledger().lookup(TextureRef::new(surface(1), frame(1)), frame(1)),
            Err(TextureUnavailable::Unknown)
        );
    }

    #[test]
    fn installing_a_texture_returns_the_one_it_replaces() {
        let mut ledger = ledger();

        assert_eq!(ledger.install(surface(1), 1, description(64, 32)), None);
        assert_eq!(
            ledger.install(surface(1), 2, description(64, 32)),
            Some(1),
            "the previous texture is handed back so its reference can be dropped"
        );
        assert_eq!(
            ledger.lookup(TextureRef::new(surface(1), frame(0)), frame(0)),
            Ok(&2)
        );
    }

    #[test]
    fn surfaces_do_not_replace_each_others_textures() {
        let mut ledger = ledger();
        assert_eq!(ledger.install(surface(1), 1, description(64, 32)), None);
        assert_eq!(ledger.install(surface(2), 2, description(64, 32)), None);

        assert_eq!(
            ledger.lookup(TextureRef::new(surface(1), frame(0)), frame(0)),
            Ok(&1)
        );
        assert_eq!(
            ledger.lookup(TextureRef::new(surface(2), frame(0)), frame(0)),
            Ok(&2)
        );
    }

    #[test]
    fn a_dead_surface_keeps_its_last_known_description() {
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(1280, 720));

        assert_eq!(ledger.mark_dead(surface(1)), Some(7));
        assert!(ledger.is_dead(surface(1)));
        assert_eq!(
            ledger.describe(surface(1)),
            Some(description(1280, 720)),
            "a handle whose client has exited reads its last-known values rather than nothing"
        );
    }

    #[test]
    fn a_dead_surface_reports_death_rather_than_staleness() {
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(64, 32));
        ledger.mark_dead(surface(1));

        assert_eq!(
            ledger.lookup(TextureRef::new(surface(1), frame(1)), frame(9)),
            Err(TextureUnavailable::Dead),
            "a handle to an exited client is both dead and stale, and death is the answer that \
             does not raise"
        );
    }

    #[test]
    fn marking_a_surface_dead_twice_yields_the_texture_once() {
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(64, 32));

        assert_eq!(ledger.mark_dead(surface(1)), Some(7));
        assert_eq!(
            ledger.mark_dead(surface(1)),
            None,
            "a second call must not hand out a reference that has already been dropped"
        );
    }

    #[test]
    fn marking_an_unknown_surface_dead_does_nothing() {
        let mut ledger = ledger();
        assert_eq!(ledger.mark_dead(surface(4)), None);
        assert!(!ledger.is_dead(surface(4)));
        assert_eq!(ledger.describe(surface(4)), None);
    }

    #[test]
    fn forgetting_a_surface_removes_it_entirely() {
        let mut ledger = ledger();
        ledger.install(surface(1), 7, description(64, 32));

        assert_eq!(ledger.forget(surface(1)), Some(7));
        assert_eq!(ledger.describe(surface(1)), None);
        assert_eq!(ledger.forget(surface(1)), None);
    }

    #[test]
    fn a_retired_image_is_not_destroyed_in_the_frame_it_was_retired() {
        let mut ledger = ledger();
        ledger.retire_image(image(1), frame(5));

        assert_eq!(
            ledger.collect_due_images(frame(5)),
            Vec::new(),
            "LÖVR retires the view at the end of this tick, so the image is still named by a \
             recorded command buffer"
        );
    }

    #[test]
    fn a_retired_image_is_destroyed_once_its_deferral_has_elapsed() {
        let mut ledger = ledger();
        ledger.retire_image(image(1), frame(5));

        assert_eq!(ledger.collect_due_images(frame(6)), Vec::new());
        assert_eq!(ledger.collect_due_images(frame(7)), vec![image(1)]);
        assert_eq!(
            ledger.collect_due_images(frame(8)),
            Vec::new(),
            "an image is collected exactly once, or it is freed twice"
        );
    }

    #[test]
    fn images_retired_in_different_frames_come_due_in_order() {
        let mut ledger = ledger();
        ledger.retire_image(image(1), frame(1));
        ledger.retire_image(image(2), frame(3));

        assert_eq!(ledger.collect_due_images(frame(3)), vec![image(1)]);
        assert_eq!(ledger.collect_due_images(frame(4)), Vec::new());
        assert_eq!(ledger.collect_due_images(frame(5)), vec![image(2)]);
    }

    #[test]
    fn several_images_retired_in_one_frame_come_due_together() {
        let mut ledger = ledger();
        ledger.retire_image(image(1), frame(2));
        ledger.retire_image(image(2), frame(2));

        let mut due = ledger.collect_due_images(frame(4));
        due.sort_unstable();
        assert_eq!(due, vec![image(1), image(2)]);
    }

    #[test]
    fn a_barrier_policy_defaults_to_what_the_specification_describes() {
        let policy = BarrierPolicy::default();
        assert_eq!(policy.source_family, QueueFamilyMode::Foreign);
        assert_eq!(policy.old_layout, ForeignLayout::General);
        assert_eq!(policy.source_family.index(), vk::QUEUE_FAMILY_FOREIGN_EXT);
        assert_eq!(policy.old_layout.layout(), vk::ImageLayout::GENERAL);
    }

    #[test]
    fn the_other_value_of_each_setting_is_reachable_without_a_rebuild() {
        let policy = BarrierPolicy::from_settings(Some("ignored"), Some("undefined"));

        assert_eq!(policy.source_family, QueueFamilyMode::Ignored);
        assert_eq!(policy.source_family.index(), vk::QUEUE_FAMILY_IGNORED);
        assert_eq!(policy.old_layout, ForeignLayout::Undefined);
        assert_eq!(policy.old_layout.layout(), vk::ImageLayout::UNDEFINED);
    }

    #[test]
    fn an_unrecognised_setting_falls_back_rather_than_stopping_the_session() {
        assert_eq!(
            BarrierPolicy::from_settings(Some("FOREIGN"), Some("")),
            BarrierPolicy::default(),
            "a diagnostic switch is not worth failing a session over, and the parse is exact"
        );
        assert_eq!(QueueFamilyMode::parse("neither"), None);
        assert_eq!(ForeignLayout::parse("optimal"), None);
    }

    #[test]
    fn an_unset_setting_is_the_default() {
        assert_eq!(
            BarrierPolicy::from_settings(None, None),
            BarrierPolicy::default()
        );
    }

    #[test]
    fn an_imported_x_format_is_described_as_opaque() {
        let buffer = ImportedBuffer::Image(ImportedImage {
            image: image(1),
            size: PixelSize::new(8, 4),
            format: smithay::backend::allocator::Fourcc::Xrgb8888,
            modifier: smithay::backend::allocator::Modifier::Linear,
        });

        assert_eq!(
            describe(&buffer),
            TextureDescription {
                size: PixelSize::new(8, 4),
                alpha: Alpha::Opaque,
            }
        );
    }

    #[test]
    fn an_imported_a_format_is_described_as_carrying_alpha() {
        let buffer = ImportedBuffer::Image(ImportedImage {
            image: image(1),
            size: PixelSize::new(8, 4),
            format: smithay::backend::allocator::Fourcc::Argb8888,
            modifier: smithay::backend::allocator::Modifier::Linear,
        });

        assert_eq!(describe(&buffer).alpha, Alpha::Present);
    }

    #[test]
    fn an_uploaded_buffer_always_carries_alpha_because_the_repack_forced_it() {
        for format in [ShmFormat::Argb8888, ShmFormat::Xrgb8888] {
            let pixels = PixelBuffer::new(PixelSize::new(1, 1), format, vec![1, 2, 3, 255])
                .expect("one pixel");

            assert_eq!(
                describe(&ImportedBuffer::Pixels(pixels)),
                TextureDescription {
                    size: PixelSize::new(1, 1),
                    alpha: Alpha::Present,
                }
            );
        }
    }

    #[test]
    fn every_shm_format_is_uploaded_as_bgra() {
        for format in [ShmFormat::Argb8888, ShmFormat::Xrgb8888] {
            assert_eq!(shm_texture_format(format), TextureFormat_FORMAT_BGRA8);
        }
    }

    #[test]
    fn the_texture_declaration_matches_what_the_import_creates() {
        let info = texture_info(PixelSize::new(2, 2), TextureFormat_FORMAT_BGRA8, 42, true);

        assert_eq!(info.usage, TEXTURE_SAMPLE | TEXTURE_TRANSFER);
        assert!(info.foreign);
        assert_eq!(info.handle, 42);
        assert_eq!(info.layers, 1);
        assert_eq!(info.mipmaps, 1);
        assert_eq!(info.samples, 1);
        assert!(!info.srgb);
        assert!(!info.xr);
        assert_eq!(info.imageCount, 0);
        assert!(info.images.is_null());
    }

    #[test]
    fn a_texture_lovr_allocates_is_not_declared_foreign() {
        let info = texture_info(PixelSize::new(2, 2), TextureFormat_FORMAT_BGRA8, 0, false);
        assert!(
            !info.foreign,
            "the flag suppresses the initial transition, which a texture LÖVR is about to fill \
             genuinely wants"
        );
        assert_eq!(info.handle, 0);
    }
}
