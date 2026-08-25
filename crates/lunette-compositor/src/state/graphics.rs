//! Giving up the graphics device and taking a new one, across a restart.
//!
//! `lunette.restart()` discards the Lua state, and discarding it destroys
//! LÖVR's graphics module and with it the `VkDevice` every imported image was
//! created against. The compositor holds a window onto that device, so it has
//! to be told to let go while the device is still alive, and told again once a
//! new one exists.
//!
//! Two commands and two acknowledgements, and nothing else about the compositor
//! changes. The display, the socket, every client connection, and every retained
//! `wl_buffer` survive the whole exchange. That is what makes the restart
//! invisible to clients: the compositor never speaks Vulkan to one, it imports
//! the descriptors a client hands it, and a descriptor outlives the device it
//! was imported into.
//!
//! # Why the buffers are retained rather than dropped
//!
//! A retained `wl_buffer` is a buffer the client has been told nothing about
//! since it committed, so its pixels are still there. Re-importing it against
//! the new device gives the surface its content back without the client having
//! drawn anything, which is the difference between a restart the user sees as a
//! hitch and one they see as every window going blank.
//!
//! Shared memory has no equivalent. Its pixels are copied out and the buffer
//! released within the import that read them, so there is nothing retained to
//! re-import; a shared-memory surface gets its content back on its next commit.

use tracing::{info, warn};

use crate::{
    protocol::Event,
    state::compositor::CompositorState,
    surface::{BufferImporter, NoGraphics},
};

impl CompositorState {
    /// Gives up every graphics object, so the device may be destroyed.
    ///
    /// Dropping the importer is the whole of it: it owns the import cache, the
    /// images that cache names, and the reference to the device. What survives
    /// is deliberate — the retained buffers, which
    /// [`CompositorState::adopt_graphics`] re-imports.
    ///
    /// The acknowledgement is reported after the importer has been dropped, not
    /// before. The main thread destroys the device the moment it sees the
    /// acknowledgement, so reporting first would put the drop and the
    /// destruction in a race.
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
    /// draws again, which is the correct outcome: the alternative is presenting
    /// content lunette can no longer read.
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
