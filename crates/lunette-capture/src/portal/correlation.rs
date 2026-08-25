//! Correlates granted portal streams with the attached monitors.
//!
//! Portal backends do not consistently provide connector names, so positional
//! geometry in the compositor's logical space is the portable fallback. A size
//! mismatch remains valid when a backend reports physical pixels for a scaled
//! output.
//!
//! Matching does not depend on response order. Connector matches take precedence
//! over positional matches, and ambiguous positional matches remain unmatched.

use std::{collections::BTreeMap, fmt};

use crate::{
    monitor::{
        geometry::LogicalPosition,
        name::MonitorKey,
        roster::{Monitor, Roster},
    },
    portal::{NodeId, PortalStream},
};

/// Matches each granted stream to the monitor it shows.
///
/// The result reports successful matches, unsuccessful matches, and monitors
/// with no corresponding stream.
#[must_use]
pub fn correlate(streams: &[PortalStream], roster: &Roster) -> Correlation {
    let mut claims = Claims::new(roster);

    // A stable node order makes connector contention independent of response order.
    let mut ordered: Vec<&PortalStream> = streams.iter().collect();
    ordered.sort_by_key(|stream| stream.node);

    for stream in ordered {
        claims.claim_by_connector(stream);
    }
    claims.claim_by_position(streams);

    claims.finish(streams)
}

/// The outcome of tying a portal response's streams to the attached monitors.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Correlation {
    /// One entry per matched stream, ordered by node identifier.
    pub matched: Vec<StreamMatch>,
    /// Streams that found no monitor, with the reason for each.
    pub unmatched: Vec<Unmatched>,
    /// Monitors that no stream showed, in roster order. This is expected when
    /// the user selected only some of their monitors, and diagnostic when they
    /// selected all of them.
    pub unmirrored: Vec<MonitorKey>,
}

/// A stream and the monitor it shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamMatch {
    pub node: NodeId,
    pub monitor: MonitorKey,
    pub strength: MatchStrength,
}

/// The evidence used to match a stream to a monitor, strongest first.
///
/// Recording positional matches identifies sessions whose mirrors may change if
/// a monitor moves.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum MatchStrength {
    /// The stream's `mapping_id` was a connector name for this monitor.
    Connector,
    /// The stream's position and size agree with the monitor's.
    PositionAndSize,
    /// The stream's position agrees, but its size differs or is absent.
    ///
    /// A backend may report pixels instead of logical coordinates. The size
    /// difference then reflects display scaling, so it lowers confidence rather
    /// than rejecting the match.
    Position,
}

/// A stream that found no monitor, with the reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unmatched {
    pub node: NodeId,
    pub reason: NoMatch,
}

/// Why a stream could not be matched to a monitor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NoMatch {
    /// The stream reported neither a usable `mapping_id` nor a position.
    Featureless,
    /// No attached monitor occupies the stream's reported position.
    NoMonitorThere { position: LogicalPosition },
    /// Multiple streams or monitors share the position. Choosing one arbitrarily
    /// would make the result depend on enumeration order.
    Ambiguous {
        position: LogicalPosition,
        monitors: usize,
        streams: usize,
    },
    /// No attached monitor has the connector named by the stream.
    NoSuchConnector,
    /// Another stream already claimed the named monitor.
    AlreadyMirrored { monitor: MonitorKey },
}

impl fmt::Display for NoMatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Featureless => f.write_str(
                "the stream reported neither a connector name nor a position, so there is nothing \
                 to identify it by",
            ),
            Self::NoMonitorThere { position } => {
                write!(f, "no attached monitor sits at {position}")
            }
            Self::Ambiguous {
                position,
                monitors,
                streams,
            } => write!(
                f,
                "{streams} streams and {monitors} monitors share the position {position}, and \
                 nothing distinguishes them"
            ),
            Self::NoSuchConnector => {
                f.write_str("the stream named a connector no attached monitor carries")
            }
            Self::AlreadyMirrored { monitor } => {
                write!(f, "another stream already shows {monitor}")
            }
        }
    }
}

/// Tracks monitor claims and rejected matches.
struct Claims<'a> {
    monitors: &'a [Monitor],
    /// The node that claimed each monitor, indexed alongside `monitors`.
    claimed_by: Vec<Option<NodeId>>,
    /// The monitor each node claimed and the strength of the match.
    taken: BTreeMap<NodeId, (usize, MatchStrength)>,
    /// Rejected nodes and their reasons.
    refused: BTreeMap<NodeId, NoMatch>,
}

impl<'a> Claims<'a> {
    fn new(roster: &'a Roster) -> Self {
        let monitors = roster.monitors();
        Self {
            monitors,
            claimed_by: vec![None; monitors.len()],
            taken: BTreeMap::new(),
            refused: BTreeMap::new(),
        }
    }

    /// Claims the monitor named by the stream's connector, when available.
    fn claim_by_connector(&mut self, stream: &PortalStream) {
        let Some(connector) = stream.connector else {
            return;
        };
        let target = connector.to_string();

        let Some(index) = self
            .monitors
            .iter()
            .position(|monitor| monitor.name().matches(&target))
        else {
            self.refused.insert(stream.node, NoMatch::NoSuchConnector);
            return;
        };

        match self.claimed_by[index] {
            None => self.take(stream.node, index, MatchStrength::Connector),
            Some(_) => {
                self.refused.insert(
                    stream.node,
                    NoMatch::AlreadyMirrored {
                        monitor: self.monitors[index].key().clone(),
                    },
                );
            }
        }
    }

    /// Claims unique positional matches and rejects ambiguous positions.
    fn claim_by_position(&mut self, streams: &[PortalStream]) {
        let mut by_position: BTreeMap<(i32, i32), Vec<NodeId>> = BTreeMap::new();

        for stream in streams {
            if self.taken.contains_key(&stream.node) || self.refused.contains_key(&stream.node) {
                continue;
            }
            let Some(position) = stream.position else {
                self.refused.insert(stream.node, NoMatch::Featureless);
                continue;
            };
            by_position
                .entry((position.x, position.y))
                .or_default()
                .push(stream.node);
        }

        for ((x, y), nodes) in by_position {
            let position = LogicalPosition::new(x, y);
            let candidates = self.unclaimed_at(position);

            match (nodes.as_slice(), candidates.as_slice()) {
                ([node], [index]) => {
                    let strength = size_agrees(streams, *node, &self.monitors[*index]);
                    self.take(*node, *index, strength);
                }
                ([node], []) => {
                    self.refused
                        .insert(*node, NoMatch::NoMonitorThere { position });
                }
                _ => {
                    for node in &nodes {
                        self.refused.insert(
                            *node,
                            NoMatch::Ambiguous {
                                position,
                                monitors: candidates.len(),
                                streams: nodes.len(),
                            },
                        );
                    }
                }
            }
        }
    }

    fn unclaimed_at(&self, position: LogicalPosition) -> Vec<usize> {
        self.monitors
            .iter()
            .enumerate()
            .filter(|(index, monitor)| {
                self.claimed_by[*index].is_none() && monitor.position() == position
            })
            .map(|(index, _)| index)
            .collect()
    }

    fn take(&mut self, node: NodeId, index: usize, strength: MatchStrength) {
        self.claimed_by[index] = Some(node);
        self.taken.insert(node, (index, strength));
    }

    fn finish(self, streams: &[PortalStream]) -> Correlation {
        let matched: Vec<StreamMatch> = self
            .taken
            .iter()
            .map(|(node, (index, strength))| StreamMatch {
                node: *node,
                monitor: self.monitors[*index].key().clone(),
                strength: *strength,
            })
            .collect();

        let mut unmatched: Vec<Unmatched> = streams
            .iter()
            .filter(|stream| !self.taken.contains_key(&stream.node))
            .map(|stream| Unmatched {
                node: stream.node,
                reason: self
                    .refused
                    .get(&stream.node)
                    .cloned()
                    .unwrap_or(NoMatch::Featureless),
            })
            .collect();
        unmatched.sort_by_key(|entry| entry.node);
        unmatched.dedup_by_key(|entry| entry.node);

        let unmirrored = self
            .monitors
            .iter()
            .enumerate()
            .filter(|(index, _)| self.claimed_by[*index].is_none())
            .map(|(_, monitor)| monitor.key().clone())
            .collect();

        Correlation {
            matched,
            unmatched,
            unmirrored,
        }
    }
}

/// Whether the stream's reported size agrees with the monitor's logical size.
fn size_agrees(streams: &[PortalStream], node: NodeId, monitor: &Monitor) -> MatchStrength {
    let reported = streams
        .iter()
        .find(|stream| stream.node == node)
        .and_then(|stream| stream.size);

    match reported {
        Some(size) if size == monitor.size() => MatchStrength::PositionAndSize,
        _ => MatchStrength::Position,
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
    use crate::monitor::{
        geometry::{LogicalGeometry, LogicalSize, PixelExtent, SurfaceTransform},
        name::{ConnectorName, MonitorName},
        roster::MonitorReport,
    };

    fn node(raw: u32) -> NodeId {
        NodeId::new(raw).expect("a non-zero node identifier")
    }

    fn named(connector: Option<&str>, model: &str) -> MonitorName {
        MonitorName::new(
            connector.and_then(ConnectorName::parse),
            Some("Acme".to_owned()),
            Some(model.to_owned()),
        )
    }

    fn geometry(x: i32, width: u32) -> LogicalGeometry {
        LogicalGeometry::new(LogicalPosition::new(x, 0), LogicalSize::new(width, 1080))
    }

    /// Returns a display mode resolution that correlation does not use.
    fn resolution() -> PixelExtent {
        PixelExtent::new(1920, 1080)
    }

    /// Builds a report with the monitor's unrotated logical geometry.
    fn report(name: MonitorName, geometry: LogicalGeometry) -> MonitorReport {
        MonitorReport {
            name,
            geometry,
            pixels: resolution(),
            transform: SurfaceTransform::Normal,
        }
    }

    /// Two monitors with distinct logical positions.
    fn two_monitors() -> Roster {
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), "Left"), geometry(0, 1920)));
        roster.add(report(
            named(Some("HDMI-A-1"), "Right"),
            geometry(1920, 1920),
        ));
        roster
    }

    fn stream(raw: u32, x: Option<i32>, width: Option<u32>) -> PortalStream {
        PortalStream {
            node: node(raw),
            position: x.map(|x| LogicalPosition::new(x, 0)),
            size: width.map(|width| LogicalSize::new(width, 1080)),
            connector: None,
        }
    }

    fn matched(correlation: &Correlation) -> Vec<(u32, String, MatchStrength)> {
        correlation
            .matched
            .iter()
            .map(|entry| (entry.node.get(), entry.monitor.to_string(), entry.strength))
            .collect()
    }

    #[test]
    fn two_streams_reach_the_monitors_their_geometry_names() {
        let correlation = correlate(
            &[
                stream(7, Some(1920), Some(1920)),
                stream(3, Some(0), Some(1920)),
            ],
            &two_monitors(),
        );

        assert_eq!(
            matched(&correlation),
            vec![
                (3, "Acme Left".to_owned(), MatchStrength::PositionAndSize),
                (7, "Acme Right".to_owned(), MatchStrength::PositionAndSize),
            ],
        );
        assert!(correlation.unmatched.is_empty());
        assert!(correlation.unmirrored.is_empty());
    }

    #[test]
    fn the_answer_does_not_depend_on_the_order_the_portal_listed_the_streams_in() {
        let forwards = [
            stream(3, Some(0), Some(1920)),
            stream(7, Some(1920), Some(1920)),
        ];
        let backwards = [forwards[1].clone(), forwards[0].clone()];

        assert_eq!(
            correlate(&forwards, &two_monitors()),
            correlate(&backwards, &two_monitors()),
        );
    }

    #[test]
    fn a_connector_name_beats_the_geometry_of_a_stream_that_sits_elsewhere() {
        let mut stream = stream(3, Some(1920), Some(1920));
        stream.connector = ConnectorName::parse("DP-1");

        let correlation = correlate(&[stream], &two_monitors());

        assert_eq!(
            matched(&correlation),
            vec![(3, "Acme Left".to_owned(), MatchStrength::Connector)],
        );
    }

    #[test]
    fn a_stream_naming_a_connector_no_monitor_carries_is_reported() {
        let mut stream = stream(3, None, None);
        stream.connector = ConnectorName::parse("DP-9");

        let correlation = correlate(&[stream], &two_monitors());

        assert!(correlation.matched.is_empty());
        assert_eq!(
            correlation.unmatched,
            vec![Unmatched {
                node: node(3),
                reason: NoMatch::NoSuchConnector,
            }],
        );
    }

    #[test]
    fn a_size_disagreement_lowers_the_confidence_rather_than_rejecting_the_match() {
        let correlation = correlate(&[stream(3, Some(0), Some(3840))], &two_monitors());

        assert_eq!(
            matched(&correlation),
            vec![(3, "Acme Left".to_owned(), MatchStrength::Position)],
        );
    }

    #[test]
    fn a_stream_reporting_no_size_still_matches_on_its_position() {
        let correlation = correlate(&[stream(3, Some(1920), None)], &two_monitors());

        assert_eq!(
            matched(&correlation),
            vec![(3, "Acme Right".to_owned(), MatchStrength::Position)],
        );
    }

    #[test]
    fn a_stream_carrying_neither_a_connector_nor_a_position_is_reported() {
        let correlation = correlate(&[stream(3, None, Some(1920))], &two_monitors());

        assert_eq!(
            correlation.unmatched,
            vec![Unmatched {
                node: node(3),
                reason: NoMatch::Featureless,
            }],
        );
    }

    #[test]
    fn a_stream_at_a_position_no_monitor_occupies_is_reported_rather_than_dropped() {
        let correlation = correlate(&[stream(3, Some(5000), Some(1920))], &two_monitors());

        assert!(correlation.matched.is_empty());
        assert_eq!(
            correlation.unmatched,
            vec![Unmatched {
                node: node(3),
                reason: NoMatch::NoMonitorThere {
                    position: LogicalPosition::new(5000, 0),
                },
            }],
        );
        assert_eq!(correlation.unmirrored.len(), 2);
    }

    #[test]
    fn two_monitors_stacked_at_one_position_leave_both_streams_ambiguous() {
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), "Left"), geometry(0, 1920)));
        roster.add(report(named(Some("HDMI-A-1"), "Right"), geometry(0, 1920)));

        let correlation = correlate(
            &[
                stream(3, Some(0), Some(1920)),
                stream(7, Some(0), Some(1920)),
            ],
            &roster,
        );

        assert!(correlation.matched.is_empty());
        assert_eq!(
            correlation.unmatched,
            vec![
                Unmatched {
                    node: node(3),
                    reason: NoMatch::Ambiguous {
                        position: LogicalPosition::new(0, 0),
                        monitors: 2,
                        streams: 2,
                    },
                },
                Unmatched {
                    node: node(7),
                    reason: NoMatch::Ambiguous {
                        position: LogicalPosition::new(0, 0),
                        monitors: 2,
                        streams: 2,
                    },
                },
            ],
        );
    }

    #[test]
    fn a_connector_match_frees_the_position_for_the_stream_that_is_left() {
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), "Left"), geometry(0, 1920)));
        roster.add(report(named(Some("HDMI-A-1"), "Right"), geometry(0, 1920)));

        let mut first = stream(3, Some(0), Some(1920));
        first.connector = ConnectorName::parse("DP-1");

        let correlation = correlate(&[first, stream(7, Some(0), Some(1920))], &roster);

        assert_eq!(
            matched(&correlation),
            vec![
                (3, "Acme Left".to_owned(), MatchStrength::Connector),
                (7, "Acme Right".to_owned(), MatchStrength::PositionAndSize),
            ],
        );
    }

    #[test]
    fn which_of_two_streams_naming_one_connector_wins_does_not_depend_on_portal_order() {
        let mut first = stream(3, None, None);
        first.connector = ConnectorName::parse("DP-1");
        let mut second = stream(7, None, None);
        second.connector = ConnectorName::parse("DP-1");

        let forwards = [first.clone(), second.clone()];
        let backwards = [second, first];

        assert_eq!(
            correlate(&forwards, &two_monitors()),
            correlate(&backwards, &two_monitors()),
        );
        assert_eq!(
            matched(&correlate(&backwards, &two_monitors())),
            vec![(3, "Acme Left".to_owned(), MatchStrength::Connector)],
            "the lower node identifier takes it, whichever order they arrived in",
        );
    }

    #[test]
    fn a_second_stream_naming_a_monitor_already_mirrored_is_reported() {
        let mut first = stream(3, None, None);
        first.connector = ConnectorName::parse("DP-1");
        let mut second = stream(7, None, None);
        second.connector = ConnectorName::parse("DP-1");

        let correlation = correlate(&[first, second], &two_monitors());

        assert_eq!(correlation.matched.len(), 1);
        assert_eq!(correlation.unmatched.len(), 1);
        assert!(matches!(
            correlation.unmatched[0].reason,
            NoMatch::AlreadyMirrored { .. }
        ));
    }

    #[test]
    fn the_monitors_no_stream_showed_are_named() {
        let correlation = correlate(&[stream(3, Some(0), Some(1920))], &two_monitors());

        assert_eq!(
            correlation
                .unmirrored
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
            vec!["Acme Right".to_owned()],
        );
    }

    #[test]
    fn no_streams_at_all_leaves_every_monitor_unmirrored() {
        let correlation = correlate(&[], &two_monitors());

        assert_eq!(correlation.matched, Vec::new());
        assert_eq!(correlation.unmatched, Vec::new());
        assert_eq!(correlation.unmirrored.len(), 2);
    }

    #[test]
    fn a_stream_against_an_empty_roster_is_reported_rather_than_dropped() {
        let correlation = correlate(&[stream(3, Some(0), Some(1920))], &Roster::new());

        assert_eq!(
            correlation.unmatched,
            vec![Unmatched {
                node: node(3),
                reason: NoMatch::NoMonitorThere {
                    position: LogicalPosition::new(0, 0),
                },
            }],
        );
    }

    #[test]
    fn every_stream_appears_in_exactly_one_half_of_the_answer() {
        let streams = [
            stream(3, Some(0), Some(1920)),
            stream(7, Some(5000), None),
            stream(11, None, None),
        ];
        let correlation = correlate(&streams, &two_monitors());

        let mut seen: Vec<u32> = correlation
            .matched
            .iter()
            .map(|entry| entry.node.get())
            .chain(correlation.unmatched.iter().map(|entry| entry.node.get()))
            .collect();
        seen.sort_unstable();

        assert_eq!(seen, vec![3, 7, 11]);
    }
}
