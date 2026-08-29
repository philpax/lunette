//! Linux-only: a LÖVR `Texture` over an imported image or an uploaded buffer.
//!
//! # LÖVR's assumptions about a foreign image
//!
//! `gpu_texture_init`'s handle branch (`gpu_vk.c:687-695`) creates nothing and
//! binds nothing. Every assumption it makes is the caller's to satisfy. Four of
//! them matter here.
//!
//! - Usage. LÖVR builds a `VkImageViewUsageCreateInfo` from the declared usage
//!   without checking the image (`gpu_vk.c:838-846`). The declaration below
//!   must agree with [`crate::import::device::IMPORT_USAGE`].
//! - Layout. `texture->layout = getNaturalLayout(info->usage)` (`gpu_vk.c:673`)
//!   is set at creation and LÖVR never re-evaluates it. Declaring
//!   `TEXTURE_SAMPLE | TEXTURE_TRANSFER` makes it `VK_IMAGE_LAYOUT_GENERAL`, the
//!   layout of an image written outside Vulkan and the layout `lovrTextureCopy`
//!   needs.
//! - Format. LÖVR takes `convertFormat(info->format, info->srgb)` to be the
//!   image's format and has no way to detect otherwise.
//! - Memory. LÖVR sets `texture->memory = NULL` and `imported = true`.
//!   `gpu_texture_destroy` (`gpu_vk.c:879-885`) returns after destroying the
//!   view, so `vkDestroyImage` and `vkFreeMemory` are lunette's, and the ledger
//!   defers them in its morgue until the view has left LÖVR's own deferred
//!   queue. LÖVR also starts a command pool and an upload effort when the
//!   foreign flag is set; the session keeps both alive until teardown.

#[cfg(test)]
mod tests;

use std::{ffi::c_void, fmt, ptr::NonNull};

use lunette_compositor::{
    protocol::{ImageHandle, ImportedImage, PixelSize},
    surface::{PixelBuffer, ShmFormat},
};
use lunette_lovr::raw::{
    TEXTURE_FEATURE_BLIT, TEXTURE_SAMPLE, TEXTURE_TRANSFER, Texture, TextureFormat,
    TextureFormat_FORMAT_BGRA8, TextureInfo, TextureType_TEXTURE_2D, lovrGraphicsGetFormatSupport,
    lovrImageCreateRaw, lovrImageDestroy, lovrImageGetLayerData, lovrRelease, lovrTextureClear,
    lovrTextureCopy, lovrTextureCreate, lovrTextureDestroy, lovrTextureGetInfo,
    lovrTextureImportAcquire, lovrTextureImportRelease, lovrTextureSetPixels,
};

use crate::{
    import::formats::mapping_for,
    texture::{
        BarrierPolicy, CopyableTexture, TextureDescription,
        barrier::{acquire_arguments, release_arguments},
    },
};

/// A LÖVR `Texture` lunette owns a reference to.
///
/// The reference is not ownership of the underlying image: for an imported
/// texture LÖVR holds a view, and [`ImageArena`](crate::import::ImageArena)
/// holds the image. Dropping this without calling [`LovrTexture::release_ref`]
/// leaks the reference, so the places that produce one are `#[must_use]`.
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

        // SAFETY: the caller guarantees the thread and the image. `info` is a
        // live local for the duration of the call, and LÖVR copies what it
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
    /// The shared-memory path. LÖVR's own upload machinery does the work, so
    /// the copy is batched into the frame's stream and not submitted on its
    /// own. This is the departure from WayVR's blocking submit at
    /// `image_importer.rs:96-97`.
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
    /// Returns whether they did. A client that resizes gets a new texture,
    /// because a LÖVR texture's dimensions are fixed at creation.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::upload`].
    pub unsafe fn refill(&self, pixels: &PixelBuffer, description: TextureDescription) -> bool {
        if self.image.is_some() || pixels.size() != description.size {
            return false;
        }

        let format = shm_texture_format(pixels.format());
        // SAFETY: the caller's guarantee, and the shapes were checked above to
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
        // format, so its single layer is `width * height * 4` bytes, the same
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
    /// The layout is [`BarrierPolicy::RELEASE_LAYOUT`], not the policy's own:
    /// this is a barrier's `newLayout`, where `UNDEFINED` is forbidden. The
    /// policy contributes only the queue family, the half of the transfer that
    /// has a release side.
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

    /// Names a texture LÖVR owns, without taking a reference to it.
    ///
    /// For a layer's swapchain image: `lovrLayerGetTexture` hands back one of
    /// the textures the swapchain holds and retains nothing, so the layer's own
    /// reference is the only one there is.
    ///
    /// # Safety
    ///
    /// `raw` must name a live LÖVR texture that outlives the returned value,
    /// and [`LovrTexture::release_ref`] must never be called on it. That would
    /// drop the owner's reference, not one of this program's, and destroy the
    /// image while whatever holds it still uses it.
    #[must_use]
    pub const unsafe fn borrowed(raw: NonNull<Texture>) -> Self {
        Self { raw, image: None }
    }

    /// The raw pointer, for the draw path that has to name it to LÖVR.
    #[must_use]
    pub fn as_raw(&self) -> *mut Texture {
        self.raw.as_ptr()
    }

    /// Whether the device can record a copy of this texture into `destination`.
    ///
    /// `lovrTextureCopy` degrades to `lovrTextureBlit` when the two formats
    /// differ, the ordinary case here: a layer's swapchain image is
    /// `FORMAT_RGBA8` with sRGB and a client's window is usually `FORMAT_BGRA8`
    /// without. A blit needs `GPU_FEATURE_BLIT` on both formats, and
    /// `lovrTextureBlit`'s own check for it is a `lovrCheck`, which compiles to
    /// nothing in a release build. Asking here prevents an unsupported blit
    /// from being recorded when it would be refused.
    ///
    /// The encoding is not part of the comparison. `lovrTextureCopy` branches on
    /// `src->info.format != dst->info.format` alone (`graphics.c:2973`), so two
    /// textures of one format and differing sRGB flags take `gpu_copy_textures`,
    /// which needs no `GPU_FEATURE_BLIT`. Asking for it anyway would demote a
    /// panel on a device that could have served it.
    #[must_use]
    pub fn can_copy_to(&self, destination: &Self) -> bool {
        let (Some(source), Some(destination)) = (self.shape(), destination.shape()) else {
            return false;
        };
        if !needs_blit(source, destination) {
            return true;
        }

        blit_supported(source) && blit_supported(destination)
    }

    /// The shape LÖVR carries for the texture.
    ///
    /// Read back out of LÖVR, because a copy's bounds are checked against LÖVR's
    /// record and a second record of the same thing is a second thing to get
    /// wrong.
    fn shape(&self) -> Option<TextureShape> {
        // SAFETY: the pointer is a live texture, and `lovrTextureGetInfo`
        // returns a borrow of the info inside it (`graphics.c:2920-2922`) which
        // is read before anything can free it.
        let info = unsafe { lovrTextureGetInfo(self.raw.as_ptr()).as_ref() }?;
        Some(TextureShape {
            size: PixelSize::new(info.width, info.height),
            layers: info.layers,
            format: info.format,
            srgb: info.srgb,
        })
    }

    /// Clears the texture when the copy about to be recorded into it will not
    /// cover it, reporting whether the clear was accepted.
    ///
    /// The size ladder rounds up, so an 800x600 window is served by a 1024x1024
    /// layer, and [`CopyableTexture::copy_to`] writes only the region the two
    /// textures share. `lovrLayerCreate` sets `subImage.imageRect` to the whole
    /// image (`headset.c:3148`), so the runtime composites the margin as well,
    /// and a swapchain image nothing has written holds uninitialised Vulkan
    /// memory. Clearing once at creation would not answer it either: a
    /// swapchain holds up to `MAX_IMAGES` images and each frame acquires a
    /// different one.
    ///
    /// A panel setting `layer:setViewport` to its source's extent is the policy
    /// answer, and it is mullion's, not the pool's. The viewport is one of the
    /// per-panel properties that let a layer of a given key serve any panel
    /// wanting that key. This catches what the panel misses: nothing a caller
    /// forgot reaches the compositor.
    ///
    /// The cost is a clear on every frame the source is copied, for a source
    /// that does not fill its destination. A clear of a region already being
    /// overwritten is cheaper than the copy it precedes, and a copy that
    /// leaves part of the destination untouched pays for it.
    fn clear_margin(&self, source: TextureShape, own: TextureShape) -> bool {
        if covers(source, own) {
            return true;
        }

        // Transparent black, so an uncovered margin composites as nothing,
        // not as a colour.
        let mut value = [0.0f32; 4];

        // SAFETY: the pointer is a live texture this program holds a reference
        // to, and `value` is a live local LÖVR reads within the call.
        // `lovrTextureClear` resolves `!0` for the layer and level counts
        // against the texture's own info, so neither range can exceed it.
        unsafe { lovrTextureClear(self.raw.as_ptr(), value.as_mut_ptr(), 0, !0, 0, !0) }
    }

    /// Drops lunette's reference to the texture.
    ///
    /// The image behind it is not touched: LÖVR retires only the view, and the
    /// image goes through
    /// [`TextureLedger::retire_image`](crate::texture::TextureLedger::retire_image)
    /// so the image is destroyed a frame later, not under a command buffer
    /// that still names the view.
    pub fn release_ref(&self) {
        // SAFETY: the reference this type holds is the one being dropped, and
        // LÖVR's own reference counting decides whether that is the last.
        unsafe { lovrRelease(self.raw.as_ptr().cast::<c_void>(), Some(lovrTextureDestroy)) };
    }
}

impl CopyableTexture for LovrTexture {
    /// Allocates a LÖVR-owned texture matching this one's size and format.
    ///
    /// The shape is read back out of LÖVR, because a copy's bounds are checked
    /// against LÖVR's record and a second record of the same thing is a second
    /// thing to get wrong.
    ///
    /// Not `foreign`: this texture is LÖVR's to initialise, and the flag exists
    /// to suppress exactly the transition it triggers.
    fn allocate_copy(&self) -> Option<Self> {
        let shape = self.shape()?;
        let copy = texture_info(shape.size, shape.format, 0, false);

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
    /// handled inside LÖVR. This is the reason it is the only copy mechanism in
    /// the codebase: a second one would have to reproduce that, and would get it
    /// subtly wrong.
    ///
    /// The extent is the region the two textures share, computed here, not left
    /// as the `~0` form that lets LÖVR resolve it. `lovrTextureCopy` resolves
    /// `~0` against both textures (`graphics.c:2977-2979`), but when the formats
    /// differ it hands the same array to `lovrTextureBlit` as both the source
    /// and the destination extent. The source's size is resolved first, and the
    /// destination is then given that many pixels whatever its own size is. The
    /// bounds check that would catch it is a `lovrCheck`, which compiles to
    /// nothing in a release build, leaving a `vkCmdBlitImage` past the end of
    /// the destination.
    ///
    /// An extent smaller than the destination leaves the rest of it as it was,
    /// which for a layer's swapchain image is memory nothing has written. The
    /// clear that precedes the copy makes the destination whole; see
    /// [`LovrTexture::clear_margin`].
    fn copy_to(&self, destination: &Self) -> bool {
        let (Some(source), Some(target)) = (self.shape(), destination.shape()) else {
            return false;
        };

        if !destination.clear_margin(source, target) {
            return false;
        }

        let mut source_offset = [0u32; 4];
        let mut destination_offset = [0u32; 4];
        let mut extent = [
            source.size.width.min(target.size.width),
            source.size.height.min(target.size.height),
            source.layers.min(target.layers),
        ];

        // SAFETY: both pointers are live textures this program holds references
        // to, and the three arrays are live locals LÖVR reads and rewrites in
        // place without retaining them.
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

/// The shape LÖVR carries for a texture, with its encoding.
///
/// Named fields taken from the `TextureInfo` it is read out of, because that
/// struct also carries a handle, a label, and the `foreign` flag. None of those
/// outlives creation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TextureShape {
    size: PixelSize,
    layers: u32,
    format: TextureFormat,
    /// Whether the sampler applies a transfer function. `lovrGraphicsGetFormatSupport`
    /// reports the two encodings separately, so a format alone does not answer
    /// what the device can do with it.
    srgb: bool,
}

/// Whether `lovrTextureCopy` between these two degrades to a blit.
///
/// The format alone, because the function branches on it:
/// `if (src->info.format != dst->info.format) return lovrTextureBlit(...)`
/// (`graphics.c:2973`). Two textures of one format and differing sRGB flags
/// take `gpu_copy_textures`, which needs no `GPU_FEATURE_BLIT`. Predicting the
/// branch prevents refusing a copy the device would have made.
fn needs_blit(source: TextureShape, destination: TextureShape) -> bool {
    source.format != destination.format
}

/// Whether a copy from `source` writes every pixel of `destination`.
///
/// The extent of a copy is the region the two share, so a source at least as
/// large in every dimension leaves nothing behind. This is separate from
/// recording the clear: the decision is arithmetic over two shapes and the
/// clear needs a device.
fn covers(source: TextureShape, destination: TextureShape) -> bool {
    source.size.width >= destination.size.width
        && source.size.height >= destination.size.height
        && source.layers >= destination.layers
}

/// Whether the device can blit a texture of this shape.
///
/// `lovrGraphicsGetFormatSupport` reports one bit per encoding:
/// `graphics.c:1049-1062` walks `state.features.formats[format][srgb]` and
/// shifts the result into bit `srgb`, so the sRGB flag selects the bit.
fn blit_supported(shape: TextureShape) -> bool {
    // SAFETY: LÖVR's graphics module is initialised, because a texture with
    // this shape exists. The call reads a table of format capabilities.
    let support = unsafe { lovrGraphicsGetFormatSupport(shape.format, TEXTURE_FEATURE_BLIT) };
    support & (1 << u32::from(shape.srgb)) != 0
}

/// The `TextureInfo` an imported or uploaded texture is created with.
///
/// `TEXTURE_SAMPLE | TEXTURE_TRANSFER`, not `TEXTURE_SAMPLE` alone, for two
/// reasons that both matter. It makes `getNaturalLayout` return
/// `VK_IMAGE_LAYOUT_GENERAL` (`gpu_vk.c:4286-4295`), the layout a foreign image
/// is in. And it takes the texture out of the sample-only exemption at
/// `graphics.c:2647-2657`, giving it a real `Sync` object so it participates in
/// `syncStream`, the need of a `lovrTextureCopy` source, and
/// `window:stabilize()` is exactly that copy.
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
