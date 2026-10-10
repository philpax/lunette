//! Linux-only: the Vulkan device LÖVR owns, borrowed for buffer import.
//!
//! An unresolved function pointer panics when called, so construction checks LÖVR's extension
//! flags first. LÖVR requests Vulkan 1.1, so a 1.2 or 1.3 call would compile, load, and panic.

use std::{fmt, mem::MaybeUninit, sync::Arc};

use ash::{
    ext, khr,
    vk::{self, Handle as _},
};
use lunette_compositor::state::{DmabufSupport, RenderNode};
use lunette_lovr::raw::{GraphicsFeatures, lovrGraphicsGetFeatures, lovrGraphicsIsInitialized};
use smithay::backend::allocator::Format;
use tracing::{debug, warn};

use crate::import::formats::{self, SUPPORTED};

/// The Vulkan device LÖVR owns, with the loaders the import path needs.
///
/// Shared across threads, which Vulkan permits for a `VkDevice`.
pub struct GraphicsDevice {
    /// Held because the loaders obtain their function pointers from it.
    _entry: ash::Entry,
    device: ash::Device,
    external_memory_fd: khr::external_memory_fd::Device,
    render_node: Option<RenderNode>,
    formats: Vec<Format>,
    export_formats: Vec<Format>,
    pub(crate) capture_live: parking_lot::Mutex<bool>,
}

impl GraphicsDevice {
    /// Wraps the device LÖVR owns.
    ///
    /// # Errors
    ///
    /// Reports the first thing that makes import impossible.
    ///
    /// # Safety
    ///
    /// LÖVR's graphics module must stay initialised for as long as the returned
    /// device is held, because every handle inside it belongs to LÖVR.
    pub unsafe fn borrow_from_lovr() -> Result<Arc<Self>, DeviceError> {
        // SAFETY: the call reads a flag and touches no Rust state.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return Err(DeviceError::GraphicsNotInitialised);
        }

        let extensions = ImportExtensions::from_lovr();
        let missing = extensions.missing();
        if !missing.is_empty() {
            return Err(DeviceError::MissingExtensions { missing });
        }

        // SAFETY: LÖVR already has the system loader open, so this only
        // raises its reference count.
        let entry = unsafe { ash::Entry::load() }.map_err(DeviceError::LoadVulkan)?;

        let handles = LovrHandles::query();
        // SAFETY: the handle is a live instance from the same loader, as
        // `lovrGraphicsIsInitialized` establishes.
        let instance = unsafe { ash::Instance::load(entry.static_fn(), handles.instance) };

        // SAFETY: `physical_device` belongs to the instance wrapped above.
        let properties =
            unsafe { instance.get_physical_device_properties(handles.physical_device) };
        if properties.api_version < vk::API_VERSION_1_1 {
            return Err(DeviceError::ApiVersionTooLow {
                found: properties.api_version,
            });
        }

        // SAFETY: `device` is a live device handle from the same loader.
        let device = unsafe { ash::Device::load(instance.fp_v1_0(), handles.device) };
        // The only extension loader the import path needs; the other
        // extensions contribute structures and no entry points.
        let external_memory_fd = khr::external_memory_fd::Device::new(&instance, &device);

        let render_node = query_render_node(&instance, handles.physical_device)?;
        let formats = query_formats(&instance, handles.physical_device);
        let export_formats = formats
            .iter()
            .copied()
            .filter(|format| {
                format.modifier != smithay::backend::allocator::Modifier::Invalid
                    && formats::mapping_for(format.code).is_some_and(|mapping| {
                        external_image_support(
                            &instance,
                            handles.physical_device,
                            mapping.vulkan,
                            u64::from(format.modifier),
                            vk::ExternalMemoryFeatureFlags::EXPORTABLE,
                        )
                    })
            })
            .collect();

        debug!(
            queue_family = handles.queue_family,
            formats = formats.len(),
            render_node = ?render_node,
            "borrowed LÖVR's vulkan device for buffer import"
        );

        Ok(Arc::new(Self {
            _entry: entry,
            device,
            external_memory_fd,
            capture_live: parking_lot::Mutex::new(true),
            render_node,
            formats,
            export_formats,
        }))
    }

    /// What to advertise over `zwp_linux_dmabuf_v1`.
    ///
    /// Without a render node nothing is advertised, and clients fall back to
    /// `wl_shm`.
    #[must_use]
    pub fn dmabuf_support(&self) -> DmabufSupport {
        DmabufSupport {
            main_device: self.render_node,
            formats: self.formats.clone(),
        }
    }

    /// Single-plane explicit layouts supporting both import and DMA buffer export.
    pub(crate) fn export_formats(&self) -> &[Format] {
        &self.export_formats
    }

    #[must_use]
    pub(crate) fn raw(&self) -> &ash::Device {
        &self.device
    }

    #[must_use]
    pub(crate) fn external_memory_fd(&self) -> &khr::external_memory_fd::Device {
        &self.external_memory_fd
    }
}

impl fmt::Debug for GraphicsDevice {
    /// Hand-written because `ash::Device` is not `Debug`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GraphicsDevice")
            .field("render_node", &self.render_node)
            .field("formats", &self.formats.len())
            .finish_non_exhaustive()
    }
}

/// The optional Vulkan extensions the import path depends on.
///
/// Separate from LÖVR's `GraphicsFeatures` so the missing-extension decision
/// needs no live graphics module.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ImportExtensions {
    pub external_memory: bool,
    pub external_memory_fd: bool,
    pub external_memory_dma_buf: bool,
    pub image_drm_format_modifier: bool,
    pub queue_family_foreign: bool,
}

impl ImportExtensions {
    /// What LÖVR reports it enabled.
    fn from_lovr() -> Self {
        // Zeroed, because upstream may add fields the call does not assign,
        // and an uninitialised byte is not a valid `bool`.
        let mut features = MaybeUninit::<GraphicsFeatures>::zeroed();
        // SAFETY: the allocation is live and initialised, and the caller has
        // established that graphics is initialised.
        let features = unsafe {
            lovrGraphicsGetFeatures(features.as_mut_ptr());
            features.assume_init()
        };

        Self {
            external_memory: features.externalMemory,
            external_memory_fd: features.externalMemoryFd,
            external_memory_dma_buf: features.externalMemoryDmaBuf,
            image_drm_format_modifier: features.imageDrmFormatModifier,
            queue_family_foreign: features.queueFamilyForeign,
        }
    }

    /// The extensions that are absent, with their Vulkan names.
    ///
    /// All five are required. Two contribute only structures, and without them
    /// the import fails validation in a way harder to read than this list.
    #[must_use]
    pub fn missing(&self) -> Vec<&'static str> {
        [
            (self.external_memory, "VK_KHR_external_memory"),
            (self.external_memory_fd, "VK_KHR_external_memory_fd"),
            (
                self.external_memory_dma_buf,
                "VK_EXT_external_memory_dma_buf",
            ),
            (
                self.image_drm_format_modifier,
                "VK_EXT_image_drm_format_modifier",
            ),
            (self.queue_family_foreign, "VK_EXT_queue_family_foreign"),
        ]
        .into_iter()
        .filter_map(|(present, name)| (!present).then_some(name))
        .collect()
    }
}

/// The raw handles LÖVR's Vulkan backend exposes.
struct LovrHandles {
    instance: vk::Instance,
    physical_device: vk::PhysicalDevice,
    device: vk::Device,
    queue_family: u32,
}

impl LovrHandles {
    /// Reads the four handles LÖVR exposes.
    ///
    /// The queue itself is discarded, because lunette never submits.
    fn query() -> Self {
        let mut queue_family = 0;
        let mut queue_index = 0;

        // SAFETY: the caller has established that LÖVR's graphics state is
        // initialised, and the out-pointers address live locals.
        unsafe {
            let instance = lunette_lovr::raw::gpu_vk_get_instance();
            let physical_device = lunette_lovr::raw::gpu_vk_get_physical_device();
            let device = lunette_lovr::raw::gpu_vk_get_device();
            lunette_lovr::raw::gpu_vk_get_queue(&raw mut queue_family, &raw mut queue_index);

            Self {
                instance: vk::Instance::from_raw(instance as u64),
                physical_device: vk::PhysicalDevice::from_raw(physical_device as u64),
                device: vk::Device::from_raw(device as u64),
                queue_family,
            }
        }
    }
}

/// The DRM render node the physical device belongs to.
///
/// Chaining a structure from an unsupported extension is not permitted, so
/// support for `VK_EXT_physical_device_drm` is checked first.
fn query_render_node(
    instance: &ash::Instance,
    physical_device: vk::PhysicalDevice,
) -> Result<Option<RenderNode>, DeviceError> {
    // SAFETY: `physical_device` belongs to `instance`.
    let supported = unsafe { instance.enumerate_device_extension_properties(physical_device) }
        .map_err(DeviceError::EnumerateExtensions)?;

    let has_drm_properties = supported
        .iter()
        .any(|extension| extension.extension_name_as_c_str() == Ok(ext::physical_device_drm::NAME));
    if !has_drm_properties {
        warn!(
            "the driver does not report {}, so no dmabuf feedback can be built and clients will \
             fall back to wl_shm",
            ext::physical_device_drm::NAME.to_string_lossy()
        );
        return Ok(None);
    }

    let mut drm = vk::PhysicalDeviceDrmPropertiesEXT::default();
    let mut properties = vk::PhysicalDeviceProperties2::default().push_next(&mut drm);
    // SAFETY: a Vulkan 1.1 core call, and the driver supports the chained
    // structure.
    unsafe { instance.get_physical_device_properties2(physical_device, &mut properties) };

    if drm.has_render == vk::FALSE {
        warn!("the driver reports no render node for the graphics device");
        return Ok(None);
    }

    let (major, minor) = (drm.render_major, drm.render_minor);
    let widen = |value: i64| u32::try_from(value).ok();
    match (widen(major), widen(minor)) {
        (Some(major), Some(minor)) => Ok(Some(RenderNode::from_major_minor(major, minor))),
        _ => Err(DeviceError::NonsensicalRenderNode { major, minor }),
    }
}

/// The formats and modifiers the device accepts for an import.
///
/// A listed modifier may still not support lunette's tiling and usage, so
/// each candidate is also checked with
/// `vkGetPhysicalDeviceImageFormatProperties2`.
fn query_formats(instance: &ash::Instance, physical_device: vk::PhysicalDevice) -> Vec<Format> {
    let mut advertised = Vec::new();

    for mapping in SUPPORTED {
        let reported = query_modifiers(instance, physical_device, mapping.vulkan);
        let usable: Vec<_> = formats::single_plane_modifiers(&reported)
            .into_iter()
            .filter(|modifier| {
                external_image_support(
                    instance,
                    physical_device,
                    mapping.vulkan,
                    u64::from(*modifier),
                    vk::ExternalMemoryFeatureFlags::IMPORTABLE,
                )
            })
            .collect();

        if usable.is_empty() {
            debug!(
                fourcc = ?mapping.fourcc,
                "no explicit modifier survived filtering; only the implicit one is advertised"
            );
        }
        advertised.extend(formats::advertise(mapping.fourcc, &usable));
    }

    advertised
}

/// The modifier list for one format, through the two-call idiom.
///
/// The list structure is built by hand on the second call, because the
/// builder derives the count from the slice.
fn query_modifiers(
    instance: &ash::Instance,
    physical_device: vk::PhysicalDevice,
    format: vk::Format,
) -> Vec<vk::DrmFormatModifierPropertiesEXT> {
    let mut list = vk::DrmFormatModifierPropertiesListEXT::default();
    let mut properties = vk::FormatProperties2::default().push_next(&mut list);
    // SAFETY: a Vulkan 1.1 core call, and `VK_EXT_image_drm_format_modifier`
    // is enabled.
    unsafe {
        instance.get_physical_device_format_properties2(physical_device, format, &mut properties)
    };

    let count = list.drm_format_modifier_count;
    if count == 0 {
        return Vec::new();
    }

    let mut storage = vec![vk::DrmFormatModifierPropertiesEXT::default(); count as usize];
    let mut list = vk::DrmFormatModifierPropertiesListEXT {
        drm_format_modifier_count: count,
        p_drm_format_modifier_properties: storage.as_mut_ptr(),
        ..Default::default()
    };
    let mut properties = vk::FormatProperties2::default().push_next(&mut list);
    // SAFETY: `storage` has room for the count the first call reported.
    unsafe {
        instance.get_physical_device_format_properties2(physical_device, format, &mut properties)
    };

    storage.truncate(list.drm_format_modifier_count as usize);
    storage
}

/// Whether an image can be created for this format and modifier at the tiling,
/// usage, and external handle type the import and export paths use.
fn external_image_support(
    instance: &ash::Instance,
    physical_device: vk::PhysicalDevice,
    format: vk::Format,
    modifier: u64,
    required: vk::ExternalMemoryFeatureFlags,
) -> bool {
    let mut modifier_info = vk::PhysicalDeviceImageDrmFormatModifierInfoEXT::default()
        .drm_format_modifier(modifier)
        .sharing_mode(vk::SharingMode::EXCLUSIVE);
    let mut external = vk::PhysicalDeviceExternalImageFormatInfo::default()
        .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
    let query = vk::PhysicalDeviceImageFormatInfo2::default()
        .format(format)
        .ty(vk::ImageType::TYPE_2D)
        .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
        .usage(IMPORT_USAGE)
        .push_next(&mut modifier_info)
        .push_next(&mut external);

    let mut external_properties = vk::ExternalImageFormatProperties::default();
    let mut properties = vk::ImageFormatProperties2::default().push_next(&mut external_properties);

    // SAFETY: a Vulkan 1.1 core call, with structures from enabled
    // extensions.
    let supported = unsafe {
        instance.get_physical_device_image_format_properties2(
            physical_device,
            &query,
            &mut properties,
        )
    }
    .is_ok();

    supported
        && external_properties
            .external_memory_properties
            .external_memory_features
            .contains(required)
}

/// The usage every imported image is created with.
///
/// It must match what [`crate::texture`] declares to `lovrTextureCreate`,
/// because LÖVR builds the image view from the declaration without validating
/// it.
pub(crate) const IMPORT_USAGE: vk::ImageUsageFlags = vk::ImageUsageFlags::from_raw(
    vk::ImageUsageFlags::SAMPLED.as_raw()
        | vk::ImageUsageFlags::TRANSFER_SRC.as_raw()
        | vk::ImageUsageFlags::TRANSFER_DST.as_raw(),
);

/// Why LÖVR's device could not be borrowed.
#[derive(Debug)]
pub enum DeviceError {
    GraphicsNotInitialised,
    LoadVulkan(ash::LoadingError),
    MissingExtensions { missing: Vec<&'static str> },
    ApiVersionTooLow { found: u32 },
    EnumerateExtensions(vk::Result),
    NonsensicalRenderNode { major: i64, minor: i64 },
}

impl fmt::Display for DeviceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "graphics device: ")?;
        match self {
            Self::GraphicsNotInitialised => write!(
                f,
                "LÖVR's graphics module is not initialised, so there is no device to borrow"
            ),
            Self::LoadVulkan(_) => write!(f, "the vulkan loader could not be opened"),
            Self::MissingExtensions { missing } => write!(
                f,
                "the driver did not enable {}, which buffer import needs; clients will be served \
                 over wl_shm instead",
                missing.join(", ")
            ),
            Self::ApiVersionTooLow { found } => write!(
                f,
                "vulkan {}.{} is below the 1.1 the import path is written against",
                vk::api_version_major(*found),
                vk::api_version_minor(*found)
            ),
            Self::EnumerateExtensions(_) => {
                write!(f, "the device's extension list could not be read")
            }
            Self::NonsensicalRenderNode { major, minor } => write!(
                f,
                "the driver reported a render node at {major}:{minor}, which is not a device number"
            ),
        }
    }
}

impl std::error::Error for DeviceError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::LoadVulkan(cause) => Some(cause),
            Self::EnumerateExtensions(cause) => Some(cause),
            Self::GraphicsNotInitialised
            | Self::MissingExtensions { .. }
            | Self::ApiVersionTooLow { .. }
            | Self::NonsensicalRenderNode { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn all_present() -> ImportExtensions {
        ImportExtensions {
            external_memory: true,
            external_memory_fd: true,
            external_memory_dma_buf: true,
            image_drm_format_modifier: true,
            queue_family_foreign: true,
        }
    }

    #[test]
    fn an_empty_extension_set_names_all_five() {
        assert_eq!(
            ImportExtensions::default().missing(),
            vec![
                "VK_KHR_external_memory",
                "VK_KHR_external_memory_fd",
                "VK_EXT_external_memory_dma_buf",
                "VK_EXT_image_drm_format_modifier",
                "VK_EXT_queue_family_foreign",
            ]
        );
    }

    #[test]
    fn each_absent_extension_is_named_on_its_own() {
        /// Clearing one flag, paired with the name that must then be reported.
        type Case = (fn(&mut ImportExtensions), &'static str);

        let cases: [Case; 5] = [
            (|e| e.external_memory = false, "VK_KHR_external_memory"),
            (
                |e| e.external_memory_fd = false,
                "VK_KHR_external_memory_fd",
            ),
            (
                |e| e.external_memory_dma_buf = false,
                "VK_EXT_external_memory_dma_buf",
            ),
            (
                |e| e.image_drm_format_modifier = false,
                "VK_EXT_image_drm_format_modifier",
            ),
            (
                |e| e.queue_family_foreign = false,
                "VK_EXT_queue_family_foreign",
            ),
        ];

        for (clear, expected) in cases {
            let mut extensions = all_present();
            clear(&mut extensions);
            assert_eq!(extensions.missing(), vec![expected]);
        }
    }
}
