//! Copy and paste across the boundary, in both directions, for both selections.
//!
//! `lunette-v1.AC4.5` is four paths, and each is exercised here against a real
//! Wayland client on one side and a fake host desktop on the other. There is no
//! host compositor and no desktop session: the machine this runs on has neither,
//! and a test that needed one would be a test nobody could run.
//!
//! What is deliberately real is the descriptor. Every transfer here is an actual
//! pipe, written by whichever side owns the bytes and read by the other, so the
//! property the design rests on — that lunette passes descriptors and never
//! copies content — is what the assertions are about.
//!
//! See `tests/harness/mod.rs` for why none of this needs a GPU.

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
    protocol::Command,
    selection::{FakeHost, HostCall, HostEvent, MimeType, OfferCounter, OfferId, SelectionKind},
    state::{CompositorConfig, DEFAULT_SEAT},
    test_client::{SelectionDevices, TestClient, read_to_end},
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

/// The MIME type every toolkit asks for first.
const UTF8: &str = "text/plain;charset=utf-8";

/// The seat name the default seat advertises.
const SEAT: &str = "lunette";

/// A compositor with a fake host clipboard, one mapped window, and that window
/// holding the default seat's keyboard focus.
///
/// The focus is not incidental: `wl_data_device` delivers a selection only to
/// the focused client, and both `set_selection` requests are refused from an
/// unfocused one (`smithay-0.7.0/.../data_device/device.rs:117-129`). A test
/// that skipped it would see nothing and blame the bridge.
fn with_host() -> (TestCompositor, TestClient, FakeHost) {
    with_host_and_devices().0
}

/// The same, with the client's two selection devices already bound.
fn with_host_and_devices() -> ((TestCompositor, TestClient, FakeHost), SelectionDevices) {
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

    // Bound before anything is announced: a client with no `wl_data_device` has
    // nowhere for an offer to arrive, and the test would then time out waiting
    // for one.
    let devices = client.open_selection(&mut compositor, SEAT);

    ((compositor, client, host), devices)
}

/// Announces a host selection carrying `mimes`, and reports its identifier.
fn host_copies(
    compositor: &mut TestCompositor,
    client: &mut TestClient,
    host: &FakeHost,
    counter: &OfferCounter,
    kind: SelectionKind,
    mimes: &[&str],
) -> OfferId {
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
    client.settle(compositor, |driver| driver.has_selection(kind));
    offer
}

#[test]
fn both_selection_protocols_and_both_data_controls_are_advertised() {
    let (_compositor, client, _host) = with_host();

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
    // Both selections, because the host has one of each and a bridge that moved
    // only the clipboard would pass half of AC4.5.
    let (mut compositor, mut client, host) = with_host();
    let counter = OfferCounter::new();

    for kind in SelectionKind::ALL {
        host_copies(
            &mut compositor,
            &mut client,
            &host,
            &counter,
            kind,
            &[UTF8, "text/plain", "TEXT"],
        );

        assert_eq!(
            client.driver().offered(kind),
            vec![UTF8.to_owned(), "text/plain".to_owned(), "TEXT".to_owned()],
            "the {kind} offer did not carry the host's own list, unchanged",
        );
    }
}

#[test]
fn pasting_in_a_client_reads_the_bytes_the_host_writes_into_its_own_pipe() {
    // The whole client-pastes-from-host path. Nothing in lunette reads or writes
    // the pipe: the descriptor the client supplied is the one the fake host is
    // handed, and the bytes the test writes into it are the bytes the client
    // reads back.
    let (mut compositor, mut client, host) = with_host();
    let counter = OfferCounter::new();

    for (kind, text) in SelectionKind::ALL.into_iter().zip(["clipped", "primary"]) {
        host_copies(&mut compositor, &mut client, &host, &counter, kind, &[UTF8]);

        let reader = client.paste(&mut compositor, kind, UTF8);

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
    let ((mut compositor, mut client, host), devices) = with_host_and_devices();

    for kind in SelectionKind::ALL {
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
    // The other half of AC4.5. The host's descriptor reaches the client that
    // owns the selection, and the client writes into it directly.
    let ((mut compositor, mut client, host), devices) = with_host_and_devices();

    for (kind, text) in SelectionKind::ALL.into_iter().zip(["copied", "selected"]) {
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
    // Nothing is handed to the host, and the client's pipe closes unread — an
    // empty paste rather than the nearest text type in the wrong encoding.
    let (mut compositor, mut client, host) = with_host();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &["image/png"],
    );

    let reader = client.paste(&mut compositor, SelectionKind::Clipboard, UTF8);

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
    let (mut compositor, mut client, host) = with_host();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    host.announce(HostEvent::Cleared {
        kind: SelectionKind::Clipboard,
    });
    client.settle(&mut compositor, |driver| {
        !driver.has_selection(SelectionKind::Clipboard)
    });

    assert!(!client.driver().has_selection(SelectionKind::Clipboard));
}

#[test]
fn a_client_offering_no_mime_types_withdraws_rather_than_publishing_nothing() {
    // A source that advertises nothing can answer no request, so a selection
    // built from it would be one every paste comes back empty from.
    let ((mut compositor, mut client, host), devices) = with_host_and_devices();

    drop(client.copy(&mut compositor, &devices, SelectionKind::Clipboard, &[]));

    assert_eq!(
        host.calls().last(),
        Some(&HostCall::Withdraw {
            kind: SelectionKind::Clipboard
        }),
    );
}

#[test]
fn a_client_that_never_reads_its_pipe_stalls_nothing() {
    // The case that would deadlock a compositor that copied the bytes itself.
    // lunette hands the descriptor on and forgets it, so a second window maps
    // while the first client's paste sits unread for ever.
    let (mut compositor, mut client, host) = with_host();
    let counter = OfferCounter::new();
    host_copies(
        &mut compositor,
        &mut client,
        &host,
        &counter,
        SelectionKind::Clipboard,
        &[UTF8],
    );

    let unread = client.paste(&mut compositor, SelectionKind::Clipboard, UTF8);

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
    // No host socket is the ordinary case on a machine with no Wayland session,
    // and it must not stop a client copying and pasting within lunette.
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
        client.driver().has_selection(SelectionKind::Clipboard),
        "a client's own selection was not offered back to it",
    );
}
