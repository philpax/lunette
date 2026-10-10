//! Where the host cursor is requested to go, and what accumulates before a
//! frame's commit.
//!
//! The coordinate types are the host desktop's own space, logical and
//! spanning every monitor. This is the only space either provider uses.
//! [`PendingPointer`] is the batching every provider does between commits,
//! extracted so that both of them share one copy of it and so it can be
//! tested without opening a device.
//!
//! Nothing here does I/O.

use std::fmt;

use crate::hid::key::PointerButton;

/// A position on the host desktop, in the compositor's logical coordinates.
///
/// The coordinate is in logical units, not pixels.
/// [`crate::monitor::LogicalPosition`] states the reason: on a scaled display
/// the two differ by the scale factor, and a pointer mapped through pixels
/// lands wrong by exactly that ratio.
///
/// The coordinate is fractional. A hit on a mirrored panel does not land on a
/// whole logical pixel, and rounding at the point of the hit throws away
/// precision the provider still has a use for.
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

    /// Keeps the point inside the rectangle `origin` and `extent` describe.
    ///
    /// A non-rectangular arrangement leaves dead zones inside the desktop's
    /// bounding box, so this is not the whole of the clamping a pointer needs;
    /// [`crate::hid::mapping`] clamps to the target monitor first. This is the
    /// last clamp, and it keeps a position from leaving the desktop entirely.
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

/// How large the host desktop's bounding box is.
///
/// Validated positive and finite at construction, because it is a divisor:
/// uinput normalises a position by dividing through it, and
/// `zwlr_virtual_pointer_v1.motion_absolute` takes it as the extent a position
/// is expressed against. A zero extent produces an infinity in the first case
/// and a division by zero in the compositor in the second, and neither reports
/// anything back.
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

/// How far a scroll wheel turned, in detents.
///
/// One unit is one click of a notched wheel, and the value is fractional
/// because a trackpad-style source produces a fraction of one. Both providers
/// convert from here into whatever their transport counts in: uinput's
/// high-resolution axes are 120ths of a detent, and `wl_pointer.axis` is ten
/// surface-local units per detent. The unit has to be stated once, here, and
/// not implied differently at each end.
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
/// Pointer and button calls accumulate, and `commit` flushes once per frame,
/// as WayVR's `MouseAction` does. A frame may produce several pointer calls,
/// for example two hands or a laser that moved and then clicked. Sending each
/// one as it arrives puts the host cursor at a position no call requested.
///
/// The type is pure. The providers own one of these and differ only in what
/// they do with what it yields.
#[derive(Clone, Debug, Default)]
pub struct PendingPointer {
    /// Where the last call requested the cursor to be, whether or not that
    /// position is still going to be sent. A click lands here, and it
    /// survives a commit so that a click in a frame with no motion lands
    /// where the previous frame left the cursor.
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

    /// Requests an absolute position.
    ///
    /// The first position of a frame is the one sent, as in WayVR. A laser
    /// that crosses a panel produces a stream of positions. The first position
    /// is where the laser was when the frame's other events were decided.
    ///
    /// A scroll already recorded suppresses the move entirely, and
    /// [`Self::scroll`] clears a motion that was recorded before it.
    pub fn move_to(&mut self, position: DesktopPoint) {
        if self.position.is_none() && self.wheel.is_none() {
            self.position = Some(position);
        }
        self.last_requested = Some(position);
    }

    /// Records a button change.
    ///
    /// One per frame. A press and a release in the same frame would be a click
    /// the host cannot observe. The second event is delayed by a frame, which
    /// keeps it from being lost.
    ///
    /// The recorded position is forced to the latest requested one, so a click
    /// lands where the laser is, not where the frame's first move was.
    /// When a scroll has already suppressed this frame's motion there is no
    /// position to send, and reinstating one would put a motion event back
    /// among the wheel events [`Self::scroll`] removed.
    pub fn press(&mut self, button: PointerButton, down: bool) {
        if self.button.is_none() {
            self.button = Some((button, down));
            if self.wheel.is_none() {
                self.position = self.last_requested;
            }
        }
    }

    /// Records a scroll, and suppresses this frame's motion.
    ///
    /// WayVR drops the motion for the same reason: Chromium and everything
    /// built on it stop scrolling when a motion event interleaves with the
    /// wheel events.
    pub fn scroll(&mut self, delta: WheelDelta) {
        if self.wheel.is_none() && !delta.is_zero() {
            self.wheel = Some(delta);
            self.position = None;
        }
    }

    /// Takes what accumulated, and keeps the last requested position.
    #[must_use]
    pub fn take(&mut self) -> PointerBatch {
        PointerBatch {
            position: self.position.take(),
            button: self.button.take(),
            wheel: self.wheel.take(),
        }
    }
}

/// One frame's worth of pointer activity, ready to be sent.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PointerBatch {
    pub position: Option<DesktopPoint>,
    pub button: Option<(PointerButton, bool)>,
    pub wheel: Option<WheelDelta>,
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

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

        assert_eq!(pending.take(), PointerBatch::default());
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

        pending.scroll(WheelDelta::new(0.0, 5.0));
        pending.move_to(DesktopPoint::new(10.0, 10.0));

        assert_eq!(pending.take().position, None, "a motion after the scroll");
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
    fn a_click_in_a_scrolling_frame_does_not_put_the_motion_back() {
        // `press` forces the recorded position to the latest requested one,
        // which after a scroll would reinstate the motion event `scroll`
        // removed. A motion event interleaved with the wheel events stops
        // Chromium scrolling.
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(10.0, 10.0));
        pending.scroll(WheelDelta::new(0.0, 5.0));
        pending.press(PointerButton::Left, true);

        let batch = pending.take();

        assert_eq!(batch.position, None);
        assert_eq!(batch.button, Some((PointerButton::Left, true)));
        assert_eq!(batch.wheel, Some(WheelDelta::new(0.0, 5.0)));
    }

    #[test]
    fn a_click_in_a_frame_with_no_motion_lands_where_the_last_frame_left_the_cursor() {
        let mut pending = PendingPointer::new();
        pending.move_to(DesktopPoint::new(100.0, 100.0));
        let _ = pending.take();
        pending.press(PointerButton::Left, true);

        assert_eq!(
            pending.take().position,
            Some(DesktopPoint::new(100.0, 100.0)),
        );
    }
}
