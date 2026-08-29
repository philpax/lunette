//! Delivers surface frame callbacks according to [`crate::pacing::FramePacer`].

use std::{collections::HashMap, time::Duration};

use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use tracing::{debug, warn};

use crate::{
    protocol::{FramePacing, SurfaceId},
    state::CompositorState,
    thread::LoopData,
};

impl CompositorState {
    /// Ignores pacing changes for unknown surfaces. Surface identifiers are never
    /// reused, so a stale request cannot apply to a different surface later.
    pub(super) fn set_frame_pacing(&mut self, surface: SurfaceId, pacing: FramePacing) {
        if !self.surfaces.knows(surface) {
            debug!(%surface, "frame pacing was set for a surface that has gone; ignoring it");
            return;
        }

        self.pacing.set(surface, pacing);
    }

    /// Sends callbacks for due surfaces. A client that does not receive a
    /// callback can stop drawing and processing its event loop. Throttled
    /// surfaces receive callbacks at the configured floor, and withheld
    /// surfaces arm a timer for the earliest deadline.
    ///
    /// `SurfaceAttributes::merge_into` extends the callback list. It does not
    /// replace it, so withheld callbacks remain queued until the surface is due.
    pub(crate) fn send_frame_callbacks(&mut self) {
        if self.frame_callbacks.is_empty() {
            self.disarm_pacing_wakeup();
            return;
        }

        let now = self.elapsed();
        let stamp = protocol_millis(now);

        // Use one clock reading for the batch so due checks and callback timestamps
        // refer to the same instant.
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

    fn arm_pacing_wakeup(&mut self, now: Duration) {
        let Some(due) = self
            .pacing
            .next_due(self.frame_callbacks.keys().copied(), now)
        else {
            self.disarm_pacing_wakeup();
            return;
        };

        // Keep the armed timer when its deadline is no later than this one. Replace
        // it only when this surface is due sooner.
        if self.pacing_wakeup.is_some_and(|(_, armed)| armed <= due) {
            return;
        }

        self.disarm_pacing_wakeup();

        // The timer only wakes the loop; callbacks are delivered after dispatch in
        // `send_frame_callbacks`, and the one-shot source clears its state.
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

    /// Removes pacing state when a surface is destroyed, so its rate does not
    /// outlive the surface.
    pub(super) fn forget_pacing(&mut self, surface: SurfaceId) {
        self.pacing.forget(surface);
    }

    fn disarm_pacing_wakeup(&mut self) {
        if let Some((token, _)) = self.pacing_wakeup.take() {
            self.loop_handle.remove(token);
        }
    }

    /// Uses elapsed time from compositor start so Wayland timestamps stay monotonic
    /// when the wall clock changes.
    #[cfg(not(any(test, feature = "test-fakes")))]
    fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// Uses a virtual clock in tests, so pacing assertions do not depend on
    /// scheduler timing. Test code advances this clock explicitly.
    #[cfg(any(test, feature = "test-fakes"))]
    fn elapsed(&self) -> Duration {
        self.clock_offset
    }

    /// Advances the virtual clock used by pacing tests.
    #[cfg(any(test, feature = "test-fakes"))]
    pub(crate) fn advance_clock(&mut self, by: Duration) {
        self.clock_offset += by;
    }

    /// Returns elapsed compositor time as a wrapping Wayland millisecond timestamp.
    pub(super) fn millis(&self) -> u32 {
        protocol_millis(self.elapsed())
    }
}

/// Converts elapsed time to Wayland's wrapping millisecond timestamp.
///
/// Callback and input timestamps are 32-bit values, and clients compare them as
/// wrapping differences.
fn protocol_millis(elapsed: Duration) -> u32 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the protocol's timestamps are 32-bit and wrap by design"
    )]
    {
        elapsed.as_millis() as u32
    }
}
