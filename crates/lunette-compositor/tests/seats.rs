//! Two hands, two seats, and no interference between them.
//!
//! A `wl_seat` carries one pointer, so two cursors need two seats. What these
//! hold is that the two are independent all the way to the wire: separate
//! pointer positions, separate hover, separate cursor images, and a seat that
//! goes away without taking the other with it.
//!
//! The keyboard half is here too: a key reaches only the seat that was focused,
//! and a modifier held on one seat is not held on the other.
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
    protocol::{
        Command, KeyModifier, KeyboardConfig, Keycode, KeymapConfig, ModifierState, PixelPoint,
        PointerButton, SeatId, WindowSnapshot,
    },
    state::DEFAULT_SEAT,
    test_client::{Driver, PointerEvent, TestClient},
    testing::{CursorImage, TestCompositor},
};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_pointer::WlPointer;

/// `KEY_A`, which every layout binds and which no test cares about beyond its
/// being a key that exists.
const KEY_A: Keycode = Keycode::from_evdev(30);

/// A keyboard on an explicitly named layout.
///
/// Named rather than defaulted, because the default is whatever the machine's
/// `XKB_DEFAULT_LAYOUT` says, and a test that depends on that passes or fails
/// according to who is running it.
fn keyboard() -> Box<KeyboardConfig> {
    Box::new(KeyboardConfig {
        keymap: KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        },
        ..KeyboardConfig::default()
    })
}

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
    let right_keyboard = client.open_keyboard_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    compositor.send(Command::Pointer {
        seat: RIGHT.0,
        sink,
        position: PixelPoint::new(7.0, 8.0),
    });
    compositor.send(Command::Focus {
        seat: RIGHT.0,
        sink: Some(sink),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&right_pointer).is_some()
            && driver.keyboard_focus(&right_keyboard).is_some()
    });

    compositor.send(Command::DestroySeat { seat: RIGHT.0 });
    client.settle(&mut compositor, |driver| {
        driver
            .events(&right_pointer)
            .iter()
            .any(|event| matches!(event, PointerEvent::Leave { .. }))
    });

    // The keyboard as well as the pointer. `Seat::remove_keyboard` clears the
    // capability and sends no leave, so a client left focused keeps its focus
    // ring and its caret alive for a seat that has stopped existing.
    assert_eq!(
        client.driver().keyboard_focus(&right_keyboard),
        None,
        "the destroyed seat's keyboard never left the surface it was focused on",
    );
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
        keyboard: keyboard(),
    });
    compositor.send(Command::CreateSeat {
        seat: seat_id(4),
        name: LEFT.1.to_owned(),
        keyboard: keyboard(),
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

#[test]
fn a_seat_advertises_a_keyboard_and_uploads_its_layout() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, _) = add_both_seats(&mut compositor, &mut client);
    let keyboard = client.open_keyboard_for(&mut compositor, left);

    let uploaded = client.driver().keymaps(&keyboard);
    assert_eq!(uploaded.len(), 1, "a keyboard is given exactly one keymap");
    assert!(
        uploaded[0].contains("xkb_keymap"),
        "what arrived was not a keymap: {:?}",
        uploaded[0].get(..64),
    );

    let published = compositor
        .snapshot()
        .seats
        .iter()
        .find(|seat| seat.seat == LEFT.0)
        .expect("the left seat is in the snapshot")
        .keymap
        .as_str()
        .to_owned();
    assert_eq!(
        uploaded[0], published,
        "the snapshot's keymap is not the one the client was given, so a virtual keyboard drawn \
         from it would show the wrong legends",
    );
}

#[test]
fn a_key_reaches_the_focused_client_and_no_other_seat() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, right) = add_both_seats(&mut compositor, &mut client);
    let left_keyboard = client.open_keyboard_for(&mut compositor, left);
    let right_keyboard = client.open_keyboard_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    compositor.send(Command::Focus {
        seat: LEFT.0,
        sink: Some(sink),
    });
    compositor.send(Command::Key {
        seat: LEFT.0,
        key: KEY_A,
        pressed: true,
    });
    compositor.send(Command::Key {
        seat: LEFT.0,
        key: KEY_A,
        pressed: false,
    });
    client.settle(&mut compositor, |driver| {
        driver.keys(&left_keyboard).len() == 2
    });

    assert_eq!(
        client.driver().keys(&left_keyboard),
        [(KEY_A.evdev(), true), (KEY_A.evdev(), false)],
        "the key did not arrive in evdev numbering",
    );
    assert_eq!(
        client.driver().keys(&right_keyboard),
        [],
        "a key sent to one seat reached the other hand's keyboard",
    );
}

#[test]
fn a_key_sent_to_an_unfocused_seat_reaches_nobody() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, _) = add_both_seats(&mut compositor, &mut client);
    let keyboard = client.open_keyboard_for(&mut compositor, left);

    compositor.send(Command::Key {
        seat: LEFT.0,
        key: KEY_A,
        pressed: true,
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(client.driver().keys(&keyboard), []);
    assert_eq!(client.driver().keyboard_focus(&keyboard), None);
}

#[test]
fn a_modifier_set_on_one_seat_is_visible_to_the_client_and_not_on_the_other() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, right) = add_both_seats(&mut compositor, &mut client);
    let left_keyboard = client.open_keyboard_for(&mut compositor, left);
    let right_keyboard = client.open_keyboard_for(&mut compositor, right);

    let sink = windows(&compositor, 1)[0].sink;
    for seat in [LEFT.0, RIGHT.0] {
        compositor.send(Command::Focus {
            seat,
            sink: Some(sink),
        });
    }
    compositor.send(Command::Modifiers {
        seat: LEFT.0,
        modifiers: ModifierState::from_iter([KeyModifier::Shift]),
    });
    client.settle(&mut compositor, |driver| {
        driver
            .modifiers(&left_keyboard)
            .is_some_and(|(depressed, _)| depressed != 0)
    });

    let (depressed, locked) = client
        .driver()
        .modifiers(&left_keyboard)
        .expect("the focused client was told about the modifier");
    assert_ne!(depressed, 0, "shift was not reported as depressed");
    assert_eq!(locked, 0, "shift is not a lock");

    assert_eq!(
        client
            .driver()
            .modifiers(&right_keyboard)
            .map(|(depressed, _)| depressed),
        Some(0),
        "a modifier held on one hand appeared on the other",
    );

    let published = seat_modifiers(&compositor, LEFT.0);
    assert!(
        published.contains(&KeyModifier::Shift),
        "the snapshot does not report what the client was told: {published:?}",
    );
    assert!(seat_modifiers(&compositor, RIGHT.0).is_empty());
}

#[test]
fn a_lock_is_reported_as_locked_rather_than_as_depressed() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);
    let (left, _) = add_both_seats(&mut compositor, &mut client);
    let keyboard = client.open_keyboard_for(&mut compositor, left);

    let sink = windows(&compositor, 1)[0].sink;
    compositor.send(Command::Focus {
        seat: LEFT.0,
        sink: Some(sink),
    });
    compositor.send(Command::Modifiers {
        seat: LEFT.0,
        modifiers: ModifierState::from_iter([KeyModifier::CapsLock]),
    });
    client.settle(&mut compositor, |driver| {
        driver
            .modifiers(&keyboard)
            .is_some_and(|(_, locked)| locked != 0)
    });

    let (depressed, locked) = client
        .driver()
        .modifiers(&keyboard)
        .expect("the client was told about the lock");
    assert_eq!(
        depressed, 0,
        "a lock reported as depressed toggles itself off"
    );
    assert_ne!(locked, 0);
}

#[test]
fn a_seat_whose_layout_does_not_compile_is_not_created() {
    let mut compositor = TestCompositor::new();
    let mut client = open_window(&mut compositor);

    compositor.send(Command::CreateSeat {
        seat: LEFT.0,
        name: LEFT.1.to_owned(),
        keyboard: Box::new(KeyboardConfig {
            keymap: KeymapConfig {
                layout: Some("this-is-not-a-layout".to_owned()),
                ..KeymapConfig::default()
            },
            ..KeyboardConfig::default()
        }),
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        seat_globals(&client),
        1,
        "a seat whose keymap failed to compile was advertised anyway",
    );
}

/// The modifiers the snapshot says a seat is holding.
fn seat_modifiers(compositor: &TestCompositor, seat: SeatId) -> ModifierState {
    compositor
        .snapshot()
        .seats
        .iter()
        .find(|entry| entry.seat == seat)
        .map(|entry| entry.modifiers.clone())
        .unwrap_or_else(|| panic!("{seat} is not in the snapshot"))
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
        keyboard: keyboard(),
    });
    compositor.send(Command::CreateSeat {
        seat: RIGHT.0,
        name: RIGHT.1.to_owned(),
        keyboard: keyboard(),
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
