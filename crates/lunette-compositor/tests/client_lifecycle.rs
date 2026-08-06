//! A client's life through the public API: connect, map, retitle, disappear.
//!
//! These drive a real `wayland-client` over a socket pair rather than calling
//! the handlers, because what needs establishing is that a client speaking the
//! protocol gets what it expects. See `tests/harness/mod.rs` for why none of it
//! needs a GPU.

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use harness::{EXPECTED_GLOBALS, WINDOW_SIZE, only_window, with_one_window};
use lunette_compositor::{
    protocol::{Event, WindowId},
    state::DEFAULT_OUTPUT,
    surface::ShmFormat,
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

#[test]
fn a_client_connecting_over_a_socket_pair_sees_every_global() {
    let mut compositor = TestCompositor::new();
    let client = TestClient::connect(&mut compositor);

    assert_eq!(client.globals(), EXPECTED_GLOBALS);
}

#[test]
fn a_toplevel_appears_in_the_snapshot_once_it_has_committed_content() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);

    assert!(
        compositor.snapshot().windows.is_empty(),
        "a toplevel that has never committed content has nothing to show"
    );

    client.attach_buffer(&mut compositor, WINDOW_SIZE);

    let opened: Vec<WindowId> = compositor
        .drain_events()
        .into_iter()
        .filter_map(|event| match event {
            Event::WindowOpened { window } => Some(window),
            _ => None,
        })
        .collect();
    assert_eq!(opened.len(), 1, "exactly one window opened");

    let window = only_window(&compositor);
    assert_eq!(window.window, opened[0]);
    assert_eq!(window.size, WINDOW_SIZE);
    assert_eq!(window.output, Some(DEFAULT_OUTPUT));
}

#[test]
fn a_title_change_is_reported_and_reaches_the_snapshot() {
    let (mut compositor, mut client) = with_one_window();
    drop(compositor.drain_events());

    client.set_title(&mut compositor, "a terminal");
    client.set_title(&mut compositor, "a terminal");

    let titles: Vec<String> = compositor
        .drain_events()
        .into_iter()
        .filter_map(|event| match event {
            Event::TitleChanged { title, .. } => Some(title),
            _ => None,
        })
        .collect();
    assert_eq!(
        titles,
        ["a terminal"],
        "setting the same title twice is not a change"
    );
    assert_eq!(
        only_window(&compositor).title.as_deref(),
        Some("a terminal")
    );
}

#[test]
fn a_disconnecting_client_closes_its_window_and_takes_it_out_of_the_snapshot() {
    let (mut compositor, client) = with_one_window();
    let window = only_window(&compositor).window;
    drop(compositor.drain_events());

    client.disconnect(&mut compositor);

    let events = compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::WindowClosed { .. }))
    });
    assert!(
        events.iter().any(
            |event| matches!(event, Event::WindowClosed { window: closed } if *closed == window)
        ),
        "the window that went away is the one reported: {events:?}"
    );
    assert!(
        compositor.snapshot().windows.is_empty(),
        "a handle whose window is absent from the snapshot is what `dead` reads as"
    );
}

#[test]
fn a_shm_commit_reaches_the_importer_with_the_layout_the_client_declared() {
    let (compositor, _client) = with_one_window();

    let layouts = compositor.imports().shm_layouts();
    assert_eq!(layouts.len(), 1, "one commit, one import");
    assert_eq!(layouts[0].size, WINDOW_SIZE);
    assert_eq!(layouts[0].stride, WINDOW_SIZE.width * 4);
    assert_eq!(layouts[0].format, ShmFormat::Argb8888);
    assert_eq!(
        compositor.imports().dmabuf_count(),
        0,
        "a shared-memory client must not reach the dmabuf path"
    );
}

#[test]
fn a_buffer_the_importer_refuses_leaves_the_window_out_of_the_snapshot() {
    let mut compositor = TestCompositor::new();
    compositor.imports().refuse("no graphics device");
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, WINDOW_SIZE);

    assert!(
        compositor.snapshot().windows.is_empty(),
        "a window with no importable content is not shown"
    );
}
