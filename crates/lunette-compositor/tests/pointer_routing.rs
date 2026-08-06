//! Where a pointer aimed at a sink actually lands.
//!
//! The client binds `wl_pointer` and records what arrives, so these assert on
//! the protocol events a real client would see rather than on the compositor's
//! internal focus. See `tests/harness/mod.rs` for why none of it needs a GPU.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use harness::{only_window, with_one_window};
use lunette_compositor::{
    protocol::{Command, PixelPoint, PointerButton, SeatId},
    state::DEFAULT_SEAT,
    test_client::PointerEvent,
};
use pretty_assertions::assert_eq;

/// `BTN_LEFT`, the evdev code a left click carries on the wire.
const BTN_LEFT: u32 = 0x110;

/// Where the pointer is aimed, in the sink's pixels.
const AIM: (f64, f64) = (12.0, 34.0);

#[test]
fn a_pointer_aimed_at_a_sink_enters_that_sink_s_surface_in_surface_local_coordinates() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let surface = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, x, y) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_eq!(
        entered, surface,
        "the pointer entered a surface other than the one behind the sink"
    );
    // The toplevel sits at the origin of the space the position is measured in,
    // so surface-local is the position as given. A translation would show up
    // here as an offset.
    assert_eq!((x, y), AIM);
}

#[test]
fn a_click_over_a_sink_is_delivered_as_a_press_and_a_release() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: true,
    });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: false,
    });
    client.settle(&mut compositor, |driver| {
        driver.buttons(&pointer).len() == 2
    });

    assert_eq!(
        client.driver().buttons(&pointer),
        [(BTN_LEFT, true), (BTN_LEFT, false)]
    );
}

#[test]
fn withdrawing_the_pointer_leaves_the_surface_it_had_entered() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let surface = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    compositor.send(Command::PointerLeave { seat: DEFAULT_SEAT });
    client.settle(&mut compositor, |driver| {
        driver
            .events(&pointer)
            .iter()
            .any(|event| matches!(event, PointerEvent::Leave { .. }))
    });

    assert!(
        client
            .driver()
            .events(&pointer)
            .contains(&PointerEvent::Leave { surface }),
        "the leave named a surface other than the one entered: {:?}",
        client.driver().events(&pointer)
    );
}

#[test]
fn input_addressed_to_a_seat_that_does_not_exist_reaches_no_client() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let absent = SeatId::new(99).expect("a non-zero identifier");

    compositor.send(Command::Pointer {
        seat: absent,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    compositor.send(Command::Button {
        seat: absent,
        sink,
        button: PointerButton::Left,
        pressed: true,
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().events(&pointer),
        [],
        "a command naming a seat that was never created must be refused, not routed"
    );
}
