//! The accumulator's decisions, exercised without a Wayland connection.
//!
//! The protocol exchange that feeds the accumulator is covered separately, by
//! `crates/lunette/tests/host_outputs.rs`, which runs this enumeration against a
//! real compositor.

use pretty_assertions::assert_eq;

use super::state::{HostOutputs, OutputId};
use crate::monitor::{
    geometry::{LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
    name::{ConnectorKind, ConnectorName, KeyStrength, MonitorKey},
};

fn output(name: u32) -> OutputId {
    OutputId::new(name)
}

/// An output described the way a wlroots compositor describes one: a
/// geometry event, a current mode, a scale, a connector name, and the logical
/// geometry from `zxdg_output_v1`.
fn described(outputs: &mut HostOutputs, id: OutputId, connector: &str, x: i32) {
    outputs.add(id);
    outputs.record_geometry(
        id,
        LogicalPosition::new(x, 0),
        Some(SurfaceTransform::Normal),
        "Acme".to_owned(),
        "X24".to_owned(),
    );
    outputs.record_name(id, connector);
    outputs.record_mode(id, true, PixelExtent::new(1920, 1080));
    outputs.record_scale(id, 1);
    outputs.record_logical_position(id, LogicalPosition::new(x, 0));
    outputs.record_logical_size(id, LogicalSize::new(1920, 1080));
}

#[test]
fn a_fully_described_output_becomes_a_monitor() {
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);

    let roster = outputs.roster();
    let monitors = roster.monitors();

    assert_eq!(monitors.len(), 1);
    assert_eq!(monitors[0].name().make(), Some("Acme"));
    assert_eq!(monitors[0].name().model(), Some("X24"));
    assert_eq!(
        monitors[0].name().connector(),
        Some(ConnectorName::new(ConnectorKind::DisplayPort, 1)),
    );
    assert_eq!(monitors[0].pixels(), PixelExtent::new(1920, 1080));
    assert_eq!(monitors[0].transform(), SurfaceTransform::Normal);
}

#[test]
fn an_output_that_has_said_nothing_yet_is_not_a_monitor() {
    // The registry announces an output before its events arrive, and an
    // incomplete output is skipped rather than given a guessed geometry.
    let mut outputs = HostOutputs::new();
    outputs.add(output(1));

    assert!(outputs.roster().monitors().is_empty());
}

#[test]
fn logical_geometry_is_preferred_to_the_derived_form() {
    // A fractionally scaled display: the integer scale is 2, so the derived
    // size would be 1920x1080, and the compositor reports a logical size of
    // 1280x720.
    let mut outputs = HostOutputs::new();
    outputs.add(output(1));
    outputs.record_geometry(
        output(1),
        LogicalPosition::new(0, 0),
        Some(SurfaceTransform::Normal),
        String::new(),
        String::new(),
    );
    outputs.record_mode(output(1), true, PixelExtent::new(3840, 2160));
    outputs.record_scale(output(1), 2);
    outputs.record_logical_size(output(1), LogicalSize::new(1280, 720));

    assert_eq!(
        outputs.roster().monitors()[0].size(),
        LogicalSize::new(1280, 720),
    );
}

#[test]
fn a_compositor_without_logical_geometry_falls_back_to_the_mode_and_the_scale() {
    let mut outputs = HostOutputs::new();
    outputs.add(output(1));
    outputs.record_geometry(
        output(1),
        LogicalPosition::new(1920, 0),
        Some(SurfaceTransform::Normal),
        String::new(),
        String::new(),
    );
    outputs.record_mode(output(1), true, PixelExtent::new(3840, 2160));
    outputs.record_scale(output(1), 2);

    let roster = outputs.roster();

    assert_eq!(roster.monitors()[0].size(), LogicalSize::new(1920, 1080));
    assert_eq!(
        roster.monitors()[0].position(),
        LogicalPosition::new(1920, 0),
    );
}

#[test]
fn the_derived_size_swaps_the_axes_for_a_rotated_output() {
    // A 1920x1080 panel mounted portrait occupies a 1080x1920 rectangle.
    let mut outputs = HostOutputs::new();
    outputs.add(output(1));
    outputs.record_geometry(
        output(1),
        LogicalPosition::new(0, 0),
        Some(SurfaceTransform::Rotate90),
        String::new(),
        String::new(),
    );
    outputs.record_mode(output(1), true, PixelExtent::new(1920, 1080));

    let roster = outputs.roster();

    assert_eq!(roster.monitors()[0].size(), LogicalSize::new(1080, 1920));
    assert_eq!(roster.monitors()[0].transform(), SurfaceTransform::Rotate90);
}

#[test]
fn a_scale_the_protocol_forbids_leaves_the_output_unplaceable() {
    // The compositor reported a scale the protocol forbids, so dividing by it
    // or silently treating the display as unscaled would both be wrong. The
    // output is left unplaceable.
    let mut outputs = HostOutputs::new();
    outputs.add(output(1));
    outputs.record_mode(output(1), true, PixelExtent::new(1920, 1080));
    outputs.record_scale(output(1), 0);

    assert!(outputs.roster().monitors().is_empty());
}

#[test]
fn a_mode_that_is_not_current_does_not_replace_the_one_that_is() {
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    outputs.record_mode(output(1), false, PixelExtent::new(1280, 720));

    assert_eq!(
        outputs.roster().monitors()[0].pixels(),
        PixelExtent::new(1920, 1080),
    );
}

#[test]
fn a_uuid_shaped_output_name_is_not_stored_as_a_connector() {
    // `wl_output.name` is documented as the connector name, and a compositor
    // is still free to put anything there.
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    outputs.record_name(output(1), "1b4e28ba-2fa1-11d2-883f-0016d3cca427");

    assert_eq!(outputs.roster().monitors()[0].name().connector(), None);
}

#[test]
fn a_make_of_unknown_does_not_become_an_identity() {
    // Several compositors send "Unknown" where the EDID carries nothing, and
    // such monitors would otherwise share one descriptor.
    let mut outputs = HostOutputs::new();
    outputs.add(output(1));
    outputs.record_geometry(
        output(1),
        LogicalPosition::new(0, 0),
        Some(SurfaceTransform::Normal),
        "Unknown".to_owned(),
        String::new(),
    );
    outputs.record_name(output(1), "DP-1");
    outputs.record_logical_size(output(1), LogicalSize::new(1920, 1080));

    assert_eq!(
        outputs.roster().monitors()[0].key(),
        &MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 1)),
    );
}

#[test]
fn two_identical_monitors_are_separated_by_the_connectors_wl_output_reports() {
    // Two identical monitors need separation that `mapping_id` cannot provide
    // on GNOME or KDE; the connector that `wl_output` reports provides it on
    // both.
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    described(&mut outputs, output(2), "DP-2", 1920);

    let roster = outputs.roster();
    let keys: Vec<&MonitorKey> = roster
        .monitors()
        .iter()
        .map(|monitor| monitor.key())
        .collect();

    assert_eq!(keys[0].strength(), KeyStrength::Descriptor);
    assert_eq!(
        keys[1],
        &MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, 2)),
    );
    assert_ne!(keys[0], keys[1]);
}

#[test]
fn an_unplugged_output_leaves_the_roster() {
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    described(&mut outputs, output(2), "DP-2", 1920);

    assert!(outputs.remove(output(1)));

    let roster = outputs.roster();
    assert_eq!(roster.monitors().len(), 1);
    assert_eq!(
        roster.monitors()[0].name().connector(),
        Some(ConnectorName::new(ConnectorKind::DisplayPort, 2)),
    );
}

#[test]
fn withdrawing_a_global_that_is_not_an_output_changes_nothing() {
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    let _ = outputs.take_changed();

    assert!(!outputs.remove(output(7)));
    assert!(!outputs.changed());
}

#[test]
fn announcing_the_same_output_twice_keeps_what_it_has_already_said() {
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    outputs.add(output(1));

    assert_eq!(outputs.len(), 1);
    assert_eq!(outputs.roster().monitors()[0].name().make(), Some("Acme"));
}

#[test]
fn an_event_for_an_output_that_is_gone_is_dropped_rather_than_reviving_it() {
    // The compositor can withdraw a global while events for it are still in
    // flight, so an event for a withdrawn output is a race condition, not a
    // defect.
    let mut outputs = HostOutputs::new();
    described(&mut outputs, output(1), "DP-1", 0);
    assert!(outputs.remove(output(1)));

    outputs.record_logical_size(output(1), LogicalSize::new(800, 600));

    assert!(outputs.roster().monitors().is_empty());
}

#[test]
fn recording_anything_marks_the_set_changed_exactly_once_per_read() {
    let mut outputs = HostOutputs::new();
    assert!(!outputs.changed());

    described(&mut outputs, output(1), "DP-1", 0);

    assert!(outputs.take_changed());
    assert!(!outputs.take_changed());
}

#[test]
fn an_empty_set_produces_an_empty_roster() {
    let outputs = HostOutputs::new();

    assert!(outputs.is_empty());
    assert!(outputs.roster().monitors().is_empty());
}
