//! Coordinates replacement of the graphics importer while the compositor thread remains alive.
//!
//! The frame thread owns the graphics-device lifetime. It sends
//! [`crate::protocol::Command::ReleaseGraphics`], waits for
//! [`crate::protocol::Event::GraphicsReleased`], destroys the old device, and later sends
//! [`crate::protocol::Command::AdoptGraphics`] with an importer for the replacement device.
//! The compositor retains its display, clients, and retained dmabuf `wl_buffer`s across that
//! exchange.
//!
//! A retained dmabuf buffer remains held while lunette samples its imported image. Re-importing
//! it against the replacement device restores content without another client commit. Shared
//! memory is the fallback: its pixels are copied into compositor-owned storage and its client
//! `wl_buffer` is released during the commit, so it has no buffer to re-import and recovers on a
//! later commit.
//!
//! [`crate::surface::BufferImporter`] runs on the compositor thread and never submits queue
//! work. The frame thread consumes [`crate::protocol::Event::BufferImported`] events and performs
//! uploads and other submissions. The importer trait is the graphics boundary used by device-free
//! tests.

use tracing::{info, warn};

use crate::{
    protocol::Event,
    state::compositor::CompositorState,
    surface::{BufferImporter, NoGraphics},
};

impl CompositorState {
    /// Drops the device-bound importer before reporting [`Event::GraphicsReleased`]. The frame
    /// thread destroys the device after receiving that event.
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

    /// Installs the replacement importer and re-imports each retained dmabuf. Successful
    /// re-imports report [`Event::BufferImported`] before [`Event::GraphicsAdopted`].
    ///
    /// A failed re-import removes the retained buffer, which releases it to the client. The
    /// surface has no new content until the client commits another buffer.
    pub(super) fn adopt_graphics(&mut self, importer: Box<dyn BufferImporter>) {
        self.importer = importer;

        let retained: Vec<_> = self
            .buffers
            .entries()
            .map(|(surface, buffer)| (surface, buffer.clone()))
            .collect();

        let mut restored = 0;
        let mut failed = 0;
        for (surface, buffer) in retained {
            let Some(content) = self.contents.get(&surface).copied() else {
                warn!(%surface, "a retained buffer had no recorded content; releasing it");
                self.buffers.forget(surface);
                failed += 1;
                continue;
            };

            if self.import_dmabuf(surface, &buffer, content.transform, content.scale) {
                restored += 1;
            } else {
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
