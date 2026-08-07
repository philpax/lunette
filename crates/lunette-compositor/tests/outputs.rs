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

use std::ffi::{OsStr, OsString};

use lunette_compositor::{
    protocol::{
        Argv, Command, OutputId, OutputMode, OutputScale, PixelSize, ProcessId, RefreshRate,
        SpawnRequest,
    },
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
    compositor.step();

    let (stream, _client) = compositor.connect_assigned(SECOND_OUTPUT);
    let mut client = TestClient::from_stream(stream, &mut compositor);
    let outputs = client.bind_outputs(&mut compositor);
    let created = outputs
        .first()
        .and_then(|output| client.driver().output(output))
        .expect("the created output reported its configuration");

    assert_eq!(created.name.as_deref(), Some("lunette-2"));
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
    compositor.step();

    let (unscaled_stream, _first) = compositor.connect_assigned(SECOND_OUTPUT);
    let (doubled_stream, _second) = compositor.connect_assigned(THIRD_OUTPUT);
    let mut unscaled_client = TestClient::from_stream(unscaled_stream, &mut compositor);
    let mut doubled_client = TestClient::from_stream(doubled_stream, &mut compositor);

    let read = |client: &mut TestClient, compositor: &mut TestCompositor| {
        let outputs = client.bind_outputs(compositor);
        outputs
            .first()
            .and_then(|output| client.driver().output(output))
            .expect("the client's output reported its configuration")
    };
    let unscaled = read(&mut unscaled_client, &mut compositor);
    let doubled = read(&mut doubled_client, &mut compositor);

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
    compositor.step();

    let (stream, _client) = compositor.connect_assigned(SECOND_OUTPUT);
    let mut client = TestClient::from_stream(stream, &mut compositor);
    client.settle(&mut compositor, |driver| {
        driver
            .globals
            .iter()
            .any(|global| global.interface == "wl_output")
    });

    compositor.send(Command::DestroyOutput {
        output: SECOND_OUTPUT,
    });
    client.settle(&mut compositor, |driver| {
        !driver
            .globals
            .iter()
            .any(|global| global.interface == "wl_output")
    });

    assert_eq!(advertised(&client), 0);
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

// Per-client filtering. Two clients are the point: with one, an advertisement
// that shows everything and one that shows the right thing are the same
// picture.

/// How many `wl_output` globals a client has been advertised.
fn advertised(client: &TestClient) -> usize {
    client
        .driver()
        .globals
        .iter()
        .filter(|global| global.interface == "wl_output")
        .count()
}

/// A compositor with the default output and two more.
fn with_three_outputs() -> TestCompositor {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::CreateOutput {
        output: SECOND_OUTPUT,
        mode: mode(1920, 1080, 1.0, 60),
    });
    compositor.send(Command::CreateOutput {
        output: THIRD_OUTPUT,
        mode: mode(1280, 720, 2.0, 90),
    });
    compositor.step();
    compositor
}

/// The names of every output a client bound, sorted.
fn bound_names(client: &mut TestClient, compositor: &mut TestCompositor) -> Vec<String> {
    let outputs = client.bind_outputs(compositor);
    let mut names: Vec<String> = outputs
        .iter()
        .filter_map(|output| client.driver().output(output))
        .filter_map(|state| state.name)
        .collect();
    names.sort();
    names
}

#[test]
fn a_client_assigned_one_output_is_advertised_exactly_that_one() {
    let mut compositor = with_three_outputs();
    let (stream, _client) = compositor.connect_assigned(SECOND_OUTPUT);
    let mut client = TestClient::from_stream(stream, &mut compositor);

    assert_eq!(advertised(&client), 1);
    assert_eq!(
        bound_names(&mut client, &mut compositor),
        vec!["lunette-2".to_owned()]
    );
}

#[test]
fn a_client_assigned_none_is_advertised_the_default_output_and_no_other() {
    let mut compositor = with_three_outputs();
    let mut client = TestClient::connect(&mut compositor);
    client.settle_quiet(&mut compositor);

    assert_eq!(advertised(&client), 1);
    assert_eq!(
        bound_names(&mut client, &mut compositor),
        vec!["lunette-1".to_owned()]
    );
}

#[test]
fn two_clients_with_different_assignments_each_see_only_their_own() {
    let mut compositor = with_three_outputs();
    let (first_stream, _first_client) = compositor.connect_assigned(SECOND_OUTPUT);
    let (second_stream, _second_client) = compositor.connect_assigned(THIRD_OUTPUT);
    let mut first = TestClient::from_stream(first_stream, &mut compositor);
    let mut second = TestClient::from_stream(second_stream, &mut compositor);

    assert_eq!(
        bound_names(&mut first, &mut compositor),
        vec!["lunette-2".to_owned()]
    );
    assert_eq!(
        bound_names(&mut second, &mut compositor),
        vec!["lunette-3".to_owned()]
    );
}

#[test]
fn binding_an_output_the_client_was_never_advertised_is_refused() {
    let mut compositor = with_three_outputs();

    // Registry names are per-display, so the name a client learns for its own
    // output is the same integer every other client would see for it. That is
    // what supplies a name the first client was never told and could not have
    // guessed from its own registry — and binding a name it *was* told is the
    // control, since an arbitrary integer would be refused for being the wrong
    // interface rather than for being the wrong output.
    let (second_stream, _second) = compositor.connect_assigned(SECOND_OUTPUT);
    let (third_stream, _third) = compositor.connect_assigned(THIRD_OUTPUT);
    let mut client = TestClient::from_stream(second_stream, &mut compositor);
    let mut other = TestClient::from_stream(third_stream, &mut compositor);

    let output_name = |client: &TestClient| {
        client
            .driver()
            .globals
            .iter()
            .find(|global| global.interface == "wl_output")
            .map(|global| global.name)
            .expect("each client was advertised its own output")
    };
    for settling in [&mut client, &mut other] {
        settling.settle(&mut compositor, |driver| {
            driver
                .globals
                .iter()
                .any(|global| global.interface == "wl_output")
        });
    }

    let hidden = output_name(&other);
    assert_ne!(
        hidden,
        output_name(&client),
        "the two clients were assigned different outputs"
    );

    drop(client.bind_output_by_name(hidden, 4));
    client.settle_quiet(&mut compositor);

    assert!(
        client.is_disconnected(),
        "binding an output global the client was never advertised must fail"
    );
    assert!(
        !other.is_disconnected(),
        "the refusal is this client's own; nothing else is torn down"
    );
}

#[test]
fn the_output_a_client_was_advertised_binds_and_stays_bound() {
    let mut compositor = with_three_outputs();
    let (stream, _client) = compositor.connect_assigned(SECOND_OUTPUT);
    let mut client = TestClient::from_stream(stream, &mut compositor);

    assert_eq!(
        bound_names(&mut client, &mut compositor),
        vec!["lunette-2".to_owned()]
    );
    assert!(
        !client.is_disconnected(),
        "binding the output the client was shown is not a protocol error"
    );
}

#[test]
fn a_spawn_naming_an_output_shows_its_client_that_output() {
    let mut compositor = with_three_outputs();
    let process = ProcessId::new(1).expect("non-zero");
    compositor.send(Command::Spawn(SpawnRequest {
        process,
        argv: Argv::from_list(vec![OsString::from("sh")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: Some(SECOND_OUTPUT),
        xwayland: false,
    }));
    compositor.step();

    // The connecting pid over a socket pair is the test's own rather than the
    // one the spawner reported, which is the shape a shell wrapper produces and
    // the reason the token exists.
    let plan = compositor.spawns().requested();
    let token = plan[0]
        .env
        .iter()
        .find(|(key, _)| key == OsStr::new("LUNETTE_DISPLAY_AUTH"))
        .map(|(_, value)| value.clone())
        .expect("a spawn carries a token");
    let connecting = i32::try_from(std::process::id()).expect("a plausible pid");
    compositor
        .proc()
        .set_variable(connecting, "LUNETTE_DISPLAY_AUTH", token.as_encoded_bytes());

    let mut client = TestClient::connect(&mut compositor);

    assert_eq!(advertised(&client), 1);
    assert_eq!(
        bound_names(&mut client, &mut compositor),
        vec!["lunette-2".to_owned()]
    );
    assert_eq!(
        only_window_output(&mut client, &mut compositor),
        SECOND_OUTPUT,
        "the window reports the output its client was assigned"
    );
}

/// The output the client's only window reports, once it has one.
fn only_window_output(client: &mut TestClient, compositor: &mut TestCompositor) -> OutputId {
    client.open_toplevel(compositor);
    client.attach_buffer(compositor, PixelSize::new(320, 240));
    harness::only_window(compositor).output
}

#[test]
fn a_spawn_naming_an_output_that_does_not_exist_falls_back_to_the_default() {
    let mut compositor = TestCompositor::new();
    let process = ProcessId::new(1).expect("non-zero");
    compositor.send(Command::Spawn(SpawnRequest {
        process,
        argv: Argv::from_list(vec![OsString::from("sh")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        // Never created. Assigning it would show the client no monitor at all.
        output: Some(SECOND_OUTPUT),
        xwayland: false,
    }));
    compositor.step();

    let plan = compositor.spawns().requested();
    let token = plan[0]
        .env
        .iter()
        .find(|(key, _)| key == OsStr::new("LUNETTE_DISPLAY_AUTH"))
        .map(|(_, value)| value.clone())
        .expect("a spawn carries a token");
    let connecting = i32::try_from(std::process::id()).expect("a plausible pid");
    compositor
        .proc()
        .set_variable(connecting, "LUNETTE_DISPLAY_AUTH", token.as_encoded_bytes());

    let mut client = TestClient::connect(&mut compositor);

    assert_eq!(
        bound_names(&mut client, &mut compositor),
        vec!["lunette-1".to_owned()]
    );
}
