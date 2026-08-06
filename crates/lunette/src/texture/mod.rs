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

#[cfg(test)]
mod tests;

use std::{collections::HashMap, ffi::c_void, fmt, ptr::NonNull, sync::Arc};

use ash::vk;
use lunette_compositor::{
    protocol::{ImageHandle, ImportedBuffer, ImportedImage, PixelSize, SurfaceId},
    surface::{PixelBuffer, ShmFormat},
};
use lunette_lovr::raw::{
    TEXTURE_SAMPLE, TEXTURE_TRANSFER, Texture, TextureFormat, TextureFormat_FORMAT_BGRA8,
    TextureInfo, TextureType_TEXTURE_2D, lovrImageCreateRaw, lovrImageDestroy,
    lovrImageGetLayerData, lovrRelease, lovrTextureCopy, lovrTextureCreate, lovrTextureDestroy,
    lovrTextureGetInfo, lovrTextureImportAcquire, lovrTextureImportRelease, lovrTextureSetPixels,
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
    /// A stabilised copy could not be allocated or written. Unlike the others
    /// this is not a race with a client: the device refused, which a caller
    /// cannot recover from and should hear about.
    CopyFailed,
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
            Self::CopyFailed => write!(f, "the stabilised copy could not be made"),
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

    /// Records a surface's new texture, returning the ones it displaces.
    ///
    /// The caller destroys what comes back. It is returned rather than dropped
    /// because destroying a LÖVR texture is an FFI call this type cannot make,
    /// and because the underlying image has to be retired at the same moment —
    /// which is the second thing this does.
    ///
    /// A stabilised copy is deliberately kept across the rotation: surviving it
    /// is the whole reason to have asked for one. The exception is a surface
    /// that changed shape, which a LÖVR texture cannot follow — its dimensions
    /// are fixed at creation — so the copy is released and the next
    /// [`stabilize`] allocates one that matches.
    ///
    /// [`stabilize`]: TextureLedger::stabilize
    pub fn install(
        &mut self,
        surface: SurfaceId,
        texture: T,
        description: TextureDescription,
    ) -> Released<T> {
        if let Some(entry) = self.entries.get_mut(&surface) {
            let resized = entry.description.size != description.size;
            let released = Released {
                imported: entry.texture.replace(texture),
                stable: if resized { entry.stable.take() } else { None },
            };

            entry.description = description;
            entry.dead = false;
            entry.damaged = true;
            return released;
        }

        self.entries.insert(
            surface,
            Entry {
                texture: Some(texture),
                description,
                dead: false,
                stable: None,
                damaged: true,
            },
        );
        Released::default()
    }

    /// Marks a surface's client as gone.
    ///
    /// The description survives, so reads keep returning last-known values, and
    /// both textures are handed back for destruction: neither an image whose
    /// client has exited nor a copy of it is going to be looked at again, since
    /// every method of a dead handle answers `false` before it reaches one.
    pub fn mark_dead(&mut self, surface: SurfaceId) -> Released<T> {
        let Some(entry) = self.entries.get_mut(&surface) else {
            return Released::default();
        };

        entry.dead = true;
        Released {
            imported: entry.texture.take(),
            stable: entry.stable.take(),
        }
    }

    /// Drops everything known about a surface, returning its textures.
    pub fn forget(&mut self, surface: SurfaceId) -> Released<T> {
        self.entries
            .remove(&surface)
            .map_or_else(Released::default, |entry| Released {
                imported: entry.texture,
                stable: entry.stable,
            })
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

    /// Hands out the surface's stabilised copy, allocating it on first ask.
    ///
    /// The copy is lunette's own texture, so its identity survives the client
    /// cycling its buffers — which is the entire point, and the reason
    /// [`TextureLedger::lookup`] cannot be used for it. It is brought up to
    /// date here when the source has been damaged since it was last written, so
    /// that the first call in a frame returns something current whether or not
    /// [`TextureLedger::refresh_stable`] has run.
    ///
    /// The cost is a full-surface copy on every damaged frame, which for a 4K
    /// mirror at 90 Hz is around 3 GB/s. `docs/rendering.md` records why that
    /// makes this opt-in rather than the default.
    ///
    /// # Errors
    ///
    /// See [`TextureUnavailable`]. The generation is checked here as it is for
    /// an imported texture: the returned texture outlives the frame, but the
    /// surface it belongs to may not.
    pub fn stabilize(
        &mut self,
        reference: TextureRef,
        current: FrameGeneration,
    ) -> Result<&T, TextureUnavailable>
    where
        T: CopyableTexture,
    {
        let Some(entry) = self.entries.get_mut(&reference.surface) else {
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
        let Some(source) = entry.texture.as_ref() else {
            return Err(TextureUnavailable::Unknown);
        };

        if entry.stable.is_none() {
            entry.stable = Some(
                source
                    .allocate_copy()
                    .ok_or(TextureUnavailable::CopyFailed)?,
            );
            entry.damaged = true;
        }

        let Some(stable) = entry.stable.as_ref() else {
            return Err(TextureUnavailable::CopyFailed);
        };
        if entry.damaged {
            if !source.copy_to(stable) {
                return Err(TextureUnavailable::CopyFailed);
            }
            entry.damaged = false;
        }

        Ok(stable)
    }

    /// Brings every stabilised copy up to date with the buffer behind it.
    ///
    /// Runs once a frame, after the frame's buffers have been installed and
    /// before anything draws. A surface that has not been damaged since its
    /// copy was last written is skipped, which is what makes an idle window cost
    /// nothing.
    pub fn refresh_stable(&mut self)
    where
        T: CopyableTexture,
    {
        for (surface, entry) in &mut self.entries {
            if entry.dead || !entry.damaged {
                continue;
            }
            let (Some(source), Some(stable)) = (entry.texture.as_ref(), entry.stable.as_ref())
            else {
                continue;
            };

            if source.copy_to(stable) {
                entry.damaged = false;
            } else {
                // Left damaged, so the next frame tries again rather than
                // leaving the copy silently showing an older frame for ever.
                warn!(%surface, "a stabilised surface could not be updated");
            }
        }
    }

    /// Every texture a live surface currently holds.
    ///
    /// The frame loop records the import barriers over these: an acquire before
    /// anything in the frame can sample one, and a release after. A dead
    /// surface is skipped because its texture has already been handed back.
    pub fn textures(&self) -> impl Iterator<Item = &T> {
        self.entries
            .values()
            .filter(|entry| !entry.dead)
            .flat_map(|entry| entry.texture.iter().chain(entry.stable.iter()))
    }

    /// Empties the ledger, returning every texture it held.
    ///
    /// For teardown, where the caller releases all of them at once. The images
    /// behind them are not retired: a shutdown destroys the graphics device
    /// immediately afterwards, and [`destroy_due_images`] cannot run then
    /// because the deferral it counts in frames has no frames left to count.
    #[must_use]
    pub fn take_all(&mut self) -> Vec<T> {
        self.entries
            .drain()
            .flat_map(|(_, entry)| entry.texture.into_iter().chain(entry.stable))
            .collect()
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
    /// The lunette-owned copy `window:stabilize()` hands out, present only once
    /// something has asked for one.
    stable: Option<T>,
    /// Whether the source has been replaced since the copy was last written.
    /// Set by every install, including the first, because a copy is only ever
    /// as current as the last buffer it was given.
    damaged: bool,
}

/// The textures a change to the ledger handed back for release.
///
/// Two fields rather than a list, because the caller has to be able to tell an
/// imported texture from one LÖVR allocated: only the first has an image behind
/// it that lunette destroys separately.
#[derive(Debug, PartialEq, Eq)]
pub struct Released<T> {
    /// The texture wrapping a client's buffer.
    pub imported: Option<T>,
    /// The stabilised copy, when it can no longer be kept.
    pub stable: Option<T>,
}

impl<T> Default for Released<T> {
    fn default() -> Self {
        Self {
            imported: None,
            stable: None,
        }
    }
}

impl<T> IntoIterator for Released<T> {
    type Item = T;
    type IntoIter = std::iter::Flatten<std::array::IntoIter<Option<T>, 2>>;

    /// Both textures, for a caller that releases them the same way.
    fn into_iter(self) -> Self::IntoIter {
        [self.imported, self.stable].into_iter().flatten()
    }
}

/// A texture that can be copied into another of its own shape.
///
/// The seam between the bookkeeping and the device. `window:stabilize()` needs
/// to allocate a texture and record a copy into it, and neither is something
/// [`TextureLedger`] can do for an arbitrary `T` — so both are asked of the
/// texture, and the tests answer with a counter.
pub trait CopyableTexture: Sized {
    /// Allocates a texture with this one's shape, to be copied into.
    ///
    /// `None` when the device refused.
    fn allocate_copy(&self) -> Option<Self>;

    /// Records a copy of this texture into `destination`, reporting whether it
    /// was accepted.
    fn copy_to(&self, destination: &Self) -> bool;
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

    /// The layout the acquire takes the image to be in.
    ///
    /// The measurable half of the policy: an acquire may legally name
    /// `UNDEFINED` here, and doing so is what asks the driver whether it
    /// discards the client's content.
    #[must_use]
    fn acquire_layout(self) -> vk::ImageLayout {
        self.old_layout.layout()
    }

    /// The layout the release hands the image back in.
    ///
    /// `GENERAL` whatever the policy says, because this is a barrier's
    /// `newLayout` and VUID-VkImageMemoryBarrier2-newLayout-01198 forbids
    /// `UNDEFINED` there. It is also the layout the image is genuinely in: a
    /// producer outside Vulkan has no other, which is why it is what
    /// [`ForeignLayout::General`] names on the way in.
    const RELEASE_LAYOUT: vk::ImageLayout = vk::ImageLayout::GENERAL;
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

        let arguments = acquire_arguments(policy);

        // SAFETY: the caller's guarantee. The two values are plain integers
        // LÖVR passes through to the barrier.
        unsafe {
            lovrTextureImportAcquire(self.raw.as_ptr(), arguments.layout, arguments.queue_family)
        }
    }

    /// Records the barrier that hands the image back after the frame's reads.
    ///
    /// The layout is [`BarrierPolicy::RELEASE_LAYOUT`] and not the policy's own:
    /// this is a barrier's `newLayout`, where `UNDEFINED` is forbidden. Only the
    /// queue family is taken from the policy, which is the half of it that has
    /// a release side at all.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::acquire`], and this must run after them.
    pub unsafe fn release(&self, policy: BarrierPolicy) -> bool {
        if self.image.is_none() {
            return true;
        }

        let arguments = release_arguments(policy);

        // SAFETY: as above.
        unsafe {
            lovrTextureImportRelease(self.raw.as_ptr(), arguments.layout, arguments.queue_family)
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

impl CopyableTexture for LovrTexture {
    /// Allocates a LÖVR-owned texture matching this one's size and format.
    ///
    /// The shape is read back out of LÖVR rather than tracked alongside,
    /// because LÖVR is what `lovrTextureCopy` checks the bounds against and a
    /// second record of the same thing is a second thing to get wrong.
    ///
    /// Not `foreign`: this texture is LÖVR's to initialise, and the flag exists
    /// to suppress exactly the transition it wants.
    fn allocate_copy(&self) -> Option<Self> {
        // SAFETY: the pointer is the live texture this type owns a reference
        // to, and `lovrTextureGetInfo` returns a borrow of the info inside it
        // (`graphics.c:2920-2922`) which is read before anything can free it.
        let info = unsafe { lovrTextureGetInfo(self.raw.as_ptr()).as_ref() }?;
        let copy = texture_info(
            PixelSize::new(info.width, info.height),
            info.format,
            0,
            false,
        );

        // SAFETY: LÖVR's graphics module is initialised, because this texture
        // exists; `copy` is a live local for the duration of the call.
        let raw = unsafe { lovrTextureCreate(&raw const copy) };
        Some(Self {
            raw: NonNull::new(raw)?,
            image: None,
        })
    }

    /// Records the copy into LÖVR's own stream.
    ///
    /// `lovrTextureCopy` takes `state.lock` and emits `syncStream` barriers
    /// against both textures, so ordering against LÖVR's own rendering is
    /// handled inside LÖVR. That is why this is the one copy mechanism in the
    /// codebase: a second one would have to reproduce that, and would get it
    /// subtly wrong.
    ///
    /// An extent of `~0` asks for the largest region the two textures share,
    /// resolved at `graphics.c:2977-2979`. Nothing here has to know the size.
    fn copy_to(&self, destination: &Self) -> bool {
        let mut source_offset = [0u32; 4];
        let mut destination_offset = [0u32; 4];
        let mut extent = [u32::MAX; 3];

        // SAFETY: both pointers are live textures this program holds references
        // to, and the three arrays are live locals LÖVR reads and rewrites in
        // place rather than retaining.
        unsafe {
            lovrTextureCopy(
                self.raw.as_ptr(),
                destination.raw.as_ptr(),
                source_offset.as_mut_ptr(),
                destination_offset.as_mut_ptr(),
                extent.as_mut_ptr(),
            )
        }
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
/// source needs, and `window:stabilize()` is exactly that copy.
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

/// The two integers an import barrier is recorded with.
///
/// Named fields rather than a pair, because both are `u32` and the FFI call
/// takes them positionally: a transposition would compile and record a barrier
/// naming a queue family index as a layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BarrierArguments {
    layout: u32,
    queue_family: u32,
}

/// The arguments the acquire barrier is recorded with.
///
/// Separate from [`LovrTexture::acquire`] so the choice is a pure function of
/// the policy: recording the barrier needs a device and this does not, which is
/// what makes the choice testable.
fn acquire_arguments(policy: BarrierPolicy) -> BarrierArguments {
    BarrierArguments {
        layout: policy.acquire_layout().as_raw().unsigned_abs(),
        queue_family: policy.source_family.index(),
    }
}

/// The arguments the release barrier is recorded with.
///
/// The layout is [`BarrierPolicy::RELEASE_LAYOUT`] whatever the policy says.
/// This is a barrier's `newLayout`, where `UNDEFINED` is forbidden, so the
/// policy's own layout must not reach here. As [`acquire_arguments`], separate
/// so that is testable without a device.
fn release_arguments(policy: BarrierPolicy) -> BarrierArguments {
    BarrierArguments {
        layout: BarrierPolicy::RELEASE_LAYOUT.as_raw().unsigned_abs(),
        queue_family: policy.source_family.index(),
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
