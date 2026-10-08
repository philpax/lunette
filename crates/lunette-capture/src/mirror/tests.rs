//! The mirror lifecycle against a scripted portal and a recording stream source.
//!
//! The portal and stream seams are substituted, so these tests do not require a
//! session bus, PipeWire, a display, or a GPU.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use pretty_assertions::assert_eq;

use super::*;
use crate::{
    mirror::fake::{RecordingSource, StreamEvent, StreamLog},
    monitor::{
        geometry::{LogicalGeometry, LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
        name::{ConnectorName, MonitorName},
        roster::MonitorReport,
    },
    portal::{
        GrantedPersistMode, PersistMode, PortalStream, RestoreToken, SessionResponse,
        fake::FakePortal,
    },
};

fn roster() -> Roster {
    let mut roster = Roster::new();
    for (index, connector) in ["DP-1", "DP-2"].into_iter().enumerate() {
        let x = i32::try_from(index).expect("a small index") * 1920;
        roster.add(MonitorReport {
            name: MonitorName::new(
                ConnectorName::parse(connector),
                Some("Acme".to_owned()),
                Some(format!("X{index}")),
            ),
            geometry: LogicalGeometry::new(
                LogicalPosition::new(x, 0),
                LogicalSize::new(1920, 1080),
            ),
            pixels: PixelExtent::new(1920, 1080),
            transform: SurfaceTransform::Normal,
        });
    }
    roster
}

fn key(roster: &Roster, index: usize) -> MonitorKey {
    roster.monitors()[index].key().clone()
}

fn stream(node: u32, index: u32) -> PortalStream {
    PortalStream {
        node: NodeId::new(node).expect("a non-zero node identifier"),
        position: Some(LogicalPosition::new(
            i32::try_from(index).expect("a small index") * 1920,
            0,
        )),
        size: Some(LogicalSize::new(1920, 1080)),
        connector: None,
    }
}

fn response(streams: Vec<PortalStream>, token: &str) -> SessionResponse {
    SessionResponse {
        streams,
        restore_token: RestoreToken::new(token),
        granted_persist_mode: GrantedPersistMode::Granted(PersistMode::UntilRevoked),
    }
}

struct DirectSource {
    log: StreamLog,
    direct: Option<MonitorKey>,
}

impl MonitorStreams for DirectSource {
    fn open_direct(&mut self, monitor: &crate::monitor::Monitor) -> DirectOpen {
        if self.direct.as_ref() != Some(monitor.key()) {
            return DirectOpen::Unavailable;
        }
        let stream = RecordingSource::new(self.log.clone())
            .open("direct", NodeId::new(99).expect("a non-zero recording id"))
            .expect("the recording source opens");
        DirectOpen::Opened(stream)
    }

    fn open(&mut self, name: &str, node: NodeId) -> Option<Box<dyn MonitorStream>> {
        RecordingSource::new(self.log.clone()).open(name, node)
    }
}

#[test]
fn direct_capture_bypasses_the_portal_and_restore_tokens() {
    let log = StreamLog::new();
    let roster = roster();
    let first = key(&roster, 0);
    let mut mirrors = mirrors(&log);
    mirrors.set_streams(Box::new(DirectSource {
        log: log.clone(),
        direct: Some(first.clone()),
    }));
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Mirroring);
    assert!(mirrors.portal().requests.is_empty());
    assert!(mirrors.take_changed_tokens().is_none());
    assert_eq!(mirrors.poll(), Progress::Idle);
    assert_eq!(log.opened().len(), 1);
}

#[test]
fn direct_capture_waits_for_graphics_without_opening_a_portal_dialog() {
    let roster = roster();
    let first = key(&roster, 0);
    let mut mirrors = MirrorSet::new(FakePortal::new(), CursorPolicy::Visible, TokenStore::new());
    mirrors.attach(roster);
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Requested);
    assert!(mirrors.portal().requests.is_empty());
    assert_eq!(mirrors.poll(), Progress::Idle);
    let log = StreamLog::new();
    mirrors.set_streams(Box::new(DirectSource {
        log,
        direct: Some(first.clone()),
    }));
    assert_eq!(mirrors.poll(), Progress::Started(vec![first]));
    assert!(mirrors.portal().requests.is_empty());
}

#[test]
fn unavailable_direct_capture_uses_the_existing_portal() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    mirrors.set_streams(Box::new(DirectSource {
        log: log.clone(),
        direct: None,
    }));
    let first = key(&roster(), 0);
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Requested);
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![first]));
    assert_eq!(mirrors.portal().requests.len(), 1);
    assert_eq!(log.opened(), vec![NodeId::new(11).expect("a node")]);
}

#[test]
fn direct_capture_survives_a_successful_explicit_portal_selection() {
    let log = StreamLog::new();
    let first = key(&roster(), 0);
    let second = key(&roster(), 1);
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(12, 1)], "selected"));
    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Visible, TokenStore::new());
    mirrors.attach(roster());
    mirrors.set_streams(Box::new(DirectSource {
        log: log.clone(),
        direct: Some(first.clone()),
    }));
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Mirroring);
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![second.clone()]));
    assert!(mirrors.is_mirroring(&first));
    assert!(mirrors.is_mirroring(&second));
    assert!(log.dropped().is_empty());
    assert!(mirrors.take_replaced_monitors().is_empty());
    mirrors.revoke_session();
    assert!(mirrors.is_mirroring(&first));
    assert!(!mirrors.is_mirroring(&second));
}

#[test]
fn direct_capture_is_dropped_on_dismissal_and_unplug() {
    let log = StreamLog::new();
    let first = key(&roster(), 0);
    let mut mirrors = mirrors(&log);
    mirrors.set_streams(Box::new(DirectSource {
        log: log.clone(),
        direct: Some(first.clone()),
    }));
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Mirroring);
    assert!(mirrors.set_paused(&first, true));
    assert!(mirrors.set_paused(&first, false));
    assert!(mirrors.dismiss(&first));
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Mirroring);
    mirrors.attach(Roster::new());
    assert!(!mirrors.is_wanted(&first));
    assert_eq!(log.dropped().len(), 2);
    assert!(mirrors.portal().requests.is_empty());
}

fn mirrors(log: &StreamLog) -> MirrorSet<FakePortal> {
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0), stream(12, 1)], "fresh"));

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log.clone())));
    mirrors.attach(roster());
    mirrors
}

/// The bound turns a non-terminating portal script into a test failure, so the
/// suite does not hang.
fn pump(mirrors: &mut MirrorSet<FakePortal>) -> Progress {
    for _ in 0..16 {
        let progress = mirrors.poll();
        if progress != Progress::Waiting {
            return progress;
        }
    }
    panic!("the scripted portal never reached a terminal progress");
}

#[test]
fn nothing_is_asked_of_the_portal_until_a_monitor_is_mirrored() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);

    assert_eq!(mirrors.poll(), Progress::Idle);
    assert!(mirrors.portal().requests.is_empty());
    assert!(log.entries().is_empty());
}

#[test]
fn mirroring_asks_the_portal_once_however_many_monitors_are_wanted() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();

    assert_eq!(mirrors.mirror(&key(&roster, 0)), MirrorOutcome::Requested);
    assert_eq!(mirrors.mirror(&key(&roster, 1)), MirrorOutcome::Requested);

    assert_eq!(
        mirrors.portal().requests.len(),
        1,
        "one dialog covers every screen, which is what removes the prescribed order",
    );
}

#[test]
fn a_granted_session_starts_a_stream_for_every_wanted_monitor() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = mirrors.mirror(&key(&roster, 1));

    let progress = pump(&mut mirrors);

    assert_eq!(
        progress,
        Progress::Started(vec![key(&roster, 0), key(&roster, 1)])
    );
    assert_eq!(log.opened().len(), 2);
    assert!(mirrors.is_mirroring(&key(&roster, 0)));
    assert!(mirrors.is_mirroring(&key(&roster, 1)));
}

#[test]
fn a_monitor_wanted_before_the_session_arrives_is_not_mirroring_yet() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();

    let _ = mirrors.mirror(&key(&roster, 0));

    assert!(mirrors.is_wanted(&key(&roster, 0)));
    assert!(
        !mirrors.is_mirroring(&key(&roster, 0)),
        "a dialog may still be on the user's screen, and nothing waits for it",
    );
}

#[test]
fn dismissing_stops_the_stream_and_keeps_the_session() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.dismiss(&key(&roster, 0)));

    assert_eq!(
        log.dropped(),
        vec![NodeId::new(11).expect("a non-zero node identifier")],
        "stopping is dropping the stream, not pausing it",
    );
    assert!(!mirrors.is_mirroring(&key(&roster, 0)));
    assert!(!mirrors.is_wanted(&key(&roster, 0)));
}

#[test]
fn re_adding_a_dismissed_monitor_restarts_without_a_second_request() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);
    assert!(mirrors.dismiss(&key(&roster, 0)));

    assert_eq!(mirrors.mirror(&key(&roster, 0)), MirrorOutcome::Mirroring);

    assert_eq!(
        mirrors.portal().requests.len(),
        1,
        "the session was kept, so re-adding must not show the user another dialog",
    );
    assert_eq!(
        log.opened().len(),
        2,
        "the second open is the restarted stream"
    );
}

#[test]
fn dismissing_a_monitor_that_is_not_mirrored_changes_nothing() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.dismiss(&key(&roster, 0)));
    assert!(!mirrors.dismiss(&key(&roster, 0)));
    assert_eq!(log.dropped().len(), 1);
}

#[test]
fn mirroring_a_monitor_already_mirrored_changes_nothing() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert_eq!(
        mirrors.mirror(&key(&roster, 0)),
        MirrorOutcome::AlreadyMirroring
    );
    assert_eq!(log.opened().len(), 1);
}

#[test]
fn a_revoked_session_falls_back_to_a_fresh_request() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    mirrors.revoke_session();

    assert!(!mirrors.is_mirroring(&key(&roster, 0)));
    assert!(
        mirrors.is_wanted(&key(&roster, 0)),
        "the monitor is still wanted; only the session went away",
    );
    assert_eq!(mirrors.portal().requests.len(), 2);
}

#[test]
fn revoking_when_nothing_was_ever_asked_for_asks_for_nothing() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);

    mirrors.revoke_session();

    assert!(mirrors.portal().requests.is_empty());
}

#[test]
fn a_monitor_no_attached_screen_carries_is_refused_rather_than_requested() {
    // This models a stored key whose monitor is no longer attached.
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let absent = MonitorKey::Connector(
        ConnectorName::parse("HDMI-A-9").expect("a well-formed connector name"),
    );

    assert_eq!(mirrors.mirror(&absent), MirrorOutcome::NoSuchMonitor);
    assert!(mirrors.portal().requests.is_empty());
}

#[test]
fn a_detached_monitor_loses_its_mirror() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    let mut remaining = Roster::new();
    remaining.add(MonitorReport {
        name: MonitorName::new(
            ConnectorName::parse("DP-2"),
            Some("Acme".to_owned()),
            Some("X1".to_owned()),
        ),
        geometry: LogicalGeometry::new(LogicalPosition::new(1920, 0), LogicalSize::new(1920, 1080)),
        pixels: PixelExtent::new(1920, 1080),
        transform: SurfaceTransform::Normal,
    });
    let change = mirrors.attach(remaining);

    assert_eq!(change.removed, vec![key(&roster, 0)]);
    assert!(change.added.is_empty());
    assert_eq!(log.dropped().len(), 1);
    assert!(!mirrors.is_wanted(&key(&roster, 0)));
}

#[test]
fn a_monitor_appearing_is_reported_as_added() {
    let log = StreamLog::new();
    let mut mirrors = MirrorSet::new(FakePortal::new(), CursorPolicy::Hidden, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log)));

    let change = mirrors.attach(roster());

    assert_eq!(change.added.len(), 2);
    assert!(change.removed.is_empty());
}

#[test]
fn pausing_a_mirror_keeps_its_stream() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.set_paused(&key(&roster, 0), true));
    assert!(mirrors.set_paused(&key(&roster, 0), false));

    let node = NodeId::new(11).expect("a non-zero node identifier");
    assert_eq!(
        log.entries()
            .into_iter()
            .filter(|event| !matches!(event, StreamEvent::Opened { .. }))
            .collect::<Vec<_>>(),
        vec![StreamEvent::Paused { node }, StreamEvent::Resumed { node },],
    );
    assert!(mirrors.is_mirroring(&key(&roster, 0)));
}

#[test]
fn pausing_a_mirror_twice_sends_one_pause() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.set_paused(&key(&roster, 0), true));
    assert!(mirrors.set_paused(&key(&roster, 0), true));

    assert_eq!(
        log.entries()
            .into_iter()
            .filter(|event| matches!(event, StreamEvent::Paused { .. }))
            .count(),
        1,
    );
}

#[test]
fn pausing_a_monitor_that_is_not_mirrored_reports_that_it_is_not() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();

    assert!(!mirrors.set_paused(&key(&roster, 0), true));
}

#[test]
fn the_granted_token_is_recorded_for_every_monitor_the_session_covers() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    let tokens = mirrors.take_changed_tokens().expect("a grant changed them");

    for index in 0..2 {
        assert_eq!(
            tokens
                .token_for(&key(&roster, index))
                .map(RestoreToken::as_str),
            Some("fresh"),
        );
    }
    assert_eq!(
        tokens.persistence_for(&key(&roster, 0)),
        Some(PersistMode::UntilRevoked),
        "the granted mode is stored, never the requested one",
    );
}

#[test]
fn the_tokens_are_reported_changed_once_per_grant() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.take_changed_tokens().is_some());
    assert!(
        mirrors.take_changed_tokens().is_none(),
        "an unchanged store must not rewrite the file every frame",
    );
}

#[test]
fn a_stored_token_is_offered_with_the_first_request() {
    let log = StreamLog::new();
    let roster = roster();
    let mut stored = TokenStore::new();
    stored.record(
        key(&roster, 0),
        RestoreToken::new("from-last-run"),
        GrantedPersistMode::Granted(PersistMode::UntilRevoked),
    );

    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0)], "fresh"));
    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, stored);
    mirrors.set_streams(Box::new(RecordingSource::new(log)));
    mirrors.attach(roster.clone());

    let _ = mirrors.mirror(&key(&roster, 0));

    assert_eq!(
        mirrors.portal().requests[0]
            .restore_token
            .as_ref()
            .map(RestoreToken::as_str),
        Some("from-last-run"),
    );
}

#[test]
fn a_refused_request_is_not_retried_by_polling() {
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_refuse_to_begin(PortalError::Dbus("no session bus".to_owned()));

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log)));
    mirrors.attach(roster.clone());

    assert_eq!(
        mirrors.mirror(&key(&roster, 0)),
        MirrorOutcome::Refused(PortalError::Dbus("no session bus".to_owned())),
    );
    assert_eq!(mirrors.poll(), Progress::Idle);
    assert_eq!(mirrors.poll(), Progress::Idle);
}

#[test]
fn a_declined_dialog_is_reported_rather_than_leaving_the_monitor_waiting() {
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_fail(PortalError::Refused { code: 1 });

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log.clone())));
    mirrors.attach(roster.clone());
    let _ = mirrors.mirror(&key(&roster, 0));

    assert_eq!(
        pump(&mut mirrors),
        Progress::Failed(PortalError::Refused { code: 1 })
    );
    assert!(log.entries().is_empty());
    assert!(!mirrors.is_mirroring(&key(&roster, 0)));
}

#[test]
fn a_session_covering_none_of_the_wanted_monitors_starts_nothing() {
    // A grant may omit a wanted monitor when the user does not select it in the
    // portal dialog.
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 1)], "fresh"));

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log.clone())));
    mirrors.attach(roster.clone());
    let _ = mirrors.mirror(&key(&roster, 0));

    assert_eq!(pump(&mut mirrors), Progress::Started(Vec::new()));
    assert!(log.entries().is_empty());
}

#[test]
fn fresh_selection_omits_restore_and_replaces_streams_only_after_a_grant() {
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0)], "initial"));
    portal.will_grant(response(vec![stream(21, 0), stream(22, 1)], "replacement"));
    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Visible, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log.clone())));
    mirrors.attach(roster.clone());
    let first = key(&roster, 0);
    let second = key(&roster, 1);
    let _ = mirrors.mirror(&first);
    let _ = mirrors.mirror(&second);
    let _ = pump(&mut mirrors);
    assert!(mirrors.is_mirroring(&first));
    assert!(!mirrors.is_mirroring(&second));

    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Busy);
    assert_eq!(mirrors.portal().requests.len(), 2);
    assert!(mirrors.portal().requests[1].restore_token.is_none());
    assert_eq!(mirrors.portal().requests[1].cursor, CursorPolicy::Visible);
    assert!(
        mirrors.is_mirroring(&first),
        "selection keeps the old capture"
    );
    assert!(mirrors.take_replaced_monitors().is_empty());
    assert_eq!(mirrors.poll(), Progress::Waiting);
    assert_eq!(mirrors.selection_state(), SelectionState::Pending);
    assert_eq!(
        pump(&mut mirrors),
        Progress::Started(vec![first.clone(), second.clone()])
    );
    assert_eq!(mirrors.take_replaced_monitors(), vec![first]);
    assert!(mirrors.take_replaced_monitors().is_empty());
    assert_eq!(mirrors.selection_state(), SelectionState::Ready);
    assert!(mirrors.is_mirroring(&second));
    assert_eq!(
        log.entries().len(),
        4,
        "one old stream stops and both new streams open"
    );
}

#[test]
fn declining_fresh_selection_preserves_capture_and_can_be_retried_explicitly() {
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0)], "initial"));
    portal.will_fail(PortalError::Refused { code: 1 });
    portal.will_grant(response(vec![stream(21, 0)], "replacement"));
    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Visible, TokenStore::new());
    mirrors.set_streams(Box::new(RecordingSource::new(log)));
    mirrors.attach(roster.clone());
    let first = key(&roster, 0);
    let _ = mirrors.mirror(&first);
    let _ = pump(&mut mirrors);
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    assert_eq!(
        pump(&mut mirrors),
        Progress::Failed(PortalError::Refused { code: 1 })
    );
    assert!(mirrors.is_mirroring(&first));
    assert_eq!(
        mirrors.selection_state(),
        SelectionState::Failed(PortalError::Refused { code: 1 })
    );
    for _ in 0..8 {
        assert_eq!(mirrors.poll(), Progress::Idle);
    }
    assert_eq!(
        mirrors.portal().requests.len(),
        2,
        "no repeated prompt after cancellation"
    );
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    let _ = pump(&mut mirrors);
    assert_eq!(mirrors.selection_state(), SelectionState::Ready);
}

#[test]
fn fresh_selection_without_monitors_does_not_open_a_dialog() {
    let mut mirrors = MirrorSet::new(FakePortal::new(), CursorPolicy::Visible, TokenStore::new());
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::NoMonitors);
    assert!(mirrors.portal().requests.is_empty());
}

#[test]
fn dismissal_during_selection_does_not_reopen_the_monitor() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    mirrors
        .portal
        .will_grant(response(vec![stream(21, 0), stream(22, 1)], "selected"));
    let first = key(mirrors.roster(), 0);
    let second = key(mirrors.roster(), 1);
    let _ = mirrors.mirror(&first);
    let _ = pump(&mut mirrors);
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    assert!(mirrors.dismiss(&first));
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![second.clone()]));
    assert!(!mirrors.is_wanted(&first));
    assert!(!mirrors.is_mirroring(&first));
    assert!(mirrors.is_mirroring(&second));
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Mirroring);
}

#[test]
fn revocation_during_selection_does_not_start_a_competing_request() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    mirrors
        .portal
        .will_grant(response(vec![stream(21, 0)], "selected"));
    let first = key(mirrors.roster(), 0);
    let _ = mirrors.mirror(&first);
    let _ = pump(&mut mirrors);
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    mirrors.revoke_session();
    assert_eq!(mirrors.portal().requests.len(), 2);
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![first]));
    assert_eq!(mirrors.selection_state(), SelectionState::Ready);
}

#[test]
fn uncorrelated_selection_retains_the_previous_capture_and_tokens() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    mirrors
        .portal
        .will_grant(response(vec![stream(21, 8)], "unmatched"));
    let first = key(mirrors.roster(), 0);
    let _ = mirrors.mirror(&first);
    let _ = pump(&mut mirrors);
    let _ = mirrors.take_changed_tokens();
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    assert!(matches!(pump(&mut mirrors), Progress::Failed(_)));
    assert!(mirrors.is_mirroring(&first));
    assert!(mirrors.take_changed_tokens().is_none());
    assert_eq!(log.entries().len(), 1);
}

#[test]
fn unplug_during_selection_excludes_the_removed_monitor() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    mirrors
        .portal
        .will_grant(response(vec![stream(21, 0), stream(22, 1)], "selected"));
    let first = key(mirrors.roster(), 0);
    let second = key(mirrors.roster(), 1);
    assert_eq!(mirrors.select_monitors(), SelectionOutcome::Requested);
    let remaining = mirrors.roster().monitors()[1].clone();
    let mut next = Roster::new();
    next.add(MonitorReport {
        name: remaining.name().clone(),
        geometry: remaining.geometry(),
        pixels: remaining.pixels(),
        transform: remaining.transform(),
    });
    mirrors.attach(next);
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![second]));
    assert!(!mirrors.is_wanted(&first));
}

#[test]
fn a_running_mirror_carries_no_frame_until_one_arrives() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.take_frames().is_empty());
}

#[test]
fn a_monitor_mirrored_before_the_source_exists_starts_once_it_does() {
    // The source is unavailable until the graphics device supplies the DRM
    // formats accepted by the importer. A mirror requested earlier remains wanted
    // until the source can open it.
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0), stream(12, 1)], "fresh"));

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.attach(roster.clone());
    let _ = mirrors.mirror(&key(&roster, 0));

    assert_eq!(pump(&mut mirrors), Progress::Idle);
    assert!(mirrors.portal().requests.is_empty());
    assert!(
        log.entries().is_empty(),
        "no stream can be opened before a source exists"
    );
    assert!(!mirrors.is_mirroring(&key(&roster, 0)));
    assert!(
        mirrors.is_wanted(&key(&roster, 0)),
        "the monitor has to stay wanted, or the deferral loses the request"
    );

    mirrors.set_streams(Box::new(RecordingSource::new(log.clone())));

    assert_eq!(
        pump(&mut mirrors),
        Progress::Started(vec![key(&roster, 0)]),
        "the source first chooses the portal, then opens the granted stream",
    );
    assert!(mirrors.is_mirroring(&key(&roster, 0)));
    assert_eq!(log.entries().len(), 1);
}

#[test]
fn a_deferred_start_does_not_ask_the_portal_a_second_time() {
    let log = StreamLog::new();
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0), stream(12, 1)], "fresh"));

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.attach(roster.clone());
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    for _ in 0..4 {
        assert_eq!(mirrors.poll(), Progress::Idle);
    }
    mirrors.set_streams(Box::new(RecordingSource::new(log)));
    let _ = mirrors.poll();

    assert_eq!(mirrors.portal().requests.len(), 1);
}

#[test]
fn mirroring_reports_a_request_rather_than_a_mirror_while_no_source_exists() {
    let roster = roster();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(11, 0), stream(12, 1)], "fresh"));

    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Hidden, TokenStore::new());
    mirrors.attach(roster.clone());
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert_eq!(
        mirrors.mirror(&key(&roster, 1)),
        MirrorOutcome::Requested,
        "the session already covers this monitor; only the source is missing",
    );
}
