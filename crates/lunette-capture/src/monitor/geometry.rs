//! Where a monitor sits on the host desktop, and how large it is there.

use std::fmt;

use serde::{Deserialize, Serialize};

/// A monitor's top-left corner in the host compositor's logical coordinate
/// space.
///
/// Logical rather than pixel coordinates, because the two differ by the scale
/// factor on a scaled display and every consumer of this — stream correlation,
/// pointer mapping — works in the space the compositor arranges outputs in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogicalPosition {
    pub x: i32,
    pub y: i32,
}

impl LogicalPosition {
    #[must_use]
    pub const fn new(x: i32, y: i32) -> Self {
        Self { x, y }
    }
}

impl fmt::Display for LogicalPosition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{},{}", self.x, self.y)
    }
}

/// How much of the logical coordinate space a monitor covers.
///
/// The counterpart to [`LogicalPosition`], and logical for the same reason: the
/// ScreenCast portal reports each stream's `position` and `size` in the
/// compositor's own arrangement space, and the comparison against a
/// `wl_output`'s geometry only holds if both sides are in that space.
///
/// A width or height of zero is representable, because a compositor that
/// reports one is describing a monitor lunette can do nothing with rather than
/// a bug this type can prevent. [`Self::is_empty`] is how a caller says so.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogicalSize {
    pub width: u32,
    pub height: u32,
}

impl LogicalSize {
    #[must_use]
    pub const fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.width == 0 || self.height == 0
    }
}

impl fmt::Display for LogicalSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{}", self.width, self.height)
    }
}

/// A monitor's resolution, in pixels.
///
/// Deliberately not [`LogicalSize`]. On a scaled display the two differ by the
/// scale factor, and they answer different questions: a pointer is placed in
/// logical coordinates, and a captured frame arrives at this size. A single type
/// for both is a transposition waiting to happen.
///
/// Zero is representable for the same reason [`LogicalSize`] allows it: a
/// monitor whose mode has not been set reports one, and that is a monitor
/// nothing can be done with rather than a state this type can rule out.
#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(deny_unknown_fields)]
pub struct PixelExtent {
    pub width: u32,
    pub height: u32,
}

impl PixelExtent {
    #[must_use]
    pub const fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }

    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.width == 0 || self.height == 0
    }
}

impl fmt::Display for PixelExtent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}x{} pixels", self.width, self.height)
    }
}

/// Where a monitor sits and how large it is, as one value.
///
/// The two travel together everywhere they are used, and a function taking them
/// as separate arguments is one a caller can transpose silently.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogicalGeometry {
    pub position: LogicalPosition,
    pub size: LogicalSize,
}

impl LogicalGeometry {
    #[must_use]
    pub const fn new(position: LogicalPosition, size: LogicalSize) -> Self {
        Self { position, size }
    }
}

impl fmt::Display for LogicalGeometry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at {}", self.size, self.position)
    }
}
