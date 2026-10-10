//! Linux-only: wraps imported images and uploaded buffers as LÖVR textures.
//!
//! LÖVR owns the image view but not the imported image or memory, so the texture ledger defers
//! image destruction until LÖVR releases the view.

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

/// An owned reference to a LÖVR texture.
///
/// For imported textures, LÖVR owns the view and [`ImageArena`](crate::import::ImageArena) owns the
/// image. Call [`LovrTexture::release_ref`] to release this reference.
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

        // SAFETY: the caller guarantees the thread and the image, and LÖVR
        // copies what it keeps from `info`.
        let raw = unsafe { lovrTextureCreate(&raw const info) };
        let raw = NonNull::new(raw).ok_or(TextureError::Create)?;

        Ok(Self {
            raw,
            image: Some(image.image),
        })
    }

    /// Allocates a LÖVR-owned texture and uploads the client's shared-memory pixels.
    ///
    /// The upload is recorded in LÖVR's frame stream and is not submitted separately.
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
    /// Returns whether they did, because a LÖVR texture's dimensions are fixed
    /// at creation.
    ///
    /// # Safety
    ///
    /// As [`LovrTexture::upload`].
    pub unsafe fn refill(&self, pixels: &PixelBuffer, description: TextureDescription) -> bool {
        if self.image.is_some() || pixels.size() != description.size {
            return false;
        }

        let format = shm_texture_format(pixels.format());
        // SAFETY: the caller's guarantee, and the shapes match.
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
        // SAFETY: the caller's guarantee. A raw image does not depend on a
        // device.
        let image = unsafe { lovrImageCreateRaw(size.width, size.height, format, false) };
        let Some(image) = NonNull::new(image) else {
            return Err(TextureError::AllocateStagingImage);
        };

        // SAFETY: the image has these dimensions and format, so its layer is
        // `width * height * 4` bytes, as `PixelBuffer` guarantees. It was
        // allocated in this call, so the regions cannot overlap.
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

        // SAFETY: nothing else holds a reference to the staging image.
        unsafe { lovrRelease(image.as_ptr().cast::<c_void>(), Some(lovrImageDestroy)) };

        if written {
            Ok(())
        } else {
            Err(TextureError::Upload)
        }
    }

    /// Records the barrier that makes the imported image readable this frame.
    ///
    /// A no-op for a texture LÖVR allocated itself, which has no foreign
    /// producer.
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

        // SAFETY: the caller's guarantee.
        unsafe {
            lovrTextureImportAcquire(self.raw.as_ptr(), arguments.layout, arguments.queue_family)
        }
    }

    /// Records a barrier that returns the image after frame reads.
    ///
    /// Vulkan forbids `UNDEFINED` as a barrier's `newLayout`, so the release
    /// layout is [`BarrierPolicy::RELEASE_LAYOUT`].
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

    /// Names a texture LÖVR owns, without taking a reference to it.
    ///
    /// Layer swapchain textures are borrowed; the layer retains their only reference.
    ///
    /// # Safety
    ///
    /// `raw` must name a live LÖVR texture that outlives the returned value,
    /// and [`LovrTexture::release_ref`] must never be called on it, because
    /// that drops the owner's reference.
    #[must_use]
    pub const unsafe fn borrowed(raw: NonNull<Texture>) -> Self {
        Self { raw, image: None }
    }

    /// The raw pointer, for the draw path that has to name it to LÖVR.
    #[must_use]
    pub fn as_raw(&self) -> *mut Texture {
        self.raw.as_ptr()
    }

    /// Returns whether LÖVR can copy this texture into `destination`.
    ///
    /// Different formats require a blit, which the device must support for both formats.
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
    /// Read from LÖVR, because a copy's bounds are checked against LÖVR's
    /// record.
    fn shape(&self) -> Option<TextureShape> {
        // SAFETY: the pointer is a live texture, and the borrowed metadata is read before it can
        // be freed.
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
    /// Layer sizes round up and the compositor samples the full swapchain image, so an unwritten
    /// margin shows uninitialised memory. Each acquired image needs its own clear.
    fn clear_margin(&self, source: TextureShape, own: TextureShape) -> bool {
        if covers(source, own) {
            return true;
        }

        // Transparent black, so an uncovered margin composites as nothing.
        let mut value = [0.0f32; 4];

        // SAFETY: the pointer is a live texture this program holds. LÖVR
        // resolves `!0` against the texture's own layer and level counts.
        unsafe { lovrTextureClear(self.raw.as_ptr(), value.as_mut_ptr(), 0, !0, 0, !0) }
    }

    /// Drops lunette's reference to the texture.
    ///
    /// The image behind it goes through
    /// [`TextureLedger::retire_image`](crate::texture::TextureLedger::retire_image),
    /// so it is not destroyed under a command buffer that still names the view.
    pub fn release_ref(&self) {
        // SAFETY: the reference this type holds is the one being dropped.
        unsafe { lovrRelease(self.raw.as_ptr().cast::<c_void>(), Some(lovrTextureDestroy)) };
    }
}

impl CopyableTexture for LovrTexture {
    /// Allocates a LÖVR-owned texture matching this one's size and format.
    ///
    /// Not `foreign`, because LÖVR initialises this texture itself.
    fn allocate_copy(&self) -> Option<Self> {
        let shape = self.shape()?;
        let copy = texture_info(shape.size, shape.format, 0, false);

        // SAFETY: LÖVR's graphics module is initialised, because this texture
        // exists.
        let raw = unsafe { lovrTextureCreate(&raw const copy) };
        Some(Self {
            raw: NonNull::new(raw)?,
            image: None,
        })
    }

    /// Records the copy into LÖVR's own stream.
    ///
    /// `lovrTextureCopy` emits the barriers that order it against LÖVR's own
    /// rendering, which is why it is the only copy mechanism.
    ///
    /// The extent is the shared region of both textures, because LÖVR's blit path otherwise uses
    /// the source extent and its bounds check is disabled in release builds.
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

        // SAFETY: both pointers are live textures this program holds, and LÖVR
        // does not retain the arrays.
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

/// Texture metadata used for copy bounds and format support.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TextureShape {
    size: PixelSize,
    layers: u32,
    format: TextureFormat,
    /// Whether the sampler applies a transfer function. Format support differs by
    /// encoding.
    srgb: bool,
}

/// Whether `lovrTextureCopy` between these two degrades to a blit.
///
/// LÖVR selects blit by pixel format, so differing sRGB flags alone use the copy path.
fn needs_blit(source: TextureShape, destination: TextureShape) -> bool {
    source.format != destination.format
}

/// Whether a copy from `source` writes every pixel of `destination`.
///
/// Kept apart from the clear, because this decision needs no device.
fn covers(source: TextureShape, destination: TextureShape) -> bool {
    source.size.width >= destination.size.width
        && source.size.height >= destination.size.height
        && source.layers >= destination.layers
}

/// Whether the device can blit a texture of this shape.
fn blit_supported(shape: TextureShape) -> bool {
    // SAFETY: LÖVR's graphics module is initialised, because a texture with
    // this shape exists.
    let support = unsafe { lovrGraphicsGetFormatSupport(shape.format, TEXTURE_FEATURE_BLIT) };
    support & (1 << u32::from(shape.srgb)) != 0
}

/// The `TextureInfo` an imported or uploaded texture is created with.
///
/// The sample and transfer usages create the synchronization object `lovrTextureCopy` requires.
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
        // Preserve encoded desktop pixels for raw layer copies. Scene renderers
        // decode sRGB explicitly, unpremultiplying window alpha before decoding.
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
/// Both variants are little-endian `[B, G, R, _]`, and [`crate::import::shm`]
/// has already forced the fourth byte to one.
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
