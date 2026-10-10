//! Linux-only: gives the graphics device back in the one safe order.
//!
//! Shutdown and restart run the same sequence and differ only in what becomes
//! of the images. [`crate::restart`] states the reasoning.

use lunette_capture::mirror::NoStreams;
use lunette_lovr::raw::{lovrGraphicsIsInitialized, lovrGraphicsWait};
use tracing::{error, info, warn};

use crate::{
    frame::{Compositor, FrameDriver, GraphicsState},
    restart,
    texture::{MonitorTextures, TextureLedger},
};

impl FrameDriver {
    /// Stops the compositor and releases every GPU object the session holds.
    ///
    /// Runs before the Lua state closes, because closing it destroys LÖVR's
    /// graphics module and with it the device the compositor thread borrowed.
    ///
    /// The images are left for the device teardown, because their views sit in
    /// LÖVR's morgue until `gpu_destroy` and destroying an image with a view is invalid.
    pub fn shutdown(&mut self) {
        tear_down_device(self, Disposal::StopCompositor);
    }

    /// Prepares for the Lua state and the graphics device to be destroyed, and
    /// leaves the compositor running.
    ///
    /// The compositor re-imports its clients' buffers against the next device,
    /// so clients stay connected across the restart.
    ///
    /// If the compositor does not acknowledge, it is stopped and its clients are
    /// disconnected, because destroying a device it may still use faults the driver.
    pub fn quiesce(&mut self) {
        // Nothing below may run while the compositor can still create an image
        // against the device.
        let acknowledged = self
            .compositor
            .as_ref()
            .map(|compositor| restart::quiesce(&compositor.handle, restart::QUIESCE_TIMEOUT));
        let disposal = match acknowledged {
            None => Disposal::Abandon,
            Some(Ok(quiesced)) => {
                info!(
                    took = ?quiesced.took,
                    discarded = quiesced.discarded,
                    "the compositor released the graphics device",
                );
                Disposal::Abandon
            }
            Some(Err(error)) => {
                error!(
                    "{error}; stopping the compositor rather than destroying a device it may \
                     still be using, so every client is disconnected by this restart"
                );
                Disposal::StopCompositor
            }
        };

        tear_down_device(self, disposal);
    }

    /// Forgets every imported image without destroying it, and leaves the
    /// compositor running with no device.
    fn abandon_images(&mut self) {
        let Some(compositor) = &mut self.compositor else {
            return;
        };
        let previous = std::mem::replace(&mut compositor.graphics, GraphicsState::Quiesced);
        let GraphicsState::Held(mut graphics) = previous else {
            return;
        };

        // A mirrored monitor produces a frame every tick, so the next session
        // re-imports on its own and old buffers are only stale.
        graphics.capture.forget_buffers();
        let abandoned = graphics.arena.abandon_all();
        drop(graphics);

        info!(
            images = abandoned,
            "abandoned the imported images; the device teardown frees them"
        );
    }
}

/// Gives up everything the graphics device owns, in the one order that is safe.
///
/// 1. Layers go while the XR session that owns their swapchains exists.
/// 2. Claims go, or they count against the next session's layer budget.
/// 3. Releasing textures must precede the images, because a view references each one.
/// 4. The images are given up according to [`Disposal`].
///
/// It is a free function over a trait so tests can record and assert the order.
pub(super) fn tear_down_device(target: &mut impl DeviceTeardown, disposal: Disposal) {
    // First, because `xrDestroySession` frees runtime command buffers without
    // waiting, and Monado faults silently on a frame still in flight.
    target.drain_gpu();
    target.destroy_layers();
    target.forget_claims();
    target.release_textures();
    target.give_up_images(disposal);
}

/// The steps [`tear_down_device`] runs, as a seam.
pub(super) trait DeviceTeardown {
    fn drain_gpu(&mut self);
    fn destroy_layers(&mut self);
    fn forget_claims(&mut self);
    fn release_textures(&mut self);
    fn give_up_images(&mut self, disposal: Disposal);
}

/// What becomes of the imported images once no texture holds one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Disposal {
    /// For a restart, the compositor keeps its clients, so it must hold no handle
    /// from the device about to be destroyed.
    Abandon,
    /// The compositor stops, at exit or after an unacknowledged quiesce.
    StopCompositor,
}

impl DeviceTeardown for FrameDriver {
    fn drain_gpu(&mut self) {
        if let Some(host) = &self.host {
            host.mirrors.set_streams(Box::new(NoStreams));
        }
        if let Some(graphics) = self.compositor.as_ref().and_then(Compositor::graphics) {
            // Upstream does not join detached request workers. Their exporters must
            // stop calling the borrowed device before LÖVR destroys it.
            *graphics.device.capture_live.lock() = false;
        }
        // The graphics module may be off, and `lovrGraphicsWait` aborts without a device.
        //
        // SAFETY: both are called on the thread that owns the graphics device,
        // between frames, with no pass open.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return;
        }

        // SAFETY: as above.
        if !unsafe { lovrGraphicsWait() } {
            // Continuing is safer than skipping the teardown, which would leave
            // the session unable to continue.
            warn!(
                "the graphics device did not drain before the restart; the teardown continues, \
                 and the xr runtime may fault on objects still in use"
            );
        }
    }

    fn destroy_layers(&mut self) {
        self.session.claims().shutdown();
    }

    fn forget_claims(&mut self) {
        self.layers.forget_claims();
    }

    fn release_textures(&mut self) {
        let released = self.session.with_textures(TextureLedger::take_all);
        for texture in released {
            texture.release_ref();
        }

        let released = self
            .session
            .with_monitor_textures(MonitorTextures::take_all);
        for texture in released {
            texture.release_ref();
        }
    }

    fn give_up_images(&mut self, disposal: Disposal) {
        match disposal {
            Disposal::Abandon => self.abandon_images(),
            Disposal::StopCompositor => self.stop_compositor(),
        }
    }
}
