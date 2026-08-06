//! Where the host cursor is asked to go, and what accumulates before a frame's
//! commit.
//!
//! Two things live here. The coordinate types are the host desktop's own
//! space — logical, spanning every monitor — which is the only space either
//! provider speaks. And [`PendingPointer`] is the batching every provider does
//! between commits, extracted so that both of them share one copy of it and so
//! it can be tested without opening a device.
//!
//! Nothing here does I/O.

use std::fmt;

use crate::hid::key::PointerButton;

/// A position on the host desktop, in the compositor's logical coordinates.
///
/// Logical rather than pixels, for the reason
/// [`crate::monitor::LogicalPosition`] gives: on a scaled display the two differ
/// by the scale factor, and a pointer mapped through pixels lands wrong by
/// exactly that ratio.
///
/// Fractional, because a hit on a mirrored panel does not land on a whole
/// logical pixel and rounding at the point of the hit throws away precision the
/// provider still has a use for.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct DesktopPoint {
    pub x: f64,
    pub y: f64,
}

impl DesktopPoint {
    pub const ORIGIN: Self = Self { x: 0.0, y: 0.0 };

    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    #[must_use]
    pub fn offset(self, delta: DesktopVector) -> Self {
        Self::new(self.x + delta.dx, self.y + delta.dy)
    }

    /// Keeps the point inside the rectangle `origin` and `extent` describe.
    ///
    /// A non-rectangular arrangement leaves dead zones inside the desktop's
    /// bounding box, so this is not the whole of the clamping a pointer needs;
    /// `crate::hid::mapping` clamps to the target monitor first. This is the
    /// last guard, and it is what keeps a relative motion from walking off the
    /// desktop entirely.
    #[must_use]
    pub fn clamped(self, origin: Self, extent: DesktopExtent) -> Self {
        Self::new(
            self.x.clamp(origin.x, origin.x + extent.width),
            self.y.clamp(origin.y, origin.y + extent.height),
        )
    }
}

impl fmt::Display for DesktopPoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.1},{:.1}", self.x, self.y)
    }
}

/// A displacement on the host desktop, in the same logical coordinates.
///
/// Distinct from [`DesktopPoint`] so a relative motion cannot be passed where an
/// absolute one is wanted; the two differ only in meaning, and that is exactly
/// the case a newtype is for.
#[derive(Clone, Copy, Debug, Default, PartialEq, PartialOrd)]
pub struct DesktopVector {
    pub dx: f64,
    pub dy: f64,
}

impl DesktopVector {
    #[must_use]
    pub const fn new(dx: f64, dy: f64) -> Self {
        Self { dx, dy }
    }
}

impl fmt::Display for DesktopVector {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:+.1},{:+.1}", self.dx, self.dy)
    }
}

/// How large the host desktop's bounding box is.
///
/// Validated positive and finite at construction, because it is a divisor:
/// uinput normalises a position by dividing through it (`uinput.rs:124` in
/// WayVR), and `zwlr_virtual_pointer_v1.motion_absolute` takes it as the extent
/// a position is expressed against. A zero extent would produce an infinity in
/// the first case and a division by zero in the compositor in the second, and
/// neither reports anything back.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct DesktopExtent {
    width: f64,
    height: f64,
}

impl DesktopExtent {
    /// Reads an extent, rejecting one that cannot be divided through.
    #[must_use]
    pub fn new(width: f64, height: f64) -> Option<Self> {
        let usable = |value: f64| value.is_finite() && value > 0.0;
        (usable(width) && usable(height)).then_some(Self { width, height })
    }

    #[must_use]
    pub const fn width(self) -> f64 {
        self.width
    }

    #[must_use]
    pub const fn height(self) -> f64 {
        self.height
    }
}

impl fmt::Display for DesktopExtent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.0}x{:.0}", self.width, self.height)
    }
}

/// How far a scroll wheel turned, in the host's logical scroll units.
#[derive(Clone, Copy, Debug, Default, PartialEq, PartialOrd)]
pub struct WheelDelta {
    pub x: f64,
    pub y: f64,
}

impl WheelDelta {
    #[must_use]
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    #[must_use]
    pub fn is_zero(self) -> bool {
        self.x == 0.0 && self.y == 0.0
    }
}

impl fmt::Display for WheelDelta {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:+.2},{:+.2}", self.x, self.y)
    }
}

/// What a frame's pointer calls add up to.
///
/// Pointer and button calls accumulate and `commit` flushes once per frame, as
/// WayVR's `MouseAction` does (`subsystem/hid/mod.rs:28-34`). The reason is that
/// a frame may produce several pointer calls — two hands, a laser that moved and
/// then clicked — and sending each one as it arrives puts the host cursor
/// somewhere it was never asked to stop.
///
/// Pure. The providers own one of these and differ only in what they do with
/// what it yields.
#[derive(Clone, Debug, Default)]
pub struct PendingPointer {
    /// Where the last call asked the cursor to be, whether or not that position
    /// is still going to be sent. Relative motion starts from here, so a
    /// sequence of relative moves within one frame composes.
    last_requested: Option<DesktopPoint>,
    position: Option<DesktopPoint>,
    button: Option<(PointerButton, bool)>,
    wheel: Option<WheelDelta>,
}

impl PendingPointer {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last_requested: None,
            position: None,
            button: None,
            wheel: None,
        }
    }

    /// Asks for an absolute position.
    ///
    /// The first position of a frame wins rather than the last, following
    /// WayVR (`uinput.rs:157-160`): a laser that crosses a panel produces a
    /// stream of positions, and the one that matters is where it was when the
    /// frame's other events were decided.
    ///
    /// A scroll already recorded suppresses the move entirely, which is the
    /// same rule from the other side.
    pub fn move_to(&mut self, position: DesktopPoint) {
        if self.position.is_none() && self.wheel.is_none() {
            self.position = Some(position);
        }
        self.last_requested = Some(position);
    }

    /// Asks for a displacement from wherever the cursor was last asked to be.
    ///
    /// Clamped to the desktop, because a relative motion has no other bound and
    /// an unbounded one walks the cursor off every monitor.
    pub fn move_by(&mut self, delta: DesktopVector, origin: DesktopPoint, extent: DesktopExtent) {
        let position = self
            .last_requested
            .unwrap_or(origin)
            .offset(delta)
            .clamped(origin, extent);
        self.position = Some(position);
        self.last_requested = Some(position);
    }

    /// Records a button change.
    ///
    /// One per frame: a press and a release in the same frame would be a click
    /// the host cannot observe, and the second of them is better delayed by a
    /// frame than lost.
    ///
    /// The recorded position is forced to the latest requested one, so a click
    /// lands where the laser is rather than where the frame's first move was.
    pub fn press(&mut self, button: PointerButton, down: bool) {
        if self.button.is_none() {
            self.button = Some((button, down));
            self.position = self.last_requested;
        }
    }

    /// Records a scroll, and suppresses this frame's motion.
    ///
    /// WayVR drops the motion for the same reason (`uinput.rs:181-184`):
    /// Chromium and everything built on it stop scrolling when a motion event
    /// interleaves with the wheel events.
    pub fn scroll(&mut self, delta: WheelDelta) {
        if self.wheel.is_none() && !delta.is_zero() {
            self.wheel = Some(delta);
            self.position = None;
        }
    }

    /// Takes what accumulated, leaving the last requested position behind.
    #[must_use]
    pub fn take(&mut self) -> PointerBatch {
        PointerBatch {
            position: self.position.take(),
            button: self.button.take(),
            wheel: self.wheel.take(),
        }
    }

    /// Where the cursor was last asked to be, whether or not it was sent.
    #[must_use]
    pub const fn last_requested(&self) -> Option<DesktopPoint> {
        self.last_requested
    }
}

/// One frame's worth of pointer activity, ready to be sent.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PointerBatch {
    pub position: Option<DesktopPoint>,
    pub button: Option<(PointerButton, bool)>,
    pub wheel: Option<WheelDelta>,
}

impl PointerBatch {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.position.is_none() && self.button.is_none() && self.wheel.is_none()
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn desktop() -> (DesktopPoint, DesktopExtent) {
        (
            DesktopPoint::new(0.0, 0.0),
            DesktopExtent::new(1920.0, 1080.0).expect("a positive extent"),
        )
    }

    #[test]
    fn an_extent_that_cannot_be_divided_through_is_rejected() {
        assert_eq!(DesktopExtent::new(0.0, 1080.0), None);
        assert_eq!(DesktopExtent::new(1920.0, -1.0), None);
        assert_eq!(DesktopExtent::new(f64::NAN, 1080.0), None);
        assert_eq!(DesktopExtent::new(f64::INFINITY, 1080.0), None);
        assert!(DesktopExtent::new(1920.0, 1080.0).is_some());
    }

    #[test]
    fn nothing_accumulated_commits_nothing() {
        let mut pending = PendingPointer::new();

        assert!(pending.take().is_empty());
    }

    #[test]
    fn the_first_position_of_a_frame_is_the_one_sent() {
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(10.0, 10.0));
        pending.move_to(DesktopPoint::new(20.0, 20.0));

        assert_eq!(pending.take().position, Some(DesktopPoint::new(10.0, 10.0)));
    }

    #[test]
    fn a_click_lands_where_the_laser_last_was_rather_than_where_it_entered() {
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(10.0, 10.0));
        pending.move_to(DesktopPoint::new(20.0, 20.0));
        pending.press(PointerButton::Left, true);

        let batch = pending.take();

        assert_eq!(batch.position, Some(DesktopPoint::new(20.0, 20.0)));
        assert_eq!(batch.button, Some((PointerButton::Left, true)));
    }

    #[test]
    fn a_second_button_in_one_frame_waits_for_the_next() {
        let mut pending = PendingPointer::new();
        pending.press(PointerButton::Left, true);
        pending.press(PointerButton::Left, false);

        assert_eq!(pending.take().button, Some((PointerButton::Left, true)));
    }

    #[test]
    fn a_scroll_suppresses_the_frames_motion() {
        // Chromium stops scrolling when motion interleaves with the wheel.
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(10.0, 10.0));
        pending.scroll(WheelDelta::new(0.0, 5.0));

        let batch = pending.take();

        assert_eq!(batch.position, None);
        assert_eq!(batch.wheel, Some(WheelDelta::new(0.0, 5.0)));
    }

    #[test]
    fn a_motion_after_a_scroll_is_also_suppressed() {
        let mut pending = PendingPointer::new();
        pending.scroll(WheelDelta::new(0.0, 5.0));
        pending.move_to(DesktopPoint::new(10.0, 10.0));

        assert_eq!(pending.take().position, None);
    }

    #[test]
    fn a_scroll_of_nothing_is_not_a_scroll() {
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(10.0, 10.0));
        pending.scroll(WheelDelta::new(0.0, 0.0));

        let batch = pending.take();

        assert_eq!(batch.wheel, None);
        assert_eq!(batch.position, Some(DesktopPoint::new(10.0, 10.0)));
    }

    #[test]
    fn relative_motions_compose_within_one_frame() {
        let (origin, extent) = desktop();
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(100.0, 100.0));
        pending.move_by(DesktopVector::new(10.0, 0.0), origin, extent);
        pending.move_by(DesktopVector::new(0.0, 10.0), origin, extent);

        assert_eq!(
            pending.take().position,
            Some(DesktopPoint::new(110.0, 110.0)),
        );
    }

    #[test]
    fn a_relative_motion_cannot_walk_off_the_desktop() {
        let (origin, extent) = desktop();
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(1900.0, 1070.0));
        pending.move_by(DesktopVector::new(1000.0, 1000.0), origin, extent);

        assert_eq!(
            pending.take().position,
            Some(DesktopPoint::new(1920.0, 1080.0)),
        );
    }

    #[test]
    fn a_relative_motion_before_any_absolute_one_starts_at_the_desktop_origin() {
        let (origin, extent) = desktop();
        let mut pending = PendingPointer::new();
        pending.move_by(DesktopVector::new(5.0, 5.0), origin, extent);

        assert_eq!(pending.take().position, Some(DesktopPoint::new(5.0, 5.0)));
    }

    #[test]
    fn the_last_requested_position_survives_a_commit() {
        // Otherwise a relative motion in the next frame restarts from the
        // desktop origin rather than from where the cursor actually is.
        let (origin, extent) = desktop();
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(100.0, 100.0));
        let _ = pending.take();
        pending.move_by(DesktopVector::new(10.0, 10.0), origin, extent);

        assert_eq!(
            pending.take().position,
            Some(DesktopPoint::new(110.0, 110.0)),
        );
        assert_eq!(
            pending.last_requested(),
            Some(DesktopPoint::new(110.0, 110.0)),
        );
    }
}
