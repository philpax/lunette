//! Which physical monitor a mirror belongs to.
//!
//! A Wayland client receives a monitor's make and model from `wl_output.geometry`
//! but cannot read its serial. The resulting identity is weaker than a
//! compositor's, so identical monitors of the same model share a descriptor.
//! [`crate::monitor::Roster`] resolves that ambiguity.
//!
//! [`MonitorName`] deliberately has no [`PartialEq`]. Identity is decided by
//! [`MonitorName::matches`], while [`MonitorName::compare`] orders names for
//! presentation without making structural comparison an identity operation.

use std::{cmp::Ordering, fmt};

use lunette_luau::closed_set;
use serde::{Deserialize, Deserializer, Serialize, Serializer, de::Error as _};

use crate::monitor::geometry::LogicalPosition;

closed_set! {
    /// A DRM connector's type, as the kernel names it.
    ///
    /// A closed set rather than a string: parsing against the kernel's connector
    /// kinds separates a real connector name from an opaque output identifier.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum ConnectorKind {
        Unknown = "Unknown",
        Vga = "VGA",
        DviI = "DVI-I",
        DviD = "DVI-D",
        DviA = "DVI-A",
        Composite = "Composite",
        SVideo = "SVIDEO",
        Lvds = "LVDS",
        Component = "Component",
        Din = "DIN",
        DisplayPort = "DP",
        HdmiA = "HDMI-A",
        HdmiB = "HDMI-B",
        Tv = "TV",
        EmbeddedDisplayPort = "eDP",
        Virtual = "Virtual",
        Dsi = "DSI",
        Dpi = "DPI",
        Writeback = "Writeback",
        Spi = "SPI",
        Usb = "USB",
    }
}

impl ConnectorKind {
    fn from_type_name(name: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|kind| kind.as_str().eq_ignore_ascii_case(name))
    }
}

/// A DRM connector name, such as `DP-1` or `HDMI-A-2`.
///
/// Parsed rather than stored as text, so `dp-01` and `DP-1` are one identity,
/// while a string that is not a connector name cannot become one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ConnectorName {
    kind: ConnectorKind,
    index: u32,
}

impl ConnectorName {
    #[must_use]
    pub const fn new(kind: ConnectorKind, index: u32) -> Self {
        Self { kind, index }
    }

    /// Reads a connector name, or `None` if the text is not one.
    ///
    /// The source may provide a connector name or no value. The shape check
    /// rejects opaque identifiers whose final group happens to contain only digits
    /// by matching the connector type against the closed list of kernel connector
    /// kinds.
    #[must_use]
    pub fn parse(text: &str) -> Option<Self> {
        let (type_name, index) = text.rsplit_once('-')?;
        if index.is_empty() || !index.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        Some(Self {
            kind: ConnectorKind::from_type_name(type_name)?,
            index: index.parse().ok()?,
        })
    }

    #[must_use]
    pub const fn kind(self) -> ConnectorKind {
        self.kind
    }

    #[must_use]
    pub const fn index(self) -> u32 {
        self.index
    }
}

impl fmt::Display for ConnectorName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}-{}", self.kind, self.index)
    }
}

/// Persisted as the name the kernel prints, such as `DP-1`.
///
/// Writes the connector's printed name rather than variant and index numbers, so
/// adding a [`ConnectorKind`] variant cannot silently renumber keys on disk.
impl Serialize for ConnectorName {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for ConnectorName {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::parse(&text)
            .ok_or_else(|| D::Error::custom(format!("{text:?} is not a DRM connector name")))
    }
}

/// A monitor's make and model, rendered as one string.
///
/// Uses the `"{make} {model}"` form with `Unknown` substituted for an absent
/// field. A monitor that reports only one of the two fields still has a
/// descriptor.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Descriptor(String);

impl Descriptor {
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    fn matches(&self, target: &str) -> bool {
        self.0.eq_ignore_ascii_case(target)
    }
}

impl fmt::Display for Descriptor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Everything lunette knows about which monitor a mirror belongs to.
///
/// The connector is optional because the host compositor may report no usable
/// connector name.
#[derive(Clone, Debug)]
pub struct MonitorName {
    connector: Option<ConnectorName>,
    make: Option<String>,
    model: Option<String>,
}

impl MonitorName {
    /// `make` and `model` come from `wl_output.geometry`. `connector` comes from
    /// `wl_output.name` after passing [`ConnectorName::parse`].
    #[must_use]
    pub fn new(
        connector: Option<ConnectorName>,
        make: Option<String>,
        model: Option<String>,
    ) -> Self {
        Self {
            connector,
            make: meaningful(make),
            model: meaningful(model),
        }
    }

    #[must_use]
    pub const fn connector(&self) -> Option<ConnectorName> {
        self.connector
    }

    #[must_use]
    pub fn make(&self) -> Option<&str> {
        self.make.as_deref()
    }

    #[must_use]
    pub fn model(&self) -> Option<&str> {
        self.model.as_deref()
    }

    /// The make and model as one string, or `None` when the monitor reported
    /// neither.
    #[must_use]
    pub fn descriptor(&self) -> Option<Descriptor> {
        if self.make.is_none() && self.model.is_none() {
            return None;
        }
        let make = self.make.as_deref().unwrap_or(UNKNOWN_FIELD);
        let model = self.model.as_deref().unwrap_or(UNKNOWN_FIELD);
        Some(Descriptor(format!("{make} {model}")))
    }

    /// Whether `target` names this monitor.
    ///
    /// The connector is more specific than the descriptor and wins when both
    /// match. Both comparisons ignore ASCII case. A shared descriptor matches
    /// both monitors; [`crate::monitor::Roster`] demotes the later one so that at
    /// most one monitor carries a given descriptor.
    #[must_use]
    pub fn matches(&self, target: &str) -> bool {
        if self.connector.is_some() && ConnectorName::parse(target) == self.connector {
            return true;
        }
        self.descriptor()
            .is_some_and(|descriptor| descriptor.matches(target))
    }

    /// The strongest key this name can produce on its own.
    ///
    /// The descriptor is preferred because it survives the monitor moving to a
    /// different port. The connector is the fallback when no descriptor exists;
    /// [`MonitorKey::for_monitor`] uses the position when neither exists.
    #[must_use]
    pub fn descriptor_or_connector(&self) -> Option<MonitorKey> {
        if let Some(descriptor) = self.descriptor() {
            return Some(MonitorKey::Descriptor(descriptor));
        }
        self.connector.map(MonitorKey::Connector)
    }

    /// Removes the descriptor so a duplicate can be identified by its connector
    /// or position.
    #[must_use]
    pub fn demoted(&self) -> Self {
        Self {
            connector: self.connector,
            make: None,
            model: None,
        }
    }

    /// A total order over names, for arranging monitors independently of the
    /// order they were enumerated in.
    ///
    /// This method is for presentation only; use [`Self::matches`] to decide
    /// identity. Keeping ordering separate from equality prevents structural
    /// comparison from being used as identity.
    ///
    /// Names without a descriptor sort after names with one, so named monitors
    /// appear first.
    #[must_use]
    pub fn compare(&self, other: &Self) -> Ordering {
        absent_last(self.descriptor(), other.descriptor())
            .then_with(|| absent_last(self.connector, other.connector))
    }
}

impl fmt::Display for MonitorName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (self.descriptor(), self.connector) {
            (Some(descriptor), Some(connector)) => write!(f, "{descriptor} on {connector}"),
            (Some(descriptor), None) => write!(f, "{descriptor}"),
            (None, Some(connector)) => write!(f, "{connector}"),
            (None, None) => f.write_str("an unidentified monitor"),
        }
    }
}

/// How a monitor is recorded across restarts.
///
/// The three key forms are distinct and ordered by the information they retain.
/// [`Self::strength`] compares them, and [`Self::upgraded`] promotes a stored key
/// when stronger information becomes available.
///
/// [`fmt::Display`] is for logs and is not parseable. Persistence uses the
/// externally tagged enum representation, so the variant remains part of the
/// stored key.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
pub enum MonitorKey {
    /// Make and model. Survives the monitor moving to a different port.
    Descriptor(Descriptor),
    /// A DRM connector name. Survives a monitor reporting no EDID make or
    /// model, but not a replug into a different port.
    Connector(ConnectorName),
    /// Where the monitor sits. Survives neither, and is recorded only when
    /// nothing else is available.
    Position(LogicalPosition),
}

/// How much a [`MonitorKey`] survives, in increasing order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum KeyStrength {
    Positional,
    Connector,
    Descriptor,
}

impl MonitorKey {
    /// The key to record for a monitor, preferring its descriptor, then its
    /// connector, and finally its position.
    ///
    /// A positional key is used only when no descriptor or connector is available,
    /// and does not survive the user rearranging monitors.
    #[must_use]
    pub fn for_monitor(name: &MonitorName, position: LogicalPosition) -> Self {
        name.descriptor_or_connector()
            .unwrap_or(Self::Position(position))
    }

    #[must_use]
    pub const fn strength(&self) -> KeyStrength {
        match self {
            Self::Descriptor(_) => KeyStrength::Descriptor,
            Self::Connector(_) => KeyStrength::Connector,
            Self::Position(_) => KeyStrength::Positional,
        }
    }

    /// Whether this key names the given monitor.
    #[must_use]
    pub fn identifies(&self, name: &MonitorName, position: LogicalPosition) -> bool {
        match self {
            Self::Descriptor(descriptor) => name.matches(descriptor.as_str()),
            Self::Connector(connector) => name.matches(&connector.to_string()),
            Self::Position(stored) => *stored == position,
        }
    }

    /// A stronger key for the same monitor, if one is now available.
    ///
    /// The key must still identify the monitor before it is upgraded. Otherwise a
    /// positional key could be rewritten to name whichever monitor later occupies
    /// that position.
    #[must_use]
    pub fn upgraded(&self, name: &MonitorName, position: LogicalPosition) -> Option<Self> {
        if !self.identifies(name, position) {
            return None;
        }
        let candidate = Self::for_monitor(name, position);
        (candidate.strength() > self.strength()).then_some(candidate)
    }
}

impl fmt::Display for MonitorKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Descriptor(descriptor) => write!(f, "{descriptor}"),
            Self::Connector(connector) => write!(f, "{connector}"),
            Self::Position(position) => write!(f, "the monitor at {position}"),
        }
    }
}

const UNKNOWN_FIELD: &str = "Unknown";

fn absent_last<T: Ord>(left: Option<T>, right: Option<T>) -> Ordering {
    match (left, right) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn meaningful(field: Option<String>) -> Option<String> {
    let field = field?;
    let trimmed = field.trim();
    if trimmed.is_empty() || trimmed.eq_ignore_ascii_case(UNKNOWN_FIELD) {
        return None;
    }
    Some(trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn connector(text: &str) -> Option<ConnectorName> {
        ConnectorName::parse(text)
    }

    fn named(connector_text: Option<&str>, make: Option<&str>, model: Option<&str>) -> MonitorName {
        MonitorName::new(
            connector_text.and_then(connector),
            make.map(str::to_owned),
            model.map(str::to_owned),
        )
    }

    #[test]
    fn every_connector_kind_parses_back_from_its_printed_name() {
        for &kind in ConnectorKind::ALL {
            assert_eq!(
                ConnectorName::parse(&format!("{kind}-3")),
                Some(ConnectorName::new(kind, 3)),
                "{kind} did not round-trip",
            );
        }
    }

    #[test]
    fn no_two_connector_kinds_share_a_printed_name() {
        let mut names: Vec<&str> = ConnectorKind::ALL
            .iter()
            .map(|kind| kind.as_str())
            .collect();
        names.sort_unstable();
        let count = names.len();
        names.dedup();

        assert_eq!(names.len(), count);
    }

    #[test]
    fn a_connector_name_with_an_interior_hyphen_parses() {
        assert_eq!(
            ConnectorName::parse("HDMI-A-2"),
            Some(ConnectorName::new(ConnectorKind::HdmiA, 2)),
        );
    }

    #[test]
    fn connector_names_ignore_case_and_leading_zeroes() {
        assert_eq!(ConnectorName::parse("dp-01"), ConnectorName::parse("DP-1"));
    }

    #[test]
    fn a_uuid_shaped_mapping_id_is_not_a_connector_name() {
        assert_eq!(
            ConnectorName::parse("1b4e28ba-2fa1-11d2-883f-0016d3cca427"),
            None,
        );
    }

    #[test]
    fn a_uuid_whose_last_group_is_all_digits_is_not_a_connector_name() {
        // A UUID can end in an all-digit group, so a numeric suffix alone is
        // insufficient.
        assert_eq!(
            ConnectorName::parse("1b4e28ba-2fa1-11d2-883f-001633000000"),
            None,
        );
    }

    #[test]
    fn text_that_is_not_a_connector_name_is_rejected() {
        assert_eq!(ConnectorName::parse(""), None);
        assert_eq!(ConnectorName::parse("DP"), None);
        assert_eq!(ConnectorName::parse("DP-"), None);
        assert_eq!(ConnectorName::parse("DP-x"), None);
        assert_eq!(ConnectorName::parse("DP-+1"), None);
        assert_eq!(ConnectorName::parse("Nonsense-1"), None);
    }

    #[test]
    fn a_descriptor_substitutes_unknown_for_a_field_the_monitor_did_not_report() {
        let name = named(None, Some("Acme"), None);

        assert_eq!(
            name.descriptor().map(|descriptor| descriptor.to_string()),
            Some("Acme Unknown".to_owned()),
        );
    }

    #[test]
    fn a_monitor_reporting_neither_make_nor_model_has_no_descriptor() {
        assert!(named(Some("DP-1"), None, None).descriptor().is_none());
    }

    #[test]
    fn a_make_of_unknown_is_treated_as_absent() {
        // Treating `unknown` as a value would give monitors with absent EDID
        // fields a shared descriptor.
        let name = named(Some("DP-1"), Some("unknown"), Some("  "));

        assert_eq!(name.make(), None);
        assert_eq!(name.model(), None);
        assert!(name.descriptor().is_none());
    }

    #[test]
    fn a_connector_target_reaches_only_the_monitor_on_that_connector() {
        let first = named(Some("DP-1"), Some("Acme"), Some("X24"));
        let second = named(Some("DP-2"), Some("Acme"), Some("X24"));

        assert!(first.matches("DP-1"));
        assert!(!second.matches("DP-1"));
    }

    #[test]
    fn a_shared_descriptor_reaches_both_monitors_until_one_is_demoted() {
        let first = named(Some("DP-1"), Some("Acme"), Some("X24"));
        let second = named(Some("DP-2"), Some("Acme"), Some("X24"));

        assert!(first.matches("Acme X24"));
        assert!(second.matches("Acme X24"));
        assert!(!second.demoted().matches("Acme X24"));
    }

    #[test]
    fn a_monitor_without_a_connector_matches_on_its_descriptor() {
        assert!(named(None, Some("Acme"), Some("X24")).matches("Acme X24"));
    }

    #[test]
    fn matching_ignores_case_on_both_paths() {
        assert!(named(Some("DP-1"), None, None).matches("dp-1"));
        assert!(named(None, Some("Acme"), Some("X24")).matches("acme x24"));
    }

    #[test]
    fn a_name_carrying_nothing_matches_nothing() {
        let name = named(None, None, None);

        assert!(!name.matches(""));
        assert!(!name.matches("Acme X24"));
    }

    #[test]
    fn a_key_prefers_the_descriptor_then_the_connector_then_the_position() {
        let position = LogicalPosition::new(1920, 0);

        assert_eq!(
            MonitorKey::for_monitor(&named(Some("DP-1"), Some("Acme"), Some("X24")), position)
                .strength(),
            KeyStrength::Descriptor,
        );
        assert_eq!(
            MonitorKey::for_monitor(&named(Some("DP-1"), None, None), position).strength(),
            KeyStrength::Connector,
        );
        assert_eq!(
            MonitorKey::for_monitor(&named(None, None, None), position),
            MonitorKey::Position(position),
        );
    }

    #[test]
    fn a_connector_key_upgrades_to_a_descriptor_once_the_monitor_reports_one() {
        let position = LogicalPosition::new(0, 0);
        let stored = MonitorKey::for_monitor(&named(Some("DP-1"), None, None), position);
        let reattached = named(Some("DP-1"), Some("Acme"), Some("X24"));

        assert_eq!(
            stored.upgraded(&reattached, position),
            reattached.descriptor().map(MonitorKey::Descriptor),
        );
    }

    #[test]
    fn a_positional_key_upgrades_once_a_connector_appears() {
        let position = LogicalPosition::new(1920, 0);
        let stored = MonitorKey::Position(position);

        assert_eq!(
            stored.upgraded(&named(Some("DP-1"), None, None), position),
            Some(MonitorKey::Connector(ConnectorName::new(
                ConnectorKind::DisplayPort,
                1,
            ))),
        );
    }

    #[test]
    fn a_key_does_not_upgrade_from_a_monitor_it_does_not_identify() {
        let stored = MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 1));
        let other = named(Some("DP-2"), Some("Acme"), Some("X24"));

        assert_eq!(stored.upgraded(&other, LogicalPosition::new(0, 0)), None);
    }

    #[test]
    fn a_positional_key_does_not_upgrade_from_whatever_moved_into_that_position() {
        let stored = MonitorKey::Position(LogicalPosition::new(0, 0));
        let elsewhere = named(Some("DP-1"), None, None);

        assert_eq!(
            stored.upgraded(&elsewhere, LogicalPosition::new(1920, 0)),
            None
        );
    }

    #[test]
    fn a_descriptor_key_has_nothing_to_upgrade_to() {
        let position = LogicalPosition::new(0, 0);
        let name = named(Some("DP-1"), Some("Acme"), Some("X24"));
        let stored = MonitorKey::for_monitor(&name, position);

        assert_eq!(stored.upgraded(&name, position), None);
    }

    #[test]
    fn a_descriptor_key_survives_the_connector_changing_between_boots() {
        // A replug can change connector order, so the same monitor can receive a
        // different connector name.
        let stored = MonitorKey::for_monitor(
            &named(Some("DP-1"), Some("Acme"), Some("X24")),
            LogicalPosition::new(0, 0),
        );
        let after_replug = named(Some("HDMI-A-2"), Some("Acme"), Some("X24"));

        assert!(stored.identifies(&after_replug, LogicalPosition::new(1920, 0)));
    }

    #[test]
    fn names_order_by_descriptor_before_connector() {
        let first = named(Some("HDMI-A-1"), Some("Acme"), Some("A1"));
        let second = named(Some("DP-1"), Some("Acme"), Some("B2"));

        assert_eq!(first.compare(&second), Ordering::Less);
        assert_eq!(second.compare(&first), Ordering::Greater);
    }

    #[test]
    fn names_sharing_a_descriptor_order_by_connector() {
        let first = named(Some("DP-1"), Some("Acme"), Some("X24"));
        let second = named(Some("DP-2"), Some("Acme"), Some("X24"));

        assert_eq!(first.compare(&second), Ordering::Less);
    }

    #[test]
    fn a_name_with_no_descriptor_orders_after_one_that_has_one() {
        let described = named(Some("DP-1"), Some("Acme"), Some("X24"));
        let bare = named(Some("DP-2"), None, None);

        assert_eq!(described.compare(&bare), Ordering::Less);
    }

    #[test]
    fn demoting_a_name_leaves_only_its_connector() {
        let demoted = named(Some("DP-1"), Some("Acme"), Some("X24")).demoted();

        assert!(demoted.descriptor().is_none());
        assert_eq!(demoted.connector(), connector("DP-1"));
        assert!(demoted.matches("DP-1"));
        assert!(!demoted.matches("Acme X24"));
    }
}
