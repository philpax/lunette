//! Tracks when the compositor may answer each surface's `wl_surface.frame`
//! callback. A client uses that callback to schedule its next frame.
//!
//! [`FramePacer`] reads no clock: callers supply elapsed time. The methods on
//! [`Application`] deliver the callbacks and register the timer on the
//! compositor thread. They keep withheld callbacks pending until their surface
//! is due, so pacing does not discard a Wayland callback.
//!
//! The supplied time is monotonic elapsed compositor time. Production supplies
//! the compositor's elapsed clock, while tests supply a virtual clock they
//! advance explicitly.

use std::{collections::HashMap, time::Duration};

use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use tracing::{debug, warn};

use crate::{
    protocol::{FramePacing, FrameRate, SurfaceId},
    thread::LoopData,
    wayvr::comp::Application,
};

/// The minimum supported frame-callback rate, in hertz.
///
/// A lower requested rate is clamped to this floor so a throttled client still
/// receives callbacks and can process input.
pub(crate) const FLOOR_HERTZ: f64 = 1.0;

/// Tracks the frame-callback deadline for each surface.
///
/// Surfaces without pacing state are unthrottled.
#[derive(Debug, Default)]
pub(crate) struct FramePacer {
    surfaces: HashMap<SurfaceId, SurfacePace>,
}

impl FramePacer {
    /// Sets a surface's pacing mode without changing its last-send time.
    pub(crate) fn set(&mut self, surface: SurfaceId, pacing: FramePacing) {
        self.surfaces.entry(surface).or_default().pacing = pacing;
    }

    /// Returns whether a pending surface callback is due at `now`.
    #[must_use]
    pub(crate) fn is_due(&self, surface: SurfaceId, now: Duration) -> bool {
        self.due_at(surface, now) <= now
    }

    /// Records an actual callback delivery at `now`.
    ///
    /// The deadline advances only after a pending callback is delivered.
    pub(crate) fn record_sent(&mut self, surface: SurfaceId, now: Duration) {
        if let Some(pace) = self.surfaces.get_mut(&surface) {
            pace.last_sent = Some(now);
        }
    }

    /// Returns the earliest deadline among `withheld` surfaces.
    ///
    /// Returns `None` when `withheld` is empty.
    #[must_use]
    pub(crate) fn next_due(
        &self,
        withheld: impl IntoIterator<Item = SurfaceId>,
        now: Duration,
    ) -> Option<Duration> {
        withheld
            .into_iter()
            .map(|surface| self.due_at(surface, now))
            .min()
    }

    /// Removes pacing state when the surface is destroyed.
    pub(crate) fn forget(&mut self, surface: SurfaceId) {
        self.surfaces.remove(&surface);
    }

    /// Returns the next callback deadline for a surface.
    fn due_at(&self, surface: SurfaceId, now: Duration) -> Duration {
        self.surfaces
            .get(&surface)
            .map_or(now, |pace| pace.due_at(now))
    }
}

/// Stores one surface's pacing mode and last callback-delivery time.
impl Application {
    /// Ignores pacing changes for unknown surfaces. Surface identifiers are never
    /// reused, so a stale request cannot apply to a different surface later.
    pub(crate) fn set_frame_pacing(&mut self, surface: SurfaceId, pacing: FramePacing) {
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
        if self.pending_frame_callbacks.is_empty() {
            self.disarm_pacing_wakeup();
            return;
        }

        let now = self.elapsed();
        let stamp = protocol_millis(now);

        // Use one clock reading for the batch so due checks and callback timestamps
        // refer to the same instant.
        let mut withheld = HashMap::new();
        for (surface, callbacks) in self.pending_frame_callbacks.drain() {
            if !self.pacing.is_due(surface, now) {
                withheld.insert(surface, callbacks);
                continue;
            }

            self.pacing.record_sent(surface, now);
            for callback in callbacks {
                callback.done(stamp);
            }
        }
        self.pending_frame_callbacks = withheld;

        self.arm_pacing_wakeup(now);
    }

    fn arm_pacing_wakeup(&mut self, now: Duration) {
        let Some(due) = self
            .pacing
            .next_due(self.pending_frame_callbacks.keys().copied(), now)
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
    pub(crate) fn forget_pacing(&mut self, surface: SurfaceId) {
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
    pub(crate) fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// Uses a virtual clock in tests, so pacing assertions do not depend on
    /// scheduler timing. Test code advances this clock explicitly.
    #[cfg(any(test, feature = "test-fakes"))]
    pub(crate) fn elapsed(&self) -> Duration {
        self.clock_offset
    }

    /// Advances the virtual clock used by pacing tests.
    #[cfg(any(test, feature = "test-fakes"))]
    pub(crate) fn advance_clock(&mut self, by: Duration) {
        self.clock_offset += by;
    }

    /// Returns elapsed compositor time as a wrapping Wayland millisecond timestamp.
    pub(crate) fn millis(&self) -> u32 {
        protocol_millis(self.elapsed())
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct SurfacePace {
    pacing: FramePacing,
    /// No deadline applies until the first callback delivery.
    last_sent: Option<Duration>,
}

impl SurfacePace {
    fn due_at(self, now: Duration) -> Duration {
        match self.pacing {
            FramePacing::Unthrottled => now,
            FramePacing::Limited(rate) => match self.last_sent {
                None => now,
                Some(last) => last.saturating_add(interval(rate)),
            },
        }
    }
}

/// Converts a rate to an interval after applying the minimum rate.
fn interval(rate: FrameRate) -> Duration {
    // Clamp before taking the reciprocal so a very small positive rate cannot
    // overflow `Duration::from_secs_f64`.
    Duration::from_secs_f64(1.0 / rate.get().max(FLOOR_HERTZ))
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

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use super::*;

    fn surface(id: u64) -> SurfaceId {
        SurfaceId::new(id).expect("a non-zero surface identifier")
    }

    fn rate(hertz: f64) -> FramePacing {
        FramePacing::Limited(FrameRate::new(hertz).expect("a positive finite rate"))
    }

    fn secs(seconds: f64) -> Duration {
        Duration::from_secs_f64(seconds)
    }

    #[test]
    fn a_surface_nobody_paced_is_always_due() {
        let pacer = FramePacer::default();
        assert!(pacer.is_due(surface(1), Duration::ZERO));
        assert!(pacer.is_due(surface(1), secs(1000.0)));
        assert_eq!(
            pacer.next_due([surface(1)], secs(5.0)),
            Some(secs(5.0)),
            "an unpaced surface is owed a callback now, not later"
        );
    }

    #[test]
    fn an_unthrottled_surface_is_always_due() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), FramePacing::Unthrottled);
        pacer.record_sent(surface(1), secs(10.0));

        assert!(pacer.is_due(surface(1), secs(10.0)));
    }

    #[test]
    fn a_surface_that_has_never_been_answered_is_due_at_once() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(10.0));

        assert!(
            pacer.is_due(surface(1), Duration::ZERO),
            "a client's first frame does not wait out an interval it was absent for"
        );
    }

    #[test]
    fn a_ten_hertz_surface_is_due_every_hundred_milliseconds() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(10.0));
        pacer.record_sent(surface(1), secs(1.0));

        assert!(!pacer.is_due(surface(1), secs(1.0) + Duration::from_millis(99)));
        assert!(pacer.is_due(surface(1), secs(1.0) + Duration::from_millis(100)));

        pacer.record_sent(surface(1), secs(1.0) + Duration::from_millis(100));
        assert!(!pacer.is_due(surface(1), secs(1.0) + Duration::from_millis(199)));
        assert!(pacer.is_due(surface(1), secs(1.0) + Duration::from_millis(200)));
    }

    #[test]
    fn an_exactly_met_budget_is_due() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(4.0));
        pacer.record_sent(surface(1), secs(2.0));

        assert!(
            pacer.is_due(surface(1), secs(2.25)),
            "the boundary is inclusive, so a tick landing exactly on it sends"
        );
    }

    #[test]
    fn a_rate_below_the_floor_is_paced_at_the_floor() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(0.001));
        pacer.record_sent(surface(1), Duration::ZERO);

        assert!(!pacer.is_due(surface(1), Duration::from_millis(999)));
        assert!(
            pacer.is_due(surface(1), secs(1.0)),
            "a client answered no callbacks stops answering input, so the floor is 1 Hz"
        );
    }

    #[test]
    fn the_smallest_representable_rate_does_not_overflow_the_interval() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(f64::MIN_POSITIVE));
        pacer.record_sent(surface(1), Duration::ZERO);

        assert!(pacer.is_due(surface(1), secs(1.0)));
    }

    #[test]
    fn a_surface_that_goes_out_of_view_and_comes_back_is_due_at_once() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(60.0));
        pacer.record_sent(surface(1), secs(1.0));

        pacer.set(surface(1), rate(1.0));
        assert!(!pacer.is_due(surface(1), secs(1.5)));

        pacer.set(surface(1), rate(60.0));
        assert!(pacer.is_due(surface(1), secs(1.5)));
    }

    #[test]
    fn lowering_the_rate_takes_effect_from_the_last_send() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(60.0));
        pacer.record_sent(surface(1), secs(1.0));
        pacer.set(surface(1), rate(2.0));

        assert!(!pacer.is_due(surface(1), secs(1.4)));
        assert!(pacer.is_due(surface(1), secs(1.5)));
    }

    #[test]
    fn next_due_is_the_earliest_of_the_withheld() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(1.0));
        pacer.set(surface(2), rate(10.0));
        pacer.record_sent(surface(1), secs(1.0));
        pacer.record_sent(surface(2), secs(1.0));

        assert_eq!(
            pacer.next_due([surface(1), surface(2)], secs(1.0)),
            Some(secs(1.1)),
            "a slow surface must not delay a fast one's wakeup"
        );
        assert_eq!(pacer.next_due([surface(1)], secs(1.0)), Some(secs(2.0)));
        assert_eq!(pacer.next_due([], secs(1.0)), None);
    }

    #[test]
    fn recording_a_send_for_an_unpaced_surface_keeps_it_unpaced() {
        let mut pacer = FramePacer::default();
        pacer.record_sent(surface(1), secs(1.0));

        assert!(
            pacer.is_due(surface(1), secs(1.0)),
            "an unthrottled surface gains no state by being answered"
        );
    }

    #[test]
    fn forgetting_a_surface_returns_it_to_unthrottled() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(1.0));
        pacer.record_sent(surface(1), secs(1.0));
        assert!(!pacer.is_due(surface(1), secs(1.5)));

        pacer.forget(surface(1));
        assert!(pacer.is_due(surface(1), secs(1.5)));
    }

    #[test]
    fn surfaces_are_paced_independently() {
        let mut pacer = FramePacer::default();
        pacer.set(surface(1), rate(1.0));
        pacer.set(surface(2), rate(100.0));
        pacer.record_sent(surface(1), Duration::ZERO);
        pacer.record_sent(surface(2), Duration::ZERO);

        assert!(!pacer.is_due(surface(1), Duration::from_millis(50)));
        assert!(pacer.is_due(surface(2), Duration::from_millis(50)));
    }
}
