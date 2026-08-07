//! Linux-only: giving the graphics device back, in the one order that is safe.
//!
//! Two callers, one sequence. [`FrameDriver::shutdown`] runs it when the process
//! is ending and [`FrameDriver::quiesce`] when a restart is about to destroy the
//! `VkDevice` and build another; they differ only in what becomes of the images
//! at the end. [`crate::restart`] states the reasoning, and
//! [`tear_down_device`] performs it.

use lunette_lovr::raw::{lovrGraphicsIsInitialized, lovrGraphicsWait};
use tracing::{error, info, warn};

use crate::{
    frame::{FrameDriver, GraphicsState},
    restart,
    texture::{MonitorTextures, TextureLedger},
};

impl FrameDriver {
    /// Stops the compositor and releases every GPU object the session held.
    ///
    /// Called before the Lua state closes, because closing it destroys LÖVR's
    /// graphics module and with it the device the compositor thread borrowed.
    ///
    /// The images themselves are deliberately not destroyed. LÖVR retires an
    /// imported texture's image *view* through its own morgue, which is emptied
    /// only by `gpu_destroy`, and `vkDestroyImage` on an image that still has a
    /// view is invalid. There are no further frames to defer into, so the
    /// images are left for the device teardown that follows immediately.
    pub fn shutdown(&mut self) {
        tear_down_device(self, Disposal::StopCompositor);
    }

    /// Prepares for the Lua state and the graphics device to be destroyed, and
    /// leaves the compositor running.
    ///
    /// The restart counterpart of [`FrameDriver::shutdown`]. What separates them
    /// is that there are further frames after this one: the next session borrows
    /// a new device and [`FrameDriver::start_if_ready`] hands it to the
    /// compositor, which re-imports the buffers its clients still hold. That is
    /// what `lunette-v1.AC5.5` means by clients staying connected.
    ///
    /// Both spend the same [`tear_down_device`], whose order is
    /// [`crate::restart`]'s and is the whole of this method's correctness.
    /// They differ only in [`Disposal`], the last step.
    ///
    /// # When the compositor does not answer
    ///
    /// It is stopped, and every client with it. That is a severe outcome for a
    /// restart, and it is the correct one: the alternative is destroying a
    /// device the compositor thread may be inside `vkCreateImage` on. A restart
    /// that loses the clients is recoverable by the user; a driver that faults is
    /// not.
    ///
    /// The teardown still runs in full on that path. It is the one the next
    /// session inherits the consequences of, so leaving a layer or a claim
    /// behind there is worse than leaving one behind at exit, not better.
    pub fn quiesce(&mut self) {
        // First, and waiting: nothing below may run while the compositor can
        // still create an image against the device that is about to go.
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
    ///
    /// [`ImageArena::abandon_all`] records why they are forgotten rather than
    /// destroyed, and `docs/decisions.md` records what that costs.
    ///
    /// [`ImageArena::abandon_all`]: crate::import::ImageArena::abandon_all
    fn abandon_images(&mut self) {
        let Some(compositor) = &mut self.compositor else {
            return;
        };
        let previous = std::mem::replace(&mut compositor.graphics, GraphicsState::Quiesced);
        let GraphicsState::Held(mut graphics) = previous else {
            return;
        };

        // The retained capture buffers are dropped rather than carried across.
        // A mirrored monitor produces a frame every tick, so the next one
        // re-imports against the new device on its own; keeping the old ones
        // would only hold descriptors open for content that is already stale.
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
/// [`crate::restart`] states the sequence and the reasoning; this performs it,
/// and both [`FrameDriver::shutdown`] and [`FrameDriver::quiesce`] spend it. The
/// short version of each step:
///
/// 1. A `Layer` is destroyed by `xrDestroySwapchain`, so the layers go while the
///    XR session that owns their swapchains still exists.
/// 2. A claim is an identifier held by a Lua handle. The state that made them is
///    about to go, and a claim left behind contends for the next session's layer
///    budget on behalf of a panel that no longer exists, forever.
/// 3. The blit ledger caches swapchain images the layers own, so it cannot
///    outlive them.
/// 4. Releasing a texture retires LÖVR's view of the image into LÖVR's own
///    morgue, which only `gpu_destroy` empties. It has to precede the images
///    being given up, because a view still names each one.
/// 5. What becomes of the images themselves, which is the only step the two
///    callers answer differently.
///
/// A free function over a trait rather than a method, because the order is the
/// deliverable and a method's statement order is asserted nowhere: reordering
/// two lines of it compiles and passes. `tests.rs` implements [`DeviceTeardown`]
/// against a recorder, so a reordering fails.
pub(super) fn tear_down_device(target: &mut impl DeviceTeardown, disposal: Disposal) {
    // First, and the reason is not LÖVR's own objects. `xrDestroySession` frees
    // the runtime's client-side command buffers and timeline semaphore, and it
    // does so with no wait of its own, so a frame still in flight makes every
    // step below operate on objects the GPU is reading. Monado faults rather
    // than reporting it.
    target.drain_gpu();
    target.destroy_layers();
    target.forget_claims();
    target.forget_blits();
    target.release_textures();
    target.give_up_images(disposal);
}

/// The steps [`tear_down_device`] runs, as a seam.
///
/// Each is documented at the call above rather than here, because what matters
/// about them is the order and the order is there.
pub(super) trait DeviceTeardown {
    fn drain_gpu(&mut self);
    fn destroy_layers(&mut self);
    fn forget_claims(&mut self);
    fn forget_blits(&mut self);
    fn release_textures(&mut self);
    fn give_up_images(&mut self, disposal: Disposal);
}

/// What becomes of the imported images once no texture names them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Disposal {
    /// A restart. The compositor keeps running and keeps its clients, so it must
    /// be left holding no handle from the device that is about to be destroyed;
    /// the images are forgotten rather than destroyed, for the reason
    /// [`FrameDriver::abandon_images`] gives.
    Abandon,
    /// The compositor stops and its clients are disconnected. A session ending,
    /// or a restart the compositor did not acknowledge.
    StopCompositor,
}

impl DeviceTeardown for FrameDriver {
    fn drain_gpu(&mut self) {
        // A configuration may switch the graphics module off, and the teardown
        // still runs. `lovrGraphicsWait` submits before it waits, which aborts
        // when there is no device to submit to.
        //
        // SAFETY: both are called on the thread that owns the graphics device,
        // between frames, with no pass open.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return;
        }

        // SAFETY: as above. `lovrGraphicsWait` submits whatever is pending and
        // waits on the device.
        if !unsafe { lovrGraphicsWait() } {
            // Reported and not fatal. The teardown below is more dangerous to
            // skip than to run against a device that would not drain, and a
            // restart that stops here leaves the session with no way forward.
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

    fn forget_blits(&mut self) {
        self.blitted.clear();
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
