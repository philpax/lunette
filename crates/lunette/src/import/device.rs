//! Linux-only: the Vulkan device LÖVR created, borrowed for buffer import.
//!
//! lunette never creates a device. LÖVR does that, and this module wraps the
//! handles it exposes so the import path can issue its own Vulkan calls against
//! them. Borrowed means borrowed: [`GraphicsDevice`] has no destructor, and
//! `vkDestroyDevice` and `vkDestroyInstance` are never called from here.
//!
//! # Why the extensions are verified rather than assumed
//!
//! `ash::Instance::load` and `ash::Device::load` cannot fail. A function
//! pointer the loader could not resolve becomes a stub that panics when it is
//! called (`ash-0.38.0/src/extensions_generated.rs`), so a missing
//! extension does not surface at construction — it surfaces as a panic in the
//! middle of a frame. The only defence is to ask what was enabled, which is
//! what the five booleans on LÖVR's `GraphicsFeatures` are for, and to refuse
//! construction with a message naming the extension that is absent.
//!
//! # Vulkan 1.1 is the ceiling as well as the floor
//!
//! LÖVR requests `apiVersion = VK_MAKE_VERSION(1, 1, 0)` (`gpu_vk.c`).
//! Everything this module calls is therefore either Vulkan 1.1 core —
//! `vkGetPhysicalDeviceProperties2`, `vkGetPhysicalDeviceFormatProperties2`,
//! `vkGetImageMemoryRequirements2`, `vkBindImageMemory2`, all without a `KHR`
//! suffix — or an extension entry point loaded explicitly. A 1.2 or 1.3 call
//! would compile, load, and panic.

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

/// The Vulkan device LÖVR owns, with the loaders buffer import needs.
///
/// Shared across threads: the compositor thread creates images through it, and
/// the frame thread destroys them and records barriers. Both are read-only uses
/// of the handle itself, and Vulkan permits concurrent use of a `VkDevice` from
/// several threads.
pub struct GraphicsDevice {
    /// Kept alive because the loader it opened is what every function pointer
    /// below was resolved from. Never called directly.
    _entry: ash::Entry,
    device: ash::Device,
    queue_family: u32,
    external_memory_fd: khr::external_memory_fd::Device,
    render_node: Option<RenderNode>,
    formats: Vec<Format>,
}

impl GraphicsDevice {
    /// Wraps the device LÖVR created.
    ///
    /// # Errors
    ///
    /// Reports the first thing that makes import impossible: the graphics
    /// module not being initialised, a Vulkan loader that could not be opened,
    /// a device below Vulkan 1.1, or any of the five extensions being absent.
    ///
    /// # Safety
    ///
    /// LÖVR's graphics module must stay initialised for as long as the returned
    /// device is held. Every handle inside it belongs to LÖVR, and
    /// `lovrGraphicsDestroy` invalidates all of them at once.
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

        // SAFETY: `Entry::load` opens the system Vulkan loader. LÖVR has one
        // open already, so this raises its reference count rather than
        // initialising a second copy.
        let entry = unsafe { ash::Entry::load() }.map_err(DeviceError::LoadVulkan)?;

        let handles = LovrHandles::query();
        // SAFETY: `load` builds a dispatch table from `vkGetInstanceProcAddr`
        // and the instance LÖVR created. It is not `unsafe` because it can
        // fail, but because the handle must be a live instance from the same
        // loader, which the check above establishes.
        let instance = unsafe { ash::Instance::load(entry.static_fn(), handles.instance) };

        // SAFETY: `physical_device` came from the instance just wrapped.
        let properties =
            unsafe { instance.get_physical_device_properties(handles.physical_device) };
        if properties.api_version < vk::API_VERSION_1_1 {
            return Err(DeviceError::ApiVersionTooLow {
                found: properties.api_version,
            });
        }

        // SAFETY: as above, for the device.
        let device = unsafe { ash::Device::load(instance.fp_v1_0(), handles.device) };
        // The only loader the import path needs. `VK_EXT_image_drm_format_modifier`
        // has to be enabled for `VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT` to be a
        // legal tiling, which is LÖVR's job, but its single entry point reads back
        // the modifier the driver chose — and the explicit create info means the
        // modifier is named rather than chosen. `VK_KHR_external_memory` and
        // `VK_EXT_external_memory_dma_buf` contribute structures and no entry
        // points at all.
        let external_memory_fd = khr::external_memory_fd::Device::new(&instance, &device);

        let render_node = query_render_node(&instance, handles.physical_device)?;
        let formats = query_formats(&instance, handles.physical_device);

        debug!(
            queue_family = handles.queue_family,
            formats = formats.len(),
            render_node = ?render_node,
            "borrowed LÖVR's vulkan device for buffer import"
        );

        Ok(Arc::new(Self {
            _entry: entry,
            device,
            queue_family: handles.queue_family,
            external_memory_fd,
            render_node,
            formats,
        }))
    }

    /// What to advertise over `zwp_linux_dmabuf_v1`.
    ///
    /// Feedback needs the render node as well as the formats, and without the
    /// node no feedback global can be built at all — so a device whose driver
    /// does not report one advertises nothing and clients fall back to
    /// `wl_shm`.
    #[must_use]
    pub fn dmabuf_support(&self) -> DmabufSupport {
        DmabufSupport {
            main_device: self.render_node,
            formats: self.formats.clone(),
        }
    }

    #[must_use]
    pub(crate) fn raw(&self) -> &ash::Device {
        &self.device
    }

    /// The family LÖVR submits on, and therefore the destination of an
    /// ownership acquire.
    #[must_use]
    pub fn queue_family(&self) -> u32 {
        self.queue_family
    }

    #[must_use]
    pub(crate) fn external_memory_fd(&self) -> &khr::external_memory_fd::Device {
        &self.external_memory_fd
    }
}

impl fmt::Debug for GraphicsDevice {
    /// Hand-written because neither `ash::Instance` nor `ash::Device` is
    /// `Debug`, and a dispatch table's contents would be noise anyway.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GraphicsDevice")
            .field("queue_family", &self.queue_family)
            .field("render_node", &self.render_node)
            .field("formats", &self.formats.len())
            .finish_non_exhaustive()
    }
}

/// The optional Vulkan extensions the import path depends on.
///
/// Named separately from LÖVR's `GraphicsFeatures` so the "which of these is
/// missing" decision is a pure function over five booleans, testable without a
/// device, rather than a read of a struct only a live graphics module produces.
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
        // Zeroed rather than uninitialised: `lovrGraphicsGetFeatures`
        // (`graphics.c`) assigns every field today, but the struct
        // grows upstream, and a zero byte is a valid `false` while an
        // uninitialised one is not a valid `bool` at all.
        let mut features = MaybeUninit::<GraphicsFeatures>::zeroed();
        // SAFETY: the pointer addresses a live, fully initialised allocation,
        // and the call fills it without retaining it. The caller has
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

    /// The extensions that are absent, named as Vulkan names them.
    ///
    /// All five are required. `VK_KHR_external_memory` and
    /// `VK_EXT_external_memory_dma_buf` contribute structures rather than entry
    /// points, so nothing loads them and nothing would panic without them —
    /// they would simply be ignored, and the import would fail validation in a
    /// way that is far harder to read than this list.
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
    /// Reads the four handles LÖVR created.
    ///
    /// `gpu_vk_get_queue` returns the queue and writes both indices, so the
    /// queue itself is discarded: lunette never submits, and holding a queue it
    /// must not use would invite one.
    fn query() -> Self {
        let mut queue_family = 0;
        let mut queue_index = 0;

        // SAFETY: each accessor reads a field of LÖVR's graphics state, which
        // the caller has established is initialised, and the two out-pointers
        // address live locals.
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
/// `VK_EXT_physical_device_drm` contributes a property structure and no entry
/// point, so it is enough for the physical device to support it — LÖVR does not
/// enable it, and does not have to. Chaining a structure from an unsupported
/// extension is not permitted, so support is checked first and the answer is
/// absent rather than wrong when it is missing.
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
    // SAFETY: a Vulkan 1.1 core call, with a structure the extension check
    // above establishes the driver understands.
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

/// The formats and modifiers the device will actually accept an import in.
///
/// Two filters, and both are needed. The modifier list on
/// `vkGetPhysicalDeviceFormatProperties2` says a modifier exists for the
/// format; it says nothing about whether an image can be created with it at the
/// tiling and usage lunette declares, which is what the per-candidate
/// `vkGetPhysicalDeviceImageFormatProperties2` answers.
///
/// A format the driver refuses entirely is dropped rather than reported: the
/// list is a negotiation offer, and offering something that cannot be imported
/// is worse than offering less.
fn query_formats(instance: &ash::Instance, physical_device: vk::PhysicalDevice) -> Vec<Format> {
    let mut advertised = Vec::new();

    for mapping in SUPPORTED {
        let reported = query_modifiers(instance, physical_device, mapping.vulkan);
        let usable: Vec<_> = formats::single_plane_modifiers(&reported)
            .into_iter()
            .filter(|modifier| {
                importable(
                    instance,
                    physical_device,
                    mapping.vulkan,
                    u64::from(*modifier),
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
/// The list structure is built by hand on the second call rather than through
/// `.drm_format_modifier_properties(&mut storage)`: that builder derives the
/// count from the slice, and on the first call — where the slice is necessarily
/// empty — it would report a capacity of zero and the driver would write
/// nothing.
fn query_modifiers(
    instance: &ash::Instance,
    physical_device: vk::PhysicalDevice,
    format: vk::Format,
) -> Vec<vk::DrmFormatModifierPropertiesEXT> {
    let mut list = vk::DrmFormatModifierPropertiesListEXT::default();
    let mut properties = vk::FormatProperties2::default().push_next(&mut list);
    // SAFETY: a Vulkan 1.1 core call. `VK_EXT_image_drm_format_modifier` is
    // established as enabled before the device is constructed, so the chained
    // structure is one the driver understands.
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
    // SAFETY: as above, and `storage` has room for the count the first call
    // reported.
    unsafe {
        instance.get_physical_device_format_properties2(physical_device, format, &mut properties)
    };

    storage.truncate(list.drm_format_modifier_count as usize);
    storage
}

/// Whether an image can be created for this format and modifier at the tiling,
/// usage, and external handle type the import path uses.
fn importable(
    instance: &ash::Instance,
    physical_device: vk::PhysicalDevice,
    format: vk::Format,
    modifier: u64,
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

    // SAFETY: a Vulkan 1.1 core call, with structures from extensions
    // established as enabled.
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
            .contains(vk::ExternalMemoryFeatureFlags::IMPORTABLE)
}

/// The usage every imported image is created with.
///
/// It must match what [`crate::texture`] later declares to `lovrTextureCreate`.
/// LÖVR never validates an imported image's usage — it builds a
/// `VkImageViewUsageCreateInfo` from the declaration alone (`gpu_vk.c`)
/// — so a mismatch surfaces as a failed `vkCreateImageView` inside LÖVR rather
/// than as anything this crate can report.
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
    fn a_complete_extension_set_reports_nothing_missing() {
        assert_eq!(all_present().missing(), Vec::<&str>::new());
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

    #[test]
    fn the_import_usage_matches_what_lovr_is_told() {
        // LÖVR builds an image view from the usage the caller declares, so
        // these two have to agree. The declaration lives in `crate::texture`,
        // and this is the assertion that keeps them from drifting apart.
        assert!(IMPORT_USAGE.contains(vk::ImageUsageFlags::SAMPLED));
        assert!(IMPORT_USAGE.contains(vk::ImageUsageFlags::TRANSFER_SRC));
        assert!(IMPORT_USAGE.contains(vk::ImageUsageFlags::TRANSFER_DST));
    }
}
