//! Tests for [`crate::state`].
//!
//! What a client sees over the protocol — the globals, mapping, retitling,
//! disconnection, and pointer routing — is covered by the integration suite in
//! `tests/`, which reaches the crate through its public API. What is here is
//! everything that needs `pub(crate)` access, plus the command paths a client
//! cannot drive on its own.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::ffi::{OsStr, OsString};

use pretty_assertions::assert_eq;
use smithay::backend::allocator::{Format, Fourcc, Modifier};

use crate::{
    client::XwaylandSatellite,
    protocol::{
        Argv, Command, Event, PixelSize, PointerButton, ProcessId, ProcessOutcome, ProcessSignal,
        SpawnRequest as SpawnCommand, Stream, ToplevelState, ToplevelStates, WindowSnapshot,
    },
    state::{
        DEFAULT_OUTPUT,
        compositor::{CompositorConfig, DmabufSupport, protocol_state, toplevel_state},
        input::evdev_button,
    },
    test_client::TestClient,
    testing::TestCompositor,
};

/// A compositor with one mapped window, and the client that owns it.
fn with_one_window() -> (TestCompositor, TestClient) {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, PixelSize::new(640, 480));
    (compositor, client)
}

fn only_window(compositor: &TestCompositor) -> WindowSnapshot {
    let snapshot = compositor.snapshot();
    assert_eq!(snapshot.windows.len(), 1, "expected exactly one window");
    snapshot.windows[0].clone()
}

/// A compositor that accepts linear `argb8888` over `zwp_linux_dmabuf_v1`.
///
/// The formats normally come from the graphics device. A test has none, so it
/// names the one the fake importer accepts, which is all the dmabuf path needs
/// to be reachable.
fn accepting_dmabuf() -> CompositorConfig {
    CompositorConfig {
        dmabuf: DmabufSupport {
            main_device: None,
            formats: vec![Format {
                code: Fourcc::Argb8888,
                modifier: Modifier::Linear,
            }],
        },
        ..CompositorConfig::default()
    }
}

#[test]
fn a_surface_falling_back_to_shared_memory_releases_the_dmabuf_it_held() {
    let mut compositor = TestCompositor::with_config(accepting_dmabuf());
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);

    let dmabuf = client.attach_dmabuf(&mut compositor, PixelSize::new(640, 480));
    assert!(
        !client.driver().released.contains(&dmabuf),
        "a dmabuf is held for as long as lunette samples it"
    );

    // The fallback a client makes when modifier negotiation changes under it.
    client.attach_buffer(&mut compositor, PixelSize::new(640, 480));
    client.settle(&mut compositor, |driver| !driver.released.is_empty());

    assert!(
        client.driver().released.contains(&dmabuf),
        "the dmabuf is no longer being sampled, so the client must be told it may reuse it"
    );
}

/// The surface an event names, for the events that name one.
fn surface_of(event: &Event) -> Option<crate::protocol::SurfaceId> {
    match event {
        Event::BufferImported { surface, .. }
        | Event::SurfaceDamaged { surface }
        | Event::SurfaceGone { surface } => Some(*surface),
        _ => None,
    }
}

#[test]
fn destroying_a_surface_that_is_not_a_window_reports_it_gone() {
    // The regression: a cursor surface, a popup, and a subsurface all commit
    // buffers, so each becomes a texture on the frame thread. Only a toplevel
    // is ever reported closed, so without this event the frame thread held a
    // texture over an image the compositor had already retired.
    let (mut compositor, mut client) = with_one_window();
    let cursor = client.open_plain_surface(&mut compositor, PixelSize::new(24, 24));

    let imported = compositor
        .drain_events()
        .iter()
        .filter_map(|event| match event {
            Event::BufferImported { surface, .. } => Some(*surface),
            _ => None,
        })
        .next_back()
        .expect("the plain surface's buffer was imported");

    client.destroy_surface(&mut compositor, &cursor);

    assert!(
        compositor
            .drain_events()
            .iter()
            .any(|event| matches!(event, Event::SurfaceGone { surface } if *surface == imported)),
        "the frame thread has a texture for this surface and nothing else would tell it to \
         release it"
    );
}

#[test]
fn a_disconnecting_client_reports_its_surfaces_gone() {
    let (mut compositor, client) = with_one_window();
    let surface = compositor
        .drain_events()
        .iter()
        .find_map(surface_of)
        .expect("the toplevel's buffer was imported");

    client.disconnect(&mut compositor);

    assert!(
        compositor
            .drain_events()
            .iter()
            .any(|event| matches!(event, Event::SurfaceGone { surface: gone } if *gone == surface)),
        "a client that vanishes leaves its textures for the frame thread to release"
    );
}

#[test]
fn unmapping_a_window_reports_the_surface_gone_after_the_window_closed() {
    let (mut compositor, mut client) = with_one_window();
    drop(compositor.drain_events());

    // A null buffer unmaps a toplevel, and the protocol lets the client map it
    // again by committing another.
    client.detach_buffer(&mut compositor);

    let events = compositor.drain_events();
    let closed = events
        .iter()
        .position(|event| matches!(event, Event::WindowClosed { .. }))
        .expect("unmapping closes the window");
    let gone = events
        .iter()
        .position(|event| matches!(event, Event::SurfaceGone { .. }))
        .expect("unmapping takes the surface's content with it");

    assert!(
        closed < gone,
        "the window dies before its texture is dropped, so a handler reading the closure still \
         sees what the ledger knew"
    );
}

#[test]
fn a_dispatch_sweeps_the_importer_even_though_it_imported_nothing() {
    // Only a sweep notices a disconnect. Retirement driven by imports alone
    // leaves a disconnected or quiet client's images held for the life of the
    // process, and the live count the shutdown path logs describes buffers
    // freed long before.
    let (mut compositor, client) = with_one_window();
    let imports = compositor.imports();
    let (sweeps, dmabufs) = (imports.sweep_count(), imports.dmabuf_count());

    client.disconnect(&mut compositor);

    assert!(
        imports.sweep_count() > sweeps,
        "dropping the retained buffer is what makes its image collectable, and only a sweep \
         notices"
    );
    assert_eq!(
        imports.dmabuf_count(),
        dmabufs,
        "nothing was imported, which is the case an import-driven sweep cannot cover"
    );
}

#[test]
fn a_toplevel_with_no_buffer_is_not_yet_a_window() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);

    assert!(
        compositor.snapshot().windows.is_empty(),
        "a toplevel that has never committed content has nothing to show"
    );
    assert!(
        !compositor
            .drain_events()
            .iter()
            .any(|event| matches!(event, Event::WindowOpened { .. })),
        "nothing opened, because nothing was drawn"
    );
}

#[test]
fn destroying_a_toplevel_reports_the_window_closed_and_removes_it() {
    let (mut compositor, mut client) = with_one_window();
    let window = only_window(&compositor).window;
    drop(compositor.drain_events());

    client.close_toplevel(&mut compositor);

    assert!(
        compositor.drain_events().iter().any(
            |event| matches!(event, Event::WindowClosed { window: closed } if *closed == window)
        ),
        "the window that went away is the one reported"
    );
    assert!(compositor.snapshot().windows.is_empty());
}

#[test]
fn closing_a_window_asks_the_client_rather_than_removing_it() {
    let (mut compositor, mut client) = with_one_window();
    let window = only_window(&compositor).window;

    compositor.send(Command::CloseWindow { window });
    client.settle(&mut compositor, |driver| driver.closed);

    assert_eq!(
        compositor.snapshot().windows.len(),
        1,
        "a close is a request; the window stays until the client acts on it"
    );
}

#[test]
fn configuring_a_window_sizes_the_toplevel_without_changing_the_snapshot() {
    let (mut compositor, mut client) = with_one_window();
    let window = only_window(&compositor).window;

    compositor.send(Command::ConfigureWindow {
        window,
        size: Some(PixelSize::new(800, 600)),
        states: ToplevelStates::new(),
    });
    client.settle(&mut compositor, |driver| {
        driver.toplevel_size == Some((800, 600))
    });

    assert_eq!(
        only_window(&compositor).size,
        PixelSize::new(640, 480),
        "the snapshot reports what the client committed, not what it was asked for"
    );
}

#[test]
fn closing_a_window_that_is_already_gone_is_not_an_error() {
    let (mut compositor, mut client) = with_one_window();
    let window = only_window(&compositor).window;
    client.close_toplevel(&mut compositor);

    compositor.send(Command::CloseWindow { window });
    client.settle_quiet(&mut compositor);
}

#[test]
fn the_default_output_is_reported_with_the_configured_mode() {
    let compositor = TestCompositor::new();
    let snapshot = compositor.snapshot();

    assert_eq!(snapshot.outputs.len(), 1);
    assert_eq!(snapshot.outputs[0].output, DEFAULT_OUTPUT);
    assert_eq!(
        snapshot.outputs[0].mode.size,
        CompositorConfig::default().output.size
    );
}

#[test]
fn spawning_a_program_that_does_not_exist_reports_a_failure_and_creates_no_window() {
    let mut compositor = TestCompositor::new();
    compositor.spawns().refuse("no such file or directory");
    let process = ProcessId::new(1).expect("non-zero");

    compositor.send(Command::Spawn(SpawnCommand {
        process,
        argv: Argv::from_list(vec![OsString::from("not-a-program")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));

    let events = compositor.collect_events(|events| !events.is_empty());
    let reported = events
        .iter()
        .find_map(|event| match event {
            Event::ProcessExited {
                process: reported,
                outcome,
            } if *reported == process => Some(outcome.clone()),
            _ => None,
        })
        .unwrap_or_else(|| panic!("the failure was not reported: {events:?}"));

    assert!(
        matches!(reported, ProcessOutcome::SpawnFailed { message } if message.contains("not-a-program")),
        "the report names the program that could not be started"
    );
    assert!(compositor.snapshot().windows.is_empty());
    assert!(
        compositor.snapshot().processes.is_empty(),
        "a process that never ran is not tracked"
    );
}

#[test]
fn a_spawned_process_is_reported_until_it_exits() {
    let mut compositor = TestCompositor::new();
    let process = ProcessId::new(1).expect("non-zero");
    compositor.send(Command::Spawn(SpawnCommand {
        process,
        argv: Argv::from_list(vec![OsString::from("foot")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();
    compositor.step();

    let snapshot = compositor.snapshot();
    assert_eq!(snapshot.processes.len(), 1);
    assert_eq!(snapshot.processes[0].process, process);
    assert!(!snapshot.processes[0].external);
    assert!(snapshot.processes[0].alive);

    compositor
        .spawns()
        .finish(0, ProcessOutcome::Exited { code: 3 });

    let events = compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::ProcessExited { .. }))
    });
    assert!(events.iter().any(|event| matches!(
        event,
        Event::ProcessExited { process: reported, outcome: ProcessOutcome::Exited { code: 3 } }
            if *reported == process
    )));
    assert!(compositor.snapshot().processes.is_empty());
}

#[test]
fn a_spawned_process_output_is_reported_as_bytes() {
    let mut compositor = TestCompositor::new();
    let process = ProcessId::new(1).expect("non-zero");
    compositor.send(Command::Spawn(SpawnCommand {
        process,
        argv: Argv::from_list(vec![OsString::from("foot")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();

    // Not UTF-8, which a child's output is under no obligation to be.
    compositor.spawns().write(0, Stream::Stderr, &[0xFF, b'!']);

    let events = compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::ProcessOutput { .. }))
    });
    assert!(events.iter().any(|event| matches!(
        event,
        Event::ProcessOutput { stream: Stream::Stderr, bytes, .. } if bytes == &[0xFF, b'!']
    )));
}

#[test]
fn signalling_a_process_reaches_its_group() {
    let mut compositor = TestCompositor::new();
    let process = ProcessId::new(1).expect("non-zero");
    compositor.send(Command::Spawn(SpawnCommand {
        process,
        argv: Argv::from_list(vec![OsString::from("foot")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();

    compositor.send(Command::SignalProcess {
        process,
        signal: ProcessSignal::Terminate,
    });
    compositor.step();

    assert_eq!(compositor.spawns().signals(0), [ProcessSignal::Terminate]);
}

#[test]
fn a_client_that_matches_no_process_is_adopted_as_external() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, PixelSize::new(320, 240));

    let snapshot = compositor.snapshot();
    assert_eq!(snapshot.processes.len(), 1);
    assert!(
        snapshot.processes[0].external,
        "a client lunette did not start is external"
    );
    assert_eq!(
        only_window(&compositor).process,
        Some(snapshot.processes[0].process),
        "an adopted process still owns the windows of the client it came with"
    );
}

#[test]
fn a_client_presenting_a_spawned_process_token_is_attributed_to_it() {
    let mut compositor = TestCompositor::new();
    let process = ProcessId::new(1).expect("non-zero");
    compositor.send(Command::Spawn(SpawnCommand {
        process,
        argv: Argv::from_list(vec![OsString::from("sh")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();

    // The connecting pid over a socket pair is the test's own, which is not
    // the pid the spawner reported — exactly the shape a shell wrapper or a
    // flatpak sandbox produces, and the reason the token exists.
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
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, PixelSize::new(320, 240));

    assert_eq!(only_window(&compositor).process, Some(process));
    assert!(
        !compositor
            .snapshot()
            .processes
            .iter()
            .any(|reported| reported.external),
        "a client that presented a valid token is not external"
    );
}

/// A configuration with a bound display and an x11 bridge, as the entry
/// point would build it.
fn with_display() -> CompositorConfig {
    CompositorConfig {
        display: Some(crate::client::DisplayName::for_test(20)),
        satellite: Some(XwaylandSatellite {
            executable: std::path::PathBuf::from("xwayland-satellite"),
        }),
        ..CompositorConfig::default()
    }
}

#[test]
fn the_x11_bridge_is_started_once_when_the_display_is_bound() {
    let compositor = TestCompositor::with_config(with_display());

    let requested = compositor.spawns().requested();
    assert_eq!(requested.len(), 1);
    assert_eq!(
        requested[0].argv.program(),
        OsStr::new("xwayland-satellite")
    );
    assert!(
        !compositor
            .snapshot()
            .processes
            .iter()
            .any(|process| process.external),
        "the bridge is lunette's own plumbing, not a user process"
    );
}

#[test]
fn nothing_is_bridged_when_no_display_was_bound() {
    let compositor = TestCompositor::new();
    assert!(
        compositor.spawns().requested().is_empty(),
        "there is nowhere for an x11 bridge to connect to"
    );
}

#[test]
fn a_spawned_client_is_told_the_display_that_was_bound() {
    let mut compositor = TestCompositor::with_config(with_display());
    compositor.send(Command::Spawn(SpawnCommand {
        process: ProcessId::new(1).expect("non-zero"),
        argv: Argv::from_list(vec![OsString::from("foot")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();

    let requested = compositor.spawns().requested();
    let plan = requested.last().expect("the spawn was requested");
    let value = |key: &str| {
        plan.env
            .iter()
            .rev()
            .find(|(name, _)| name == OsStr::new(key))
            .map(|(_, value)| value.clone())
    };

    assert_eq!(value("WAYLAND_DISPLAY"), Some(OsString::from("wayland-20")));
    assert_eq!(value("DISPLAY"), Some(OsString::from(":20")));
}

#[test]
fn a_spawned_client_is_told_nothing_when_no_display_was_bound() {
    let mut compositor = TestCompositor::new();
    compositor.send(Command::Spawn(SpawnCommand {
        process: ProcessId::new(1).expect("non-zero"),
        argv: Argv::from_list(vec![OsString::from("foot")]).expect("non-empty"),
        env: Vec::new(),
        cwd: None,
        output: None,
        xwayland: false,
    }));
    compositor.step();

    let requested = compositor.spawns().requested();
    assert!(
        !requested[0]
            .env
            .iter()
            .any(|(key, _)| key == OsStr::new("WAYLAND_DISPLAY")),
        "an empty display name would make a client connect to a socket called nothing, \
         rather than fall back to the session's own"
    );
}

#[test]
fn every_pointer_button_maps_to_a_distinct_evdev_code() {
    let buttons = [
        PointerButton::Left,
        PointerButton::Right,
        PointerButton::Middle,
        PointerButton::Back,
        PointerButton::Forward,
    ];
    let mut codes: Vec<u32> = buttons.into_iter().map(evdev_button).collect();
    codes.sort_unstable();
    codes.dedup();

    assert_eq!(codes.len(), buttons.len(), "two buttons share a code");
    assert_eq!(evdev_button(PointerButton::Left), 0x110, "BTN_LEFT");
}

#[test]
fn every_reported_toplevel_state_round_trips_through_the_protocol() {
    for state in [
        ToplevelState::Maximized,
        ToplevelState::Fullscreen,
        ToplevelState::Resizing,
        ToplevelState::Activated,
        ToplevelState::TiledLeft,
        ToplevelState::TiledRight,
        ToplevelState::TiledTop,
        ToplevelState::TiledBottom,
        ToplevelState::Suspended,
    ] {
        assert_eq!(
            toplevel_state(protocol_state(state)),
            Some(state),
            "{state:?} did not survive the round trip"
        );
    }
}
