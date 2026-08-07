//! Linux-only: turning what a client committed into something the frame thread
//! can draw.
//!
//! This is the implementation of `lunette-compositor`'s [`BufferImporter`]
//! seam, and it lives here rather than there for one reason: the compositor
//! crate must not gain a graphics dependency, because its tests have to run
//! with no device, no XR runtime, and no headset attached (`AC9.4`). Everything
//! Vulkan is on this side of that line.
//!
//! Three concerns, one per submodule. [`device`] borrows the device LÖVR
//! created and verifies it can do what is about to be asked of it. [`formats`]
//! relates a client's DRM fourcc to a `VkFormat` and a LÖVR `TextureFormat`.
//! [`dmabuf`] performs the import and owns the images it creates; [`shm`] does
//! the same job for shared memory, which stops at pixels because the upload is
//! a submission and submissions belong to the frame thread. [`capture`] is the
//! second consumer of [`dmabuf`]: a mirrored monitor's frame arrives from
//! PipeWire's thread as plain descriptors and is imported here, on the main
//! thread, rather than in the callback that produced it.
//!
//! # Threading
//!
//! [`Importer`] runs on the compositor thread. It shares two things with the
//! frame thread: the [`GraphicsDevice`], which both may use concurrently, and
//! the [`ImageArena`], which is where the images it creates are handed over to
//! be destroyed.
//!
//! [`CaptureImporter`] runs on the frame thread, against the same device and the
//! same arena. Two importers, one import path: an image created for a mirrored
//! monitor is retired and destroyed by exactly the machinery that destroys a
//! client's.

pub mod capture;
pub mod device;
pub mod dmabuf;
pub mod formats;
pub mod shm;

use std::sync::Arc;

use lunette_compositor::{
    protocol::ImportedImage,
    surface::{BufferImporter, ImportFailed, PixelBuffer, ShmLayout},
};
use smithay::backend::allocator::dmabuf::Dmabuf;

use crate::import::dmabuf::DmabufImporter;
pub use crate::import::{
    capture::{CaptureImportError, CaptureImporter},
    device::{DeviceError, GraphicsDevice},
    dmabuf::ImageArena,
};

/// The compositor's window onto the graphics device.
///
/// One per compositor thread, moved into it at construction. The `Box<dyn>` on
/// the far side is what keeps the compositor crate free of `ash`.
#[derive(Debug)]
pub struct Importer {
    dmabuf: DmabufImporter,
}

impl Importer {
    /// Builds an importer against a device and the arena its images live in.
    ///
    /// The arena is a parameter rather than something built here, because the
    /// frame thread needs a handle to it too and this constructor runs inside
    /// the compositor thread's closure.
    #[must_use]
    pub fn new(device: Arc<GraphicsDevice>, arena: ImageArena) -> Self {
        Self {
            dmabuf: DmabufImporter::new(device, arena),
        }
    }
}

impl BufferImporter for Importer {
    /// Always. An `Importer` exists only while the device it was built against
    /// does; a restart replaces it with the compositor crate's inert one rather
    /// than leaving this one holding a destroyed device.
    fn accepts_imports(&self) -> bool {
        true
    }

    fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, ImportFailed> {
        self.dmabuf
            .import(dmabuf)
            .map_err(|error| ImportFailed::new(error.to_string()))
    }

    fn import_shm(
        &mut self,
        pixels: &[u8],
        layout: ShmLayout,
    ) -> Result<PixelBuffer, ImportFailed> {
        shm::repack(pixels, layout).map_err(|error| ImportFailed::new(error.to_string()))
    }

    /// Only the dmabuf path holds anything: a shared-memory buffer is copied out
    /// and released within the import that read it.
    fn sweep(&mut self) {
        self.dmabuf.evict_gone_buffers();
    }
}
