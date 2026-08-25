//! Handing over the graphics device across a restart.
//!
//! `lunette.restart()` discards the Lua state, and discarding it destroys
//! LÖVR's graphics module together with the `VkDevice` every imported image
//! was created against. The compositor holds a window onto that device, so it
//! must be told to release it while the device is still alive, and told again
//! once a new one exists.
//!
//! The handover is two commands and two acknowledgements, and nothing else
//! about the compositor changes. The display, the socket, every client
//! connection, and every retained `wl_buffer` survive the whole exchange.
//!
//! The restart is invisible to clients because the compositor never speaks
//! Vulkan to them. It imports the descriptors a client hands it, and a
//! descriptor outlives the device it was imported into.
//!
//! Retained buffers survive because their pixels are still valid: the client
//! has heard nothing about them since it committed. Re-importing each against
//! the new device gives the surface its content back without the client having
//! drawn anything.
//!
//! Shared memory has no equivalent. Its pixels are copied out and the buffer
//! released within the import that read them, so there is nothing retained to
//! re-import. A shared-memory surface gets its content back on its next
//! commit.

use tracing::{info, warn};

use crate::{
    protocol::Event,
    state::compositor::CompositorState,
    surface::{BufferImporter, NoGraphics},
};

impl CompositorState {
    /// Gives up every graphics object, so the device may be destroyed.
    ///
    /// Dropping the importer releases the import cache, the images that cache
    /// names, and the reference to the device. The retained buffers survive
    /// deliberately, and [`CompositorState::adopt_graphics`] re-imports them.
    ///
    /// The acknowledgement is reported after the importer has been dropped, not
    /// before. The main thread destroys the device the moment it sees the
    /// acknowledgement, so reporting first would race the drop against the
    /// destruction.
    pub(super) fn release_graphics(&mut self) {
        let previous = std::mem::replace(
            &mut self.importer,
            Box::new(NoGraphics) as Box<dyn BufferImporter>,
        );
        drop(previous);

        info!(
            surfaces = self.buffers.entries().count(),
            "released the graphics device; the clients and their buffers are untouched"
        );
        self.report(Event::GraphicsReleased);
    }

    /// Takes a new importer and restores what the clients still hold.
    ///
    /// Every retained buffer is imported again through the path a commit takes,
    /// so the frame thread rebuilds its textures from the events it already
    /// knows how to handle rather than from a second mechanism.
    ///
    /// A buffer that cannot be imported against the new device is released to
    /// its client and counted. The surface then shows nothing until the client
    /// draws again, which is preferable to presenting content lunette can no
    /// longer read.
    pub(super) fn adopt_graphics(&mut self, importer: Box<dyn BufferImporter>) {
        self.importer = importer;

        // Collected first. The import borrows the whole state mutably, and it
        // both retains and forgets buffers as it goes, so iterating the map it
        // is mutating is not available.
        let retained: Vec<_> = self
            .buffers
            .entries()
            .map(|(surface, buffer)| (surface, buffer.clone()))
            .collect();

        let mut restored = 0;
        let mut failed = 0;
        for (surface, buffer) in retained {
            let Some(content) = self.contents.get(&surface).copied() else {
                // A buffer is retained only by an import that recorded the
                // content alongside it, so this cannot happen; forgetting it
                // releases the buffer rather than leaving one held that nothing
                // describes.
                warn!(%surface, "a retained buffer had no recorded content; releasing it");
                self.buffers.forget(surface);
                failed += 1;
                continue;
            };

            if self.import_dmabuf(surface, &buffer, content.transform, content.scale) {
                restored += 1;
            } else {
                // Releases the buffer as well as dropping it, so the client is
                // free to draw into it again.
                self.buffers.forget(surface);
                failed += 1;
            }
        }

        if failed == 0 {
            info!(
                restored,
                "adopted a new graphics device and restored every retained buffer"
            );
        } else {
            warn!(
                restored,
                failed,
                "adopted a new graphics device; the surfaces that could not be re-imported are \
                 blank until their clients draw again"
            );
        }
        self.report(Event::GraphicsAdopted { restored, failed });
    }
}
