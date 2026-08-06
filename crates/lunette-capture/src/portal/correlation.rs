//! Which monitor each granted stream shows.
//!
//! The portal hands out anonymous streams. Nothing in the response says which
//! screen a stream came from, and nothing guarantees the order corresponds to
//! the user's selection order or to output enumeration order, so the tie has to
//! be made from what the stream properties carry: `position` and `size`, in the
//! compositor's logical space, which is the same space a `wl_output`'s geometry
//! is reported in.
//!
//! That geometry match is the portable mechanism, and it is what wlx-overlay-s
//! does. `mapping_id` is read opportunistically and wins where it is a real
//! connector name, but it cannot be the mechanism: two of the three portal
//! backends do not supply a usable one. `docs/decisions.md` records the
//! evidence.
//!
//! Pure over plain data. Nothing here touches the portal, PipeWire, or a
//! display, and the result is sorted, so correlating the same streams in a
//! different order produces the same answer.

use std::{collections::BTreeMap, fmt};

use crate::{
    monitor::{
        geometry::LogicalPosition,
        name::MonitorKey,
        roster::{Monitor, Roster},
    },
    portal::{NodeId, PortalStream},
};

/// Ties each granted stream to the monitor it shows.
///
/// The connector pass runs first and across every stream, then the position
/// pass over what is left, so a stream that names its connector never loses its
/// monitor to a stream that merely sits at the same coordinates.
///
/// Both halves of the answer are reported. A stream matching no monitor is
/// listed in [`Correlation::unmatched`] with the reason, and a monitor no
/// stream showed is listed in [`Correlation::unmirrored`]: dropping either
/// would turn a portal or arrangement problem into a mirror that silently never
/// appears.
#[must_use]
pub fn correlate(streams: &[PortalStream], roster: &Roster) -> Correlation {
    let mut claims = Claims::new(roster);

    for stream in streams {
        claims.claim_by_connector(stream);
    }
    claims.claim_by_position(streams);

    claims.finish(streams)
}

/// The outcome of tying a portal response's streams to the attached monitors.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Correlation {
    /// One entry per stream that found its monitor, ordered by node identifier
    /// so the result does not depend on the order the portal listed them in.
    pub matched: Vec<StreamMatch>,
    /// The streams that found none, with the reason for each.
    pub unmatched: Vec<Unmatched>,
    /// The monitors no stream showed, in the roster's own sorted order.
    ///
    /// Ordinary when the user selected only some of their screens; a symptom
    /// when they selected all of them and one is missing anyway.
    pub unmirrored: Vec<MonitorKey>,
}

/// A stream and the monitor it shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamMatch {
    pub node: NodeId,
    pub monitor: MonitorKey,
    pub strength: MatchStrength,
}

/// How the tie was made, strongest first.
///
/// Worth recording rather than discarding: a session where every match is
/// [`Self::Position`] is one where a monitor moving will silently re-point the
/// mirror, and that is a thing to be able to say in a log.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum MatchStrength {
    /// The stream's `mapping_id` was a connector name, and it named this
    /// monitor.
    Connector,
    /// The stream's position and size both agree with the monitor's.
    PositionAndSize,
    /// The stream's position agrees and its size does not, or it reported none.
    ///
    /// Not a failure. A backend that reports a stream's size in pixels rather
    /// than in logical coordinates disagrees with the monitor's logical size by
    /// exactly the scale factor, and the position is still correct — so a size
    /// disagreement lowers the confidence rather than rejecting the match.
    Position,
}

/// A stream that found no monitor, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Unmatched {
    pub node: NodeId,
    pub reason: NoMatch,
}

/// Why a stream could not be tied to a monitor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NoMatch {
    /// The stream reported neither a usable `mapping_id` nor a position, so
    /// there is nothing to match it on.
    Featureless,
    /// No attached monitor sits where the stream says it does. A monitor
    /// unplugged between the portal's dialog and this correlation looks like
    /// this.
    NoMonitorThere { position: LogicalPosition },
    /// More than one candidate sits there, or more than one stream claims the
    /// same place. Mirrored outputs occupying one logical rectangle produce
    /// this, and picking one arbitrarily would put the mirror on whichever the
    /// enumeration happened to list first.
    Ambiguous {
        position: LogicalPosition,
        monitors: usize,
        streams: usize,
    },
    /// The stream named a connector no attached monitor carries.
    NoSuchConnector,
    /// The monitor this stream names was already taken by another stream.
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

/// Which monitor each stream has taken, while the passes run.
struct Claims<'a> {
    monitors: &'a [Monitor],
    /// The node that claimed each monitor, indexed alongside `monitors`.
    claimed_by: Vec<Option<NodeId>>,
    /// The monitor each node claimed, and how. Ordered, so the finished result
    /// is too.
    taken: BTreeMap<NodeId, (usize, MatchStrength)>,
    /// The nodes that failed, and why. Only consulted for a node that never
    /// claimed anything.
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

    /// Takes the monitor a stream's `mapping_id` names, where it names one.
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

    /// Takes a monitor for each remaining stream whose position names exactly
    /// one.
    ///
    /// Grouped by position rather than walked stream by stream, because the
    /// ambiguous case is a property of the group: two streams at one position
    /// are indistinguishable from each other, not merely from the monitors
    /// there.
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
        geometry::{LogicalGeometry, LogicalSize, PixelExtent},
        name::{ConnectorName, MonitorName},
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

    /// A resolution correlation does not read: streams are tied to monitors by
    /// logical geometry and by connector name, never by mode.
    fn resolution() -> PixelExtent {
        PixelExtent::new(1920, 1080)
    }

    /// Two monitors side by side, each 1920 wide, distinguishable by model.
    fn two_monitors() -> Roster {
        let mut roster = Roster::new();
        roster.add(named(Some("DP-1"), "Left"), geometry(0, 1920), resolution());
        roster.add(
            named(Some("HDMI-A-1"), "Right"),
            geometry(1920, 1920),
            resolution(),
        );
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
        // The portal guarantees nothing about stream order, so an arrangement
        // derived from it would change between runs with nothing else changing.
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
        // The stream says it is at the right-hand monitor's position, but names
        // the left-hand monitor's connector. The connector is the more specific
        // of the two, so it wins.
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
        // A backend reporting the stream's pixel size on a 2x display disagrees
        // with the logical size by exactly the scale factor. The position is
        // still right, and refusing here would leave a scaled monitor
        // unmirrorable.
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
        // Mirrored outputs occupy one logical rectangle. Picking one would put
        // the mirror on whichever the enumeration happened to list first.
        let mut roster = Roster::new();
        roster.add(named(Some("DP-1"), "Left"), geometry(0, 1920), resolution());
        roster.add(
            named(Some("HDMI-A-1"), "Right"),
            geometry(0, 1920),
            resolution(),
        );

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
        // Two monitors at one position, but one stream names its connector. The
        // connector pass takes that monitor, so the position pass sees exactly
        // one candidate and one stream, which is no longer ambiguous.
        let mut roster = Roster::new();
        roster.add(named(Some("DP-1"), "Left"), geometry(0, 1920), resolution());
        roster.add(
            named(Some("HDMI-A-1"), "Right"),
            geometry(0, 1920),
            resolution(),
        );

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
        // Ordinary when the user selected one of two screens, and the only way
        // a configuration can say which mirror it did not get.
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
