//! Linux-only: supplies the two DMA buffers WayVR's screencopy backend captures into.
//!
//! A device lifetime guard keeps detached upstream workers from using a destroyed device.

use std::{
    os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd},
    sync::Arc,
};

use ash::vk;
use lunette_capture::{
    mirror::screencopy::{CaptureExporter, ExporterFactory, FramePlane, WlxFrame},
    stream::{
        CaptureFormat, CapturedFrame, DrmFormat, DrmFourcc, DrmModifier, FrameSize, FrameTransform,
    },
};
use tracing::warn;

use crate::import::{device::GraphicsDevice, formats::mapping_for};

/// Creates an exporter over `device` for each direct stream.
pub(crate) fn exporters(device: Arc<GraphicsDevice>, formats: Vec<DrmFormat>) -> ExporterFactory {
    Box::new(move || {
        Box::new(Exporter {
            device: Arc::clone(&device),
            formats: formats.clone(),
            images: Vec::new(),
            current: 0,
        })
    })
}

struct Exporter {
    device: Arc<GraphicsDevice>,
    formats: Vec<DrmFormat>,
    images: Vec<ExportedImage>,
    current: usize,
}

impl CaptureExporter for Exporter {
    fn next_frame(
        &mut self,
        width: u32,
        height: u32,
        fourcc: DrmFourcc,
    ) -> Option<(FramePlane, DrmModifier)> {
        let size = FrameSize::new(width, height)?;
        if !self
            .images
            .first()
            .is_some_and(|image| image.format.size == size && image.format.fourcc == fourcc)
        {
            self.images.clear();
            let modifier = self
                .formats
                .iter()
                .find(|format| {
                    format.code == fourcc
                        && self.device.export_formats().iter().any(|supported| {
                            supported.code == format.code && supported.modifier == format.modifier
                        })
                })?
                .modifier;
            for _ in 0..2 {
                match ExportedImage::create(Arc::clone(&self.device), size, fourcc, modifier) {
                    Ok(image) => self.images.push(image),
                    Err(error) => {
                        warn!(%error, "direct capture: DMA export unavailable; upstream uses shared memory");
                        self.images.clear();
                        return None;
                    }
                }
            }
        }
        self.current = 1 - self.current;
        let image = self.images.get(self.current)?;
        Some((
            FramePlane {
                fd: Some(image.fd.as_raw_fd()),
                offset: image.offset,
                stride: image.stride as i32,
            },
            image.format.modifier,
        ))
    }

    fn completed(&self, frame: &WlxFrame) -> Option<CapturedFrame> {
        let WlxFrame::Implicit(transform) = frame else {
            return None;
        };
        let image = self.images.get(self.current)?;
        let mut format = image.format;
        format.transform = FrameTransform::from_wlx(*transform);
        CapturedFrame::from_exported(format, image.fd.as_fd(), image.offset, image.stride)
            .inspect_err(
                |error| warn!(%error, "direct capture: exported frame cannot be delivered"),
            )
            .ok()
    }
}

struct ExportedImage {
    device: Arc<GraphicsDevice>,
    image: vk::Image,
    memory: vk::DeviceMemory,
    fd: OwnedFd,
    format: CaptureFormat,
    offset: u32,
    stride: u32,
}

impl ExportedImage {
    fn create(
        device: Arc<GraphicsDevice>,
        size: FrameSize,
        fourcc: DrmFourcc,
        modifier: DrmModifier,
    ) -> Result<Self, ExportError> {
        let live = device.capture_live.lock();
        if !*live {
            return Err(ExportError::Unavailable);
        }
        let mapping = mapping_for(fourcc).ok_or(ExportError::Unavailable)?;
        let modifiers = [u64::from(modifier)];
        let mut list =
            vk::ImageDrmFormatModifierListCreateInfoEXT::default().drm_format_modifiers(&modifiers);
        let mut external = vk::ExternalMemoryImageCreateInfo::default()
            .handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
        let info = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(mapping.vulkan)
            .extent(vk::Extent3D {
                width: size.width(),
                height: size.height(),
                depth: 1,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
            .usage(
                vk::ImageUsageFlags::TRANSFER_SRC
                    | vk::ImageUsageFlags::TRANSFER_DST
                    | vk::ImageUsageFlags::SAMPLED,
            )
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .initial_layout(vk::ImageLayout::UNDEFINED)
            .push_next(&mut list)
            .push_next(&mut external);
        // SAFETY: the guard keeps the borrowed device live; creation uses enabled extensions.
        let image =
            unsafe { device.raw().create_image(&info, None) }.map_err(ExportError::Vulkan)?;
        let (memory, fd, offset, stride) = allocate(&device, image)?;
        drop(live);
        Ok(Self {
            device,
            image,
            memory,
            fd,
            offset,
            stride,
            format: CaptureFormat {
                size,
                fourcc,
                modifier,
                transform: FrameTransform::Normal,
            },
        })
    }
}

/// Takes responsibility for the new image, including cleanup if allocation fails.
fn allocate(
    device: &GraphicsDevice,
    image: vk::Image,
) -> Result<(vk::DeviceMemory, OwnedFd, u32, u32), ExportError> {
    // SAFETY: the caller owns the image and holds the device lifetime guard.
    let requirements = unsafe { device.raw().get_image_memory_requirements(image) };
    let mut export = vk::ExportMemoryAllocateInfo::default()
        .handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
    let mut dedicated = vk::MemoryDedicatedAllocateInfo::default().image(image);
    let info = vk::MemoryAllocateInfo::default()
        .allocation_size(requirements.size)
        .memory_type_index(requirements.memory_type_bits.trailing_zeros())
        .push_next(&mut export)
        .push_next(&mut dedicated);
    let memory = if requirements.memory_type_bits == 0 {
        Err(ExportError::Unavailable)
    } else {
        // SAFETY: allocation describes the image's requirements and dedicated export memory.
        unsafe { device.raw().allocate_memory(&info, None) }.map_err(ExportError::Vulkan)
    };
    let memory = match memory {
        Ok(memory) => memory,
        Err(error) => {
            // SAFETY: this image has no allocation and has not escaped.
            unsafe { device.raw().destroy_image(image, None) };
            return Err(error);
        }
    };
    let result = (|| {
        // SAFETY: memory satisfies the image's requirements and has no other bindings.
        unsafe { device.raw().bind_image_memory(image, memory, 0) }.map_err(ExportError::Vulkan)?;
        let info = vk::MemoryGetFdInfoKHR::default()
            .memory(memory)
            .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
        // SAFETY: the memory was allocated with the requested export handle type.
        let fd = unsafe { device.external_memory_fd().get_memory_fd(&info) }
            .map_err(ExportError::Vulkan)?;
        // SAFETY: successful export transfers a new owned descriptor to the caller.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: single-plane DRM modifier images expose memory-plane-zero layout.
        let layout = unsafe {
            device.raw().get_image_subresource_layout(
                image,
                vk::ImageSubresource::default()
                    .aspect_mask(vk::ImageAspectFlags::MEMORY_PLANE_0_EXT),
            )
        };
        let offset = u32::try_from(layout.offset).map_err(|_| ExportError::Unavailable)?;
        let stride = u32::try_from(layout.row_pitch)
            .ok()
            .filter(|stride| *stride <= i32::MAX as u32)
            .ok_or(ExportError::Unavailable)?;
        Ok((memory, fd, offset, stride))
    })();
    if result.is_err() {
        // SAFETY: neither object escaped, and the image is destroyed before its bound memory.
        unsafe {
            device.raw().destroy_image(image, None);
            device.raw().free_memory(memory, None);
        }
    }
    result
}

impl Drop for ExportedImage {
    fn drop(&mut self) {
        let live = self.device.capture_live.lock();
        if *live {
            // SAFETY: capture uses exported descriptors, never this Vulkan image;
            // the main-thread importer owns its separate image and allocation.
            unsafe {
                self.device.raw().destroy_image(self.image, None);
                self.device.raw().free_memory(self.memory, None);
            }
        }
    }
}

#[derive(Debug)]
enum ExportError {
    Unavailable,
    Vulkan(vk::Result),
}

impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => {
                f.write_str("capture export: the image layout or device is unavailable")
            }
            Self::Vulkan(error) => write!(f, "capture export: {error}"),
        }
    }
}
impl std::error::Error for ExportError {}
