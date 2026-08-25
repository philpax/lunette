//! Tests selection transfers between a real Wayland client and a fake host.
//!
//! The compositor advertises both selection protocols and both data-control
//! managers so clients can choose a compatible interface.
//!
//! Transfers pass file descriptors between the owners of the bytes; the compositor
//! does not copy selection contents. MIME lists are re-offered byte for byte in
//! source order in both directions, and requests for unadvertised types are refused.
//!
//! The client and compositor use the in-process socket-pair harness, so the tests
//! run without a host compositor, desktop session, or GPU.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use std::io::Write;

use harness::WINDOW_SIZE;
use lunette_compositor::{
    protocol::{Command, KeyboardConfig, KeymapConfig, SeatId},
    selection::{FakeHost, HostCall, HostEvent, MimeType, OfferCounter, SelectionKind},
    state::{CompositorConfig, DEFAULT_SEAT},
    test_client::{SelectionDevices, TestClient, read_to_end},
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

const UTF8: &str = "text/plain;charset=utf-8";

const SEAT: &str = "lunette";

/// A focused client with a fake host selection provider.
///
/// Selection offers reach only a focused client, and requests from an unfocused
/// client are refused.
fn with_host() -> (TestCompositor, TestClient, FakeHost, SelectionDevices) {
    let host = FakeHost::default();
    let mut compositor = TestCompositor::with_config(CompositorConfig {
        host_selection: Some(host.source()),
        ..CompositorConfig::default()
    });

    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, WINDOW_SIZE);

    let sink = compositor
        .snapshot()
        .windows
        .first()
        .expect("the window mapped")
        .sink;
    compositor.send(Command::Focus {
        seat: DEFAULT_SEAT,
        sink: Some(sink),
    });
    client.settle_quiet(&mut compositor);

    // Bind the selection devices before announcing a host offer so the client can
    // receive it.
    let devices = client.open_selection(&mut compositor, SEAT);

    (compositor, client, host, devices)
}

/// Announces a host offer with a strictly increasing identifier, then waits until the client
/// receives it.
fn host_copies(
    compositor: &mut TestCompositor,
    client: &mut TestClient,
    devices: &SelectionDevices,
    host: &FakeHost,
    counter: &OfferCounter,
    kind: SelectionKind,
    mimes: &[&str],
) {
    let offer = counter.next();
    host.announce(HostEvent::Offered {
        kind,
        offer,
        mimes: mimes
            .iter()
            .copied()
            .map(|mime| MimeType::new(mime).expect("a non-empty mime type"))
            .collect(),
    });
    client.settle(compositor, |driver| driver.has_selection(devices, kind));
}

#[test]
fn both_selection_protocols_and_both_data_controls_are_advertised() {
    let (_compositor, client, _host, _devices) = with_host();

    let globals = client.globals();
    for wanted in [
        "wl_data_device_manager",
        "zwp_primary_selection_device_manager_v1",
        "zwlr_data_control_manager_v1",
        "ext_data_control_manager_v1",
    ] {
        assert!(
            globals.iter().any(|global| global == wanted),
            "{wanted} is not advertised; the client sees {globals:?}"
        );
    }
}

#[test]
fn a_host_selection_is_offered_to_a_client_with_the_hosts_own_mime_types() {
    let (mut compositor, mut client, host, devices) = with_host();
    let counter = OfferCounter::new();

    for &kind in SelectionKind::ALL {
        host_copies(
            &mut compositor,
            &mut client,
            &devices,
            &host,
            &counter,
            kind,
            &[UTF8, "text/plain", "TEXT"],
        );

        assert_eq!(
            client.driver().offered(&devices, kind),
            vec![UTF8.to_owned(), "text/plain".to_owned(), "TEXT".to_owned()],
            "the {kind} offer did not carry the host's own list, unchanged",
        );
    }
}

#[test]
fn pasting_in_a_client_reads_the_bytes_the_host_writes_into_its_own_pipe() {
    // The client gives the pipe's write end to the receive request and keeps its
    // read end; the compositor forwards that descriptor without reading or writing it.
    let (mut compositor, mut client, host, devices) = with_host();
    let counter = OfferCounter::new();

    for (kind, text) in SelectionKind::ALL
        .iter()
        .copied()
        .zip(["clipped", "primary"])
    {
        host_copies(
            &mut compositor,
            &mut client,
            &devices,
            &host,
            &counter,
            kind,
            &[UTF8],
        );

        let reader = client.paste(&mut compositor, &devices, kind, UTF8);

        assert_eq!(
            host.calls().last(),
            Some(&HostCall::Read {
                kind,
                mime: MimeType::new(UTF8).expect("non-empty"),
            }),
            "the read did not reach the host",
        );

        let mut pipes = host.take_pipes();
        assert_eq!(
            pipes.len(),
            1,
            "expected exactly one descriptor to be passed"
        );
        let mut writer = std::fs::File::from(pipes.remove(0));
        writer.write_all(text.as_bytes()).expect("the pipe accepts");
        drop(writer);

        assert_eq!(read_to_end(reader), text.as_bytes());
    }
}

#[test]
fn copying_in_a_client_publishes_the_clients_own_mime_types_to_the_host() {
    let (mut compositor, mut client, host, devices) = with_host();

    for &kind in SelectionKind::ALL {
        drop(client.copy(&mut compositor, &devices, kind, &[UTF8, "text/html"]));

        assert_eq!(
            host.calls().last(),
            Some(&HostCall::Publish {
                kind,
                mimes: vec![
                    MimeType::new(UTF8).expect("non-empty"),
                    MimeType::new("text/html").expect("non-empty"),
                ],
            }),
            "the {kind} offer was not published to the host as the client wrote it",
        );
    }
}

#[test]
fn pasting_on_the_host_reads_the_bytes_the_client_writes_into_the_hosts_pipe() {
    // The host gives the pipe's write end to the compositor, which forwards it to
    // the client source that owns the selection.
    let (mut compositor, mut client, host, devices) = with_host();

    for (kind, text) in SelectionKind::ALL
        .iter()
        .copied()
        .zip(["copied", "selected"])
    {
        let _source = client.copy(&mut compositor, &devices, kind, &[UTF8]);

        let (reader, writer) = std::os::unix::net::UnixStream::pair().expect("a socket pair");
        reader.set_nonblocking(true).expect("a fresh socket");
        host.announce(HostEvent::Send {
            kind,
            mime: MimeType::new(UTF8).expect("non-empty"),
            pipe: writer.into(),
        });

        client.settle(&mut compositor, |driver| !driver.sends_are_empty());
        let mut asked = client.take_sends();
        assert_eq!(asked.len(), 1, "expected exactly one request from the host");
        let (mime, pipe) = asked.remove(0);
        assert_eq!(mime, UTF8);

        let mut answer = std::fs::File::from(pipe);
        answer.write_all(text.as_bytes()).expect("the pipe accepts");
        drop(answer);

        assert_eq!(read_to_end(reader.into()), text.as_bytes());
    }
}

#[test]
fn a_mime_type_the_host_does_not_offer_is_refused_rather_than_substituted() {
    let (mut compositor, mut client, host, devices) = with_host();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &devices,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &["image/png"],
    );

    let reader = client.paste(&mut compositor, &devices, SelectionKind::Clipboard, UTF8);

    assert!(
        !host
            .calls()
            .iter()
            .any(|call| matches!(call, HostCall::Read { .. })),
        "a type the host does not offer was asked for anyway: {:?}",
        host.calls(),
    );
    assert!(read_to_end(reader).is_empty());
}

#[test]
fn the_host_clearing_its_selection_withdraws_the_offer_from_the_client() {
    let (mut compositor, mut client, host, devices) = with_host();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &devices,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    host.announce(HostEvent::Cleared {
        kind: SelectionKind::Clipboard,
    });
    client.settle(&mut compositor, |driver| {
        !driver.has_selection(&devices, SelectionKind::Clipboard)
    });

    assert!(
        !client
            .driver()
            .has_selection(&devices, SelectionKind::Clipboard)
    );
}

#[test]
fn a_client_offering_no_mime_types_withdraws_rather_than_publishing_nothing() {
    let (mut compositor, mut client, host, devices) = with_host();
    drop(client.copy(&mut compositor, &devices, SelectionKind::Clipboard, &[UTF8]));

    drop(client.copy(&mut compositor, &devices, SelectionKind::Clipboard, &[]));

    assert_eq!(
        host.calls().last(),
        Some(&HostCall::Withdraw {
            kind: SelectionKind::Clipboard
        }),
    );
}

#[test]
fn an_empty_source_on_a_clipboard_lunette_never_owned_says_nothing_to_the_host() {
    let (mut compositor, mut client, host, devices) = with_host();

    drop(client.copy(&mut compositor, &devices, SelectionKind::Clipboard, &[]));

    assert_eq!(
        host.calls(),
        Vec::new(),
        "an empty source reached the host at all",
    );
}

#[test]
fn a_client_that_never_reads_its_pipe_stalls_nothing() {
    // The compositor does not read the forwarded descriptor, so a client that
    // leaves its pipe unread cannot block other clients.
    let (mut compositor, mut client, host, devices) = with_host();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &devices,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    let unread = client.paste(&mut compositor, &devices, SelectionKind::Clipboard, UTF8);

    let mut second = TestClient::connect(&mut compositor);
    second.open_toplevel(&mut compositor);
    second.attach_buffer(&mut compositor, WINDOW_SIZE);

    assert_eq!(
        compositor.snapshot().windows.len(),
        2,
        "the compositor stopped serving clients while a transfer was outstanding",
    );
    drop(unread);
}

#[test]
fn a_session_with_no_host_desktop_keeps_its_selections_to_itself() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, WINDOW_SIZE);

    let sink = compositor
        .snapshot()
        .windows
        .first()
        .expect("the window mapped")
        .sink;
    compositor.send(Command::Focus {
        seat: DEFAULT_SEAT,
        sink: Some(sink),
    });
    client.settle_quiet(&mut compositor);

    let devices = client.open_selection(&mut compositor, SEAT);
    drop(client.copy(&mut compositor, &devices, SelectionKind::Clipboard, &[UTF8]));

    assert!(
        client
            .driver()
            .has_selection(&devices, SelectionKind::Clipboard),
        "a client's own selection was not offered back to it",
    );
}

const SECOND: (SeatId, &str) = (
    match SeatId::new(2) {
        Some(seat) => seat,
        None => unreachable!(),
    },
    "second",
);

fn keyboard() -> Box<KeyboardConfig> {
    Box::new(KeyboardConfig {
        keymap: KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        },
        ..KeyboardConfig::default()
    })
}

/// A host bridge with two seats focused on one client.
///
/// Only the designated bridge seat exchanges selections with the host. Both seats
/// focus the same surface, so selection differences reflect bridge routing.
fn with_two_seats() -> (
    TestCompositor,
    TestClient,
    FakeHost,
    SelectionDevices,
    SelectionDevices,
) {
    let (mut compositor, mut client, host, first) = with_host();

    compositor.send(Command::CreateSeat {
        seat: SECOND.0,
        name: SECOND.1.to_owned(),
        keyboard: keyboard(),
    });
    client.settle(&mut compositor, |driver| {
        driver
            .globals
            .iter()
            .filter(|global| global.interface == "wl_seat")
            .count()
            == 2
    });

    let sink = compositor
        .snapshot()
        .windows
        .first()
        .expect("the window mapped")
        .sink;
    compositor.send(Command::Focus {
        seat: SECOND.0,
        sink: Some(sink),
    });
    client.settle_quiet(&mut compositor);

    let second = client.open_selection(&mut compositor, SECOND.1);
    (compositor, client, host, first, second)
}

#[test]
fn only_the_bridged_seat_sees_the_hosts_selection() {
    let (mut compositor, mut client, host, first, second) = with_two_seats();
    let counter = OfferCounter::new();

    host_copies(
        &mut compositor,
        &mut client,
        &first,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    assert!(
        client
            .driver()
            .has_selection(&first, SelectionKind::Clipboard),
    );
    assert!(
        !client
            .driver()
            .has_selection(&second, SelectionKind::Clipboard),
        "an unbridged seat was given the host's selection",
    );
}

#[test]
fn a_copy_on_an_unbridged_seat_stays_inside_lunette() {
    let (mut compositor, mut client, host, _first, second) = with_two_seats();

    drop(client.copy(&mut compositor, &second, SelectionKind::Clipboard, &[UTF8]));

    assert!(
        !host
            .calls()
            .iter()
            .any(|call| matches!(call, HostCall::Publish { .. })),
        "an unbridged seat's copy reached the host: {:?}",
        host.calls(),
    );
    assert!(
        client
            .driver()
            .has_selection(&second, SelectionKind::Clipboard),
        "the selection did not reach the seat that owns it either",
    );
}

#[test]
fn moving_the_bridge_moves_both_directions_at_once() {
    let (mut compositor, mut client, host, first, second) = with_two_seats();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &first,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    compositor.send(Command::SetClipboardBridge {
        seat: Some(SECOND.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.has_selection(&second, SelectionKind::Clipboard)
    });

    assert!(
        !client
            .driver()
            .has_selection(&first, SelectionKind::Clipboard),
        "the host's selection stayed on the seat that is no longer bridged",
    );

    drop(client.copy(&mut compositor, &second, SelectionKind::Clipboard, &[UTF8]));

    assert_eq!(
        host.calls().last(),
        Some(&HostCall::Publish {
            kind: SelectionKind::Clipboard,
            mimes: vec![MimeType::new(UTF8).expect("non-empty")],
        }),
        "the newly bridged seat's copy did not reach the host",
    );
}

#[test]
fn taking_the_bridge_away_leaves_no_seat_speaking_for_the_host() {
    // A null selection clears the seat's current selection regardless of its owner;
    // the bridge must not withdraw a host selection it did not publish.
    let (mut compositor, mut client, host, first, _second) = with_two_seats();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &first,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    compositor.send(Command::SetClipboardBridge { seat: None });
    client.settle(&mut compositor, |driver| {
        !driver.has_selection(&first, SelectionKind::Clipboard)
    });

    assert!(
        !host
            .calls()
            .iter()
            .any(|call| matches!(call, HostCall::Withdraw { .. })),
        "the host's own clipboard was withdrawn on lunette's behalf: {:?}",
        host.calls(),
    );
    assert_eq!(
        compositor
            .snapshot()
            .seats
            .iter()
            .filter(|seat| seat.clipboard_bridge)
            .count(),
        0,
    );
}

#[test]
fn moving_the_bridge_leaves_a_selection_the_host_owns_untouched() {
    let (mut compositor, mut client, host, first, _second) = with_two_seats();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &first,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    compositor.send(Command::SetClipboardBridge {
        seat: Some(SECOND.0),
    });
    client.settle_quiet(&mut compositor);

    assert!(
        !host
            .calls()
            .iter()
            .any(|call| matches!(call, HostCall::Withdraw { .. })),
        "moving the bridge cleared the desktop's clipboard: {:?}",
        host.calls(),
    );
}

#[test]
fn taking_the_bridge_away_withdraws_only_the_selection_lunette_published() {
    let (mut compositor, mut client, host, first, _second) = with_two_seats();
    let _source = client.copy(&mut compositor, &first, SelectionKind::Clipboard, &[UTF8]);

    compositor.send(Command::SetClipboardBridge { seat: None });
    client.settle_quiet(&mut compositor);

    let withdrawn: Vec<SelectionKind> = host
        .calls()
        .into_iter()
        .filter_map(|call| match call {
            HostCall::Withdraw { kind } => Some(kind),
            _ => None,
        })
        .collect();
    assert_eq!(withdrawn, vec![SelectionKind::Clipboard]);
}

#[test]
fn moving_the_bridge_leaves_a_selection_a_lunette_client_owns_alone() {
    let (mut compositor, mut client, _host, first, _second) = with_two_seats();
    let _source = client.copy(&mut compositor, &first, SelectionKind::Clipboard, &[UTF8]);

    compositor.send(Command::SetClipboardBridge {
        seat: Some(SECOND.0),
    });
    client.settle_quiet(&mut compositor);

    assert!(
        client
            .driver()
            .has_selection(&first, SelectionKind::Clipboard),
        "the client's own selection was cleared because the bridge moved",
    );
}

#[test]
fn the_snapshot_names_exactly_one_bridged_seat() {
    let (mut compositor, mut client, _host, _first, _second) = with_two_seats();

    let bridged: Vec<SeatId> = compositor
        .snapshot()
        .seats
        .iter()
        .filter(|seat| seat.clipboard_bridge)
        .map(|seat| seat.seat)
        .collect();
    assert_eq!(bridged, vec![DEFAULT_SEAT]);

    compositor.send(Command::SetClipboardBridge {
        seat: Some(SECOND.0),
    });
    client.settle(&mut compositor, |_| true);
    compositor.step();

    let bridged: Vec<SeatId> = compositor
        .snapshot()
        .seats
        .iter()
        .filter(|seat| seat.clipboard_bridge)
        .map(|seat| seat.seat)
        .collect();
    assert_eq!(bridged, vec![SECOND.0], "two seats claimed the one bridge");
}

#[test]
fn two_seats_hold_different_selections_without_interfering() {
    let (mut compositor, mut client, host, first, second) = with_two_seats();
    let counter = OfferCounter::new();

    host_copies(
        &mut compositor,
        &mut client,
        &first,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &["text/host"],
    );
    drop(client.copy(
        &mut compositor,
        &second,
        SelectionKind::Clipboard,
        &["text/local"],
    ));

    assert_eq!(
        client.driver().offered(&first, SelectionKind::Clipboard),
        vec!["text/host".to_owned()],
    );
    assert_eq!(
        client.driver().offered(&second, SelectionKind::Clipboard),
        vec!["text/local".to_owned()],
    );
}
