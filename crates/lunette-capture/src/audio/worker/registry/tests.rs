use super::*;
use crate::audio::tests_support::*;

#[test]
fn authoritative_info_properties_clear_mutable_pid_owner_and_channel_assertions() {
    let mut snapshot = system();
    let props = properties! { "object.serial" => "1020", "media.class" => "Stream/Output/Audio", "node.name" => "player", "client.id" => "40", "application.process.id" => "100", "client.api" => "pipewire-pulse" };
    update_node(&mut snapshot, 20, props.dict(), "test");
    let client = properties! { "object.serial" => "4000", "pipewire.sec.pid" => "999", "client.api" => "pipewire-pulse", "application.name" => "arbitrary display name" };
    update_client(&mut snapshot, 40, client.dict());
    assert_eq!(
        snapshot.process_candidates()[0].assertion.provenance,
        crate::audio::AttributionProvenance::ApplicationMetadata
    );
    let empty = properties! { "media.class" => "Stream/Output/Audio" };
    update_node(&mut snapshot, 20, empty.dict(), "test");
    assert_eq!(snapshot.nodes[&20].identity.serial.0, 1020);
    assert!(snapshot.nodes[&20].application_pid.is_none());
    assert!(snapshot.nodes[&20].client.is_none());
    assert!(snapshot.process_candidates().is_empty());
    let empty_client = properties! { "application.name" => "pipewire-pulse" };
    update_client(&mut snapshot, 40, empty_client.dict());
    assert!(snapshot.clients[&40].pid.is_none());
    assert_eq!(snapshot.clients[&40].kind, ClientKind::Native);
    let owned =
        properties! { "lunette.audio.owner" => "test", "media.class" => "Stream/Output/Audio" };
    update_node(&mut snapshot, 20, owned.dict(), "test");
    assert_eq!(snapshot.nodes[&20].kind, NodeKind::Owned);
    update_node(&mut snapshot, 20, empty.dict(), "test");
    assert_eq!(snapshot.nodes[&20].kind, NodeKind::Playback);
    let other = properties! { "node.name" => "test.lookalike" };
    update_node(&mut snapshot, 20, other.dict(), "test");
    assert_eq!(snapshot.nodes[&20].kind, NodeKind::Other);
    let port = properties! { "object.serial" => "2200", "node.id" => "20", "port.direction" => "out", "audio.channel" => "FL" };
    update_port(&mut snapshot, 200, port.dict());
    update_port(&mut snapshot, 200, other.dict());
    assert_eq!(snapshot.ports[&200].channel, "");
    assert!(!snapshot.ports[&200].output);
}

// PipeWire sends an info event's property dictionary only when its change mask
// names properties. A state or parameter change, such as the default sink
// resuming or renegotiating its latency for a new stream, arrives with an empty
// dictionary. Treating that as authoritative made the default sink an unnamed
// non-sink node, and the system source stayed unavailable until a reconnect.
#[test]
fn state_and_parameter_info_events_keep_the_default_sink_and_its_properties() {
    let mut snapshot = RegistrySnapshot::new(lunette_compositor::protocol::PipeWireGeneration(1));
    snapshot.default_sink = crate::audio::DefaultSink::Name("speakers".into());
    let sink = properties! { "object.serial" => "1010", "media.class" => "Audio/Sink", "node.name" => "speakers" };
    node_info(
        &mut snapshot,
        10,
        pw::node::NodeChangeMask::all(),
        Some(sink.dict()),
        "test",
    );
    let system = || crate::audio::plan_graph(crate::audio::Source::System, &snapshot, None).state;
    assert!(matches!(
        system(),
        crate::audio::CaptureState::Active { .. }
    ));
    let empty = pw::properties::PropertiesBox::new();
    for mask in [
        pw::node::NodeChangeMask::STATE,
        pw::node::NodeChangeMask::PARAMS,
    ] {
        node_info(&mut snapshot, 10, mask, Some(empty.dict()), "test");
        assert_eq!(snapshot.nodes[&10].kind, NodeKind::Sink);
        assert_eq!(snapshot.nodes[&10].name, "speakers");
        assert!(matches!(
            crate::audio::plan_graph(crate::audio::Source::System, &snapshot, None).state,
            crate::audio::CaptureState::Active { .. }
        ));
    }
    let client = properties! { "object.serial" => "4000", "pipewire.sec.pid" => "999" };
    client_info(
        &mut snapshot,
        40,
        pw::client::ClientChangeMask::PROPS,
        Some(client.dict()),
    );
    client_info(
        &mut snapshot,
        40,
        pw::client::ClientChangeMask::empty(),
        Some(empty.dict()),
    );
    assert!(snapshot.clients[&40].pid.is_some());
    let port = properties! { "object.serial" => "2200", "node.id" => "10", "port.direction" => "out", "audio.channel" => "FL" };
    port_info(
        &mut snapshot,
        200,
        pw::port::PortChangeMask::all(),
        Some(port.dict()),
    );
    port_info(
        &mut snapshot,
        200,
        pw::port::PortChangeMask::PARAMS,
        Some(empty.dict()),
    );
    assert!(snapshot.ports[&200].output);
    assert_eq!(snapshot.ports[&200].channel, "FL");
    let renamed = properties! { "media.class" => "Audio/Sink", "node.name" => "headphones" };
    node_info(
        &mut snapshot,
        10,
        pw::node::NodeChangeMask::PROPS,
        Some(renamed.dict()),
        "test",
    );
    assert_eq!(snapshot.nodes[&10].name, "headphones");
}
