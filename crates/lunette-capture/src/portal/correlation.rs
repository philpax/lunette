//! Which monitor each granted stream shows.
//!
//! The portal grants anonymous streams. Nothing in the response says which
//! screen a stream came from, and nothing guarantees the order corresponds to
//! the user's selection order or to output enumeration order. The mapping is
//! made from the stream's `position`, in the compositor's logical space, which
//! is the same space a `wl_output`'s geometry is reported in. This is what
//! wlx-overlay-s does. `mapping_id` is not read, because two of the three
//! portal backends do not supply a usable one; `docs/development/native/host-desktop.md`
//! records the evidence.
//!
//! The correlation is pure computation over plain data. Nothing here touches
//! the portal, PipeWire, or a display. Streams are grouped by position in an
//! ordered map, and the result is sorted by node, so correlating the same
//! streams in a different order produces the same answer.

use std::{collections::BTreeMap, fmt};

use crate::{
    monitor::{geometry::LogicalPosition, name::MonitorKey, roster::Roster},
    portal::{NodeId, PortalStream},
};

/// Ties each granted stream to the monitor at its position.
///
/// A stream matching no monitor is listed in [`Correlation::unmatched`] with
/// the reason. Dropping it would hide a portal or arrangement problem: the
/// mirror would silently never appear.
///
/// The pass groups by position. The ambiguous case is a property of the
/// group: two streams at one position are indistinguishable from each other,
/// not merely from the monitors there.
#[must_use]
pub fn correlate(streams: &[PortalStream], roster: &Roster) -> Correlation {
    let monitors = roster.monitors();
    let mut matched = Vec::new();
    let mut unmatched = Vec::new();
    let mut by_position: BTreeMap<(i32, i32), Vec<NodeId>> = BTreeMap::new();

    for stream in streams {
        match stream.position {
            Some(position) => by_position
                .entry((position.x, position.y))
                .or_default()
                .push(stream.node),
            None => unmatched.push(Unmatched {
                node: stream.node,
                reason: NoMatch::Featureless,
            }),
        }
    }

    for ((x, y), nodes) in by_position {
        let position = LogicalPosition::new(x, y);
        let candidates: Vec<&MonitorKey> = monitors
            .iter()
            .filter(|monitor| monitor.position() == position)
            .map(|monitor| monitor.key())
            .collect();

        match (nodes.as_slice(), candidates.as_slice()) {
            ([node], [monitor]) => matched.push(StreamMatch {
                node: *node,
                monitor: (*monitor).clone(),
            }),
            ([node], []) => unmatched.push(Unmatched {
                node: *node,
                reason: NoMatch::NoMonitorThere { position },
            }),
            _ => unmatched.extend(nodes.iter().map(|node| Unmatched {
                node: *node,
                reason: NoMatch::Ambiguous {
                    position,
                    monitors: candidates.len(),
                    streams: nodes.len(),
                },
            })),
        }
    }

    matched.sort_by_key(|entry| entry.node);
    unmatched.sort_by_key(|entry| entry.node);
    unmatched.dedup_by_key(|entry| entry.node);

    Correlation { matched, unmatched }
}

/// The outcome of tying a portal response's streams to the attached monitors.
///
/// Both halves are ordered by node identifier, so the result does not depend
/// on the order the portal listed the streams in.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Correlation {
    /// One entry per stream that found its monitor.
    pub matched: Vec<StreamMatch>,
    /// The streams that found none, with the reason for each.
    pub unmatched: Vec<Unmatched>,
}

/// A stream and the monitor it shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamMatch {
    pub node: NodeId,
    pub monitor: MonitorKey,
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
    /// The stream reported no position, so there is nothing to match it on.
    Featureless,
    /// No attached monitor occupies the stream's reported position. Unplugging
    /// a monitor between the portal's dialog and this correlation produces
    /// this.
    NoMonitorThere { position: LogicalPosition },
    /// More than one candidate sits there, or more than one stream claims the
    /// same place. Mirrored outputs occupying one logical rectangle produce
    /// this. Picking one arbitrarily would put the mirror on whichever the
    /// enumeration happened to list first.
    Ambiguous {
        position: LogicalPosition,
        monitors: usize,
        streams: usize,
    },
}

impl fmt::Display for NoMatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Featureless => f.write_str(
                "the stream reported no position, so there is nothing to identify it by",
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
    use crate::monitor::{
        geometry::{LogicalGeometry, LogicalSize, PixelExtent},
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

    /// A resolution correlation does not read: streams are tied to monitors by
    /// logical position, never by mode.
    fn resolution() -> PixelExtent {
        PixelExtent::new(1920, 1080)
    }

    fn report(name: MonitorName, geometry: LogicalGeometry) -> MonitorReport {
        MonitorReport {
            name,
            geometry,
            pixels: resolution(),
        }
    }

    /// Two monitors side by side, each 1920 wide, distinguishable by model.
    fn two_monitors() -> Roster {
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), "Left"), geometry(0, 1920)));
        roster.add(report(
            named(Some("HDMI-A-1"), "Right"),
            geometry(1920, 1920),
        ));
        roster
    }

    fn stream(raw: u32, x: Option<i32>) -> PortalStream {
        PortalStream {
            node: node(raw),
            position: x.map(|x| LogicalPosition::new(x, 0)),
        }
    }

    fn matched(correlation: &Correlation) -> Vec<(u32, String)> {
        correlation
            .matched
            .iter()
            .map(|entry| (entry.node.get(), entry.monitor.to_string()))
            .collect()
    }

    #[test]
    fn two_streams_reach_the_monitors_their_geometry_names() {
        let correlation = correlate(
            &[stream(7, Some(1920)), stream(3, Some(0))],
            &two_monitors(),
        );

        assert_eq!(
            matched(&correlation),
            vec![(3, "Acme Left".to_owned()), (7, "Acme Right".to_owned()),],
        );
        assert!(correlation.unmatched.is_empty());
    }

    #[test]
    fn the_answer_does_not_depend_on_the_order_the_portal_listed_the_streams_in() {
        // The portal guarantees nothing about stream order. An arrangement
        // derived from it would change between runs with nothing else changing.
        let forwards = [stream(3, Some(0)), stream(7, Some(1920))];
        let backwards = [forwards[1].clone(), forwards[0].clone()];

        assert_eq!(
            correlate(&forwards, &two_monitors()),
            correlate(&backwards, &two_monitors()),
        );
    }

    #[test]
    fn a_stream_carrying_no_position_is_reported() {
        let correlation = correlate(&[stream(3, None)], &two_monitors());

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
        let correlation = correlate(&[stream(3, Some(5000))], &two_monitors());

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
    }

    #[test]
    fn two_monitors_stacked_at_one_position_leave_both_streams_ambiguous() {
        // Mirrored outputs occupy one logical rectangle. Picking one would put
        // the mirror on whichever the enumeration happened to list first.
        let mut roster = Roster::new();
        roster.add(report(named(Some("DP-1"), "Left"), geometry(0, 1920)));
        roster.add(report(named(Some("HDMI-A-1"), "Right"), geometry(0, 1920)));

        let correlation = correlate(&[stream(3, Some(0)), stream(7, Some(0))], &roster);

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
    fn a_stream_against_an_empty_roster_is_reported_rather_than_dropped() {
        let correlation = correlate(&[stream(3, Some(0))], &Roster::new());

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
        let streams = [stream(3, Some(0)), stream(7, Some(5000)), stream(11, None)];
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
