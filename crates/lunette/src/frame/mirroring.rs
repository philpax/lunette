//! Linux-only: the frame's half of mirroring the user's own screens.
//!
//! [`crate::mirrors`] owns the portal exchange and the capture streams; this is
//! what the frame loop does around them each frame — attaching newly enumerated
//! outputs, persisting the restore tokens a stream answers with, importing the
//! frames that arrived, and dropping what a stopped stream left behind.
//!
//! Split out of `mod.rs` as a self-contained concern.

use lunette_capture::{mirror::PipewireStreams, monitor::MonitorKey, tokens};
use lunette_compositor::protocol::ImportedBuffer;
use tracing::{debug, info, warn};

use crate::{
    frame::{Compositor, FrameDriver, capture_formats, stopped_monitors},
    import::device::GraphicsDevice,
    texture::LovrTexture,
};

impl FrameDriver {
    /// Reads what the host compositor has said about its outputs, and applies it.
    ///
    /// Both consumers are updated together and from the one roster: the mirror
    /// lifecycle, so a monitor that has gone loses its stream, and the pointer
    /// mapping, so the desktop's bounding box follows the monitor that moved.
    /// Splitting them would let the two disagree about what is attached, which
    /// is how a pointer ends up on a screen that is no longer there.
    pub(super) fn attach_outputs(&mut self) {
        let Some(host) = &mut self.host else {
            return;
        };
        let Some(roster) = host.outputs.poll() else {
            return;
        };

        host.pointer.attach(&roster);
        let change = host.mirrors.attach(roster);
        for monitor in change.removed {
            // A monitor that has gone produces no further frames, so a texture
            // left behind is a still picture that looks live.
            self.forget_monitor_texture(&monitor);
        }
    }

    /// Writes the portal's restore tokens when a grant has changed them.
    ///
    /// Best-effort, and reported rather than fatal: the cost of failing is one
    /// dialog on the next run, which is not worth ending a session over.
    pub(super) fn persist_tokens(&mut self) {
        let Some(host) = &self.host else {
            return;
        };
        let Some(file) = &host.tokens else {
            return;
        };
        let Some(store) = host.mirrors.take_changed_tokens() else {
            return;
        };

        match tokens::write(file, &store) {
            Ok(()) => info!(
                path = %file.path().display(),
                monitors = store.len(),
                "recorded the screencast restore tokens",
            ),
            Err(error) => warn!(
                %error,
                "the screencast restore tokens were not recorded, so the next run will prompt",
            ),
        }
    }

    /// Turns each mirror's newest frame into the texture Lua samples.
    ///
    /// The frames arrive as plain descriptors from PipeWire's own thread, and
    /// every Vulkan import in the process happens here, on the main thread,
    /// through the same dmabuf path a client's buffer takes.
    pub(super) fn import_capture_frames(&mut self) {
        let (Some(host), Some(graphics)) = (
            &self.host,
            self.compositor.as_mut().and_then(Compositor::graphics_mut),
        ) else {
            return;
        };

        for (monitor, frame) in host.mirrors.take_frames() {
            let size = frame.format().size;
            // Read before the import, because the importer needs it: the image
            // a monitor's texture wraps is the one entry its buffer retention
            // must not release, and releasing it would free the image out from
            // under a live view.
            let installed = self
                .session
                .with_monitor_textures(|textures| textures.image(&monitor));

            let image = match graphics.capture.import(&monitor, frame, installed) {
                Ok(image) => image,
                Err(error) => {
                    warn!(%monitor, %error, "a mirrored monitor's frame could not be imported");
                    continue;
                }
            };

            // The importer answers a recurring PipeWire buffer with the image it
            // already made, and PipeWire cycles a small fixed pool — so after
            // the first few frames this is the branch that runs, and wrapping
            // the image again would allocate a texture over memory a texture
            // already covers.
            if installed == Some(image.image) {
                continue;
            }

            // SAFETY: this is the frame thread and LÖVR's graphics module is
            // initialised, because the device the import ran against is the one
            // LÖVR created. The handle names an image the arena holds.
            let texture = match unsafe { LovrTexture::import(&image) } {
                Ok(texture) => texture,
                Err(error) => {
                    warn!(%monitor, %error, "a mirrored monitor's frame could not become a texture");
                    continue;
                }
            };

            debug!(
                %monitor,
                %size,
                retained = graphics.capture.held(),
                "a mirrored monitor produced a new texture",
            );
            let description = crate::texture::describe(&ImportedBuffer::Image(image));
            let displaced = self.session.with_monitor_textures(|textures| {
                textures.install(monitor.clone(), image.image, texture, description)
            });
            if let Some(displaced) = displaced {
                displaced.release_ref();
            }
        }
    }

    /// Releases the texture of every monitor whose mirror has stopped.
    ///
    /// `monitor:dismiss()` tears the stream down from Lua, and nothing after
    /// that refreshes what the texture holds. Leaving it would leave a panel
    /// showing whatever the screen last displayed, which is worse than showing
    /// nothing because it looks live.
    ///
    /// A paused mirror keeps its texture on purpose: pausing is for a panel that
    /// has left the user's view, and resuming it is meant to cost nothing.
    ///
    /// Driven from everything lunette holds for a monitor rather than from the
    /// texture ledger alone, for the reason [`stopped_monitors`] gives: a
    /// monitor can retain capture buffers while holding no texture at all.
    pub(super) fn drop_stopped_mirrors(&mut self) {
        let holding = self
            .session
            .with_monitor_textures(|textures| textures.monitors());
        let retaining = self
            .compositor
            .as_ref()
            .and_then(Compositor::graphics)
            .map(|graphics| graphics.capture.streams())
            .unwrap_or_default();

        let stopped = {
            let mirrors = self.session.mirrors();
            // `None` is a monitor that has been unplugged, which stops
            // producing for the same reason and is answered the same way.
            stopped_monitors(holding, retaining, |monitor| {
                mirrors.state(monitor).is_some_and(|state| state.mirrored)
            })
        };

        for monitor in &stopped {
            self.forget_monitor_texture(monitor);
        }
    }

    /// Drops everything held for a monitor that is no longer producing frames.
    ///
    /// The texture first and the retained capture buffers second, in that order.
    /// Releasing the texture is what puts LÖVR's view of the image into its own
    /// morgue; dropping the buffers is what lets the image behind it be retired
    /// and, two frames later, destroyed. The other order frees an image a live
    /// view still names.
    ///
    /// The buffers have to be dropped here and not left to the process exit:
    /// the retained `Dmabuf` is a strong reference, so nothing else ever makes
    /// the importer's cache entry collectable, and a dismissed screen would keep
    /// its image and its imported memory for the rest of the session.
    fn forget_monitor_texture(&mut self, monitor: &MonitorKey) {
        let released = self
            .session
            .with_monitor_textures(|textures| textures.forget(monitor));
        if let Some(texture) = released {
            texture.release_ref();
        }

        if let Some(graphics) = self.compositor.as_mut().and_then(Compositor::graphics_mut) {
            graphics.capture.forget_stream(monitor);
        }
    }

    /// Tells monitor capture which DRM formats the new device can import.
    ///
    /// Re-run for every device rather than once at startup: a capture stream
    /// negotiates against what the importer accepts, and that is a property of a
    /// particular device.
    pub(super) fn negotiate_capture_formats(&self, device: &GraphicsDevice) {
        let Some(host) = &self.host else {
            return;
        };
        let formats = capture_formats(device);
        info!(
            formats = formats.len(),
            "monitor capture can now negotiate a dmabuf"
        );
        host.mirrors
            .set_streams(Box::new(PipewireStreams::new(formats)));
    }
}
