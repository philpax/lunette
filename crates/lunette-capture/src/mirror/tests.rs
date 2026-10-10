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
    mirror::fake::{RecordingSource, ScriptedNodes, StreamEvent, StreamLog},
    monitor::{
        geometry::{LogicalGeometry, LogicalPosition, LogicalSize, PixelExtent},
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
        roster.add(report(index, connector));
    }
    roster
}

/// The roster after the first monitor of [`roster`] is unplugged.
fn second_only() -> Roster {
    let mut roster = Roster::new();
    roster.add(report(1, "DP-2"));
    roster
}

fn report(index: usize, connector: &str) -> MonitorReport {
    let x = i32::try_from(index).expect("a small index") * 1920;
    MonitorReport {
        name: MonitorName::new(
            ConnectorName::parse(connector),
            Some("Acme".to_owned()),
            Some(format!("X{index}")),
        ),
        geometry: LogicalGeometry::new(LogicalPosition::new(x, 0), LogicalSize::new(1920, 1080)),
        pixels: PixelExtent::new(1920, 1080),
    }
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
fn direct_capture_bypasses_the_portal_and_is_dropped_on_dismissal_and_unplug() {
    let log = StreamLog::new();
    let first = key(&roster(), 0);
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

/// [`mirrors`] with a node watch the test drives.
fn watched(log: &StreamLog) -> (MirrorSet<FakePortal>, ScriptedNodes) {
    let nodes = ScriptedNodes::new();
    let mirrors = mirrors(log).with_node_watch(Box::new(nodes.clone()));
    (mirrors, nodes)
}

fn node(raw: u32) -> NodeId {
    NodeId::new(raw).expect("a non-zero node identifier")
}

/// The bound turns a non-terminating portal script into a test failure instead of a hang.
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
    assert!(mirrors.is_wanted(&key(&roster, 0)));
    assert!(
        !mirrors.is_mirroring(&key(&roster, 0)),
        "a dialog may still be on the user's screen, and nothing waits for it",
    );
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
fn dismissing_stops_the_stream_and_keeps_the_session() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();
    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.dismiss(&key(&roster, 0)));
    assert!(
        !mirrors.dismiss(&key(&roster, 0)),
        "a monitor no longer mirrored has nothing to dismiss",
    );

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

    let change = mirrors.attach(second_only());

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
fn pausing_a_mirror_keeps_its_stream_and_pauses_it_once() {
    let log = StreamLog::new();
    let mut mirrors = mirrors(&log);
    let roster = roster();

    assert!(
        !mirrors.set_paused(&key(&roster, 0), true),
        "a monitor that is not mirrored cannot be paused",
    );

    let _ = mirrors.mirror(&key(&roster, 0));
    let _ = pump(&mut mirrors);

    assert!(mirrors.set_paused(&key(&roster, 0), true));
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
fn a_monitor_unplugged_during_selection_is_neither_reopened_nor_given_a_token() {
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
    let change = mirrors.attach(second_only());
    assert_eq!(change.removed, vec![first.clone()]);
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![second.clone()]));
    assert_eq!(mirrors.selection_state(), SelectionState::Ready);
    assert!(!mirrors.is_wanted(&first));
    assert!(!mirrors.is_mirroring(&first));
    assert!(mirrors.is_mirroring(&second));
    let tokens = mirrors
        .take_changed_tokens()
        .expect("the grant records tokens");
    assert!(tokens.token_for(&first).is_none());
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
fn a_monitor_mirrored_before_the_source_exists_starts_once_it_does() {
    // The source is unavailable until the graphics device supplies the importer's DRM formats.
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
    for _ in 0..4 {
        assert_eq!(mirrors.poll(), Progress::Idle);
    }
    assert_eq!(
        mirrors.mirror(&key(&roster, 1)),
        MirrorOutcome::Requested,
        "a mirror cannot start while no source exists",
    );

    mirrors.set_streams(Box::new(RecordingSource::new(log.clone())));

    assert_eq!(
        pump(&mut mirrors),
        Progress::Started(vec![key(&roster, 0), key(&roster, 1)]),
        "the source first chooses the portal, then opens the granted streams",
    );
    assert!(mirrors.is_mirroring(&key(&roster, 0)));
    assert_eq!(log.entries().len(), 2);
    assert_eq!(
        mirrors.portal().requests.len(),
        1,
        "a deferred start does not ask the portal a second time",
    );
}

#[test]
fn a_session_whose_every_node_is_removed_is_revoked_and_requested_again() {
    let log = StreamLog::new();
    let (mut mirrors, nodes) = watched(&log);
    let first = key(mirrors.roster(), 0);
    let second = key(mirrors.roster(), 1);
    let _ = mirrors.mirror(&first);
    let _ = mirrors.mirror(&second);
    assert_eq!(
        pump(&mut mirrors),
        Progress::Started(vec![first.clone(), second.clone()])
    );

    nodes.remove(node(11));
    nodes.remove(node(12));

    assert_eq!(mirrors.poll(), Progress::Waiting);
    assert!(!mirrors.is_mirroring(&first));
    assert!(!mirrors.is_mirroring(&second));
    assert!(mirrors.is_wanted(&first));
    assert!(mirrors.is_wanted(&second));
    assert_eq!(log.dropped(), vec![node(11), node(12)]);
    let requests = &mirrors.portal().requests;
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[1].restore_token,
        RestoreToken::new("fresh"),
        "the new request restores the revoked grant's token",
    );
}

#[test]
fn a_session_that_loses_one_node_keeps_the_rest_and_asks_for_nothing() {
    let log = StreamLog::new();
    let (mut mirrors, nodes) = watched(&log);
    let first = key(mirrors.roster(), 0);
    let second = key(mirrors.roster(), 1);
    let _ = mirrors.mirror(&first);
    let _ = mirrors.mirror(&second);
    let _ = pump(&mut mirrors);

    nodes.remove(node(11));

    assert_eq!(mirrors.poll(), Progress::Idle);
    assert!(!mirrors.is_mirroring(&first));
    assert!(
        mirrors.is_wanted(&first),
        "the monitor waits for a later grant"
    );
    assert!(mirrors.is_mirroring(&second));
    assert_eq!(log.dropped(), vec![node(11)]);
    assert_eq!(mirrors.portal().requests.len(), 1);
}

#[test]
fn removing_the_last_remaining_node_revokes_the_session() {
    let log = StreamLog::new();
    let (mut mirrors, nodes) = watched(&log);
    let first = key(mirrors.roster(), 0);
    let second = key(mirrors.roster(), 1);
    let _ = mirrors.mirror(&first);
    let _ = mirrors.mirror(&second);
    let _ = pump(&mut mirrors);

    nodes.remove(node(11));
    let _ = mirrors.poll();
    nodes.remove(node(12));
    let _ = mirrors.poll();

    assert!(!mirrors.is_mirroring(&second));
    assert_eq!(mirrors.portal().requests.len(), 2);
}

#[test]
fn removing_a_node_the_session_does_not_hold_changes_nothing() {
    let log = StreamLog::new();
    let (mut mirrors, nodes) = watched(&log);
    let first = key(mirrors.roster(), 0);
    let _ = mirrors.mirror(&first);
    let _ = pump(&mut mirrors);

    nodes.remove(node(40));

    assert_eq!(mirrors.poll(), Progress::Idle);
    assert!(mirrors.is_mirroring(&first));
    assert!(log.dropped().is_empty());
    assert_eq!(mirrors.portal().requests.len(), 1);
}

#[test]
fn a_removal_reported_before_the_grant_does_not_end_it() {
    let log = StreamLog::new();
    let (mut mirrors, nodes) = watched(&log);
    let first = key(mirrors.roster(), 0);
    let _ = mirrors.mirror(&first);

    // A node of an earlier session whose identifier the new grant reuses.
    nodes.remove(node(11));

    assert_eq!(pump(&mut mirrors), Progress::Started(vec![first.clone()]));
    assert_eq!(mirrors.poll(), Progress::Idle);
    assert!(mirrors.is_mirroring(&first));
}

#[test]
fn direct_capture_survives_the_removal_of_every_portal_node() {
    let log = StreamLog::new();
    let first = key(&roster(), 0);
    let second = key(&roster(), 1);
    let nodes = ScriptedNodes::new();
    let mut portal = FakePortal::new();
    portal.will_grant(response(vec![stream(12, 1)], "fresh"));
    let mut mirrors = MirrorSet::new(portal, CursorPolicy::Visible, TokenStore::new())
        .with_node_watch(Box::new(nodes.clone()));
    mirrors.attach(roster());
    mirrors.set_streams(Box::new(DirectSource {
        log: log.clone(),
        direct: Some(first.clone()),
    }));
    assert_eq!(mirrors.mirror(&first), MirrorOutcome::Mirroring);
    let _ = mirrors.mirror(&second);
    assert_eq!(pump(&mut mirrors), Progress::Started(vec![second.clone()]));

    nodes.remove(node(12));
    let _ = mirrors.poll();

    assert!(mirrors.is_direct(&first));
    assert!(!mirrors.is_mirroring(&second));
    assert_eq!(mirrors.portal().requests.len(), 2);
}
