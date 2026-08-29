//! Linux: the frame's half of mirroring the user's own screens.
//!
//! [`crate::mirrors`] owns the portal exchange and the capture streams. The
//! frame loop does its work around them each frame: attaching newly enumerated
//! outputs, persisting the restore tokens a stream returns, importing the
//! frames that arrived, and dropping what remains after a stream stops.

use lunette_capture::{mirror::PipewireStreams, monitor::MonitorKey, tokens};
use lunette_compositor::protocol::ImportedBuffer;
use tracing::{debug, info, warn};

use crate::{
    frame::{Compositor, FrameDriver, capture_formats, stopped_monitors},
    import::device::GraphicsDevice,
    texture::LovrTexture,
};

impl FrameDriver {
    /// Reads the outputs the host compositor reported, and applies them.
    ///
    /// Both consumers update together from the one roster. The mirror lifecycle
    /// follows the roster, so a monitor that has gone loses its stream. The
    /// pointer mapping follows it, so the desktop's bounding box tracks the
    /// monitor that moved. Updating the two separately lets them disagree about
    /// what is attached, so a pointer can land on a screen that is no longer
    /// there.
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
    /// Best-effort: a failure is reported with a warning, costs one dialog on
    /// the next run, and does not end the session.
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
    /// The frames arrive as plain descriptors from PipeWire's own thread. Every
    /// Vulkan import in the process runs in this method, on the main thread,
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
            // Read this first, because the importer requires it. The
            // image a monitor's texture wraps is the entry its buffer
            // retention must not release; releasing it would free an image a
            // live view still names.
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

            // The importer returns the image it already made for a recurring
            // PipeWire buffer. PipeWire cycles a small fixed pool, so after the
            // first few frames this branch runs. Wrapping the image again would
            // allocate a texture over memory a texture already covers.
            if installed == Some(image.image) {
                continue;
            }

            // SAFETY: this runs on the frame thread, and LÖVR's graphics module
            // is initialised, because the import runs against the device LÖVR
            // created. The handle names an image the arena holds.
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
    /// that refreshes what the texture holds. Leaving it leaves a panel showing
    /// whatever the screen last displayed; the picture looks live though
    /// nothing updates it.
    ///
    /// A paused mirror keeps its texture: pausing is for a panel that has left
    /// the user's view, and resuming it is meant to cost nothing.
    ///
    /// Uses everything lunette holds for a monitor, not the texture ledger
    /// alone, for the reason [`stopped_monitors`] states: a monitor can retain
    /// capture buffers while holding no texture.
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
            // `mirrors.state` returns `None` for an unplugged monitor; such
            // a monitor never produces again and receives the same handling
            // as a dismissed mirror.
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
    /// The texture comes first, the retained capture buffers second. Releasing
    /// the texture puts LÖVR's view of the image into its own morgue; the
    /// buffers keep the image behind it alive, and dropping them lets the image
    /// be retired and, two frames later, destroyed. The other order frees an
    /// image a live view still names.
    ///
    /// The buffers must be dropped here, not left to the process exit. The
    /// retained `Dmabuf` is a strong reference, so nothing else makes the
    /// importer's cache entry collectable, and a dismissed screen would keep
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

    /// Sends monitor capture the DRM formats the new device can import.
    ///
    /// Runs again for every device, not once at startup. A capture stream
    /// negotiates against what the importer accepts, and that is a property of
    /// a particular device.
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
