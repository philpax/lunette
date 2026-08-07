//! What a client is told about the scale of the output it is on.
//!
//! Driven over a real `wayland-client`, because the whole subject is what
//! arrives on the wire: `wp_fractional_scale_v1.preferred_scale` in 120ths,
//! `wl_surface.preferred_buffer_scale` as a whole number, and the toplevel
//! configure that carries the matching logical size. None of the three is
//! observable from the compositor's own side.
//!
//! The three travel together on purpose. A client renders at the fractional
//! scale, sets an integer `wl_surface.set_buffer_scale`, and corrects the
//! result with `wp_viewport.set_destination`; given only some of the three it
//! produces sharp content at the wrong size, which reads as a bug in the client
//! rather than as a missing configure in the compositor.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use lunette_compositor::{
    protocol::{Command, OutputId, OutputMode, OutputScale, PixelSize, RefreshRate},
    state::DEFAULT_OUTPUT,
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

/// The identifier the main thread would mint for the first Lua-created output.
const SECOND_OUTPUT: OutputId = match OutputId::new(2) {
    Some(output) => output,
    None => unreachable!(),
};

fn mode(width: u32, height: u32, scale: f64) -> OutputMode {
    OutputMode {
        size: PixelSize::new(width, height),
        scale: OutputScale::new(scale).expect("the test names a positive scale"),
        refresh: RefreshRate::from_millihertz(60_000),
    }
}

/// A compositor whose default output has the named scale, and a client on it
/// with a mapped toplevel.
fn with_scaled_output(scale: f64) -> (TestCompositor, TestClient) {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::ReconfigureOutput {
        output: DEFAULT_OUTPUT,
        mode: mode(2560, 1440, scale),
    });
    compositor.step();

    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    (compositor, client)
}

#[test]
fn the_manager_is_advertised_and_a_client_can_obtain_a_fractional_scale() {
    let (mut compositor, mut client) = with_scaled_output(1.5);
    let surface = client.surface().expect("a toplevel was opened").clone();

    let fractional = client.request_fractional_scale(&surface);
    client.settle(&mut compositor, |driver| {
        !driver.preferred_scales(&fractional).is_empty()
    });

    assert!(
        !client.is_disconnected(),
        "obtaining a wp_fractional_scale_v1 is not a protocol error"
    );
}

#[test]
fn the_preferred_scale_arrives_in_120ths() {
    // 1.5 is 180 in the protocol's own unit, and the unit is the reason
    // `crates/lunette/src/scale.rs` keeps its ladder in 120ths rather than as
    // floats.
    let (mut compositor, mut client) = with_scaled_output(1.5);
    let surface = client.surface().expect("a toplevel was opened").clone();

    let fractional = client.request_fractional_scale(&surface);
    client.settle(&mut compositor, |driver| {
        !driver.preferred_scales(&fractional).is_empty()
    });

    assert_eq!(client.driver().preferred_scales(&fractional), vec![180]);
}

#[test]
fn a_scale_that_is_not_a_whole_number_of_120ths_is_rounded() {
    // A ninth of one is 13.33 in 120ths. The protocol carries a `uint`, so a
    // compositor either rounds or lies about the unit.
    let (mut compositor, mut client) = with_scaled_output(1.0 + 1.0 / 9.0);
    let surface = client.surface().expect("a toplevel was opened").clone();

    let fractional = client.request_fractional_scale(&surface);
    client.settle(&mut compositor, |driver| {
        !driver.preferred_scales(&fractional).is_empty()
    });

    assert_eq!(client.driver().preferred_scales(&fractional), vec![133]);
}

#[test]
fn the_scale_set_before_the_object_existed_is_replayed_on_creation() {
    // The surface is created, mapped, and settled long before the client asks
    // for its fractional scale. Setting the preferred scale at surface creation
    // is what avoids a first frame at the wrong one, and this is the property
    // that makes pre-setting safe.
    let (mut compositor, mut client) = with_scaled_output(2.0);
    client.attach_buffer(&mut compositor, PixelSize::new(640, 480));
    client.settle_quiet(&mut compositor);

    let surface = client.surface().expect("a toplevel was opened").clone();
    let fractional = client.request_fractional_scale(&surface);
    client.settle(&mut compositor, |driver| {
        !driver.preferred_scales(&fractional).is_empty()
    });

    assert_eq!(client.driver().preferred_scales(&fractional), vec![240]);
}

#[test]
fn raising_the_output_scale_tells_the_client_to_render_sharper() {
    // `lunette-v1.AC2.5`, as far as the compositor's side of it reaches: the
    // client is told the new fractional scale, the new whole-number scale, and
    // the logical size that goes with them.
    let (mut compositor, mut client) = with_scaled_output(1.0);
    let surface = client.surface().expect("a toplevel was opened").clone();
    let surface_id = client.surface_id().expect("a toplevel was opened");

    let fractional = client.request_fractional_scale(&surface);
    // Larger than the logical bounds the doubled scale will leave, so the
    // configure that follows has a visible number in it rather than the size the
    // window already had.
    client.attach_buffer(&mut compositor, PixelSize::new(1600, 900));
    client.settle_quiet(&mut compositor);

    compositor.send(Command::ReconfigureOutput {
        output: DEFAULT_OUTPUT,
        mode: mode(2560, 1440, 2.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.preferred_scales(&fractional).contains(&240)
    });

    assert_eq!(
        client.driver().preferred_scales(&fractional).last(),
        Some(&240),
        "the fractional scale the client renders at"
    );
    assert_eq!(
        client.driver().buffer_scales(&surface_id).last(),
        Some(&2),
        "the whole-number scale a client without the fractional protocol renders at"
    );
    // 2560x1440 at scale two is 1280x720 logical, so the 1600x900 window is
    // pulled in rather than left overhanging the output it is on.
    assert_eq!(
        client.driver().toplevel_size,
        Some((1280, 720)),
        "the configure carrying the logical size that matches the new scale"
    );
}

#[test]
fn a_reconfigure_that_leaves_the_scale_alone_sends_no_new_preferred_scale() {
    // A client re-rendering its whole surface because its refresh rate changed
    // is exactly the waste discrete steps and hysteresis exist to avoid, and
    // `set_preferred_scale` sending only on a change is what delivers it.
    let (mut compositor, mut client) = with_scaled_output(1.5);
    let surface = client.surface().expect("a toplevel was opened").clone();

    let fractional = client.request_fractional_scale(&surface);
    client.settle(&mut compositor, |driver| {
        !driver.preferred_scales(&fractional).is_empty()
    });

    compositor.send(Command::ReconfigureOutput {
        output: DEFAULT_OUTPUT,
        mode: OutputMode {
            refresh: RefreshRate::from_millihertz(90_000),
            ..mode(2560, 1440, 1.5)
        },
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().preferred_scales(&fractional),
        vec![180],
        "the scale did not change, so nothing about it was sent again"
    );
}

#[test]
fn the_preferred_buffer_scale_is_the_ceiling_of_the_fractional_one() {
    // 1.5 rounds up to 2, not down to 1. Rounding down would tell a client its
    // monitor is unscaled and leave it rendering at half the density the
    // fractional scale asked for.
    let (mut compositor, mut client) = with_scaled_output(1.5);
    let surface_id = client.surface_id().expect("a toplevel was opened");
    client.settle_quiet(&mut compositor);

    assert_eq!(client.driver().buffer_scales(&surface_id), vec![2]);
}

#[test]
fn a_client_on_another_output_is_unaffected_by_a_reconfigure() {
    // Two outputs are the point: with one, a scale sent to everybody and a scale
    // sent to the right client are the same picture.
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateOutput {
        output: SECOND_OUTPUT,
        mode: mode(1920, 1080, 1.0),
    });
    compositor.step();

    let (stream, _client) = compositor.connect_assigned(SECOND_OUTPUT);
    let mut elsewhere = TestClient::from_stream(stream, &mut compositor);
    elsewhere.open_toplevel(&mut compositor);
    let elsewhere_surface = elsewhere.surface().expect("a toplevel was opened").clone();
    let elsewhere_scale = elsewhere.request_fractional_scale(&elsewhere_surface);
    elsewhere.settle(&mut compositor, |driver| {
        !driver.preferred_scales(&elsewhere_scale).is_empty()
    });

    compositor.send(Command::ReconfigureOutput {
        output: DEFAULT_OUTPUT,
        mode: mode(2560, 1440, 3.0),
    });
    elsewhere.settle_quiet(&mut compositor);

    assert_eq!(
        elsewhere.driver().preferred_scales(&elsewhere_scale),
        vec![120],
        "the client is on the other output, and its scale did not move"
    );
}
