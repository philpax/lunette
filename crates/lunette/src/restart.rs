//! Linux-only: the restart quiesce, and the recovery that follows it.
//!
//! A hard restart discards the Lua state and the Vulkan device. The clients
//! survive both.
//!
//! # Requesting one
//!
//! A configuration requests a hard restart with LÖVR's own
//! `lovr.event.restart()`. `lunette.restartIntoSafeMode` records a safe-mode
//! request on the session and then calls the same function, as
//! [`crate::safe_mode`] describes; nothing else wraps it. LÖVR reads the event
//! out of the queue once the frame's callbacks have returned and ends the boot
//! coroutine; [`crate::boot`] then runs the quiesce. No re-entry guard is
//! needed: a restart requested from `lovr.load`, from inside a reload, or
//! several times in one frame is one restart at the end of the frame.
//!
//! # What a restart destroys
//!
//! `lovr.event.restart` ends the boot coroutine. `crate::boot` answers by
//! calling `luax_close`, which runs LÖVR's finalizer chain. The chain contains
//! `lovrGraphicsDestroy`, ending in `gpu_destroy`'s `vkDeviceWaitIdle`,
//! `vkDestroyDevice`, and `vkDestroyInstance`, and `lovrHeadsetDestroy`, ending
//! in `xrDestroySession` and `xrDestroyInstance`. Every image lunette imported
//! and every allocation behind one was created against that device. The
//! compositor thread holds a reference to it.
//!
//! # The clients and their connections
//!
//! The compositor never speaks Vulkan to a client. It receives descriptors and
//! imports them. The Wayland socket, the connections, and the `wl_buffer`
//! objects are all plain Rust and plain file descriptors. None of them is
//! invalidated when the device is destroyed. `docs/development/architecture.md` records the rule
//! this rests on: Rust holds no long-lived reference into Lua, so nothing the
//! compositor owns is reachable from the state being discarded.
//!
//! # The ordering
//!
//! Getting this wrong is a use-after-free on the GPU, not a failed assertion.
//! The sequence is stated once, here, and [`crate::frame::FrameDriver::quiesce`]
//! performs it exactly.
//!
//! 1. Send the compositor a request to release the device, and wait for the
//!    acknowledgement. Until that acknowledgement arrives the compositor may be
//!    inside `vkCreateImage` for a client that committed a microsecond ago.
//!    This is the one place in the design where the frame thread waits on the
//!    compositor thread. [`quiesce`] records why it cannot deadlock.
//! 2. Destroy the composition layers while the XR session still exists.
//!    `lovrLayerDestroy` calls `xrDestroySwapchain` inline. A handle that
//!    `xrDestroySession` has already invalidated cannot be passed to it.
//! 3. Release every LÖVR texture. That moves the image views into LÖVR's own
//!    morgue, which `gpu_destroy` empties.
//! 4. Abandon the images without destroying them, and drop the device.
//!    [`ImageArena::abandon_all`] records the reasoning. The short version is
//!    that a view still names each image. Destroying an image a view names is a
//!    use-after-free the driver may act on. Leaving it is a `vkDestroyDevice`
//!    valid-usage violation the validation layers report and nothing else
//!    observes. `docs/development/native/rendering.md` records the trade.
//! 5. Close the Lua state. That is `crate::boot`'s to do, and it performs the
//!    destruction the four steps above prepared for.
//!
//! Then, in the next session, once LÖVR has built a new device: borrow it,
//! build a new importer against a new arena, and pass it to the compositor,
//! which re-imports every buffer its clients still hold.
//!
//! # The `luax_atexit` alternative
//!
//! The chain is a linked list with no ordering guarantee relative to
//! `lovrGraphicsDestroy`. `vendor/lovr/src/modules/graphics/graphics.c` carries
//! LÖVR's own comment calling the existing headset-versus-graphics ordering
//! "really hacky". Adding a third participant with a hard ordering requirement
//! to an ordering nobody is confident in breaks intermittently, on one driver,
//! six months later.
//!
//! [`ImageArena::abandon_all`]: crate::import::ImageArena::abandon_all

use std::{
    error::Error,
    fmt,
    time::{Duration, Instant},
};

use lunette_compositor::{
    protocol::{Command, Event},
    thread::{CompositorHandle, TrySendError, WaitError},
};
use tracing::debug;

/// How long the frame thread waits for the compositor to release the device.
///
/// Generous, because the alternative to waiting is worse than a stall: the
/// caller answers a timeout by stopping the compositor thread, which
/// disconnects every client. The compositor reaches the command between
/// two dispatches. The only thing that makes this slow is a client flooding it,
/// and a second of that is a large amount of flooding.
pub const QUIESCE_TIMEOUT: Duration = Duration::from_secs(1);

/// How long one wait for an event lasts before the send is retried.
///
/// The command channel can be full when the quiesce starts. The only way to
/// find room is to come back and try again. The slice is short enough that a
/// retry is prompt, and long enough that the loop does not spin.
const RETRY_SLICE: Duration = Duration::from_millis(20);

/// Sends the compositor a request to release the graphics device, and waits
/// until it has done so.
///
/// Returns once [`Event::GraphicsReleased`] has arrived, at which point the
/// compositor holds no image, no allocation, and no reference to the device,
/// and imports nothing until [`Command::AdoptGraphics`] gives it a new one.
///
/// # Why this cannot deadlock
///
/// `lunette-compositor`'s module documentation sets out the cycle the two
/// bounded channels could otherwise form: it needs both directions to wait.
/// This waits in the receiving direction only. The command goes by
/// [`TrySendError`]-returning `try_send` and is retried between waits, so a full
/// command channel is a retry, not a block. A compositor blocked filling the
/// event channel is released by this call, which drains it.
///
/// # What happens to the events drained on the way
///
/// They are discarded. Every one of them is addressed to a Lua state that is
/// about to be closed. The session that replaces it reads the snapshot, not the
/// event history: a window that closed during the quiesce is absent from the
/// snapshot the next session reads. An
/// [`Event::BufferImported`] discarded here names an image that is about to be
/// abandoned with the device, so discarding it keeps a texture from being built
/// over memory that is going away.
///
/// # Errors
///
/// If the compositor thread is gone, or does not acknowledge within `timeout`.
/// Either is a session that cannot restart safely, and the caller's answer is to
/// stop the compositor, not to destroy a device it may still be using.
pub fn quiesce(handle: &CompositorHandle, timeout: Duration) -> Result<Quiesced, QuiesceError> {
    let started = Instant::now();
    let deadline = started + timeout;
    let mut unsent = Some(Command::ReleaseGraphics);
    let mut discarded = 0usize;

    loop {
        if let Some(command) = unsent.take() {
            match handle.commands().try_send(command) {
                Ok(()) => {}
                Err(TrySendError::Full(command)) => unsent = Some(command),
                Err(TrySendError::Disconnected(_)) => return Err(QuiesceError::Disconnected),
            }
        }

        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(QuiesceError::TimedOut { after: timeout });
        }

        match handle.events().wait(remaining.min(RETRY_SLICE)) {
            Ok(Event::GraphicsReleased) => {
                return Ok(Quiesced {
                    took: started.elapsed(),
                    discarded,
                });
            }
            Ok(event) => {
                debug!(
                    ?event,
                    "discarding an event reported during the restart quiesce"
                );
                discarded += 1;
            }
            Err(WaitError::TimedOut) => {}
            Err(WaitError::Disconnected) => return Err(QuiesceError::Disconnected),
        }
    }
}

/// What the quiesce cost.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Quiesced {
    /// How long the frame thread waited.
    pub took: Duration,
    /// How many events were reported during the wait and discarded.
    pub discarded: usize,
}

/// Why the compositor could not be quiesced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuiesceError {
    /// The compositor thread has stopped. Nothing holds the device, so the
    /// restart is safe, but the session has no compositor to come back to.
    Disconnected,
    /// The compositor did not acknowledge in time. It may still be using the
    /// device, so the device must not be destroyed while it runs.
    TimedOut { after: Duration },
}

impl fmt::Display for QuiesceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "restart: ")?;
        match self {
            Self::Disconnected => write!(
                f,
                "the compositor thread is no longer running, so it cannot be quiesced"
            ),
            Self::TimedOut { after } => write!(
                f,
                "the compositor did not release the graphics device within {after:?}, so the \
                 device cannot be destroyed while it is running"
            ),
        }
    }
}

impl Error for QuiesceError {}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use lunette_compositor::{
        config::CompositorConfig,
        testing::{FakeInspector, FakeSpawner, ImportLog, recording_importer, silent_compositor},
        thread::{PanicPolicy, spawn_with},
    };
    use pretty_assertions::assert_eq;

    use super::*;

    /// A real compositor thread with a fake importer and no listening socket.
    ///
    /// The thread is the part under test: the handshake is between two threads
    /// and a harness that ran the compositor inline would not exercise it.
    fn compositor_thread() -> CompositorHandle {
        spawn_with(
            CompositorConfig::default(),
            None,
            recording_importer(ImportLog::default()),
            Box::new(FakeSpawner::default()),
            Box::new(FakeInspector::default()),
            PanicPolicy::Unwind,
        )
        .expect("the compositor thread starts")
    }

    /// The wait is what makes the ordering safe, so the acknowledgement has to
    /// be what ends it, and the timeout must not have to be long enough.
    #[test]
    fn a_quiesce_with_nothing_imported_is_acknowledged_before_the_bound() {
        let compositor = compositor_thread();

        let quiesced = quiesce(&compositor, QUIESCE_TIMEOUT).expect("the compositor acknowledges");

        assert_eq!(
            quiesced.discarded, 0,
            "an idle compositor reports nothing while it is being quiesced"
        );
        assert!(
            quiesced.took < QUIESCE_TIMEOUT,
            "the quiesce took {:?}, which is the whole bound, so it waited rather than being told",
            quiesced.took,
        );
        compositor.shutdown().expect("the thread stops cleanly");
    }

    /// A restart during a restart runs a second quiesce. The second one has
    /// to return, never hang: the compositor already holds no device, so
    /// releasing again is a no-op it still acknowledges.
    #[test]
    fn a_second_quiesce_is_acknowledged_too() {
        let compositor = compositor_thread();

        quiesce(&compositor, QUIESCE_TIMEOUT).expect("the first quiesce is acknowledged");
        quiesce(&compositor, QUIESCE_TIMEOUT).expect("the second quiesce is acknowledged");

        compositor.shutdown().expect("the thread stops cleanly");
    }

    /// A compositor thread that has stopped is reported, and the report lands
    /// before the whole bound passes.
    #[test]
    fn a_compositor_that_has_stopped_is_reported() {
        let compositor = compositor_thread();
        compositor
            .commands()
            .try_send(Command::Shutdown)
            .expect("the queue has room");

        // `Shutdown` is queued ahead of the release. When the loop reaches it
        // is the thread's business: a quiesce sent before it does is answered,
        // never refused. This waits for the condition, a thread that has stopped,
        // not for a fixed number of tries, which would be the same race.
        let deadline = Instant::now() + QUIESCE_TIMEOUT;
        let error = loop {
            match quiesce(&compositor, RETRY_SLICE) {
                Err(QuiesceError::Disconnected) => break QuiesceError::Disconnected,
                outcome => assert!(
                    Instant::now() < deadline,
                    "the compositor thread did not stop within {QUIESCE_TIMEOUT:?}; the last \
                     quiesce answered {outcome:?}"
                ),
            }
        };

        assert_eq!(error, QuiesceError::Disconnected);
        assert!(
            error.to_string().starts_with("restart: "),
            "an error's context prefix names the subsystem: {error}"
        );
    }

    /// A compositor that takes the command and never answers is reported when
    /// the bound passes, which is what the bound is for. This case arises
    /// when a flooding client keeps the compositor busy. The caller stops the
    /// thread, and a device the compositor may still be inside `vkCreateImage`
    /// on is not destroyed.
    #[test]
    fn a_compositor_that_never_acknowledges_is_reported_when_the_bound_passes() {
        let (compositor, silent) = silent_compositor();

        let started = Instant::now();
        let error = quiesce(&compositor, RETRY_SLICE)
            .expect_err("a compositor that answers nothing cannot be quiesced");

        assert_eq!(error, QuiesceError::TimedOut { after: RETRY_SLICE });
        assert!(
            started.elapsed() >= RETRY_SLICE,
            "the wait ended after {:?}, which is less than the bound it was given",
            started.elapsed(),
        );

        silent.stop();
        compositor.shutdown().expect("the thread stops cleanly");
    }
}
