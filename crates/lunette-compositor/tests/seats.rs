//! Two hands, two seats, and no interference between them.
//!
//! A `wl_seat` carries one pointer, so two cursors need two seats. What these
//! hold is that the two are independent all the way to the wire: separate
//! pointer positions, separate hover, separate cursor images, and a seat that
//! goes away without taking the other with it.
//!
//! The keyboard half of a seat — modifier state in particular — arrives with the
//! keymap work, since `add_keyboard` cannot be called without one.
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

use harness::WINDOW_SIZE;
use lunette_compositor::{
    protocol::{Command, PixelPoint, PointerButton, SeatId, WindowSnapshot},
    state::DEFAULT_SEAT,
    test_client::{Driver, PointerEvent, TestClient},
    testing::{CursorImage, TestCompositor},
};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_pointer::WlPointer;

/// The two hands, as a caller would name them.
const LEFT: (SeatId, &str) = (seat_id(2), "left");
const RIGHT: (SeatId, &str) = (seat_id(3), "right");

/// How many seats exist once both hands have been created: the default seat and
/// one per hand.
const SEAT_COUNT: usize = 3;

/// A seat identifier, for a constant that cannot use `expect`.
const fn seat_id(raw: u64) -> SeatId {
    match SeatId::new(raw) {
        Some(seat) => seat,
        None => unreachable!(),
    }
}

#[test]
fn two_seats_hover_two_different_windows_at_once() {
    let mut compositor = TestCompositor::new();
    let mut first = open_window(&mut compositor);
    let mut second = open_window(&mut compositor);

    let (left, right) = add_both_seats(&mut compositor, &mut first);
    let left_pointer = first.open_pointer_for(&mut compositor, left);
    // The second client binds the same seats over its own connection, which is
    // what a second application in the session does. It creates nothing: the
    // seats already exist, and it learns about them from the registry.
    await_seats(&mut compositor, &mut second, SEAT_COUNT);
    let right_pointer = second.open_pointer_for(&mut compositor, right);

    let windows = windows(&compositor, 2);
    compositor.send(Command::Pointer {
        seat: LEFT.0,
        sink: windows[0].sink,
        position: PixelPoint::new(10.0, 20.0),
    });
    compositor.send(Command::Pointer {
        seat: RIGHT.0,
        sink: windows[1].sink,
        position: PixelPoint::new(30.0, 40.0),
    });

    first.settle(&mut compositor, |driver| {
        driver.first_enter(&left_pointer).is_some()
    });
    second.settle(&mut compositor, |driver| {
        driver.first_enter(&right_pointer).is_some()
    });

    let (left_surface, left_x, left_y) = first
        .driver()
        .first_enter(&left_pointer)
        .expect("the left seat entered a surface");
    let (right_surface, right_x, right_y) = second
        .driver()
        .first_enter(&right_pointer)
        .expect("the right seat entered a surface");

    assert_eq!(
        left_surface,
        first.surface_id().expect("the first client has a toplevel")
    );
    assert_eq!(
        right_surface,
        second
            .surface_id()
            .expect("the second client has a toplevel")
    );
    assert_eq!((left_x, left_y), (10.0, 20.0));
    assert_eq!(
        (right_x, right_y),
        (30.0, 40.0),
        "each seat carries its own pointer position"
    );
}

#[test]
fn two_seats_over_one_window_keep_separate_positions() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, right) = add_both_seats(&mut compositor, &mut client);
    let left_pointer = client.open_pointer_for(&mut compositor, left);
    let right_pointer = client.open_pointer_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    compositor.send(Command::Pointer {
        seat: LEFT.0,
        sink,
        position: PixelPoint::new(1.0, 2.0),
    });
    compositor.send(Command::Pointer {
        seat: RIGHT.0,
        sink,
        position: PixelPoint::new(300.0, 400.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&left_pointer).is_some() && driver.first_enter(&right_pointer).is_some()
    });

    assert_eq!(
        enter_position(client.driver(), &left_pointer),
        (1.0, 2.0),
        "the left seat's position followed the right seat's"
    );
    assert_eq!(
        enter_position(client.driver(), &right_pointer),
        (300.0, 400.0)
    );
}

#[test]
fn a_button_is_refused_on_a_seat_whose_pointer_is_elsewhere() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, right) = add_both_seats(&mut compositor, &mut client);
    let left_pointer = client.open_pointer_for(&mut compositor, left);
    let right_pointer = client.open_pointer_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    // Only the left seat is moved onto the sink. The right seat's pointer is
    // over nothing, so its button has nowhere to go, even though another seat
    // is hovering the sink it names.
    compositor.send(Command::Pointer {
        seat: LEFT.0,
        sink,
        position: PixelPoint::new(5.0, 5.0),
    });
    compositor.send(Command::Button {
        seat: RIGHT.0,
        sink,
        button: PointerButton::Left,
        pressed: true,
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&left_pointer).is_some()
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().buttons(&right_pointer),
        [],
        "a seat that is not hovering must not borrow another seat's hover"
    );
    assert_eq!(
        client.driver().buttons(&left_pointer),
        [],
        "and the hovering seat did not press anything either"
    );
}

#[test]
fn destroying_a_seat_leaves_the_other_one_working() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, right) = add_both_seats(&mut compositor, &mut client);
    let left_pointer = client.open_pointer_for(&mut compositor, left);
    let right_pointer = client.open_pointer_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    compositor.send(Command::Pointer {
        seat: RIGHT.0,
        sink,
        position: PixelPoint::new(7.0, 8.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&right_pointer).is_some()
    });

    compositor.send(Command::DestroySeat { seat: RIGHT.0 });
    client.settle(&mut compositor, |driver| {
        driver
            .events(&right_pointer)
            .iter()
            .any(|event| matches!(event, PointerEvent::Leave { .. }))
    });
    assert_eq!(
        seat_globals(&client),
        SEAT_COUNT - 1,
        "the destroyed seat's global is still advertised"
    );

    compositor.send(Command::Pointer {
        seat: LEFT.0,
        sink,
        position: PixelPoint::new(9.0, 10.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&left_pointer).is_some()
    });

    assert_eq!(
        enter_position(client.driver(), &left_pointer),
        (9.0, 10.0),
        "destroying one seat stopped the other from delivering"
    );
}

#[test]
fn each_seat_keeps_its_own_cursor_image() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, right) = add_both_seats(&mut compositor, &mut client);
    let left_pointer = client.open_pointer_for(&mut compositor, left);
    let right_pointer = client.open_pointer_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    for seat in [LEFT.0, RIGHT.0] {
        compositor.send(Command::Pointer {
            seat,
            sink,
            position: PixelPoint::new(5.0, 5.0),
        });
    }
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&left_pointer).is_some() && driver.first_enter(&right_pointer).is_some()
    });

    let cursor = client.open_plain_surface(&mut compositor, WINDOW_SIZE);
    client.set_cursor(&mut compositor, &left_pointer, &cursor);

    assert_eq!(
        compositor.cursor_image(LEFT.0),
        Some(CursorImage::Surface),
        "the seat the client set a cursor on did not record it"
    );
    assert_eq!(
        compositor.cursor_image(RIGHT.0),
        Some(CursorImage::Named),
        "a cursor set on one seat must not follow the other hand"
    );
}

#[test]
fn a_seat_is_refused_when_its_identifier_or_its_name_is_taken() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    add_both_seats(&mut compositor, &mut client);

    compositor.send(Command::CreateSeat {
        seat: LEFT.0,
        name: "another".to_owned(),
    });
    compositor.send(Command::CreateSeat {
        seat: seat_id(4),
        name: LEFT.1.to_owned(),
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        seat_globals(&client),
        SEAT_COUNT,
        "a duplicate identifier or name must not produce a fourth seat"
    );
}

#[test]
fn the_default_seat_is_the_one_a_caller_gets_without_asking() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let pointer = client.open_pointer(&mut compositor);

    let sink = windows(&compositor, 1)[0].sink;
    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(2.0, 3.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    assert_eq!(seat_globals(&client), 1);
    assert_eq!(enter_position(client.driver(), &pointer), (2.0, 3.0));
}

/// A client with one mapped window of its own.
fn open_window(compositor: &mut TestCompositor) -> TestClient {
    let mut client = TestClient::connect(compositor);
    client.open_toplevel(compositor);
    client.attach_buffer(compositor, WINDOW_SIZE);
    client
}

/// Creates both hands, and waits until `client` has seen all three seat globals.
///
/// Three, because the default seat is already there. The names are handed back
/// so a caller opens a pointer by the name a client would use.
fn add_both_seats(
    compositor: &mut TestCompositor,
    client: &mut TestClient,
) -> (&'static str, &'static str) {
    compositor.send(Command::CreateSeat {
        seat: LEFT.0,
        name: LEFT.1.to_owned(),
    });
    compositor.send(Command::CreateSeat {
        seat: RIGHT.0,
        name: RIGHT.1.to_owned(),
    });
    await_seats(compositor, client, SEAT_COUNT);
    (LEFT.1, RIGHT.1)
}

/// Waits until `client` has seen `expected` `wl_seat` globals.
///
/// A wait for a condition rather than for a fixed number of rounds: a global
/// created on the compositor's side reaches a client when that client next
/// reads, and a second client learns about a seat the first one asked for the
/// same way.
fn await_seats(compositor: &mut TestCompositor, client: &mut TestClient, expected: usize) {
    client.settle(compositor, |driver| {
        driver
            .globals
            .iter()
            .filter(|global| global.interface == "wl_seat")
            .count()
            == expected
    });
}

/// How many `wl_seat` globals the client currently sees.
fn seat_globals(client: &TestClient) -> usize {
    client
        .globals()
        .iter()
        .filter(|interface| *interface == "wl_seat")
        .count()
}

/// The snapshot's windows, in creation order, when there are exactly `expected`.
fn windows(compositor: &TestCompositor, expected: usize) -> Vec<WindowSnapshot> {
    let snapshot = compositor.snapshot();
    assert_eq!(
        snapshot.windows.len(),
        expected,
        "expected {expected} windows, found {:?}",
        snapshot.windows
    );
    snapshot.windows.clone()
}

/// Where a pointer was told it entered.
fn enter_position(driver: &Driver, pointer: &WlPointer) -> (f64, f64) {
    let (_, x, y) = driver
        .first_enter(pointer)
        .expect("the pointer entered a surface");
    (x, y)
}
