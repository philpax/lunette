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
