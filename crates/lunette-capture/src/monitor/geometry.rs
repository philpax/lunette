//! Where a monitor sits on the host desktop, how large it is there, and which
//! way up it is.
//!
//! All three arrive together, from the `wl_output.geometry` and
//! `zxdg_output_v1.logical_*` events that [`crate::monitor::outputs`] reads, so
//! they are described together here.

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

    /// A size the host reported as the protocol's signed pair.
    ///
    /// `None` for a negative dimension. `zxdg_output_v1.logical_size` does not
    /// permit one, so it means the compositor is misbehaving — and coercing it
    /// to zero would turn that into a monitor with no area, which reads as an
    /// output that has simply not finished describing itself.
    #[must_use]
    pub fn from_signed(width: i32, height: i32) -> Option<Self> {
        match (u32::try_from(width), u32::try_from(height)) {
            (Ok(width), Ok(height)) => Some(Self::new(width, height)),
            _ => None,
        }
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

    /// A resolution the host reported as the protocol's signed pair.
    ///
    /// `None` for a negative dimension, which `wl_output.mode` does not permit.
    /// Rejected rather than coerced, for the reason
    /// [`LogicalSize::from_signed`] gives.
    #[must_use]
    pub fn from_signed(width: i32, height: i32) -> Option<Self> {
        match (u32::try_from(width), u32::try_from(height)) {
            (Ok(width), Ok(height)) => Some(Self::new(width, height)),
            _ => None,
        }
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

/// How a monitor's panel is oriented relative to the rectangle it occupies.
///
/// The eight values of `wl_output.transform`, as a closed set. The logical
/// geometry already accounts for the rotation — a portrait-mounted 1920x1080
/// panel reports a logical size of 1080x1920 — so this describes only which
/// corner of the panel corresponds to which corner of that rectangle.
///
/// Here rather than beside the pointer mapping that consumes it, because this is
/// what `wl_output.geometry` reports alongside the position, the make, and the
/// model: [`crate::monitor::outputs`] reads all four from the one event.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SurfaceTransform {
    #[default]
    Normal,
    Rotate90,
    Rotate180,
    Rotate270,
    /// Mirrored about the vertical axis.
    Flipped,
    Flipped90,
    Flipped180,
    Flipped270,
}

impl SurfaceTransform {
    /// Every transform, in `wl_output.transform`'s own order.
    pub const ALL: [Self; 8] = [
        Self::Normal,
        Self::Rotate90,
        Self::Rotate180,
        Self::Rotate270,
        Self::Flipped,
        Self::Flipped90,
        Self::Flipped180,
        Self::Flipped270,
    ];

    /// The transform a `wl_output.geometry` event's value names.
    ///
    /// `None` for anything outside the protocol's eight, rather than a silent
    /// fallback to [`Self::Normal`]: a value this does not recognise would put
    /// the cursor in the wrong corner, which is worse than reporting that the
    /// monitor cannot be mapped.
    #[must_use]
    pub const fn from_wl_output(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::Normal),
            1 => Some(Self::Rotate90),
            2 => Some(Self::Rotate180),
            3 => Some(Self::Rotate270),
            4 => Some(Self::Flipped),
            5 => Some(Self::Flipped90),
            6 => Some(Self::Flipped180),
            7 => Some(Self::Flipped270),
            _ => None,
        }
    }

    /// The value `wl_output.geometry` carries for this transform.
    #[must_use]
    pub const fn as_wl_output(self) -> u32 {
        match self {
            Self::Normal => 0,
            Self::Rotate90 => 1,
            Self::Rotate180 => 2,
            Self::Rotate270 => 3,
            Self::Flipped => 4,
            Self::Flipped90 => 5,
            Self::Flipped180 => 6,
            Self::Flipped270 => 7,
        }
    }

    /// Whether the transform exchanges the two axes.
    ///
    /// A rotated monitor's logical size is its pixel size with the axes swapped,
    /// which is what makes this worth asking: the fallback that derives a
    /// logical size from `wl_output.mode` and `wl_output.scale` has to swap them
    /// back, and `zxdg_output_v1` reports the already-swapped size directly.
    #[must_use]
    pub const fn swaps_axes(self) -> bool {
        matches!(
            self,
            Self::Rotate90 | Self::Rotate270 | Self::Flipped90 | Self::Flipped270
        )
    }
}

impl fmt::Display for SurfaceTransform {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn a_signed_pair_the_protocol_permits_becomes_a_size() {
        assert_eq!(
            LogicalSize::from_signed(1920, 1080),
            Some(LogicalSize::new(1920, 1080)),
        );
        assert_eq!(
            PixelExtent::from_signed(3840, 2160),
            Some(PixelExtent::new(3840, 2160)),
        );
        assert_eq!(LogicalSize::from_signed(0, 0), Some(LogicalSize::new(0, 0)));
    }

    #[test]
    fn a_negative_dimension_is_refused_rather_than_coerced_to_zero() {
        // Zero would read as an output that has not finished describing itself,
        // which is an ordinary state; a negative dimension is a compositor
        // sending something the protocol does not permit, and the two must not
        // be answered the same way.
        assert_eq!(LogicalSize::from_signed(-1, 1080), None);
        assert_eq!(LogicalSize::from_signed(1920, -1), None);
        assert_eq!(PixelExtent::from_signed(-1, -1), None);
    }

    #[test]
    fn every_transform_round_trips_through_its_protocol_value() {
        for transform in SurfaceTransform::ALL {
            assert_eq!(
                SurfaceTransform::from_wl_output(transform.as_wl_output()),
                Some(transform),
            );
        }
    }

    #[test]
    fn a_value_outside_the_protocols_eight_names_no_transform() {
        assert_eq!(SurfaceTransform::from_wl_output(8), None);
        assert_eq!(SurfaceTransform::from_wl_output(u32::MAX), None);
    }

    #[test]
    fn exactly_the_quarter_turns_exchange_the_axes() {
        let swapping: Vec<SurfaceTransform> = SurfaceTransform::ALL
            .into_iter()
            .filter(|transform| transform.swaps_axes())
            .collect();

        assert_eq!(
            swapping,
            vec![
                SurfaceTransform::Rotate90,
                SurfaceTransform::Rotate270,
                SurfaceTransform::Flipped90,
                SurfaceTransform::Flipped270,
            ],
        );
    }
}
