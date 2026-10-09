//! Linux-only: turns a client's committed buffers into images the frame thread
//! can draw.
//!
//! The compositor's [`BufferImporter`] seam is implemented here because the
//! compositor crate must
//! not gain a graphics dependency.

pub mod capture;
pub mod device;
pub mod dmabuf;
pub(crate) mod export;
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

/// The compositor's access to the graphics device.
///
/// One per compositor thread. The `Box<dyn>` behind [`BufferImporter`] keeps
/// the compositor crate
/// free of `ash`.
#[derive(Debug)]
pub struct Importer {
    dmabuf: DmabufImporter,
}

impl Importer {
    /// Builds an importer against a device and the arena that retires its
    /// images.
    ///
    /// The arena is a parameter because the frame thread needs a handle to it
    /// too, and this constructor runs inside the compositor thread's closure.
    #[must_use]
    pub fn new(device: Arc<GraphicsDevice>, arena: ImageArena) -> Self {
        Self {
            dmabuf: DmabufImporter::new(device, arena),
        }
    }
}

impl BufferImporter for Importer {
    /// Always true, because a restart replaces the importer with the compositor
    /// crate's
    /// `NoGraphics` importer.
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

    /// A shared-memory buffer is released in the import that read it, so only
    /// the dmabuf cache has
    /// entries to evict.
    fn sweep(&mut self) {
        self.dmabuf.evict_gone_buffers();
    }
}
