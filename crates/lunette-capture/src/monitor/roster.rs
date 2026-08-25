//! The monitors currently attached, with their identities resolved against one
//! another.
//!
//! Identity is decided here rather than by each monitor alone, because the two
//! things that can go wrong are both properties of the set: two monitors of the
//! same model report the same descriptor, and a monitor with neither a
//! descriptor nor a connector has nothing left but where it sits.
//!
//! Pure over plain data. Nothing here touches the portal, PipeWire, or a
//! display, so the whole of it is exercised directly by the tests below.

use std::cmp::Ordering;

use tracing::warn;

use crate::monitor::{
    geometry::{LogicalGeometry, LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
    name::{MonitorKey, MonitorName},
};

/// What a source knows about one monitor before its identity is resolved.
///
/// A parameter struct rather than four positional arguments, because three of
/// the four are sizes and positions that a caller can transpose silently.
#[derive(Clone, Debug)]
pub struct MonitorReport {
    pub name: MonitorName,
    pub geometry: LogicalGeometry,
    pub pixels: PixelExtent,
    /// Which way up the panel is, from `wl_output.geometry`. A monitor whose
    /// source cannot report one is [`SurfaceTransform::Normal`], which is what
    /// the protocol's own default means.
    pub transform: SurfaceTransform,
}

/// One attached monitor, as the rest of lunette refers to it.
#[derive(Clone, Debug)]
pub struct Monitor {
    name: MonitorName,
    geometry: LogicalGeometry,
    pixels: PixelExtent,
    transform: SurfaceTransform,
    key: MonitorKey,
}

impl Monitor {
    #[must_use]
    pub const fn name(&self) -> &MonitorName {
        &self.name
    }

    /// Where the monitor sits and how large it is, in logical coordinates.
    ///
    /// This is what a ScreenCast stream is correlated against: the portal
    /// reports each stream's `position` and `size` in the same space.
    #[must_use]
    pub const fn geometry(&self) -> LogicalGeometry {
        self.geometry
    }

    #[must_use]
    pub const fn position(&self) -> LogicalPosition {
        self.geometry.position
    }

    #[must_use]
    pub const fn size(&self) -> LogicalSize {
        self.geometry.size
    }

    /// The monitor's resolution, which is the size a captured frame arrives at.
    ///
    /// Zero on both axes for a monitor whose mode the source could not read.
    /// Reported rather than guessed from the logical size and a scale factor:
    /// the two are only related by an integer on an unscaled display.
    #[must_use]
    pub const fn pixels(&self) -> PixelExtent {
        self.pixels
    }

    /// Which way up the panel is, relative to the rectangle it occupies.
    ///
    /// What the pointer mapping needs on top of the geometry: the logical size
    /// already accounts for a rotation, and this says which corner of the
    /// mirrored panel is which corner of that rectangle.
    #[must_use]
    pub const fn transform(&self) -> SurfaceTransform {
        self.transform
    }

    /// How this monitor is recorded across restarts.
    #[must_use]
    pub const fn key(&self) -> &MonitorKey {
        &self.key
    }

    fn compare(&self, other: &Self) -> Ordering {
        self.name
            .compare(&other.name)
            .then_with(|| self.geometry.cmp(&other.geometry))
    }
}

/// Every monitor lunette can mirror.
#[derive(Clone, Debug, Default)]
pub struct Roster {
    monitors: Vec<Monitor>,
}

impl Roster {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            monitors: Vec::new(),
        }
    }

    /// Adds a monitor, resolving its identity against those already added.
    ///
    /// The check runs incrementally rather than over the finished set, so a
    /// monitor that appears while lunette is running is resolved the same way
    /// as one present at startup.
    ///
    /// Following niri (`src/backend/tty.rs:1050-1080`), a monitor whose
    /// descriptor another already carries is demoted to its connector: the
    /// earlier one keeps the descriptor and the later one loses it. lunette has
    /// no serial to separate them with, so this is commoner here than in niri
    /// rather than rarer.
    pub fn add(&mut self, report: MonitorReport) {
        let MonitorReport {
            name,
            geometry,
            pixels,
            transform,
        } = report;

        let name = if self.carries_descriptor_of(&name) {
            warn!(
                monitor = %name,
                "another monitor already reports this make and model, so this one is identified by its connector alone; \
                 a Wayland client cannot read a serial, so the two are otherwise indistinguishable",
            );
            name.demoted()
        } else {
            name
        };

        let key = MonitorKey::for_monitor(&name, geometry.position);
        if let MonitorKey::Position(position) = key {
            warn!(
                %position,
                "this monitor reports no make, model, or connector, so it is identified by where it sits; \
                 that identity will not survive the monitors being rearranged",
            );
        }

        self.monitors.push(Monitor {
            name,
            geometry,
            pixels,
            transform,
            key,
        });
    }

    /// The monitors in the order they were added.
    #[must_use]
    pub fn monitors(&self) -> &[Monitor] {
        &self.monitors
    }

    /// The monitors ordered by identity rather than by enumeration.
    ///
    /// `Niri::reposition_outputs` (`src/niri.rs:2700-2760`) sorts before
    /// assigning positions for the same reason: udev connector order is
    /// arbitrary, so an arrangement derived from enumeration order changes when
    /// the user replugs a cable and nothing else has.
    #[must_use]
    pub fn sorted(&self) -> Vec<&Monitor> {
        let mut sorted: Vec<&Monitor> = self.monitors.iter().collect();
        sorted.sort_by(|left, right| left.compare(right));
        sorted
    }

    /// The monitor a recorded key names, if it is attached.
    ///
    /// `None` covers the monitor that is absent at startup, which is ordinary
    /// rather than exceptional: the key stays recorded, and the monitor is
    /// found once it appears.
    #[must_use]
    pub fn find(&self, key: &MonitorKey) -> Option<&Monitor> {
        self.monitors
            .iter()
            .find(|monitor| key.identifies(&monitor.name, monitor.geometry.position))
    }

    fn carries_descriptor_of(&self, name: &MonitorName) -> bool {
        let Some(descriptor) = name.descriptor() else {
            return false;
        };
        self.monitors
            .iter()
            .any(|monitor| monitor.name.matches(descriptor.as_str()))
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
    use crate::monitor::name::{ConnectorKind, ConnectorName, KeyStrength};

    fn named(connector: Option<&str>, make: Option<&str>, model: Option<&str>) -> MonitorName {
        MonitorName::new(
            connector.and_then(ConnectorName::parse),
            make.map(str::to_owned),
            model.map(str::to_owned),
        )
    }

    /// A monitor's geometry: a 1920-wide panel whose left edge is at `x`.
    fn at(x: i32) -> LogicalGeometry {
        LogicalGeometry::new(origin(x), LogicalSize::new(1920, 1080))
    }

    fn origin(x: i32) -> LogicalPosition {
        LogicalPosition::new(x, 0)
    }

    /// A resolution the identity rules do not depend on.
    ///
    /// Identity is decided from the name and the position alone, so every
    /// monitor here reports the same mode; a test that cared would say so.
    fn resolution() -> PixelExtent {
        PixelExtent::new(1920, 1080)
    }

    /// An unrotated monitor, which is what every identity test is about.
    fn report(name: MonitorName, geometry: LogicalGeometry) -> MonitorReport {
        MonitorReport {
            name,
            geometry,
            pixels: resolution(),
            transform: SurfaceTransform::Normal,
        }
    }

    fn keys(roster: &Roster) -> Vec<MonitorKey> {
        roster
            .monitors()
            .iter()
            .map(|monitor| monitor.key().clone())
            .collect()
    }

    #[test]
    fn a_monitor_reporting_no_make_or_model_is_identified_by_its_connector() {
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), None, None), at(0)));

        assert_eq!(
            keys(&roster),
            vec![MonitorKey::Connector(ConnectorName::new(
                ConnectorKind::DisplayPort,
                1,
            ))],
        );
    }

    #[test]
    fn two_identical_monitors_are_separated_by_their_connectors() {
        let mut roster = Roster::new();
        roster.add(report(
            named(Some("DP-1"), Some("Acme"), Some("X24")),
            at(0),
        ));
        roster.add(report(
            named(Some("DP-2"), Some("Acme"), Some("X24")),
            at(1920),
        ));

        let keys = keys(&roster);
        assert_eq!(keys[0].strength(), KeyStrength::Descriptor);
        assert_eq!(
            keys[1],
            MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 2)),
        );
        assert_ne!(keys[0], keys[1]);
    }

    #[test]
    fn the_earlier_of_two_identical_monitors_keeps_the_descriptor() {
        let mut roster = Roster::new();
        roster.add(report(
            named(Some("DP-1"), Some("Acme"), Some("X24")),
            at(0),
        ));
        roster.add(report(
            named(Some("DP-2"), Some("Acme"), Some("X24")),
            at(1920),
        ));

        let monitors = roster.monitors();
        assert!(monitors[0].name().descriptor().is_some());
        assert!(monitors[1].name().descriptor().is_none());
    }

    #[test]
    fn a_descriptor_key_reaches_exactly_one_of_two_identical_monitors() {
        let mut roster = Roster::new();
        roster.add(report(
            named(Some("DP-1"), Some("Acme"), Some("X24")),
            at(0),
        ));
        roster.add(report(
            named(Some("DP-2"), Some("Acme"), Some("X24")),
            at(1920),
        ));

        let found = roster
            .find(&keys(&roster)[0])
            .map(|monitor| monitor.position());

        assert_eq!(found, Some(origin(0)));
    }

    #[test]
    fn a_third_identical_monitor_is_demoted_against_the_first() {
        // The check is incremental, so it has to compare against every monitor
        // already added rather than only the previous one.
        let mut roster = Roster::new();
        roster.add(report(
            named(Some("DP-1"), Some("Acme"), Some("X24")),
            at(0),
        ));
        roster.add(report(
            named(Some("DP-2"), Some("Acme"), Some("X24")),
            at(1920),
        ));
        roster.add(report(
            named(Some("DP-3"), Some("Acme"), Some("X24")),
            at(3840),
        ));

        assert_eq!(
            keys(&roster)[2],
            MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 3)),
        );
    }

    #[test]
    fn two_identical_monitors_with_no_connectors_fall_back_to_position() {
        // GNOME or KDE, whose portal backends supply no usable connector name.
        let mut roster = Roster::new();
        roster.add(report(named(None, Some("Acme"), Some("X24")), at(0)));
        roster.add(report(named(None, Some("Acme"), Some("X24")), at(1920)));

        let keys = keys(&roster);
        assert_eq!(keys[0].strength(), KeyStrength::Descriptor);
        assert_eq!(keys[1], MonitorKey::Position(origin(1920)));
    }

    #[test]
    fn a_monitor_reporting_nothing_at_all_is_identified_by_position() {
        let mut roster = Roster::new();
        roster.add(report(named(None, None, None), at(1920)));

        assert_eq!(keys(&roster), vec![MonitorKey::Position(origin(1920))]);
    }

    #[test]
    fn a_recorded_key_finds_its_monitor_after_the_connector_changes() {
        let recorded = {
            let mut roster = Roster::new();
            roster.add(report(
                named(Some("DP-1"), Some("Acme"), Some("X24")),
                at(0),
            ));
            keys(&roster)[0].clone()
        };

        let mut after_reboot = Roster::new();
        after_reboot.add(report(
            named(Some("HDMI-A-2"), Some("Acme"), Some("X24")),
            at(1920),
        ));

        assert!(after_reboot.find(&recorded).is_some());
    }

    #[test]
    fn a_recorded_key_finds_nothing_until_its_monitor_appears() {
        let recorded = MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 1));
        let mut roster = Roster::new();

        assert!(roster.find(&recorded).is_none());

        roster.add(report(named(Some("DP-1"), None, None), at(0)));

        assert!(roster.find(&recorded).is_some());
    }

    #[test]
    fn a_key_recorded_before_the_monitor_reported_a_descriptor_upgrades_on_reattach() {
        let recorded = MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 1));
        let mut roster = Roster::new();
        roster.add(report(
            named(Some("DP-1"), Some("Acme"), Some("X24")),
            at(0),
        ));

        let monitor = roster.find(&recorded).expect("the monitor is attached");
        let upgraded = recorded.upgraded(monitor.name(), monitor.position());

        assert_eq!(upgraded, Some(monitor.key().clone()));
    }

    #[test]
    fn the_sorted_order_does_not_depend_on_the_order_monitors_were_added() {
        let arrangement = |order: [(&str, &str); 3]| {
            let mut roster = Roster::new();
            for (connector, model) in order {
                roster.add(report(
                    named(Some(connector), Some("Acme"), Some(model)),
                    at(0),
                ));
            }
            roster
                .sorted()
                .iter()
                .map(|monitor| monitor.name().to_string())
                .collect::<Vec<_>>()
        };

        assert_eq!(
            arrangement([("DP-1", "A1"), ("HDMI-A-1", "B2"), ("eDP-1", "C3")]),
            arrangement([("eDP-1", "C3"), ("DP-1", "A1"), ("HDMI-A-1", "B2")]),
        );
    }

    #[test]
    fn monitors_sort_by_descriptor_rather_than_by_connector() {
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), Some("Acme"), Some("Z9")), at(0)));
        roster.add(report(
            named(Some("DP-2"), Some("Acme"), Some("A1")),
            at(1920),
        ));

        let order: Vec<String> = roster
            .sorted()
            .iter()
            .map(|monitor| monitor.name().to_string())
            .collect();

        assert_eq!(order, vec!["Acme A1 on DP-2", "Acme Z9 on DP-1"]);
    }

    #[test]
    fn a_rotated_monitor_keeps_its_transform_through_the_roster() {
        // The regression: the roster carried no transform at all, so a
        // portrait-mounted monitor reached the pointer mapping as though it were
        // upright and every hit landed in the wrong corner.
        let mut roster = Roster::new();
        roster.add(MonitorReport {
            name: named(Some("DP-1"), Some("Acme"), Some("X24")),
            geometry: LogicalGeometry::new(origin(0), LogicalSize::new(1080, 1920)),
            pixels: resolution(),
            transform: SurfaceTransform::Rotate90,
        });

        assert_eq!(roster.monitors()[0].transform(), SurfaceTransform::Rotate90,);
    }

    #[test]
    fn a_demoted_monitor_keeps_its_transform() {
        // Demotion rewrites the name and must not disturb anything else.
        let mut roster = Roster::new();
        roster.add(report(
            named(Some("DP-1"), Some("Acme"), Some("X24")),
            at(0),
        ));
        roster.add(MonitorReport {
            name: named(Some("DP-2"), Some("Acme"), Some("X24")),
            geometry: at(1920),
            pixels: resolution(),
            transform: SurfaceTransform::Flipped180,
        });

        assert_eq!(
            roster.monitors()[1].transform(),
            SurfaceTransform::Flipped180,
        );
    }

    #[test]
    fn an_empty_roster_sorts_to_nothing() {
        assert!(Roster::new().sorted().is_empty());
    }
}
