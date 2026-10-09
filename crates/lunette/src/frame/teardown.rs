//! Linux-only: how the session gives the graphics device back, in the one
//! order that is safe.
//!
//! Two callers run the same sequence. [`FrameDriver::shutdown`] runs it when
//! the process ends. [`FrameDriver::quiesce`] runs it when a restart is about
//! to destroy the `VkDevice` and build another. The callers differ in what
//! becomes of the images at the end. [`crate::restart`] states the reasoning,
//! and [`tear_down_device`] performs it.

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
    /// The images are not destroyed. LÖVR retires an imported texture's image
    /// view through its own morgue, which `gpu_destroy` empties, and
    /// `vkDestroyImage` on an image that still has a view is invalid. No
    /// further frame exists for deferring the destruction, so the images are
    /// left for the device teardown that follows immediately.
    pub fn shutdown(&mut self) {
        tear_down_device(self, Disposal::StopCompositor);
    }

    /// Prepares for the Lua state and the graphics device to be destroyed, and
    /// leaves the compositor running.
    ///
    /// This is the restart counterpart of [`FrameDriver::shutdown`]. Frames
    /// continue after this one: the next session borrows a new device, and
    /// [`FrameDriver::start_if_ready`] passes it to the compositor, which
    /// re-imports the buffers its clients still hold. The clients stay
    /// connected across the restart.
    ///
    /// Both callers run the same [`tear_down_device`]. Its order is
    /// [`crate::restart`]'s order, and the order constitutes the method's
    /// correctness. The callers differ in [`Disposal`], the last step.
    ///
    /// # Unacknowledged quiesce
    ///
    /// Stopping the compositor disconnects every client. A restart that loses
    /// its clients is recoverable by the user; a faulting driver ends the
    /// session. The alternative to stopping is destroying a device the
    /// compositor thread may be inside `vkCreateImage` on.
    ///
    /// The teardown still runs in full on this path. The next session
    /// inherits the consequences of it, so a layer or a claim left behind
    /// here is worse than one left behind at exit.
    pub fn quiesce(&mut self) {
        // The quiesce waits before anything below runs. Nothing below may run
        // while the compositor can still create an image against the device
        // that is about to be destroyed.
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
    /// [`ImageArena::abandon_all`] records why the images are forgotten, and
    /// `docs/dev/rendering.md` records what that costs.
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

        // The capture buffers are dropped; none are carried across. A mirrored
        // monitor produces a frame every tick, so the next session re-imports
        // against the new device on its own. Keeping the old buffers holds
        // descriptors open for content that is already stale.
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
/// and both [`FrameDriver::shutdown`] and [`FrameDriver::quiesce`] run it. The
/// short version of each step:
///
/// 1. A `Layer` is destroyed by `xrDestroySwapchain`, so the layers are torn
///    down while the XR session that owns their swapchains still exists.
/// 2. A claim is an identifier held by a Lua handle. The state that made them
///    is about to be destroyed, and a claim left behind still counts against
///    the next session's layer budget for a panel that no longer exists.
/// 3. The blit ledger caches swapchain images the layers own, so it cannot
///    outlive them.
/// 4. Releasing a texture retires LÖVR's view of the image into LÖVR's own
///    morgue, which `gpu_destroy` alone empties. It has to precede the images
///    being given up, because a view still references each one.
/// 5. What becomes of the images themselves. This is the single step that
///    differs between the two callers.
///
/// This is a free function over a trait. The order is the function's
/// contract, and a method's statement order is asserted nowhere: reordering
/// two lines of it compiles and passes. `tests.rs` implements
/// [`DeviceTeardown`] against a recorder, so a reordering fails.
pub(super) fn tear_down_device(target: &mut impl DeviceTeardown, disposal: Disposal) {
    // First, because the reason is in the XR runtime's own objects. It is not
    // in LÖVR's own objects. `xrDestroySession` frees the runtime's
    // client-side command buffers and timeline semaphore, and it does so with
    // no wait of its own, so a frame still in flight makes every step below
    // operate on objects the GPU is reading. Monado faults without reporting
    // the condition.
    target.drain_gpu();
    target.destroy_layers();
    target.forget_claims();
    target.forget_blits();
    target.release_textures();
    target.give_up_images(disposal);
}

/// The steps [`tear_down_device`] runs, as a seam.
///
/// Each step is documented at the call above.
pub(super) trait DeviceTeardown {
    fn drain_gpu(&mut self);
    fn destroy_layers(&mut self);
    fn forget_claims(&mut self);
    fn forget_blits(&mut self);
    fn release_textures(&mut self);
    fn give_up_images(&mut self, disposal: Disposal);
}

/// What becomes of the imported images once no texture holds one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Disposal {
    /// For a restart, the compositor keeps running and keeps its clients, so it
    /// must be left holding no handle from the device that is about to be
    /// destroyed. The images are forgotten, and [`FrameDriver::abandon_images`]
    /// gives the reason.
    Abandon,
    /// The compositor stops, and its clients are disconnected. This occurs for
    /// a session ending, or for a restart the compositor did not acknowledge.
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
        // A configuration may switch the graphics module off, and the teardown
        // still runs. `lovrGraphicsWait` submits before it waits, and that
        // submit aborts when there is no device to submit to.
        //
        // SAFETY: both are called on the thread that owns the graphics device,
        // between frames, with no pass open.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return;
        }

        // SAFETY: as above. `lovrGraphicsWait` submits whatever is pending and
        // waits on the device.
        if !unsafe { lovrGraphicsWait() } {
            // Running the teardown against a device that does not drain is
            // safer than skipping it. A restart that stops here leaves the
            // session unable to continue.
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
