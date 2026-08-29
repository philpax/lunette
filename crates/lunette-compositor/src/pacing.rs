//! Tracks when the compositor may answer each surface's `wl_surface.frame`
//! callback. A client uses that callback to schedule its next frame.
//!
//! This state reads no clock: callers supply elapsed time, and the compositor
//! thread performs callback delivery and timer registration. The compositor
//! keeps withheld callbacks pending until their surface is due, so pacing does
//! not discard a Wayland callback.
//!
//! The supplied time is monotonic elapsed compositor time. Production supplies
//! the compositor's elapsed clock, while tests supply explicit durations.

use std::{collections::HashMap, time::Duration};

use crate::protocol::{FramePacing, FrameRate, SurfaceId};

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
