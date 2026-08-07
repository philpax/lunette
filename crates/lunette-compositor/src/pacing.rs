//! When a surface's accumulated frame callbacks are answered.
//!
//! A Wayland client draws only after the compositor answers its
//! `wl_surface.frame` callback, so this is the whole of how often a client that
//! nobody is looking at costs anything. Lua decides the rate — visibility,
//! gaze, distance, focus, whether a game is running — and this decides when the
//! next answer is owed.
//!
//! Pure. Nothing here reads a clock or touches a `wl_callback`: every entry
//! point takes the current time as an argument and answers a question about it,
//! and [`crate::state`] does the sending. That is what makes the policy
//! testable without a client, a socket, or a sleep.
//!
//! # Why not `send_frames_surface_tree`
//!
//! smithay's own throttle (`src/desktop/wayland/utils.rs:217-266`) is not
//! usable for this. It sends when the surface is on the primary scan-out output
//! **or** when the frame is overdue (`:245-249`), so the scan-out branch
//! bypasses the throttle entirely — rate limiting with it means passing a
//! closure that deliberately names a non-matching output, to disable half the
//! function in order to reach the other half. And its `SurfaceFrameThrottling
//! State` (`:484-503`) is declared without `pub`, so it cannot be named, reset,
//! or inspected, and there is nowhere to hang a per-surface override.
//!
//! Withholding is safe because callbacks accumulate rather than replace:
//! smithay's `SurfaceAttributes::merge_into` extends the list
//! (`src/wayland/compositor/handlers.rs:146`), so a callback withheld across
//! several commits is still there to be answered and no `wl_callback` is ever
//! dropped without its `done`.

use std::{collections::HashMap, time::Duration};

use crate::protocol::{FramePacing, FrameRate, SurfaceId};

/// The slowest a surface is ever paced, in hertz.
///
/// `docs/rendering.md`: the floor is approximately 1 Hz, not zero. A client
/// answered no frame callbacks at all stops pumping its event loop, and stops
/// answering input with it, so it looks hung rather than idle. A rate below
/// this is paced at this instead, which is what keeps a throttled window
/// responsive to a click.
pub(crate) const FLOOR_HERTZ: f64 = 1.0;

/// How often each surface's frame callbacks are answered.
///
/// A surface with no entry is unthrottled, which is the state every surface
/// starts in: throttling is something Lua asks for, not something a client is
/// subjected to by default.
#[derive(Debug, Default)]
pub(crate) struct FramePacer {
    surfaces: HashMap<SurfaceId, SurfacePace>,
}

impl FramePacer {
    /// Sets how often a surface is answered.
    ///
    /// When it was last answered is kept, so a rate change is measured from the
    /// last real send rather than restarting the interval. Raising the rate
    /// therefore takes effect at once when the old interval has already
    /// elapsed, and at the new interval's boundary otherwise.
    pub(crate) fn set(&mut self, surface: SurfaceId, pacing: FramePacing) {
        self.surfaces.entry(surface).or_default().pacing = pacing;
    }

    /// Whether a surface holding callbacks should be answered at `now`.
    #[must_use]
    pub(crate) fn is_due(&self, surface: SurfaceId, now: Duration) -> bool {
        self.due_at(surface, now) <= now
    }

    /// Records that a surface was answered at `now`.
    ///
    /// Only a send that actually happened is recorded. A surface holding no
    /// callbacks is not "answered", so an idle client does not spend its budget
    /// on silence and then wait an extra interval for the frame it finally
    /// asks for.
    pub(crate) fn record_sent(&mut self, surface: SurfaceId, now: Duration) {
        if let Some(pace) = self.surfaces.get_mut(&surface) {
            pace.last_sent = Some(now);
        }
    }

    /// The earliest moment any of `withheld` becomes due.
    ///
    /// `None` when nothing is withheld. The caller wakes the event loop then,
    /// because a client waiting on a frame callback sends nothing, and a
    /// compositor that only wakes on client traffic would never wake to
    /// deliver it.
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

    /// Drops a surface that has gone.
    pub(crate) fn forget(&mut self, surface: SurfaceId) {
        self.surfaces.remove(&surface);
    }

    /// When a surface's callbacks are next owed, which is `now` for one that is
    /// unthrottled or has never been answered.
    fn due_at(&self, surface: SurfaceId, now: Duration) -> Duration {
        self.surfaces
            .get(&surface)
            .map_or(now, |pace| pace.due_at(now))
    }
}

/// One surface's rate and when it was last answered.
#[derive(Clone, Copy, Debug, Default)]
struct SurfacePace {
    pacing: FramePacing,
    /// `None` until the first send, so a surface that has never been drawn is
    /// answered immediately rather than waiting out an interval it was not
    /// present for.
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

/// The gap between callbacks for a rate, with the floor applied.
fn interval(rate: FrameRate) -> Duration {
    // Clamped before the reciprocal rather than after. `FrameRate` admits any
    // finite positive value, and the reciprocal of a very small one overflows
    // `Duration::from_secs_f64`, which panics; clamping first bounds the
    // reciprocal to one second and makes the panic unreachable.
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

        // Out of view: throttled to the floor, and withheld for most of a
        // second.
        pacer.set(surface(1), rate(1.0));
        assert!(!pacer.is_due(surface(1), secs(1.5)));

        // Back in view before the floor's interval elapsed. The 60 Hz budget
        // was met long ago, so the client is answered on the next tick rather
        // than serving out the throttled interval it no longer has.
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
