//! `Sink:typeText`, over a real client on a socket pair.
//!
//! What the pure tests in `src/type_text.rs` establish is the plan. What these
//! establish is the half that only a client can see: the characters arrive, and
//! the keymap the client is holding afterwards is the one it had before.
//!
//! That second clause is `lunette-v1.AC4.3` in full. A client left with
//! lunette's synthetic layout has a keyboard on which every key types the wrong
//! thing, so restoring is part of the criterion rather than a nicety.
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
    keymap::Keymap,
    protocol::{Command, KeymapConfig, KeymapDefaults, ModifierState, SinkId},
    state::DEFAULT_SEAT,
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_keyboard::WlKeyboard;

/// A client with one mapped window, focused, and holding its seat's keyboard.
fn typing_client(compositor: &mut TestCompositor) -> (TestClient, WlKeyboard) {
    let mut client = TestClient::connect(compositor);
    client.open_toplevel(compositor);
    client.attach_buffer(compositor, WINDOW_SIZE);

    let keyboard = client.open_keyboard_for(compositor, "lunette");
    let sink = only_sink(compositor);
    compositor.send(Command::Focus {
        seat: DEFAULT_SEAT,
        sink: Some(sink),
    });
    client.settle(compositor, |driver| {
        driver.keyboard_focus(&keyboard).is_some()
    });

    (client, keyboard)
}

fn only_sink(compositor: &TestCompositor) -> SinkId {
    let snapshot = compositor.snapshot();
    assert_eq!(snapshot.windows.len(), 1);
    snapshot.windows[0].sink
}

/// The text the client's key events spell, read through the keymap that was
/// loaded when each key arrived.
///
/// The events are replayed in order against whichever keymap the compositor had
/// most recently uploaded, which is exactly what a real toolkit does. A press
/// types; a release does not.
fn typed(client: &TestClient, keyboard: &WlKeyboard) -> String {
    use lunette_compositor::test_client::KeyboardEvent;

    let mut text = String::new();
    let mut keymap: Option<Keymap> = None;
    let mut held = ModifierState::new();

    for event in client.driver().keyboard_events(keyboard) {
        match event {
            KeyboardEvent::Keymap { text: layout } => {
                let layout = lunette_compositor::protocol::KeymapText::new(layout)
                    .expect("a keymap the compositor sent is not empty");
                keymap = Some(Keymap::from_text(&layout).expect("it compiles"));
            }
            KeyboardEvent::Modifiers { depressed, .. } => {
                held = if depressed == 0 {
                    ModifierState::new()
                } else {
                    // The only modifier any of these tests takes is shift, and
                    // the mask is what the client was told to hold.
                    ModifierState::from_iter([lunette_compositor::protocol::KeyModifier::Shift])
                };
            }
            KeyboardEvent::Key { key, pressed: true } => {
                let keymap = keymap.as_ref().expect("a keymap arrives before any key");
                if let Some(character) = keymap.character(
                    lunette_compositor::protocol::Keycode::from_evdev(key),
                    &held,
                ) {
                    text.push_str(&character);
                }
            }
            _ => {}
        }
    }

    text
}

/// Every keymap the client was handed, in order.
fn keymaps(client: &TestClient, keyboard: &WlKeyboard) -> Vec<String> {
    client.driver().keymaps(keyboard)
}

#[test]
fn text_the_layout_expresses_arrives_without_a_keymap_change() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "ls -la".to_owned(),
    });
    client.settle(&mut compositor, |driver| {
        driver.keys(&keyboard).len() >= "ls -la".len() * 2
    });

    assert_eq!(typed(&client, &keyboard), "ls -la");
    assert_eq!(
        keymaps(&client, &keyboard),
        before,
        "the ordinary path uploaded a layout it did not need to",
    );
}

#[test]
fn text_the_layout_cannot_express_arrives_and_the_keymap_is_restored() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);
    assert_eq!(before.len(), 1, "a keyboard starts with one keymap");

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "\u{2603}\u{4e00}".to_owned(),
    });
    client.settle(&mut compositor, |driver| {
        driver.keymaps(&keyboard).len() >= 3
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        typed(&client, &keyboard),
        "\u{2603}\u{4e00}",
        "the characters the layout cannot express did not arrive",
    );

    let after = keymaps(&client, &keyboard);
    assert_eq!(
        after.len(),
        3,
        "expected the original, the synthetic one, and the restore",
    );
    assert_ne!(after[1], before[0], "no temporary layout was uploaded");
    assert_eq!(
        after[2], before[0],
        "the client was left holding lunette's synthetic layout, so its keyboard is broken",
    );
}

#[test]
fn a_failure_part_way_through_still_restores_the_clients_own_layout() {
    // Two chunks, and the second chunk's upload fails. The loop breaks, and the
    // restore has to happen anyway: leaving the client on lunette's synthetic
    // layout is the state `lunette-v1.AC4.3` exists to rule out, and it is worse
    // than the failure that produced it.
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    // "\u{2603}a\u{4e00}" plans as synthetic, native, synthetic, so the uploads
    // are: the first synthetic layout, the seat's own for the native run, the
    // second synthetic layout, and the restore. Failing the second breaks the
    // loop with a synthetic layout loaded, which is the only way to reach that
    // path.
    compositor.fail_keymap_uploads(1, 1);
    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "\u{2603}a\u{4e00}".to_owned(),
    });
    client.settle_quiet(&mut compositor);

    let after = keymaps(&client, &keyboard);
    assert_eq!(
        after.last(),
        before.first(),
        "a failure while typing left the client holding a layout that is not its own: {after:?}",
    );
}

#[test]
fn a_restore_that_failed_is_made_good_by_the_next_call_rather_than_assumed_away() {
    // The state nothing can observe from outside: smithay holds a synthetic
    // layout and this crate thinks it holds the seat's own. A native-only plan
    // uploads nothing, so without tracking what was actually uploaded the next
    // `typeText` types whatever the stale layout happens to bind.
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    // The synthetic upload goes through and the restore after it fails, so the
    // client is left holding a layout that is not its own.
    compositor.fail_keymap_uploads(1, 1);
    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "\u{2603}".to_owned(),
    });
    client.settle_quiet(&mut compositor);

    // Text the seat's own layout expresses entirely.
    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "ab".to_owned(),
    });
    client.settle_quiet(&mut compositor);

    let after = keymaps(&client, &keyboard);
    assert_eq!(
        after.last(),
        before.first(),
        "the seat's own layout was never put back: {after:?}",
    );
    assert!(
        typed(&client, &keyboard).ends_with("ab"),
        "native text was typed against a stale synthetic layout: {:?}",
        typed(&client, &keyboard),
    );
}

#[test]
fn a_restore_that_failed_is_made_good_even_by_a_call_that_types_nothing() {
    // A call with nothing to type still repairs a seat left synthetic. The
    // repair used to sit below the two early returns, so empty text and text
    // that could not be planned both left the client holding a layout that is
    // not its own until something else happened to type.
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    compositor.fail_keymap_uploads(1, 1);
    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "\u{2603}".to_owned(),
    });
    client.settle_quiet(&mut compositor);

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: String::new(),
    });
    client.settle_quiet(&mut compositor);

    let after = keymaps(&client, &keyboard);
    assert_eq!(
        after.last(),
        before.first(),
        "typing nothing left the stale synthetic layout in place: {after:?}",
    );
}

#[test]
fn a_client_can_still_type_normally_after_text_was_entered_for_it() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "\u{2603}".to_owned(),
    });
    client.settle(&mut compositor, |driver| {
        driver.keymaps(&keyboard).len() >= 3
    });

    // `KEY_A` under the seat's own layout, which is what the restore has to
    // have put back for this to be an `a` rather than a snowman.
    compositor.send(Command::Key {
        seat: DEFAULT_SEAT,
        key: lunette_compositor::protocol::Keycode::from_evdev(30),
        pressed: true,
    });
    compositor.send(Command::Key {
        seat: DEFAULT_SEAT,
        key: lunette_compositor::protocol::Keycode::from_evdev(30),
        pressed: false,
    });
    client.settle(&mut compositor, |driver| driver.keys(&keyboard).len() >= 4);

    assert_eq!(typed(&client, &keyboard), "\u{2603}a");
}

#[test]
fn a_capital_letter_takes_shift_and_gives_it_back() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "Ab".to_owned(),
    });
    client.settle(&mut compositor, |driver| driver.keys(&keyboard).len() >= 4);
    client.settle_quiet(&mut compositor);

    assert_eq!(typed(&client, &keyboard), "Ab");
    assert_eq!(
        client.driver().modifiers(&keyboard),
        Some((0, 0)),
        "typing left a modifier held for whatever the caller does next",
    );
}

#[test]
fn empty_text_sends_nothing_at_all() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: String::new(),
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(client.driver().keys(&keyboard), []);
    assert_eq!(keymaps(&client, &keyboard), before);
}

#[test]
fn the_synthetic_keymap_binds_exactly_what_the_text_needed() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);

    compositor.send(Command::TypeText {
        seat: DEFAULT_SEAT,
        text: "\u{2603}".to_owned(),
    });
    client.settle(&mut compositor, |driver| {
        driver.keymaps(&keyboard).len() >= 3
    });

    let uploaded = keymaps(&client, &keyboard);
    let layout = lunette_compositor::protocol::KeymapText::new(uploaded[1].clone())
        .expect("the temporary keymap is not empty");
    let keymap = Keymap::from_text(&layout).expect("the client could compile it");

    assert_eq!(
        keymap.stroke_for('\u{2603}').map(|stroke| stroke.key),
        Some(lunette_compositor::protocol::Keycode::from_evdev(0)),
        "the first spare key does not carry the character that was asked for",
    );
}

#[test]
fn typing_on_a_seat_that_does_not_exist_changes_nothing() {
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    compositor.send(Command::TypeText {
        seat: lunette_compositor::protocol::SeatId::new(99).expect("non-zero"),
        text: "\u{2603}".to_owned(),
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(client.driver().keys(&keyboard), []);
    assert_eq!(keymaps(&client, &keyboard), before);
}

#[test]
fn the_default_seat_types_under_the_layout_it_was_created_with() {
    // Not a tautology: it establishes that the seat this test drives is on the
    // layout the rest of the assertions assume, so a seat that inherited
    // something else fails here rather than confusingly further down. Both
    // sides resolve against `KeymapDefaults::default()`, which names its layout
    // rather than leaving it to the environment, so the answer does not depend
    // on the machine.
    let compositor = TestCompositor::new();
    let published = compositor
        .snapshot()
        .seats
        .iter()
        .find(|seat| seat.seat == DEFAULT_SEAT)
        .expect("the default seat is published")
        .keymap
        .clone();
    let keymap = Keymap::from_text(&published).expect("the published layout compiles");

    let system = Keymap::compile(&KeymapConfig::default(), &KeymapDefaults::default())
        .expect("the inherited layout compiles");
    assert_eq!(keymap.layouts(), system.layouts());
}
