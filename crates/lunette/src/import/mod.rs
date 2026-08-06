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
//! [`dmabuf`] performs the import and owns the images it creates.
//!
//! # Threading
//!
//! [`Importer`] runs on the compositor thread. It shares two things with the
//! frame thread: the [`GraphicsDevice`], which both may use concurrently, and
//! the [`ImageArena`], which is where the images it creates are handed over to
//! be destroyed.

pub mod device;
pub mod dmabuf;
pub mod formats;

use std::sync::Arc;

use lunette_compositor::{
    protocol::ImportedImage,
    surface::{BufferImporter, ImportFailed, ShmLayout},
};
use smithay::backend::allocator::dmabuf::Dmabuf;

use crate::import::dmabuf::DmabufImporter;
pub use crate::import::{
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
    fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, ImportFailed> {
        self.dmabuf
            .import(dmabuf)
            .map_err(|error| ImportFailed::new(error.to_string()))
    }

    /// Refuses, until the shared-memory path lands alongside it.
    ///
    /// A refusal rather than a fallback to the dmabuf path: the two have nothing
    /// in common, and a client that committed shared memory would otherwise be
    /// told its buffer was imported when nothing was.
    fn import_shm(
        &mut self,
        _pixels: &[u8],
        _layout: ShmLayout,
    ) -> Result<ImportedImage, ImportFailed> {
        Err(ImportFailed::new(
            "shared-memory buffers are not imported yet",
        ))
    }
}
