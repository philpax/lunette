//! How often each surface is answered, and the clock that decides.
//!
//! The decision is [`crate::pacing::FramePacer`], which is arithmetic over a
//! rate and a timestamp; this is the shell around it — the callbacks a surface
//! has accumulated, the timer that wakes the loop when the earliest of them
//! comes due, and the monotonic clock both are measured against.
//!
//! Split out of `compositor.rs` because it is a self-contained concern with one
//! entry point per tick, not because of its size.

use std::{collections::HashMap, time::Duration};

use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use tracing::{debug, warn};

use crate::{
    protocol::{FramePacing, SurfaceId},
    state::CompositorState,
    thread::LoopData,
};

impl CompositorState {
    /// Sets how often a surface's frame callbacks are answered.
    ///
    /// A surface the compositor no longer knows is dropped rather than
    /// recorded: identifiers are never reused, so an entry made for one could
    /// never be matched again and would be carried for the rest of the session.
    /// Lua reaching a window a frame after it closed is ordinary, so this is
    /// not worth reporting.
    pub(super) fn set_frame_pacing(&mut self, surface: SurfaceId, pacing: FramePacing) {
        if !self.surfaces.knows(surface) {
            debug!(%surface, "frame pacing was set for a surface that has gone; ignoring it");
            return;
        }

        self.pacing.set(surface, pacing);
    }

    /// Answers the frame callbacks of every surface that is due one.
    ///
    /// Called once a tick. A client that is not answered stops drawing, and
    /// most clients stop pumping their event loop with it, so this is what
    /// keeps a window responsive as well as animated — which is why a
    /// throttled surface is paced to a floor rather than starved, and why a
    /// withheld one arms a timer to come back for it.
    ///
    /// Withholding loses nothing. smithay's `SurfaceAttributes::merge_into`
    /// extends the callback list rather than replacing it, so a surface that
    /// commits three times while withheld holds all three callbacks and all
    /// three are answered by the next send.
    pub(crate) fn send_frame_callbacks(&mut self) {
        if self.frame_callbacks.is_empty() {
            self.disarm_pacing_wakeup();
            return;
        }

        let now = self.elapsed();
        let stamp = protocol_millis(now);

        // Disjoint field borrows: the pacer is consulted and updated while the
        // callback map is being drained into, which is why `now` is taken
        // before the loop rather than read from `self` inside it.
        let mut withheld = HashMap::new();
        for (surface, callbacks) in self.frame_callbacks.drain() {
            if !self.pacing.is_due(surface, now) {
                withheld.insert(surface, callbacks);
                continue;
            }

            self.pacing.record_sent(surface, now);
            for callback in callbacks {
                callback.done(stamp);
            }
        }
        self.frame_callbacks = withheld;

        self.arm_pacing_wakeup(now);
    }

    /// Wakes the loop when the earliest withheld surface comes due.
    fn arm_pacing_wakeup(&mut self, now: Duration) {
        let Some(due) = self
            .pacing
            .next_due(self.frame_callbacks.keys().copied(), now)
        else {
            self.disarm_pacing_wakeup();
            return;
        };

        // An armed timer that already fires no later than this one would is
        // left alone; a nearer deadline replaces it, so a 60 Hz surface that
        // starts being withheld does not wait out a 1 Hz surface's interval.
        if self.pacing_wakeup.is_some_and(|(_, armed)| armed <= due) {
            return;
        }

        self.disarm_pacing_wakeup();

        // The timer only has to wake the loop: `send_frame_callbacks` runs
        // after every dispatch, so the delivery happens there and this fires
        // once and drops.
        let inserted = self.loop_handle.insert_source(
            Timer::from_duration(due.saturating_sub(now)),
            |_now, _metadata, data: &mut LoopData| {
                data.state.pacing_wakeup = None;
                TimeoutAction::Drop
            },
        );

        match inserted {
            Ok(token) => self.pacing_wakeup = Some((token, due)),
            Err(error) => warn!(
                error = %error.error,
                "could not arm the frame pacing timer; a throttled surface will \
                 wait for other traffic to wake the compositor"
            ),
        }
    }

    /// Drops the pacing of a surface that has gone, so a rate set for it does
    /// not outlive it.
    pub(super) fn forget_pacing(&mut self, surface: SurfaceId) {
        self.pacing.forget(surface);
    }

    fn disarm_pacing_wakeup(&mut self) {
        if let Some((token, _)) = self.pacing_wakeup.take() {
            self.loop_handle.remove(token);
        }
    }

    /// Since the compositor started, on the clock every timestamp is measured
    /// against.
    ///
    /// WayVR reads the wall clock and unwraps the conversion (`time.rs:4-9`).
    /// Wayland's timestamps must be monotonic and a wall clock is not, so this
    /// is monotonic by construction.
    #[cfg(not(any(test, feature = "test-fakes")))]
    fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// The same, on the virtual clock a test drives.
    ///
    /// Real time is deliberately absent. A test that reaches a pacing interval
    /// by advancing the clock is measuring one thing, and a test that reaches
    /// it by taking a hundred milliseconds to settle a round on a loaded
    /// machine is measuring another: with both summed, a surface came due
    /// because the runner was busy, and the case asserting it was not yet due
    /// failed.
    #[cfg(any(test, feature = "test-fakes"))]
    fn elapsed(&self) -> Duration {
        self.clock_offset
    }

    /// Moves the compositor's clock forward, so a test can reach a pacing
    /// interval without sleeping for one.
    #[cfg(any(test, feature = "test-fakes"))]
    pub(crate) fn advance_clock(&mut self, by: Duration) {
        self.clock_offset += by;
    }

    /// Milliseconds since the compositor started, which is what the protocol's
    /// timestamps are measured in.
    pub(super) fn millis(&self) -> u32 {
        protocol_millis(self.elapsed())
    }
}

/// An elapsed time as the protocol's millisecond timestamp.
///
/// Truncating to 32 bits is the protocol's own convention: `wl_callback.done`
/// and every input event carry a `uint` that wraps, and clients compare
/// timestamps as wrapping differences.
fn protocol_millis(elapsed: Duration) -> u32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the protocol's timestamps are 32-bit and wrap by design"
    )]
    {
        elapsed.as_millis() as u32
    }
}
