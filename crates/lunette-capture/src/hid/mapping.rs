//! Maps a hit on a mirrored panel to a position on a physical monitor.
//!
//! A [`HidProvider`](crate::hid::HidProvider) uses the host desktop bounding box for absolute pointer input. This module maps a panel hit to one monitor's logical rectangle before the provider maps it to the desktop.
//!
//! [`MonitorMapping`] applies the monitor's [`SurfaceTransform`](crate::monitor::SurfaceTransform), including rotation and reflection.
//!
//! # Logical coordinates
//!
//! All dimensions use the compositor's logical geometry. Logical dimensions differ from pixel dimensions when display scaling is enabled. Pointer mapping through pixel dimensions produces incorrect positions on scaled displays.
//!
//! # Desktop layout updates
//!
//! [`DesktopLayout`] is derived from the current monitor mappings. Adding, removing, or moving a monitor changes the desktop origin or extent. The provider's normalised input range remains fixed.
//!
use std::{error::Error, fmt};

use crate::{
    hid::pointer::{DesktopExtent, DesktopPoint},
    monitor::geometry::{LogicalGeometry, LogicalPosition, SurfaceTransform},
};

/// A hit on a mirrored panel, normalised over its surface.
///
/// `(0, 0)` is the panel's top-left corner. `(1, 1)` is its bottom-right corner in the panel's orientation. The coordinates do not depend on the panel's render resolution.
///
/// Coordinates outside the unit square are valid. [`MonitorMapping::map`] clamps them to the unit square so an out-of-panel hit reaches the corresponding monitor edge.
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

    /// Returns the point with both coordinates clamped to the unit square.
    ///
    /// A non-finite coordinate becomes zero. `clamp` preserves NaN, but the host cannot interpret a NaN pointer position.
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

/// Maps a normalised panel coordinate into the monitor's orientation.
///
/// The mapping is a bijection of the unit square. It maps corners to corners and preserves the centre.
///
/// This function applies [`SurfaceTransform`] within the mapping module. [`SurfaceTransform`] describes monitor geometry and remains defined in that module.
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

/// Maps a mirrored panel to one physical monitor.
///
/// Every instance has non-zero logical width and height. [`Self::new`] rejects empty monitors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MonitorMapping {
    geometry: LogicalGeometry,
    transform: SurfaceTransform,
}

impl MonitorMapping {
    /// Creates a mapping for a monitor.
    ///
    /// A monitor can have a zero logical dimension while it is being reconfigured or before its mode is set. Such a monitor cannot receive pointer input, so this constructor rejects it.
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

    /// Maps a panel hit to the host desktop.
    ///
    /// The method clamps the hit to the unit square before applying the transform. The result stays inside this monitor's rectangle, including its edges. Clamping to the desktop bounding box could place a hit in a gap between monitors.
    ///
    /// [`DesktopLayout::monitor_at`] uses half-open rectangles for partitioning.
    #[must_use]
    pub fn map(&self, hit: PanelPoint) -> DesktopPoint {
        let local = reorient(self.transform, hit.clamped());
        DesktopPoint::new(
            f64::from(self.geometry.position.x) + local.u * f64::from(self.geometry.size.width),
            f64::from(self.geometry.position.y) + local.v * f64::from(self.geometry.size.height),
        )
    }

    /// Returns whether `point` is inside this monitor.
    ///
    /// Both axes use half-open intervals. The top-left corner is inside. The bottom-right corner is outside. Adjacent monitors therefore do not both contain a shared edge.
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

/// The host desktop bounding box over all mappable monitors.
///
/// The [`HidProvider`](crate::hid::HidProvider) receives this value through `set_desktop_origin` and `set_desktop_extent`. The layout is rebuilt after every output change so monitor movement updates the complete bounding box.
#[derive(Clone, Debug, PartialEq)]
pub struct DesktopLayout {
    monitors: Vec<MonitorMapping>,
    origin: DesktopPoint,
    extent: DesktopExtent,
}

impl DesktopLayout {
    /// Creates the bounding box over `monitors`.
    ///
    /// Every [`MonitorMapping`] is non-empty, so the resulting extent is non-zero. The constructor accepts mappings rather than geometries because [`MonitorMapping::new`] rejects empty monitors.
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

        // Each mapping has positive width and height, so the union has a non-zero extent.
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

    /// Returns the bounding box's minimum position.
    ///
    /// The origin can be negative when a monitor is placed left of or above the primary monitor.
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

    /// Returns the monitor containing `point`, if one exists.
    ///
    /// Returns `None` for a point in a gap between monitors or outside the bounding box. The method does not select the nearest monitor because a gap and an out-of-bounds point have different meanings.
    ///
    /// A point on a shared edge belongs to the monitor whose rectangle begins at that edge. [`MonitorMapping::contains`] uses half-open rectangles.
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

/// An error from monitor or desktop mapping.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MappingError {
    /// The monitor has zero logical width or height and cannot receive pointer input.
    EmptyMonitor { geometry: LogicalGeometry },
    /// No monitors define a desktop coordinate space.
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

/// Rectangle edges in logical coordinates.
///
/// The edges use `i64` because each right or bottom edge adds an `i32` position to a `u32` size. The sum can exceed the `i32` range.
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
        // A monitor can have a negative logical position when it is left of or above the primary monitor.
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
        // Pixel dimensions differ, but both monitors have a logical width of 1920. The second monitor's centre is at 2880 logical units.
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
        // A portrait monitor has logical size 1080x1920. A 90-degree transform maps the panel's top-left corner to the monitor's bottom-left corner.
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
        // A bijection of the unit square maps the four corners to four distinct corners.
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
        // An out-of-panel hit clamps to the target monitor's edge.
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
        // Empty monitors are rejected before layout construction. No usable mappings remain.
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
        // Half-open rectangles assign the shared edge to the monitor whose rectangle begins there.
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
        // Different monitor heights can leave a gap inside the bounding box. `map` clamps to the target monitor rather than to the bounding box.
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
        // The mapped point belongs to the selected physical monitor.
        let second = mapping(1920, 0, 1920, 1080);
        let desktop = layout([mapping(0, 0, 1920, 1080), second]);

        let landed = second.map(PanelPoint::new(0.25, 0.5));

        assert_eq!(landed, DesktopPoint::new(2400.0, 540.0));
        assert_eq!(desktop.monitor_at(landed), Some(&second));
    }
}
