//! Where a monitor sits on the host desktop.

use std::fmt;

/// A monitor's top-left corner in the host compositor's logical coordinate
/// space.
///
/// Logical rather than pixel coordinates, because the two differ by the scale
/// factor on a scaled display and every consumer of this — stream correlation,
/// pointer mapping — works in the space the compositor arranges outputs in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
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
