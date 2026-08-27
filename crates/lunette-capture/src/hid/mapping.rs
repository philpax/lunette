//! Turns a hit on a mirrored panel into a position on a physical monitor.
//!
//! Two coordinate spaces meet here, and the file keeps them apart.
//!
//! A [`HidProvider`](crate::hid::HidProvider) receives only the host desktop's
//! bounding box. Uinput's device spans the box in a fixed normalised range, as
//! WayVR's does, and `zwlr_virtual_pointer_v1.motion_absolute` takes the box as
//! the extent a position is expressed against. The interface has no concept of
//! a monitor.
//!
//! Per-monitor targeting sits above the box, and this file implements it. A
//! [`MonitorMapping`] turns a normalised hit on the panel into a position inside
//! one monitor's logical rectangle, including its rotation and flip, exactly as
//! WayVR builds an `Affine2` per screen. The provider then places the position
//! on the desktop.
//!
//! The rotation itself is
//! [`SurfaceTransform`](crate::monitor::SurfaceTransform), which sits with the
//! rest of a monitor's geometry because that is where it is read from. What to
//! do with it is [`reorient`], in this file.
//!
//! # Logical coordinates
//!
//! Every dimension here is the compositor's logical geometry. On a display
//! scaled by two, the logical and pixel sizes differ by that factor, and a
//! pointer mapped through pixels lands wrong by exactly that ratio. Two
//! monitors at different scales side by side make the difference visible.
//!
//! # Output changes
//!
//! [`DesktopLayout`] is derived, not stored. A monitor added, removed, or moved
//! changes the bounding box, and the origin and extent handed to the provider
//! change with it. WayVR applies them once at screen enumeration, and nothing
//! observed re-runs it. Neither provider needs anything recreated for a change:
//! uinput's range is fixed and normalised, which is what the abstraction
//! provides.
//!
//! The file is pure. Nothing here touches a device, a compositor, or a
//! display.

use std::{error::Error, fmt};

use crate::{
    hid::pointer::{DesktopExtent, DesktopPoint},
    monitor::geometry::{LogicalGeometry, LogicalPosition, SurfaceTransform},
};

/// A hit on a mirrored panel, normalised over its surface.
///
/// `(0, 0)` is the panel's top-left corner and `(1, 1)` its bottom-right, in
/// the panel's own orientation. The value is normalised, not in pixels, so
/// nothing here depends on the resolution the panel happens to be rendered at.
///
/// Values outside the unit square are representable, because a laser that has
/// left the panel produces them. [`MonitorMapping::map`] clamps those values
/// to the square and does not refuse them. A pointer at the edge of a panel
/// then reaches the edge of the monitor. It does not vanish.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct PanelPoint {
    pub u: f64,
    pub v: f64,
}

impl PanelPoint {
    pub const TOP_LEFT: Self = Self::new(0.0, 0.0);
    pub const CENTRE: Self = Self::new(0.5, 0.5);
    pub const BOTTOM_RIGHT: Self = Self::new(1.0, 1.0);

    #[must_use]
    pub const fn new(u: f64, v: f64) -> Self {
        Self { u, v }
    }

    /// The same point with both axes brought into the unit square.
    ///
    /// A non-finite coordinate becomes zero and does not propagate. A NaN
    /// through `clamp` stays NaN, and a NaN reaching the provider becomes a
    /// pointer position the host cannot interpret.
    #[must_use]
    fn clamped(self) -> Self {
        let unit = |value: f64| {
            if value.is_finite() {
                value.clamp(0.0, 1.0)
            } else {
                0.0
            }
        };
        Self::new(unit(self.u), unit(self.v))
    }
}

impl fmt::Display for PanelPoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.3},{:.3}", self.u, self.v)
    }
}

/// Moves a normalised panel coordinate into its monitor's own orientation.
///
/// The mapping is a bijection of the unit square, so a corner always lands on a
/// corner and the centre always stays the centre.
///
/// The function is free-standing. It is not a method on [`SurfaceTransform`].
/// The type describes what the host reported, and sits with the rest of a
/// monitor's geometry. What to do with it sits here with the mapping.
#[must_use]
pub fn reorient(transform: SurfaceTransform, point: PanelPoint) -> PanelPoint {
    let PanelPoint { u, v } = point;
    match transform {
        SurfaceTransform::Normal => PanelPoint::new(u, v),
        SurfaceTransform::Rotate90 => PanelPoint::new(v, 1.0 - u),
        SurfaceTransform::Rotate180 => PanelPoint::new(1.0 - u, 1.0 - v),
        SurfaceTransform::Rotate270 => PanelPoint::new(1.0 - v, u),
        SurfaceTransform::Flipped => PanelPoint::new(1.0 - u, v),
        SurfaceTransform::Flipped90 => PanelPoint::new(v, u),
        SurfaceTransform::Flipped180 => PanelPoint::new(u, 1.0 - v),
        SurfaceTransform::Flipped270 => PanelPoint::new(1.0 - v, 1.0 - u),
    }
}

/// How to reach one physical monitor from its mirrored panel.
///
/// The mapping is non-empty by construction, so nothing downstream has to guard
/// against a division by a zero-sized monitor. [`Self::new`] is the only way to
/// build one, and it rejects that case by name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MonitorMapping {
    geometry: LogicalGeometry,
    transform: SurfaceTransform,
}

impl MonitorMapping {
    /// The mapping for a monitor, or [`MappingError::EmptyMonitor`] when it has
    /// no area to map onto.
    ///
    /// A compositor can report a monitor with a zero logical dimension. This
    /// happens for a monitor being reconfigured, or one whose mode has not been
    /// set. Such a monitor cannot take a pointer.
    ///
    /// # Errors
    ///
    /// [`MappingError::EmptyMonitor`] when either logical dimension is zero.
    pub fn new(
        geometry: LogicalGeometry,
        transform: SurfaceTransform,
    ) -> Result<Self, MappingError> {
        if geometry.size.is_empty() {
            return Err(MappingError::EmptyMonitor { geometry });
        }
        Ok(Self {
            geometry,
            transform,
        })
    }

    #[must_use]
    pub const fn geometry(&self) -> LogicalGeometry {
        self.geometry
    }

    #[must_use]
    pub const fn transform(&self) -> SurfaceTransform {
        self.transform
    }

    /// Where on the host desktop a hit on this monitor's panel lands.
    ///
    /// The hit is clamped into the unit square before the transform, which
    /// keeps a pointer near a panel's edge inside this monitor's rectangle.
    /// The desktop's bounding box on its own is not enough. A non-rectangular
    /// arrangement leaves dead zones inside it, and a hit clamped only to the
    /// box could land in the gap between two screens.
    ///
    /// The result spans the monitor's rectangle inclusively, corner to corner.
    /// [`DesktopLayout::monitor_at`] partitions with half-open rectangles
    /// instead, for the reason given there.
    #[must_use]
    pub fn map(&self, hit: PanelPoint) -> DesktopPoint {
        let local = reorient(self.transform, hit.clamped());
        DesktopPoint::new(
            f64::from(self.geometry.position.x) + local.u * f64::from(self.geometry.size.width),
            f64::from(self.geometry.position.y) + local.v * f64::from(self.geometry.size.height),
        )
    }

    /// Whether `point` is on this monitor.
    ///
    /// The test is half-open on both axes. The top-left corner is on the
    /// monitor and the bottom-right one is not. Two monitors sharing an edge
    /// therefore partition it, and a position on the shared edge belongs to
    /// exactly one of them.
    #[must_use]
    pub fn contains(&self, point: DesktopPoint) -> bool {
        let within = |value: f64, start: i32, span: u32| {
            let start = f64::from(start);
            value >= start && value < start + f64::from(span)
        };
        within(point.x, self.geometry.position.x, self.geometry.size.width)
            && within(point.y, self.geometry.position.y, self.geometry.size.height)
    }
}

impl fmt::Display for MonitorMapping {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.geometry, self.transform)
    }
}

/// The host desktop's bounding box over every mappable monitor.
///
/// This is what a [`HidProvider`](crate::hid::HidProvider) is told through
/// `set_desktop_origin` and `set_desktop_extent`. The box is rebuilt on every
/// output change. It is not kept up to date in place, because a monitor moving
/// changes the box in ways an incremental update gets wrong far more easily than
/// recomputing gets it wrong.
#[derive(Clone, Debug, PartialEq)]
pub struct DesktopLayout {
    monitors: Vec<MonitorMapping>,
    origin: DesktopPoint,
    extent: DesktopExtent,
}

impl DesktopLayout {
    /// The bounding box over `monitors`.
    ///
    /// Every [`MonitorMapping`] is non-empty by construction, so the box is too,
    /// and [`Self::extent`] is a divisor that can never be zero. That is why
    /// this takes mappings. The one degenerate case is rejected where it can
    /// be named.
    ///
    /// # Errors
    ///
    /// [`MappingError::NoMonitors`] when the list is empty. A desktop with no
    /// monitors has no coordinate space, so there is nothing to hand a provider.
    pub fn new(monitors: impl IntoIterator<Item = MonitorMapping>) -> Result<Self, MappingError> {
        let monitors: Vec<MonitorMapping> = monitors.into_iter().collect();
        let mut bounds: Option<Bounds> = None;
        for monitor in &monitors {
            let monitor = Bounds::of(monitor.geometry);
            bounds = Some(match bounds {
                Some(box_so_far) => box_so_far.union(monitor),
                None => monitor,
            });
        }
        let Some(bounds) = bounds else {
            return Err(MappingError::NoMonitors);
        };

        // Every mapping has a positive width and height, so the union of at
        // least one of them does too, and `DesktopExtent::new` cannot refuse it.
        let extent = DesktopExtent::new(
            (bounds.right - bounds.left) as f64,
            (bounds.bottom - bounds.top) as f64,
        )
        .ok_or(MappingError::NoMonitors)?;

        Ok(Self {
            monitors,
            origin: DesktopPoint::new(bounds.left as f64, bounds.top as f64),
            extent,
        })
    }

    /// Where the bounding box begins.
    ///
    /// This is not the coordinate origin in general. A monitor placed to the
    /// left of or above the primary one has a negative logical position.
    #[must_use]
    pub const fn origin(&self) -> DesktopPoint {
        self.origin
    }

    /// How large the bounding box is.
    #[must_use]
    pub const fn extent(&self) -> DesktopExtent {
        self.extent
    }

    #[must_use]
    pub fn monitors(&self) -> &[MonitorMapping] {
        &self.monitors
    }

    /// Which monitor a desktop position is on, if any.
    ///
    /// `None` is returned for a position in a dead zone and for one outside the
    /// box entirely. A non-rectangular arrangement leaves gaps inside the
    /// bounding box. The function reports which monitor contains the position. It
    /// does not move the position to the nearest monitor, because the two cases
    /// mean different things to a caller, and only the caller knows which it
    /// wants.
    ///
    /// Where two monitors share an edge, the position belongs to the one whose
    /// rectangle begins there, since [`MonitorMapping::contains`] is half-open.
    #[must_use]
    pub fn monitor_at(&self, point: DesktopPoint) -> Option<&MonitorMapping> {
        self.monitors.iter().find(|monitor| monitor.contains(point))
    }
}

impl fmt::Display for DesktopLayout {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} monitors spanning {} at {}",
            self.monitors.len(),
            self.extent,
            self.origin,
        )
    }
}

/// Why a monitor or a desktop could not be mapped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MappingError {
    /// The monitor has a zero logical width or height, so there is nothing to
    /// place a pointer on.
    EmptyMonitor { geometry: LogicalGeometry },
    /// There are no monitors, so there is no desktop coordinate space.
    NoMonitors,
}

impl fmt::Display for MappingError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("pointer mapping: ")?;
        match self {
            Self::EmptyMonitor { geometry } => write!(
                f,
                "the monitor {geometry} has no area, so no position on it can be reached"
            ),
            Self::NoMonitors => {
                f.write_str("no monitor can be mapped, so the desktop has no extent")
            }
        }
    }
}

impl Error for MappingError {}

/// A rectangle's edges, in the logical coordinate space.
///
/// The right edge is a position plus a size, so the edges use `i64`: `i32`
/// cannot hold the sum of `i32::MAX` and `u32::MAX`.
#[derive(Clone, Copy, Debug)]
struct Bounds {
    left: i64,
    top: i64,
    right: i64,
    bottom: i64,
}

impl Bounds {
    fn of(geometry: LogicalGeometry) -> Self {
        let LogicalPosition { x, y } = geometry.position;
        Self {
            left: i64::from(x),
            top: i64::from(y),
            right: i64::from(x) + i64::from(geometry.size.width),
            bottom: i64::from(y) + i64::from(geometry.size.height),
        }
    }

    fn union(self, other: Self) -> Self {
        Self {
            left: self.left.min(other.left),
            top: self.top.min(other.top),
            right: self.right.max(other.right),
            bottom: self.bottom.max(other.bottom),
        }
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
    use crate::monitor::geometry::LogicalSize;

    fn geometry(x: i32, y: i32, width: u32, height: u32) -> LogicalGeometry {
        LogicalGeometry::new(LogicalPosition::new(x, y), LogicalSize::new(width, height))
    }

    fn mapping(x: i32, y: i32, width: u32, height: u32) -> MonitorMapping {
        MonitorMapping::new(geometry(x, y, width, height), SurfaceTransform::Normal)
            .expect("a monitor with an area")
    }

    fn layout(monitors: impl IntoIterator<Item = MonitorMapping>) -> DesktopLayout {
        DesktopLayout::new(monitors).expect("at least one monitor")
    }

    #[test]
    fn a_hit_at_a_panels_centre_lands_at_the_centre_of_its_monitor() {
        let monitor = mapping(0, 0, 1920, 1080);

        assert_eq!(
            monitor.map(PanelPoint::CENTRE),
            DesktopPoint::new(960.0, 540.0),
        );
    }

    #[test]
    fn a_hit_at_a_panels_corners_lands_at_its_monitors_corners() {
        let monitor = mapping(0, 0, 1920, 1080);

        assert_eq!(
            monitor.map(PanelPoint::TOP_LEFT),
            DesktopPoint::new(0.0, 0.0)
        );
        assert_eq!(
            monitor.map(PanelPoint::BOTTOM_RIGHT),
            DesktopPoint::new(1920.0, 1080.0),
        );
    }

    #[test]
    fn a_monitor_at_a_non_zero_origin_offsets_by_it() {
        let monitor = mapping(1920, 0, 1920, 1080);

        assert_eq!(
            monitor.map(PanelPoint::CENTRE),
            DesktopPoint::new(2880.0, 540.0),
        );
    }

    #[test]
    fn a_monitor_at_a_negative_logical_position_maps_into_negative_coordinates() {
        // A screen placed to the left of and above the primary one. This case
        // is why the desktop's origin is a value. It is not assumed to be zero.
        let monitor = mapping(-1920, -1080, 1920, 1080);

        assert_eq!(
            monitor.map(PanelPoint::TOP_LEFT),
            DesktopPoint::new(-1920.0, -1080.0),
        );
        assert_eq!(
            monitor.map(PanelPoint::CENTRE),
            DesktopPoint::new(-960.0, -540.0),
        );
    }

    #[test]
    fn two_monitors_at_different_scales_map_by_logical_size_rather_than_pixels() {
        // A 1920x1080 monitor at scale 1, and a 3840x2160 monitor at scale 2
        // beside it. In pixels the second is twice as wide. Logically the two
        // are the same width, and the centre of the second is at 2880.
        let unscaled = mapping(0, 0, 1920, 1080);
        let scaled = mapping(1920, 0, 1920, 1080);

        assert_eq!(
            unscaled.map(PanelPoint::CENTRE),
            DesktopPoint::new(960.0, 540.0),
        );
        assert_eq!(
            scaled.map(PanelPoint::CENTRE),
            DesktopPoint::new(2880.0, 540.0),
        );

        let desktop = layout([unscaled, scaled]);
        assert_eq!(desktop.extent().width(), 3840.0);
    }

    #[test]
    fn a_rotated_monitor_maps_through_its_transform() {
        // A 1920x1080 panel mounted portrait. The compositor reports a logical
        // size of 1080x1920, so the panel's top-left corner is the monitor's
        // bottom-left one.
        let monitor = MonitorMapping::new(geometry(0, 0, 1080, 1920), SurfaceTransform::Rotate90)
            .expect("a monitor with an area");

        assert_eq!(
            monitor.map(PanelPoint::TOP_LEFT),
            DesktopPoint::new(0.0, 1920.0),
        );
        assert_eq!(
            monitor.map(PanelPoint::CENTRE),
            DesktopPoint::new(540.0, 960.0),
        );
    }

    #[test]
    fn a_flipped_monitor_mirrors_about_the_vertical_axis() {
        let monitor = MonitorMapping::new(geometry(0, 0, 1920, 1080), SurfaceTransform::Flipped)
            .expect("a monitor with an area");

        assert_eq!(
            monitor.map(PanelPoint::new(0.25, 0.5)),
            DesktopPoint::new(1440.0, 540.0),
        );
    }

    #[test]
    fn every_transform_keeps_the_centre_at_the_centre() {
        for &transform in SurfaceTransform::ALL {
            assert_eq!(
                reorient(transform, PanelPoint::CENTRE),
                PanelPoint::CENTRE,
                "{transform} moved the centre",
            );
        }
    }

    #[test]
    fn every_transform_sends_corners_to_corners() {
        // A bijection of the unit square: the four corners permute among
        // themselves, so no transform can fold the panel onto itself.
        let corners = [
            PanelPoint::new(0.0, 0.0),
            PanelPoint::new(1.0, 0.0),
            PanelPoint::new(0.0, 1.0),
            PanelPoint::new(1.0, 1.0),
        ];

        for &transform in SurfaceTransform::ALL {
            let mut mapped: Vec<(u8, u8)> = corners
                .into_iter()
                .map(|corner| {
                    let moved = reorient(transform, corner);
                    (moved.u as u8, moved.v as u8)
                })
                .collect();
            mapped.sort_unstable();
            mapped.dedup();

            assert_eq!(mapped.len(), 4, "{transform} folded two corners together");
        }
    }

    #[test]
    fn rotating_by_ninety_degrees_four_times_is_the_identity() {
        let start = PanelPoint::new(0.25, 0.75);
        let mut point = start;
        for _ in 0..4 {
            point = reorient(SurfaceTransform::Rotate90, point);
        }

        assert_eq!(point, start);
    }

    #[test]
    fn a_hit_past_a_panels_edge_is_clamped_into_its_monitor() {
        // A laser that has left the panel reaches the monitor's edge, not
        // a coordinate on the neighbouring screen.
        let monitor = mapping(0, 0, 1920, 1080);

        assert_eq!(
            monitor.map(PanelPoint::new(1.5, -0.5)),
            DesktopPoint::new(1920.0, 0.0),
        );
    }

    #[test]
    fn a_hit_that_is_not_a_number_lands_at_the_panels_origin_rather_than_nowhere() {
        let monitor = mapping(100, 100, 1920, 1080);

        assert_eq!(
            monitor.map(PanelPoint::new(f64::NAN, f64::INFINITY)),
            DesktopPoint::new(100.0, 100.0),
        );
    }

    #[test]
    fn a_monitor_with_no_area_cannot_be_mapped() {
        assert_eq!(
            MonitorMapping::new(geometry(0, 0, 1920, 0), SurfaceTransform::Normal),
            Err(MappingError::EmptyMonitor {
                geometry: geometry(0, 0, 1920, 0),
            }),
        );
        assert_eq!(
            MonitorMapping::new(geometry(0, 0, 0, 1080), SurfaceTransform::Normal),
            Err(MappingError::EmptyMonitor {
                geometry: geometry(0, 0, 0, 1080),
            }),
        );
    }

    #[test]
    fn a_desktop_of_only_an_empty_monitor_has_no_extent() {
        // The empty monitor is refused where it can be named, so the desktop
        // built from what is left is empty, never zero-sized.
        let usable: Vec<MonitorMapping> = [geometry(0, 0, 1920, 0)]
            .into_iter()
            .filter_map(|geometry| MonitorMapping::new(geometry, SurfaceTransform::Normal).ok())
            .collect();

        assert_eq!(DesktopLayout::new(usable), Err(MappingError::NoMonitors));
    }

    #[test]
    fn a_desktop_with_no_monitors_at_all_has_no_extent() {
        assert_eq!(DesktopLayout::new([]), Err(MappingError::NoMonitors));
    }

    #[test]
    fn the_bounding_box_spans_every_monitor() {
        let desktop = layout([mapping(0, 0, 1920, 1080), mapping(1920, 0, 2560, 1440)]);

        assert_eq!(desktop.origin(), DesktopPoint::new(0.0, 0.0));
        assert_eq!(desktop.extent().width(), 4480.0);
        assert_eq!(desktop.extent().height(), 1440.0);
    }

    #[test]
    fn the_bounding_box_begins_at_the_leftmost_and_topmost_monitor() {
        let desktop = layout([mapping(0, 0, 1920, 1080), mapping(-1280, -200, 1280, 720)]);

        assert_eq!(desktop.origin(), DesktopPoint::new(-1280.0, -200.0));
        assert_eq!(desktop.extent().width(), 3200.0);
        assert_eq!(desktop.extent().height(), 1280.0);
    }

    #[test]
    fn a_coordinate_on_the_boundary_between_two_monitors_belongs_to_exactly_one() {
        // Half-open rectangles. The shared edge belongs to the monitor whose
        // rectangle begins there, so the two partition the desktop without
        // overlap.
        let left = mapping(0, 0, 1920, 1080);
        let right = mapping(1920, 0, 1920, 1080);
        let desktop = layout([left, right]);

        let found = desktop.monitor_at(DesktopPoint::new(1920.0, 500.0));

        assert_eq!(found, Some(&right));
        assert!(!left.contains(DesktopPoint::new(1920.0, 500.0)));
    }

    #[test]
    fn a_coordinate_outside_every_monitor_belongs_to_none() {
        let desktop = layout([mapping(0, 0, 1920, 1080)]);

        assert_eq!(desktop.monitor_at(DesktopPoint::new(-1.0, 500.0)), None);
        assert_eq!(desktop.monitor_at(DesktopPoint::new(1920.0, 500.0)), None);
        assert_eq!(desktop.monitor_at(DesktopPoint::new(500.0, 1080.0)), None);
    }

    #[test]
    fn a_coordinate_in_a_dead_zone_inside_the_bounding_box_belongs_to_none() {
        // Two monitors of different heights side by side leave a gap under the
        // shorter one that is inside the box and on no screen. This is why
        // `map` clamps to the target monitor, not to the box.
        let desktop = layout([mapping(0, 0, 1920, 1080), mapping(1920, 0, 1280, 720)]);

        assert_eq!(desktop.monitor_at(DesktopPoint::new(2000.0, 900.0)), None);
        assert!(
            desktop
                .monitor_at(DesktopPoint::new(2000.0, 700.0))
                .is_some()
        );
    }

    #[test]
    fn a_desktop_rebuilt_after_a_hotplug_reports_the_new_bounds() {
        let before = layout([mapping(0, 0, 1920, 1080)]);
        assert_eq!(before.extent().width(), 1920.0);

        let after = layout([mapping(0, 0, 1920, 1080), mapping(1920, 0, 2560, 1440)]);

        assert_eq!(after.extent().width(), 4480.0);
        assert_eq!(after.extent().height(), 1440.0);
        assert_eq!(after.origin(), before.origin());
    }

    #[test]
    fn removing_the_leftmost_monitor_moves_the_desktops_origin() {
        let before = layout([mapping(-1920, 0, 1920, 1080), mapping(0, 0, 1920, 1080)]);
        assert_eq!(before.origin(), DesktopPoint::new(-1920.0, 0.0));

        let after = layout([mapping(0, 0, 1920, 1080)]);

        assert_eq!(after.origin(), DesktopPoint::new(0.0, 0.0));
        assert_eq!(after.extent().width(), 1920.0);
    }

    #[test]
    fn a_hit_on_the_second_monitor_lands_on_the_second_monitor() {
        // A pointer sent to a monitor's sink reaches that physical display,
        // whichever it is.
        let second = mapping(1920, 0, 1920, 1080);
        let desktop = layout([mapping(0, 0, 1920, 1080), second]);

        let landed = second.map(PanelPoint::new(0.25, 0.5));

        assert_eq!(landed, DesktopPoint::new(2400.0, 540.0));
        assert_eq!(desktop.monitor_at(landed), Some(&second));
    }
}
