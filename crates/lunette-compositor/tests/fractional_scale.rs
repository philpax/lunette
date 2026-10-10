//! Exercises the client-visible output-scale protocols over a real
//! `wayland-client` connection.
//!
//! Clients bind `wp_fractional_scale_manager_v1` at version 1 and request
//! `wp_fractional_scale_v1` objects. The compositor reports the preferred
//! fractional scale in 120ths, the preferred buffer scale as an integer, and
//! the matching logical size in an xdg-toplevel configure. The integer scale is
//! the ceiling of the fractional scale for clients without fractional-scale
//! support; the logical size uses the fractional scale.
//!
//! `TestCompositor` runs the real display and handlers on the calling thread.
//! The harness connects over `UnixStream::pair()` and uses a recording importer
//! in place of a graphics device. The driver records protocol events in arrival
//! order. `open_toplevel` completes the initial configure handshake before a
//! test attaches a buffer, and `TestClient` retains fractional-scale objects for
//! their surface lifetime.

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
    config::DEFAULT_OUTPUT,
    protocol::{Command, OutputId, OutputMode, OutputScale, PixelSize, RefreshRate},
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

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
    // Smithay rounds `scale * 120.0` to the protocol's unsigned integer.
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
    // The surface has already committed a buffer when the client creates the
    // fractional-scale object, so the first event must replay the stored scale.
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
    // Reconfiguration derives the fractional scale, integer buffer scale, and
    // logical configure from the same output mode.
    let (mut compositor, mut client) = with_scaled_output(1.0);
    let surface = client.surface().expect("a toplevel was opened").clone();
    let surface_id = client.surface_id().expect("a toplevel was opened");

    let fractional = client.request_fractional_scale(&surface);
    // This buffer exceeds the 1280x720 bounds at scale 2.0, which makes the new
    // logical configure observable.
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
    assert_eq!(
        client.driver().toplevel_size,
        Some((1280, 720)),
        "the configure carrying the logical size that matches the new scale"
    );
}

#[test]
fn a_reconfigure_that_leaves_the_scale_alone_sends_no_new_preferred_scale() {
    // Smithay suppresses `preferred_scale` when the stored fractional scale is
    // unchanged, even when another output property changes.
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
    let (mut compositor, mut client) = with_scaled_output(1.5);
    let surface_id = client.surface_id().expect("a toplevel was opened");
    client.settle_quiet(&mut compositor);

    assert_eq!(client.driver().buffer_scales(&surface_id), vec![2]);
}

#[test]
fn a_client_on_another_output_is_unaffected_by_a_reconfigure() {
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
