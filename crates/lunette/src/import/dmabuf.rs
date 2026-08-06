//! Linux-only: turning a client's dmabuf into a `VkImage` on LÖVR's device.
//!
//! The compositor thread calls this. It creates images and allocates memory,
//! and it never submits: the queue belongs to the frame thread, and the frame
//! thread is also what destroys what is created here.
//!
//! # Ownership across the two threads
//!
//! An image outlives the import that created it. LÖVR wraps it in a `Texture`
//! whose view is retired through LÖVR's own deferred morgue, so `vkDestroyImage`
//! must not run in the same tick. [`ImageArena`] is where the two threads meet:
//! the compositor thread inserts and retires, the frame thread collects what was
//! retired and destroys it once enough ticks have passed. Nothing else may hold
//! a `vk::Image` from here.
//!
//! # What is deliberately not handled
//!
//! A disjoint dmabuf — planes backed by different buffer objects — is rejected
//! rather than imported. Handling one needs `VK_IMAGE_CREATE_DISJOINT_BIT`, an
//! allocation per plane, and `vkBindImageMemory2` with
//! `VkBindImagePlaneMemoryInfo`. Importing it as though it were contiguous
//! would read one plane's memory at another plane's offset, which produces a
//! picture rather than an error, and that is the worst of the outcomes
//! available.

use std::{
    collections::HashMap,
    fmt,
    fs::File,
    mem::ManuallyDrop,
    os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, IntoRawFd, OwnedFd, RawFd},
    sync::Arc,
};

use ash::vk::{self, Handle as _};
use lunette_compositor::protocol::{ImageHandle, ImportedImage, PixelSize};
use parking_lot::Mutex;
use smithay::backend::allocator::{
    Buffer as _, Fourcc,
    dmabuf::{Dmabuf, WeakDmabuf},
};
use tracing::{debug, warn};

use crate::import::{
    device::{GraphicsDevice, IMPORT_USAGE},
    formats::{self, FormatMapping},
};

/// Imports client dmabufs, once each.
///
/// The cache is keyed on the buffer's identity rather than its contents, so a
/// client cycling three buffers imports three images and then imports nothing
/// further. That is also what makes the discarding-transition question in
/// LÖVR's upload path a once-per-buffer concern rather than a per-frame one.
pub(crate) struct DmabufImporter {
    device: Arc<GraphicsDevice>,
    arena: ImageArena,
    cache: HashMap<WeakDmabuf, ImportedImage>,
}

impl DmabufImporter {
    pub(crate) fn new(device: Arc<GraphicsDevice>, arena: ImageArena) -> Self {
        Self {
            device,
            arena,
            cache: HashMap::new(),
        }
    }

    /// Imports a dmabuf, or returns the image a previous import produced.
    pub(crate) fn import(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, DmabufError> {
        self.evict_gone_buffers();

        if let Some(image) = self.cache.get(&dmabuf.weak()) {
            return Ok(*image);
        }

        let image = self.create(dmabuf)?;
        self.cache.insert(dmabuf.weak(), image);
        Ok(image)
    }

    /// Drops the entries whose buffers the client has destroyed.
    ///
    /// Retiring here rather than at destruction time is what keeps the cache
    /// from pinning a client's file descriptors: the key is weak, so the entry
    /// becomes collectable as soon as the compositor releases the buffer.
    ///
    /// Called from the import above and from [`BufferImporter::sweep`], because
    /// imports are not the only thing that makes an entry collectable and a
    /// compositor whose clients have all disconnected performs none.
    ///
    /// [`BufferImporter::sweep`]: lunette_compositor::surface::BufferImporter::sweep
    pub(crate) fn evict_gone_buffers(&mut self) {
        self.cache.retain(|buffer, image| {
            if buffer.is_gone() {
                self.arena.retire(image.image);
                false
            } else {
                true
            }
        });
    }

    fn create(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, DmabufError> {
        let fourcc = dmabuf.format().code;
        let mapping = formats::mapping_for(fourcc).ok_or(DmabufError::UnsupportedFormat(fourcc))?;
        let size = buffer_size(dmabuf)?;
        let planes = PlaneLayouts::gather(dmabuf)?;

        let image = self.create_image(dmabuf, mapping, size, &planes)?;
        // Named before the memory is imported, so a driver that somehow
        // returned a null handle is rejected while there is still nothing to
        // unwind but the image itself.
        let Some(handle) = ImageHandle::new(image.as_raw()) else {
            // SAFETY: the image was created above and nothing else has seen it.
            unsafe { self.device.raw().destroy_image(image, None) };
            return Err(DmabufError::NullImage);
        };

        let memory = match self.bind_memory(image, dmabuf) {
            Ok(memory) => memory,
            Err(error) => {
                // SAFETY: as above, and no memory is bound to it.
                unsafe { self.device.raw().destroy_image(image, None) };
                return Err(error);
            }
        };

        self.arena.insert(handle, ImageAllocation { image, memory });
        debug!(
            ?fourcc,
            %size,
            modifier = u64::from(dmabuf.format().modifier),
            "imported a client dmabuf"
        );

        Ok(ImportedImage {
            image: handle,
            size,
            format: fourcc,
            modifier: dmabuf.format().modifier,
        })
    }

    /// Creates the image with the client's exact layout.
    ///
    /// The explicit create info rather than the list variant: the client's
    /// modifier is known, and the list variant would have the driver choose one
    /// and then require reading back which it chose.
    fn create_image(
        &self,
        dmabuf: &Dmabuf,
        mapping: FormatMapping,
        size: PixelSize,
        planes: &PlaneLayouts,
    ) -> Result<vk::Image, DmabufError> {
        let mut external = vk::ExternalMemoryImageCreateInfo::default()
            .handle_types(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT);
        let view_formats = [mapping.vulkan];
        let mut format_list = vk::ImageFormatListCreateInfo::default().view_formats(&view_formats);
        let mut explicit = vk::ImageDrmFormatModifierExplicitCreateInfoEXT::default()
            .drm_format_modifier(u64::from(dmabuf.format().modifier))
            .plane_layouts(&planes.layouts);

        let info = vk::ImageCreateInfo::default()
            .image_type(vk::ImageType::TYPE_2D)
            .format(mapping.vulkan)
            .extent(vk::Extent3D {
                width: size.width,
                height: size.height,
                depth: 1,
            })
            .mip_levels(1)
            .array_layers(1)
            .samples(vk::SampleCountFlags::TYPE_1)
            .tiling(vk::ImageTiling::DRM_FORMAT_MODIFIER_EXT)
            .usage(IMPORT_USAGE)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            // The client wrote the buffer outside Vulkan, so there is no layout
            // to preserve; the acquire barrier the frame thread records is what
            // moves it into a layout LÖVR can read.
            .initial_layout(vk::ImageLayout::UNDEFINED)
            .push_next(&mut external)
            .push_next(&mut format_list)
            .push_next(&mut explicit);

        // SAFETY: every structure in the chain comes from an extension the
        // device was established to have enabled, and the slices borrowed into
        // the chain outlive the call.
        unsafe { self.device.raw().create_image(&info, None) }.map_err(DmabufError::CreateImage)
    }

    /// Allocates memory for the image from the client's descriptor and binds it.
    fn bind_memory(
        &self,
        image: vk::Image,
        dmabuf: &Dmabuf,
    ) -> Result<vk::DeviceMemory, DmabufError> {
        let requirements_info = vk::ImageMemoryRequirementsInfo2::default().image(image);
        let mut dedicated = vk::MemoryDedicatedRequirements::default();
        // Scoped so the chain releases its borrow of `dedicated`, which is what
        // the driver wrote the dedicated-allocation hint into.
        let requirements = {
            let mut chain = vk::MemoryRequirements2::default().push_next(&mut dedicated);
            // SAFETY: a Vulkan 1.1 core call against an image from this device.
            unsafe {
                self.device
                    .raw()
                    .get_image_memory_requirements2(&requirements_info, &mut chain);
            }
            chain.memory_requirements
        };

        let plane = dmabuf
            .handles()
            .next()
            .ok_or(DmabufError::NoPlanes)?
            .try_clone_to_owned()
            .map_err(DmabufError::DuplicateDescriptor)?;

        // Taken before the descriptor is handed over: after `vkAllocateMemory`
        // succeeds the descriptor is the driver's, and a borrow of one it owns
        // is not a borrow this side may take.
        let importable = self.memory_type_bits(plane.as_fd())?;
        let allowed = requirements.memory_type_bits & importable;
        if allowed == 0 {
            return Err(DmabufError::NoCommonMemoryType {
                image: requirements.memory_type_bits,
                descriptor: importable,
            });
        }
        // The lowest set bit. Vulkan orders memory types most-suitable first,
        // and every type in the intersection is a legal answer.
        let memory_type = allowed.trailing_zeros();

        debug!(
            prefers_dedicated = dedicated.prefers_dedicated_allocation == vk::TRUE,
            requires_dedicated = dedicated.requires_dedicated_allocation == vk::TRUE,
            memory_type,
            "allocating imported memory"
        );

        let mut dedicated_allocation = vk::MemoryDedicatedAllocateInfo::default().image(image);
        with_donated_fd(plane, |raw| {
            let mut import = vk::ImportMemoryFdInfoKHR::default()
                .handle_type(vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT)
                .fd(raw);
            let info = vk::MemoryAllocateInfo::default()
                .allocation_size(requirements.size)
                .memory_type_index(memory_type)
                .push_next(&mut dedicated_allocation)
                .push_next(&mut import);

            // SAFETY: the allocation size and type index come from this
            // image's own requirements, and `raw` is a live dma-buf descriptor
            // for the duration of the call.
            unsafe { self.device.raw().allocate_memory(&info, None) }
                .map_err(DmabufError::AllocateMemory)
        })
        .and_then(|memory| {
            let bind = vk::BindImageMemoryInfo::default()
                .image(image)
                .memory(memory)
                .memory_offset(0);
            // SAFETY: a Vulkan 1.1 core call binding this image to the memory
            // just allocated for it.
            match unsafe { self.device.raw().bind_image_memory2(&[bind]) } {
                Ok(()) => Ok(memory),
                Err(error) => {
                    // SAFETY: the bind failed, so nothing references the
                    // allocation.
                    unsafe { self.device.raw().free_memory(memory, None) };
                    Err(DmabufError::BindMemory(error))
                }
            }
        })
    }

    /// Which memory types the descriptor itself can be imported into.
    ///
    /// VUID-VkMemoryAllocateInfo-memoryTypeIndex-00648 requires the index come
    /// from here whenever the descriptor was created outside Vulkan, which a
    /// client dmabuf always was. Taking the image's requirements alone happens
    /// to work on Mesa and is not what the specification permits.
    ///
    /// A borrow rather than a raw descriptor, because this module's other
    /// descriptor-taking call donates: `vkGetMemoryFdPropertiesKHR` leaves
    /// ownership with the caller and the type is where that is said.
    fn memory_type_bits(&self, fd: BorrowedFd<'_>) -> Result<u32, DmabufError> {
        let mut properties = vk::MemoryFdPropertiesKHR::default();
        // SAFETY: the call reads the descriptor without taking ownership of it,
        // and `properties` addresses a live local.
        unsafe {
            self.device.external_memory_fd().get_memory_fd_properties(
                vk::ExternalMemoryHandleTypeFlags::DMA_BUF_EXT,
                fd.as_raw_fd(),
                &mut properties,
            )
        }
        .map_err(DmabufError::DescriptorProperties)?;

        Ok(properties.memory_type_bits)
    }
}

impl fmt::Debug for DmabufImporter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DmabufImporter")
            .field("cached", &self.cache.len())
            .finish_non_exhaustive()
    }
}

/// The images lunette created and has not yet destroyed.
///
/// Shared between the compositor thread, which creates and retires, and the
/// frame thread, which destroys. A `parking_lot::Mutex` because every span
/// under it is a map operation with no await and no reentry.
#[derive(Clone, Default)]
pub struct ImageArena(Arc<Mutex<ArenaInner>>);

impl ImageArena {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn insert(&self, handle: ImageHandle, allocation: ImageAllocation) {
        self.0.lock().live.insert(handle, allocation);
    }

    /// Marks an image as no longer referenced by the compositor.
    ///
    /// Retiring is not destroying. LÖVR may still hold a view onto the image,
    /// and destroying it in the same tick would free memory a recorded command
    /// buffer still names.
    fn retire(&self, handle: ImageHandle) {
        self.0.lock().retired.push(handle);
    }

    /// Takes the images retired since the last call, for the frame thread to
    /// schedule.
    #[must_use]
    pub fn take_retired(&self) -> Vec<ImageHandle> {
        std::mem::take(&mut self.0.lock().retired)
    }

    /// Destroys an image and frees its memory.
    ///
    /// The caller is responsible for the timing: not before LÖVR has retired
    /// the view onto it, which is at least one full tick after the texture
    /// wrapping it was destroyed.
    ///
    /// # Safety
    ///
    /// No submitted work may still reference the image.
    pub unsafe fn destroy(&self, handle: ImageHandle, device: &GraphicsDevice) {
        let Some(allocation) = self.0.lock().live.remove(&handle) else {
            warn!(?handle, "an image was scheduled for destruction twice");
            return;
        };

        // SAFETY: the caller guarantees no work references the image, and the
        // allocation was removed under the lock so no second call can follow.
        unsafe {
            device.raw().destroy_image(allocation.image, None);
            device.raw().free_memory(allocation.memory, None);
        }
    }

    /// How many images are still alive. Diagnostic: a number that only grows is
    /// how a leak in the retirement path shows up.
    #[must_use]
    pub fn live(&self) -> usize {
        self.0.lock().live.len()
    }
}

impl fmt::Debug for ImageArena {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let inner = self.0.lock();
        f.debug_struct("ImageArena")
            .field("live", &inner.live.len())
            .field("retired", &inner.retired.len())
            .finish()
    }
}

#[derive(Default)]
struct ArenaInner {
    live: HashMap<ImageHandle, ImageAllocation>,
    retired: Vec<ImageHandle>,
}

/// An image and the memory bound to it, which are freed together.
struct ImageAllocation {
    image: vk::Image,
    memory: vk::DeviceMemory,
}

/// The per-plane layout an explicit-modifier image is created with.
struct PlaneLayouts {
    layouts: Vec<vk::SubresourceLayout>,
}

impl PlaneLayouts {
    /// Reads a dmabuf's plane layout, rejecting a disjoint buffer.
    fn gather(dmabuf: &Dmabuf) -> Result<Self, DmabufError> {
        let identities = dmabuf
            .handles()
            .map(identify_buffer)
            .collect::<Result<Vec<_>, _>>()
            .map_err(DmabufError::IdentifyDescriptor)?;

        if identities.is_empty() {
            return Err(DmabufError::NoPlanes);
        }
        if is_disjoint(&identities) {
            return Err(DmabufError::Disjoint {
                planes: identities.len(),
            });
        }

        Ok(Self {
            layouts: plane_layouts(
                &dmabuf.offsets().collect::<Vec<_>>(),
                &dmabuf.strides().collect::<Vec<_>>(),
                identities.len(),
            )?,
        })
    }
}

/// Hands a descriptor to a Vulkan call that takes ownership on success only.
///
/// `VkImportMemoryFdInfoKHR` transfers the descriptor to the implementation
/// when the allocation succeeds (Vulkan-Docs `chapters/memory.adoc:2637`). The
/// specification does not state the failure case, and the transfer is
/// conditioned on success, so on failure the caller still owns it. Encoding
/// both halves here is what stops a call site closing a descriptor the driver
/// now owns, or leaking one it does not.
fn with_donated_fd<T, E>(
    descriptor: OwnedFd,
    donate: impl FnOnce(RawFd) -> Result<T, E>,
) -> Result<T, E> {
    let raw = descriptor.into_raw_fd();
    match donate(raw) {
        Ok(value) => Ok(value),
        Err(error) => {
            // SAFETY: the call failed, so ownership did not transfer, and `raw`
            // came from the `OwnedFd` this function consumed. Reconstructing it
            // is what closes it.
            drop(unsafe { OwnedFd::from_raw_fd(raw) });
            Err(error)
        }
    }
}

/// What identifies the buffer object behind a plane's descriptor.
///
/// Two descriptors for the same dma-buf share an inode on the anonymous
/// `dmabuf` filesystem, whether they arrived as one descriptor or as a `dup` of
/// it. Two separate buffer objects do not, which is what makes this the
/// distinction between a contiguous buffer and a disjoint one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct BufferIdentity {
    device: u64,
    inode: u64,
}

/// Reads a descriptor's identity without taking ownership of it.
fn identify_buffer(descriptor: BorrowedFd<'_>) -> std::io::Result<BufferIdentity> {
    use std::os::unix::fs::MetadataExt as _;

    // SAFETY: `File` is the only way to reach `fstat` from `std`, and it closes
    // on drop; `ManuallyDrop` is what keeps the borrowed descriptor open. The
    // descriptor is valid for the borrow's lifetime, which spans this call.
    let file = ManuallyDrop::new(unsafe { File::from_raw_fd(descriptor.as_raw_fd()) });
    let metadata = file.metadata()?;

    Ok(BufferIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

/// Whether the planes are backed by more than one buffer object.
fn is_disjoint(identities: &[BufferIdentity]) -> bool {
    identities
        .iter()
        .any(|identity| Some(identity) != identities.first())
}

/// Widens a dmabuf's per-plane offsets and strides into Vulkan's layout struct.
///
/// Only `offset` and `row_pitch` are read for an explicit-modifier image; the
/// remaining three fields must be zero, which is what `default` gives them.
/// smithay's offsets and strides are `u32` and Vulkan's are `VkDeviceSize`, so
/// each widens rather than being reinterpreted.
///
/// The three counts have to agree. `planes` is what the descriptors reported and
/// is what the image is created for, so producing fewer layouts than that would
/// describe a different image from the one the client sent — a picture rather
/// than an error, which is the outcome this module exists to refuse.
fn plane_layouts(
    offsets: &[u32],
    strides: &[u32],
    planes: usize,
) -> Result<Vec<vk::SubresourceLayout>, DmabufError> {
    if offsets.len() != planes || strides.len() != planes {
        return Err(DmabufError::InconsistentPlaneCounts {
            planes,
            offsets: offsets.len(),
            strides: strides.len(),
        });
    }

    Ok(offsets
        .iter()
        .zip(strides)
        .map(|(offset, stride)| vk::SubresourceLayout {
            offset: u64::from(*offset),
            row_pitch: u64::from(*stride),
            ..Default::default()
        })
        .collect())
}

/// A dmabuf's size, rejecting the dimensions Vulkan cannot represent.
fn buffer_size(dmabuf: &Dmabuf) -> Result<PixelSize, DmabufError> {
    let size = dmabuf.size();
    match (u32::try_from(size.w), u32::try_from(size.h)) {
        (Ok(width), Ok(height)) if width > 0 && height > 0 => Ok(PixelSize::new(width, height)),
        _ => Err(DmabufError::NonsensicalSize {
            width: size.w,
            height: size.h,
        }),
    }
}

/// Why a dmabuf could not be imported.
#[derive(Debug)]
pub(crate) enum DmabufError {
    UnsupportedFormat(Fourcc),
    NonsensicalSize {
        width: i32,
        height: i32,
    },
    NoPlanes,
    Disjoint {
        planes: usize,
    },
    InconsistentPlaneCounts {
        planes: usize,
        offsets: usize,
        strides: usize,
    },
    IdentifyDescriptor(std::io::Error),
    DuplicateDescriptor(std::io::Error),
    CreateImage(vk::Result),
    DescriptorProperties(vk::Result),
    NoCommonMemoryType {
        image: u32,
        descriptor: u32,
    },
    AllocateMemory(vk::Result),
    BindMemory(vk::Result),
    NullImage,
}

impl fmt::Display for DmabufError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "dmabuf: ")?;
        match self {
            Self::UnsupportedFormat(fourcc) => {
                write!(f, "{fourcc:?} is not a format lunette can import")
            }
            Self::NonsensicalSize { width, height } => {
                write!(f, "a buffer of {width}x{height} has no image to import")
            }
            Self::NoPlanes => write!(f, "the buffer carries no planes"),
            Self::Disjoint { planes } => write!(
                f,
                "the {planes} planes are backed by different buffer objects, and disjoint imports \
                 are out of scope for v1"
            ),
            Self::InconsistentPlaneCounts {
                planes,
                offsets,
                strides,
            } => write!(
                f,
                "the buffer reports {planes} planes but {offsets} offsets and {strides} strides, \
                 so its layout cannot be described"
            ),
            Self::IdentifyDescriptor(_) => {
                write!(f, "a plane's descriptor could not be identified")
            }
            Self::DuplicateDescriptor(_) => {
                write!(f, "a plane's descriptor could not be duplicated")
            }
            Self::CreateImage(_) => write!(f, "the image could not be created"),
            Self::DescriptorProperties(_) => write!(
                f,
                "the descriptor's importable memory types could not be read"
            ),
            Self::NoCommonMemoryType { image, descriptor } => write!(
                f,
                "no memory type suits both the image ({image:#x}) and the descriptor \
                 ({descriptor:#x})"
            ),
            Self::AllocateMemory(_) => write!(f, "the descriptor's memory could not be imported"),
            Self::BindMemory(_) => write!(f, "the memory could not be bound to the image"),
            Self::NullImage => write!(f, "the driver returned a null image handle"),
        }
    }
}

impl std::error::Error for DmabufError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::IdentifyDescriptor(cause) | Self::DuplicateDescriptor(cause) => Some(cause),
            Self::CreateImage(cause)
            | Self::DescriptorProperties(cause)
            | Self::AllocateMemory(cause)
            | Self::BindMemory(cause) => Some(cause),
            Self::UnsupportedFormat(_)
            | Self::NonsensicalSize { .. }
            | Self::NoPlanes
            | Self::Disjoint { .. }
            | Self::InconsistentPlaneCounts { .. }
            | Self::NoCommonMemoryType { .. }
            | Self::NullImage => None,
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::os::fd::AsFd;

    use pretty_assertions::assert_eq;
    use smithay::reexports::rustix;

    use super::*;

    /// A descriptor to hand around, and the other end of the pipe it came from.
    ///
    /// A pipe rather than a file, so no filesystem is touched, and both ends
    /// rather than one because the write end is what makes the read end's
    /// closure observable. Asking whether a descriptor *number* is still open
    /// answers a question about whichever thread claimed it next — the kernel
    /// hands out the lowest free number and the harness runs tests in parallel
    /// — so the question has to be about this pipe instead.
    fn pipe() -> (OwnedFd, OwnedFd) {
        let (read, write) = std::io::pipe().expect("a pipe can be created");
        (OwnedFd::from(read), OwnedFd::from(write))
    }

    /// A descriptor whose pipe nothing else holds.
    fn descriptor() -> OwnedFd {
        pipe().0
    }

    /// Whether the read end of the pipe `write` belongs to has been closed.
    ///
    /// A write into a pipe with no reader fails with `EPIPE`. Rust's runtime
    /// sets `SIGPIPE` to `SIG_IGN` at startup, so the error arrives rather than
    /// the signal.
    fn read_end_is_closed(write: BorrowedFd<'_>) -> bool {
        matches!(rustix::io::write(write, b"."), Err(rustix::io::Errno::PIPE))
    }

    fn identity(device: u64, inode: u64) -> BufferIdentity {
        BufferIdentity { device, inode }
    }

    #[test]
    fn a_donated_descriptor_stays_open_when_the_call_succeeds() {
        let (read, write) = pipe();
        let raw = read.as_fd().as_raw_fd();

        let outcome: Result<(), ()> = with_donated_fd(read, |donated| {
            assert_eq!(donated, raw);
            Ok(())
        });

        assert_eq!(outcome, Ok(()));
        assert!(
            !read_end_is_closed(write.as_fd()),
            "the driver owns the descriptor after a successful import, so closing it here would \
             close one it is using"
        );

        // SAFETY: the test, standing in for the driver, is the owner now.
        drop(unsafe { OwnedFd::from_raw_fd(raw) });
    }

    #[test]
    fn a_donated_descriptor_is_closed_when_the_call_fails() {
        let (read, write) = pipe();
        let raw = read.as_fd().as_raw_fd();

        let outcome: Result<(), &str> = with_donated_fd(read, |donated| {
            assert_eq!(donated, raw);
            Err("the allocation failed")
        });

        assert_eq!(outcome, Err("the allocation failed"));
        assert!(
            read_end_is_closed(write.as_fd()),
            "ownership did not transfer, so leaving it open would leak a descriptor per rejected \
             buffer"
        );
    }

    #[test]
    fn two_descriptors_for_the_same_buffer_share_an_identity() {
        let fd = descriptor();
        let duplicate = fd.try_clone().expect("a descriptor can be duplicated");

        assert_eq!(
            identify_buffer(fd.as_fd()).expect("a live descriptor can be identified"),
            identify_buffer(duplicate.as_fd()).expect("a live descriptor can be identified"),
            "a dup shares its inode, which is what makes a duplicated plane look contiguous"
        );
    }

    #[test]
    fn two_descriptors_for_different_buffers_do_not_share_an_identity() {
        let one = descriptor();
        let other = descriptor();

        assert_ne!(
            identify_buffer(one.as_fd()).expect("identifiable"),
            identify_buffer(other.as_fd()).expect("identifiable"),
        );
    }

    #[test]
    fn a_single_plane_is_never_disjoint() {
        assert!(!is_disjoint(&[identity(1, 2)]));
    }

    #[test]
    fn planes_sharing_one_buffer_are_not_disjoint() {
        assert!(!is_disjoint(&[
            identity(1, 2),
            identity(1, 2),
            identity(1, 2)
        ]));
    }

    #[test]
    fn a_plane_on_another_buffer_makes_the_set_disjoint() {
        assert!(is_disjoint(&[identity(1, 2), identity(1, 3)]));
        assert!(is_disjoint(&[identity(1, 2), identity(2, 2)]));
        assert!(
            is_disjoint(&[identity(1, 2), identity(1, 2), identity(9, 9)]),
            "one differing plane out of three is still disjoint"
        );
    }

    #[test]
    fn an_empty_plane_set_is_not_reported_as_disjoint() {
        // It is rejected as having no planes instead, which is the more
        // accurate error; this states that the two checks do not overlap.
        assert!(!is_disjoint(&[]));
    }

    #[test]
    fn plane_layouts_widen_the_offsets_and_strides_and_zero_the_rest() {
        let layouts = plane_layouts(&[0, 4096], &[7680, 3840], 2).expect("the counts agree");

        assert_eq!(layouts.len(), 2);
        assert_eq!(layouts[0].offset, 0);
        assert_eq!(layouts[0].row_pitch, 7680);
        assert_eq!(layouts[1].offset, 4096);
        assert_eq!(layouts[1].row_pitch, 3840);

        for layout in &layouts {
            assert_eq!(layout.size, 0, "size must be zero for an explicit layout");
            assert_eq!(layout.array_pitch, 0);
            assert_eq!(layout.depth_pitch, 0);
        }
    }

    #[test]
    fn the_widest_offset_and_stride_survive_the_widening() {
        let layouts = plane_layouts(&[u32::MAX], &[u32::MAX], 1).expect("the counts agree");
        assert_eq!(layouts[0].offset, u64::from(u32::MAX));
        assert_eq!(layouts[0].row_pitch, u64::from(u32::MAX));
    }

    #[test]
    fn a_layout_is_produced_for_every_plane_the_descriptors_reported() {
        let layouts = plane_layouts(&[0, 4096, 8192], &[10, 20, 30], 3).expect("the counts agree");
        assert_eq!(layouts.len(), 3);
    }

    #[test]
    fn a_report_of_fewer_strides_than_planes_is_refused_rather_than_truncated() {
        // Truncating here would create the image for one plane and hand the
        // driver a buffer of three, which reads a plane's memory at another
        // plane's offset.
        assert!(matches!(
            plane_layouts(&[0, 1, 2], &[10], 3),
            Err(DmabufError::InconsistentPlaneCounts {
                planes: 3,
                offsets: 3,
                strides: 1,
            })
        ));
    }

    #[test]
    fn a_report_of_more_offsets_than_planes_is_refused() {
        assert!(matches!(
            plane_layouts(&[0, 1], &[10, 20], 1),
            Err(DmabufError::InconsistentPlaneCounts {
                planes: 1,
                offsets: 2,
                strides: 2,
            })
        ));
    }

    #[test]
    fn no_planes_at_all_produces_no_layouts() {
        // Reachable only through `PlaneLayouts::gather`, which rejects the
        // empty case before it gets here; stated so the two checks stay
        // distinct.
        assert!(
            plane_layouts(&[], &[], 0)
                .expect("the counts agree")
                .is_empty()
        );
    }
}
