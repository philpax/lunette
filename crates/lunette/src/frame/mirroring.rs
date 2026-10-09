//! Linux: the frame's half of mirroring the user's own screens.
//!
//! [`crate::mirrors`] owns the portal exchange and the capture streams. The
//! frame loop does its work around them each frame: attaching newly enumerated
//! outputs, persisting the restore tokens a stream returns, importing the
//! frames that arrived, and dropping what remains after a stream stops.

use std::sync::Arc;

use lunette_capture::{
    mirror::screencopy::PreferredStreams,
    monitor::MonitorKey,
    stream::{CaptureFormat, CapturedFrame, DrmFourcc},
    tokens,
};
use lunette_compositor::{
    protocol::{ImportedBuffer, PixelSize},
    surface::{PixelBuffer, ShmFormat},
};
use tracing::{debug, info, warn};

use crate::{
    frame::{Compositor, FrameDriver, capture_formats, stopped_monitors},
    import::{CaptureImporter, device::GraphicsDevice, export::exporters},
    lua::Session,
    texture::{LovrTexture, describe},
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
    /// Frames arrive as owned descriptors or copied pixels from the capture
    /// worker. Vulkan import and LÖVR uploads run on this main thread, through
    /// the same paths a client's buffers take.
    pub(super) fn import_capture_frames(&mut self) {
        let (Some(host), Some(graphics)) = (
            &self.host,
            self.compositor.as_mut().and_then(Compositor::graphics_mut),
        ) else {
            return;
        };

        for (monitor, frame) in host.mirrors.take_frames() {
            let CaptureFormat {
                size, transform, ..
            } = frame.format();
            let frame = match frame {
                CapturedFrame::Pixels { format, pixels } => {
                    import_pixels(
                        &self.session,
                        &mut graphics.capture,
                        &monitor,
                        format,
                        pixels,
                    );
                    continue;
                }
                dmabuf @ CapturedFrame::Dmabuf { .. } => dmabuf,
            };
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
                self.session.with_monitor_textures(|textures| {
                    textures.refresh_frame(&monitor, transform);
                });
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
            let description = describe(&ImportedBuffer::Image(image));
            let displaced = self.session.with_monitor_textures(|textures| {
                textures.install(
                    monitor.clone(),
                    Some(image.image),
                    texture,
                    description,
                    transform,
                )
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
        let replaced = self
            .host
            .as_ref()
            .map(|host| host.mirrors.take_replaced_monitors())
            .unwrap_or_default();
        for monitor in &replaced {
            self.forget_monitor_texture(monitor);
        }
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
    pub(super) fn negotiate_capture_formats(&self, device: &Arc<GraphicsDevice>) {
        let Some(host) = &self.host else {
            return;
        };
        let formats = capture_formats(device);
        info!(
            formats = formats.len(),
            "monitor capture can now negotiate a dmabuf"
        );
        host.mirrors.set_streams(Box::new(PreferredStreams::new(
            host.capture_client,
            exporters(Arc::clone(device), formats.clone()),
            formats,
        )));
    }
}

/// Uploads a shared-memory frame, refilling the monitor's texture in place when
/// its description is unchanged.
fn import_pixels(
    session: &Session<LovrTexture>,
    capture: &mut CaptureImporter,
    monitor: &MonitorKey,
    format: CaptureFormat,
    pixels: Vec<u8>,
) {
    let shm_format = match format.fourcc {
        DrmFourcc::Argb8888 => ShmFormat::Argb8888,
        _ => ShmFormat::Xrgb8888,
    };
    let size = PixelSize::new(format.size.width(), format.size.height());
    let Some(pixels) = PixelBuffer::new(size, shm_format, pixels) else {
        warn!(%monitor, "capture upload: shared-memory pixels have an invalid length");
        return;
    };
    let description = describe(&ImportedBuffer::Pixels(pixels.clone()));
    let refilled = session.with_monitor_textures(|textures| {
        textures
            .texture(monitor)
            .zip(textures.describe(monitor))
            .is_some_and(|(texture, previous)| {
                // SAFETY: this is the frame thread and graphics is initialized.
                previous == description && unsafe { texture.refill(&pixels, previous) }
            })
    });
    if refilled {
        session.with_monitor_textures(|textures| {
            textures.refresh_frame(monitor, format.transform);
        });
        return;
    }
    // SAFETY: this is the frame thread and graphics is initialized.
    match unsafe { LovrTexture::upload(&pixels) } {
        Ok(texture) => {
            let displaced = session.with_monitor_textures(|textures| {
                textures.install(
                    monitor.clone(),
                    None,
                    texture,
                    description,
                    format.transform,
                )
            });
            if let Some(displaced) = displaced {
                displaced.release_ref();
            }
            capture.forget_stream(monitor);
        }
        Err(error) => {
            warn!(%monitor, %error, "capture upload: shared-memory texture unavailable");
        }
    }
}
