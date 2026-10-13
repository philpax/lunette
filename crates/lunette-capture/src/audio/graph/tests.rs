use lunette_compositor::protocol::ProcessObservationFailure;

use super::*;
use crate::audio::tests_support::*;

#[test]
fn late_attribution_reply_is_discarded() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL", "FR"]);
    let candidate = snapshot.process_candidates()[0];
    let request = snapshot
        .observe_process(candidate, live(1))
        .unwrap_or_else(|| unreachable!());
    assert!(!snapshot.attribution_reply(
        AudioAttributionReply {
            request,
            process: Some(process())
        },
        live(2)
    ));
    assert!(snapshot.attributions.is_empty());
    assert!(snapshot.process_candidates().is_empty());
    assert!(snapshot.observe_process(candidate, live(2)).is_none());
    snapshot.remove(20);
    playback(&mut snapshot, 20, &["FL", "FR"]);
    assert!(
        snapshot
            .observe_process(snapshot.process_candidates()[0], live(2))
            .is_some()
    );
}

#[test]
fn unresolved_reply_never_retries_replacement_instance() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    let candidate = snapshot.process_candidates()[0];
    let denied = ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied);
    assert!(snapshot.observe_process(candidate, denied).is_none());
    let request = snapshot
        .observe_process(candidate, live(1))
        .unwrap_or_else(|| unreachable!());
    assert!(snapshot.attribution_reply(
        AudioAttributionReply {
            request,
            process: None
        },
        live(1)
    ));
    assert!(snapshot.observe_process(candidate, live(2)).is_none());
    assert!(snapshot.attributions.is_empty());
}

#[test]
fn node_instance_history_survives_client_replacement_and_pid_assertion_changes() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    let old_candidate = snapshot.process_candidates()[0];
    let request = snapshot
        .observe_process(old_candidate, live(1))
        .unwrap_or_else(|| unreachable!());
    assert!(snapshot.attribution_reply(
        AudioAttributionReply {
            request,
            process: None
        },
        live(1)
    ));
    let mut incoming = system();
    playback(&mut incoming, 20, &["FL"]);
    if let Some(client) = incoming.clients.get_mut(&40) {
        client.identity.serial += 1;
    }
    snapshot.update_observations(incoming.clone());
    assert!(
        snapshot.observe_process(old_candidate, live(1)).is_none(),
        "old candidate assertion cannot cross client reuse"
    );
    let current = snapshot.process_candidates()[0];
    assert!(
        snapshot.observe_process(current, live(2)).is_none(),
        "same node cannot bind replacement instance"
    );
    assert!(
        snapshot.observe_process(current, live(1)).is_some(),
        "unchanged instance may retry against current assertion"
    );
    incoming.clients.clear();
    snapshot.update_observations(incoming);
    let mut incoming = system();
    playback(&mut incoming, 20, &["FL"]);
    snapshot.update_observations(incoming);
    assert!(
        snapshot
            .observe_process(snapshot.process_candidates()[0], live(2))
            .is_none()
    );
}

#[test]
fn pending_observation_and_reply_cannot_cross_client_reuse() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    let old = snapshot.process_candidates()[0];
    let request = snapshot
        .observe_process(old, live(1))
        .unwrap_or_else(|| unreachable!());
    let mut incoming = system();
    playback(&mut incoming, 20, &["FL"]);
    if let Some(client) = incoming.clients.get_mut(&40) {
        client.identity.serial += 1;
    }
    snapshot.update_observations(incoming);
    assert!(snapshot.observe_process(old, live(1)).is_none());
    assert!(!snapshot.attribution_reply(
        AudioAttributionReply {
            request,
            process: Some(process())
        },
        live(1)
    ));
    assert!(snapshot.attributions.is_empty());
}

#[test]
fn pulse_metadata_attribution_is_explicit() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["MONO"]);
    if let Some(client) = snapshot.clients.get_mut(&40) {
        client.kind = ClientKind::Pulse;
        client.pid = Pid::new(999);
    }
    let candidate = snapshot.process_candidates()[0];
    assert_eq!(candidate.pid, pid());
    assert_eq!(
        candidate.assertion.provenance,
        AttributionProvenance::ApplicationMetadata
    );
    let request = snapshot
        .observe_process(candidate, live(1))
        .unwrap_or_else(|| unreachable!());
    assert!(snapshot.attribution_reply(
        AudioAttributionReply {
            request,
            process: Some(process())
        },
        live(1)
    ));
    mixer(&mut snapshot);
    let plan = plan_graph(Source::Process(process()), &snapshot, Some(90));
    assert_eq!(plan.links.len(), 2);
    assert_eq!(
        plan.state,
        CaptureState::Active {
            provenance: Some(AttributionProvenance::ApplicationMetadata)
        }
    );
    if let Some(client) = snapshot.clients.get_mut(&40) {
        client.kind = ClientKind::Native;
    }
    assert_eq!(
        snapshot.assertion(identity(20).serial),
        AssertionStatus::Ambiguous
    );
}

#[test]
fn downmix_is_complete_deterministic_and_unknown_positions_fail() {
    let mut snapshot = system();
    mixer(&mut snapshot);
    playback(&mut snapshot, 20, &["FL", "FR", "FC", "LFE", "SL", "SR"]);
    attribute(&mut snapshot, 20);
    playback(&mut snapshot, 21, &["MONO"]);
    attribute(&mut snapshot, 21);
    let plan = plan_graph(Source::Process(process()), &snapshot, Some(90));
    assert_eq!(plan.links.len(), 10);
    let outputs: BTreeSet<_> = plan
        .links
        .iter()
        .map(|link| link.output_port.global)
        .collect();
    assert_eq!(
        outputs.len(),
        7,
        "all channels from both attributed nodes are included"
    );
    port(&mut snapshot, 219, 21, true, "AUX0");
    let plan = plan_graph(Source::Process(process()), &snapshot, Some(90));
    assert!(plan.links.is_empty());
    assert!(matches!(
        plan.state,
        CaptureState::Unavailable {
            reason: UnavailableReason::UnsupportedFormat,
            ..
        }
    ));
}

#[test]
fn silent_target_is_idle_when_other_processes_are_resolved_and_starting_until_its_ports_arrive() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL"]);
    attribute(&mut snapshot, 20);
    let other = ProcessId::new(2).unwrap_or_else(|| unreachable!());
    assert_eq!(
        plan_graph(Source::Process(other), &snapshot, None).state,
        CaptureState::Idle
    );
    playback(&mut snapshot, 21, &["FR"]);
    assert!(matches!(
        plan_graph(Source::Process(other), &snapshot, None).state,
        CaptureState::Unavailable {
            reason: UnavailableReason::UnresolvedAttribution,
            ..
        }
    ));
    assert_eq!(
        plan_graph(Source::Process(process()), &snapshot, None).state,
        CaptureState::Starting
    );
    mixer(&mut snapshot);
    assert!(matches!(
        plan_graph(Source::Process(process()), &snapshot, Some(90)).state,
        CaptureState::Active { .. }
    ));
    snapshot.ports.retain(|_, port| port.node != 20);
    assert_eq!(
        plan_graph(Source::Process(process()), &snapshot, Some(90)).state,
        CaptureState::Starting
    );
}

#[test]
fn default_sink_json_and_ambiguous_name_never_fall_back_to_microphone() {
    assert_eq!(parse_default_sink(None), DefaultSink::Missing);
    assert_eq!(parse_default_sink(Some("speakers")), DefaultSink::Invalid);
    assert_eq!(
        parse_default_sink(Some(r#"{"name":"speakers"}"#)),
        DefaultSink::Name("speakers".into())
    );
    let mut snapshot = system();
    node(&mut snapshot, 13, NodeKind::Sink, "speakers");
    let plan = plan_graph(Source::System, &snapshot, None);
    assert!(plan.monitor.is_none());
    assert!(matches!(
        plan.state,
        CaptureState::Unavailable {
            reason: UnavailableReason::InvalidDefaultSink,
            ..
        }
    ));
}

// A Pulse client's security PID is the pipewire-pulse daemon's own PID, so it
// cannot attribute a stream whose node lacks application metadata.
#[test]
fn pulse_stream_without_application_metadata_has_no_assertion() {
    let mut snapshot = system();
    playback(&mut snapshot, 20, &["FL", "FR"]);
    if let Some(node) = snapshot.nodes.get_mut(&20) {
        node.application_pid = None;
    }
    if let Some(client) = snapshot.clients.get_mut(&40) {
        client.kind = ClientKind::Pulse;
    }
    assert_eq!(
        snapshot.assertion(identity(20).serial),
        AssertionStatus::Missing
    );
    assert!(snapshot.process_candidates().is_empty());
    if let Some(client) = snapshot.clients.get_mut(&40) {
        client.kind = ClientKind::Native;
    }
    if let Some(node) = snapshot.nodes.get_mut(&20) {
        node.client_api = Some("pipewire-pulse".into());
    }
    assert_eq!(
        snapshot.assertion(identity(20).serial),
        AssertionStatus::Missing
    );
}

// A host stream, such as a voice client lunette did not start, must not make a
// silent pinned process look unattributed once the host answers that the
// stream's process belongs to no lunette process.
