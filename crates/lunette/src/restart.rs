//! Linux-only: the restart quiesce, and the recovery that follows it.
//!
//! `lunette.restart()` discards the Lua state *and* the Vulkan device, and the
//! clients survive both. This module is the protocol that makes that true.
//!
//! # What a restart actually destroys
//!
//! `lovr.event.restart` ends the boot coroutine, and `crate::boot` answers by
//! calling `luax_close`. That runs LÖVR's finalizer chain, which contains
//! `lovrGraphicsDestroy` — ending in `gpu_destroy`'s `vkDeviceWaitIdle`,
//! `vkDestroyDevice`, and `vkDestroyInstance` — and `lovrHeadsetDestroy`, ending
//! in `xrDestroySession` and `xrDestroyInstance`. Every image lunette imported
//! and every allocation behind one was created against that device, and the
//! compositor thread holds a reference to it.
//!
//! # Why the clients do not care
//!
//! The compositor never speaks Vulkan to a client. It receives descriptors and
//! imports them. The Wayland socket, the connections, and the `wl_buffer`
//! objects are all plain Rust and plain file descriptors, and none of them is
//! invalidated by a device going away. `docs/architecture.md` records the rule
//! this rests on: Rust holds no long-lived reference into Lua, so nothing the
//! compositor owns is reachable from the state being discarded.
//!
//! # The ordering, which is the deliverable
//!
//! Getting this wrong is a use-after-free on the GPU rather than a failed
//! assertion, so the sequence is stated once, here, and
//! [`crate::frame::FrameDriver::quiesce`] performs exactly it.
//!
//! 1. **Ask the compositor to release the device, and wait for it to say it
//!    has.** Until that acknowledgement arrives the compositor may be inside
//!    `vkCreateImage` for a client that committed a microsecond ago. This is the
//!    one place in the design where the frame thread waits on the compositor
//!    thread, and [`quiesce`] records why it cannot deadlock.
//! 2. **Destroy the composition layers, while the XR session still exists.**
//!    `lovrLayerDestroy` calls `xrDestroySwapchain` inline, and a handle
//!    `xrDestroySession` has already invalidated cannot be passed to it.
//! 3. **Release every LÖVR texture.** That retires the image *views* into
//!    LÖVR's own morgue, which `gpu_destroy` empties.
//! 4. **Abandon the images without destroying them**, and drop the device.
//!    [`ImageArena::abandon_all`] records the reasoning; the short version is
//!    that a view still names each one, and destroying an image a view names is
//!    a use-after-free the driver may act on, where leaving it is a
//!    `vkDestroyDevice` valid-usage violation the validation layers report and
//!    nothing else observes. `docs/rendering.md` records the trade.
//! 5. **Close the Lua state**, which is `crate::boot`'s to do, and is what
//!    performs the destruction the four steps above prepared for.
//!
//! Then, in the next session, once LÖVR has built a new device: borrow it,
//! build a new importer against a new arena, and hand it to the compositor,
//! which re-imports every buffer its clients still hold.
//!
//! # Why this is not a `luax_atexit` finalizer
//!
//! It would be the obvious place, and it would be wrong. The chain is a linked
//! list with no ordering guarantee relative to `lovrGraphicsDestroy`, and
//! `vendor/lovr/src/modules/graphics/graphics.c` carries LÖVR's own
//! comment calling the existing headset-versus-graphics ordering "really hacky".
//! Adding a third participant with a hard ordering requirement to an ordering
//! nobody is confident in is how this breaks intermittently, on one driver, six
//! months later.
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
use mlua::{Function, Lua, Table};
use tracing::{debug, info};

/// `lunette.restart()`: asks for a hard restart.
///
/// Nothing here performs one. The call pushes LÖVR's own restart event and
/// returns; `vendor/lovr/etc/boot.lua` reads it out of the queue once the
/// frame's callbacks have returned, ends the boot coroutine, and [`crate::boot`]
/// answers with the quiesce this module documents.
///
/// # Why there is no re-entry guard
///
/// [`crate::reload::reload`] refuses a reload asked for from inside one,
/// because it re-runs `main.lua` inline and a configuration that reloads as it
/// loads would recurse until the stack ran out. This recurses into nothing: the
/// event is read after the frame, so a restart asked for from `lovr.load`, from
/// inside a reload, or twice in the same frame is one restart at the end of the
/// frame rather than a nested call.
///
/// `lovr.event.restart` is reached through the globals at each call rather than
/// held, so the module keeps no Lua value between calls and a configuration that
/// replaced the event module is honoured rather than bypassed.
///
/// # Errors
///
/// If `lovr.event.restart` cannot be reached. That is a LÖVR built without the
/// event module, or a configuration that replaced `lovr.event` with something
/// that is not one, rather than anything about the restart itself.
pub(crate) fn restart_from_lua(lua: &Lua) -> mlua::Result<()> {
    let restart = lovr_event_restart(lua).map_err(|error| {
        mlua::Error::runtime(format!(
            "restart: lovr.event.restart could not be reached, so a restart cannot be asked for: \
             {error}"
        ))
    })?;

    restart.call::<()>(())?;
    info!("a restart was asked for; it is taken at the end of this frame");
    Ok(())
}

/// LÖVR's own `lovr.event.restart`, as `boot.lua` reaches it.
fn lovr_event_restart(lua: &Lua) -> mlua::Result<Function> {
    lua.globals()
        .get::<Table>("lovr")?
        .get::<Table>("event")?
        .get("restart")
}

/// How long the frame thread waits for the compositor to give up the device.
///
/// Generous, because the alternative to waiting is worse than a stall: the
/// caller's answer to a timeout is to stop the compositor thread outright,
/// which disconnects every client. The compositor reaches the command between
/// two dispatches, so the only thing that makes this slow is a client flooding
/// it, and a second of that is a great deal of flooding.
pub const QUIESCE_TIMEOUT: Duration = Duration::from_secs(1);

/// How long one wait for an event lasts before the send is retried.
///
/// The command channel can be full when the quiesce starts, and the only way to
/// find room is to come back and try again. A slice short enough that a retry is
/// prompt, long enough that the loop is not a spin.
const RETRY_SLICE: Duration = Duration::from_millis(20);

/// Asks the compositor to release the graphics device, and waits until it has.
///
/// Returns once [`Event::GraphicsReleased`] has arrived, at which point the
/// compositor holds no image, no allocation, and no reference to the device, and
/// will import nothing until [`Command::AdoptGraphics`] hands it a new one.
///
/// # Why this cannot deadlock
///
/// `lunette-compositor`'s module documentation sets out the cycle the two
/// bounded channels could otherwise form: it needs *both* directions to wait.
/// This waits in the receiving direction only. The command goes by
/// [`TrySendError`]-returning `try_send` and is retried between waits, so a full
/// command channel is a retry rather than a block; and a compositor blocked
/// filling the event channel is released by this very call, which is draining
/// it.
///
/// # What happens to the events drained on the way
///
/// They are discarded, and that is deliberate rather than convenient. Every one
/// of them is addressed to a Lua state that is about to be closed, and the
/// session that replaces it builds its picture of the world from the snapshot
/// rather than from the event history — a window that closed during the quiesce
/// is simply absent from the snapshot the next session reads. A
/// [`Event::BufferImported`] discarded here names an image that is about to be
/// abandoned with the device, so discarding it is what keeps a texture from
/// being built over memory that is going away.
///
/// # Errors
///
/// If the compositor thread is gone, or does not acknowledge within `timeout`.
/// Either is a session that cannot restart safely, and the caller's answer is to
/// stop the compositor rather than to destroy a device it may still be using.
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

/// The result of quiescing the compositor.
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
    /// The compositor thread is gone. Nothing holds the device, so the restart
    /// is safe, but the session has no compositor to come back to.
    Disconnected,
    /// The compositor did not acknowledge in time. It may still be using the
    /// device, so the device must not be destroyed under it.
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
        state::CompositorConfig,
        testing::{FakeInspector, FakeSpawner, ImportLog, recording_importer, silent_compositor},
        thread::{PanicPolicy, spawn_with},
    };
    use pretty_assertions::assert_eq;

    use super::*;

    /// A real compositor thread with a fake importer and no listening socket.
    ///
    /// The thread is the part under test: the handshake is between two threads
    /// and a harness that ran the compositor inline would answer a different
    /// question.
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

    #[test]
    fn a_quiesce_with_nothing_imported_is_acknowledged() {
        let compositor = compositor_thread();

        let quiesced = quiesce(&compositor, QUIESCE_TIMEOUT).expect("the compositor acknowledges");

        assert_eq!(
            quiesced.discarded, 0,
            "an idle compositor reports nothing while it is being quiesced"
        );
        compositor.shutdown().expect("the thread stops cleanly");
    }

    /// The wait is what makes the ordering safe, so the acknowledgement has to
    /// be the thing that ends it rather than the timeout being long enough.
    #[test]
    fn the_wait_ends_on_the_acknowledgement_and_not_on_the_bound() {
        let compositor = compositor_thread();

        let quiesced = quiesce(&compositor, QUIESCE_TIMEOUT).expect("the compositor acknowledges");

        assert!(
            quiesced.took < QUIESCE_TIMEOUT,
            "the quiesce took {:?}, which is the whole bound, so it waited rather than being told",
            quiesced.took,
        );
        compositor.shutdown().expect("the thread stops cleanly");
    }

    /// Quiescing twice is what a restart during a restart would do, and the
    /// second one has to answer rather than hang: the compositor already holds
    /// no device, so releasing again is a no-op it still acknowledges.
    #[test]
    fn a_second_quiesce_is_acknowledged_too() {
        let compositor = compositor_thread();

        quiesce(&compositor, QUIESCE_TIMEOUT).expect("the first quiesce is acknowledged");
        quiesce(&compositor, QUIESCE_TIMEOUT).expect("the second quiesce is acknowledged");

        compositor.shutdown().expect("the thread stops cleanly");
    }

    /// A compositor thread that has gone is reported rather than waited on for
    /// the whole bound.
    #[test]
    fn a_compositor_that_has_stopped_is_reported() {
        let compositor = compositor_thread();
        compositor
            .commands()
            .try_send(Command::Shutdown)
            .expect("the queue has room");

        // `Shutdown` is queued ahead of the release, but *when* the loop reaches
        // it is the thread's business: a quiesce sent before it does is answered
        // rather than refused. So this waits for the condition — a thread that
        // has gone — rather than for a fixed number of tries, which is the same
        // race under a different name.
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

    /// A compositor that takes the command and never answers is reported rather
    /// than waited on forever, which is what the bound is for. This is the path
    /// a restart takes when the compositor is wedged behind a flooding client,
    /// and the caller answers it by stopping the thread rather than destroying a
    /// device it may still be inside `vkCreateImage` on.
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
        assert!(
            error.to_string().starts_with("restart: "),
            "an error's context prefix names the subsystem: {error}"
        );

        silent.stop();
        compositor.shutdown().expect("the thread stops cleanly");
    }

    /// The command is delivered rather than refused, so the timeout is about the
    /// answer and not about the send. A quiesce that reported a timeout because
    /// it never managed to ask would be reporting the wrong thing.
    #[test]
    fn a_quiesce_that_times_out_still_delivered_its_command() {
        let (compositor, silent) = silent_compositor();

        let _ = quiesce(&compositor, RETRY_SLICE);

        assert!(
            matches!(
                compositor.commands().try_send(Command::ReleaseGraphics),
                Ok(())
            ),
            "the channel should still be live, so the earlier send was taken rather than refused"
        );

        silent.stop();
        compositor.shutdown().expect("the thread stops cleanly");
    }
}
