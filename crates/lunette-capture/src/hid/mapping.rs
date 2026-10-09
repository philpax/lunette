//! Turns a hit on a mirrored panel into a position on a physical monitor.
//!
//! A [`HidProvider`](crate::hid::HidProvider) knows only the desktop's bounding box, so
//! per-monitor targeting happens here, in the compositor's logical coordinates. Panels apply the
//! capture transform before presentation, so the mapping applies none.

use std::{error::Error, fmt};

use crate::{
    hid::pointer::{DesktopExtent, DesktopPoint},
    monitor::geometry::{LogicalGeometry, LogicalPosition},
};

/// A hit on a mirrored panel, normalised over its surface.
///
/// `(0, 0)` is the panel's top-left corner and `(1, 1)` its bottom-right. Values
/// outside the unit square come from a laser that has left the panel, and
/// [`MonitorMapping::map`] clamps them so the pointer stays at the monitor's edge.
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
    /// A non-finite coordinate becomes zero, because `clamp` keeps NaN and the
    /// host cannot interpret a NaN position.
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

/// How to reach one physical monitor from its mirrored panel.
///
/// The mapping is non-empty by construction, so nothing downstream divides by a
/// zero-sized monitor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MonitorMapping {
    geometry: LogicalGeometry,
}

impl MonitorMapping {
    /// The mapping for a monitor, or [`MappingError::EmptyMonitor`] when it has
    /// no area to map onto.
    ///
    /// A monitor being reconfigured, or one with no mode set, can report a zero
    /// logical dimension.
    ///
    /// # Errors
    ///
    /// [`MappingError::EmptyMonitor`] when either logical dimension is zero.
    pub fn new(geometry: LogicalGeometry) -> Result<Self, MappingError> {
        if geometry.size.is_empty() {
            return Err(MappingError::EmptyMonitor { geometry });
        }
        Ok(Self { geometry })
    }

    #[must_use]
    pub const fn geometry(&self) -> LogicalGeometry {
        self.geometry
    }

    /// Where on the host desktop a hit on this monitor's panel lands.
    ///
    /// The hit is clamped to this monitor, not to the desktop's bounding box,
    /// because a non-rectangular arrangement leaves dead zones inside the box.
    /// The result spans the monitor's rectangle inclusively.
    #[must_use]
    pub fn map(&self, hit: PanelPoint) -> DesktopPoint {
        let local = hit.clamped();
        DesktopPoint::new(
            f64::from(self.geometry.position.x) + local.u * f64::from(self.geometry.size.width),
            f64::from(self.geometry.position.y) + local.v * f64::from(self.geometry.size.height),
        )
    }

    /// Whether `point` is on this monitor.
    ///
    /// The test is half-open, so a position on an edge shared by two monitors
    /// belongs to exactly one of them.
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
        write!(f, "{}", self.geometry)
    }
}

/// The host desktop's bounding box over every mappable monitor.
///
/// A [`HidProvider`](crate::hid::HidProvider) receives it through
/// `set_desktop_origin` and `set_desktop_extent`. It is rebuilt on every output
/// change, because an incremental update is easier to get wrong.
#[derive(Clone, Debug, PartialEq)]
pub struct DesktopLayout {
    monitors: Vec<MonitorMapping>,
    origin: DesktopPoint,
    extent: DesktopExtent,
}

impl DesktopLayout {
    /// The bounding box over `monitors`.
    ///
    /// It takes mappings because they are non-empty, so [`Self::extent`] is never zero.
    ///
    /// # Errors
    ///
    /// [`MappingError::NoMonitors`] when the list is empty.
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

        // The union of non-empty mappings is non-empty, so this cannot fail.
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
    /// A monitor left of or above the primary one makes this negative.
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
    /// `None` covers both a dead zone and a position outside the box. It does not
    /// snap to the nearest monitor, because only the caller knows which it wants.
    /// A shared edge belongs to the monitor whose rectangle begins there.
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
    /// The monitor has a zero logical width or height.
    EmptyMonitor { geometry: LogicalGeometry },
    /// There are no monitors.
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
/// The edges use `i64` because a position plus a size can overflow `i32`.
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
        MonitorMapping::new(geometry(x, y, width, height)).expect("a monitor with an area")
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
        // The second is a 3840x2160 monitor at scale 2.
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
    fn a_hit_past_a_panels_edge_is_clamped_into_its_monitor() {
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
            MonitorMapping::new(geometry(0, 0, 1920, 0)),
            Err(MappingError::EmptyMonitor {
                geometry: geometry(0, 0, 1920, 0),
            }),
        );
        assert_eq!(
            MonitorMapping::new(geometry(0, 0, 0, 1080)),
            Err(MappingError::EmptyMonitor {
                geometry: geometry(0, 0, 0, 1080),
            }),
        );
    }

    #[test]
    fn a_desktop_of_only_an_empty_monitor_has_no_extent() {
        let usable: Vec<MonitorMapping> = [geometry(0, 0, 1920, 0)]
            .into_iter()
            .filter_map(|geometry| MonitorMapping::new(geometry).ok())
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
        let second = mapping(1920, 0, 1920, 1080);
        let desktop = layout([mapping(0, 0, 1920, 1080), second]);

        let landed = second.map(PanelPoint::new(0.25, 0.5));

        assert_eq!(landed, DesktopPoint::new(2400.0, 540.0));
        assert_eq!(desktop.monitor_at(landed), Some(&second));
    }
}
