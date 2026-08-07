//! The virtual monitors clients are told about.
//!
//! Driven over a real `wayland-client`, because what needs establishing is what
//! a client sees on `wl_output` — the mode, the scale, the name — and none of
//! that is observable from the compositor's own side.

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
use wayland_client::Proxy;

/// The identifier the main thread would mint for the first Lua-created output.
///
/// One past the default, which is what `Session::mint_output` allocates from.
const SECOND_OUTPUT: OutputId = match OutputId::new(2) {
    Some(output) => output,
    None => unreachable!(),
};

const THIRD_OUTPUT: OutputId = match OutputId::new(3) {
    Some(output) => output,
    None => unreachable!(),
};

fn mode(width: u32, height: u32, scale: f64, hertz: u32) -> OutputMode {
    OutputMode {
        size: PixelSize::new(width, height),
        scale: OutputScale::new(scale).expect("the test names a positive scale"),
        refresh: RefreshRate::from_millihertz(hertz * 1_000),
    }
}

#[test]
fn a_session_starts_with_one_output_and_the_snapshot_describes_it() {
    let mut compositor = TestCompositor::new();
    compositor.step();

    let snapshot = compositor.snapshot();
    assert_eq!(snapshot.outputs.len(), 1);
    assert_eq!(snapshot.outputs[0].output, DEFAULT_OUTPUT);
    assert_eq!(snapshot.outputs[0].mode.size, PixelSize::new(2560, 1440));
}

#[test]
fn a_created_output_reaches_the_client_with_the_mode_it_was_asked_for() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateOutput {
        output: SECOND_OUTPUT,
        mode: mode(1920, 1080, 1.5, 90),
    });

    let mut client = TestClient::connect(&mut compositor);
    client.settle(&mut compositor, |driver| {
        driver
            .globals
            .iter()
            .filter(|global| global.interface == "wl_output")
            .count()
            == 2
    });

    let outputs = client.bind_outputs(&mut compositor);
    let reported: Vec<_> = outputs
        .iter()
        .filter_map(|output| client.driver().output(output))
        .collect();

    let created = reported
        .iter()
        .find(|state| state.name.as_deref() == Some("lunette-2"))
        .expect("the created output reported its name");

    assert_eq!(created.size, (1920, 1080));
    // Hertz in Lua, millihertz on the wire, converted once at the boundary.
    assert_eq!(created.refresh, 90_000);
    // The ceiling of 1.5, because `wl_output.scale` is a whole number and
    // rounding down would tell the client its monitor is unscaled.
    assert_eq!(created.scale, 2);
}

#[test]
fn two_outputs_with_different_scales_coexist() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateOutput {
        output: SECOND_OUTPUT,
        mode: mode(1920, 1080, 1.0, 60),
    });
    compositor.send(Command::CreateOutput {
        output: THIRD_OUTPUT,
        mode: mode(1920, 1080, 2.0, 60),
    });

    let mut client = TestClient::connect(&mut compositor);
    client.settle(&mut compositor, |driver| {
        driver
            .globals
            .iter()
            .filter(|global| global.interface == "wl_output")
            .count()
            == 3
    });

    let outputs = client.bind_outputs(&mut compositor);
    let named = |name: &str| {
        outputs
            .iter()
            .filter_map(|output| client.driver().output(output))
            .find(|state| state.name.as_deref() == Some(name))
            .unwrap_or_else(|| panic!("{name} reported its configuration"))
    };

    let unscaled = named("lunette-2");
    let doubled = named("lunette-3");

    assert_eq!(unscaled.scale, 1);
    assert_eq!(doubled.scale, 2);
    assert_eq!(unscaled.size, doubled.size);
    // The same resolution over half the physical size is what a doubled scale
    // means, and it is what a client divides to guess a density.
    assert_eq!(doubled.physical.0 * 2, unscaled.physical.0);
}

#[test]
fn reconfiguring_an_output_tells_the_clients_that_bound_it() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    let outputs = client.bind_outputs(&mut compositor);
    let output = outputs.first().expect("the default output was bound");

    assert_eq!(
        client
            .driver()
            .output(output)
            .expect("the default output reported its configuration")
            .size,
        (2560, 1440)
    );

    compositor.send(Command::ReconfigureOutput {
        output: DEFAULT_OUTPUT,
        mode: mode(3840, 2160, 2.0, 120),
    });
    client.settle(&mut compositor, |driver| {
        driver
            .output(output)
            .is_some_and(|state| state.size == (3840, 2160))
    });

    let state = client
        .driver()
        .output(output)
        .expect("the reconfigured output reported its configuration");
    assert_eq!(state.refresh, 120_000);
    assert_eq!(state.scale, 2);
}

#[test]
fn a_destroyed_output_stops_being_advertised() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateOutput {
        output: SECOND_OUTPUT,
        mode: mode(1920, 1080, 1.0, 60),
    });

    let mut client = TestClient::connect(&mut compositor);
    let advertised = |client: &TestClient| {
        client
            .driver()
            .globals
            .iter()
            .filter(|global| global.interface == "wl_output")
            .count()
    };
    client.settle(&mut compositor, |driver| {
        driver
            .globals
            .iter()
            .filter(|global| global.interface == "wl_output")
            .count()
            == 2
    });

    compositor.send(Command::DestroyOutput {
        output: SECOND_OUTPUT,
    });
    client.settle(&mut compositor, |driver| {
        driver
            .globals
            .iter()
            .filter(|global| global.interface == "wl_output")
            .count()
            == 1
    });

    assert_eq!(advertised(&client), 1);
    let snapshot = compositor.snapshot();
    assert_eq!(snapshot.outputs.len(), 1);
    assert_eq!(snapshot.outputs[0].output, DEFAULT_OUTPUT);
}

#[test]
fn the_default_output_refuses_to_be_destroyed() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::DestroyOutput {
        output: DEFAULT_OUTPUT,
    });

    let mut client = TestClient::connect(&mut compositor);
    client.settle_quiet(&mut compositor);

    // A client assigned no output has to see something, and every adopted
    // client is one of those.
    assert_eq!(compositor.snapshot().outputs.len(), 1);
    assert_eq!(
        client
            .driver()
            .globals
            .iter()
            .filter(|global| global.interface == "wl_output")
            .count(),
        1
    );
}

#[test]
fn a_surface_is_told_which_output_it_is_on() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    let outputs = client.bind_outputs(&mut compositor);
    let output = outputs.first().expect("the default output was bound").id();

    client.open_toplevel(&mut compositor);
    let surface = client
        .surface_id()
        .expect("opening a toplevel created a surface");
    client.settle(&mut compositor, move |driver| {
        driver.surface_outputs(&surface).contains(&output)
    });
}
