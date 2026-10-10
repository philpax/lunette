//! Integration tests for `Sink:typeText` with a real Wayland client over an in-process socket pair.
//!
//! They verify `wl_keyboard` event ordering, restoration of the client's original keymap after
//! synthetic input, and recovery from failures injected through `TestCompositor`'s deterministic
//! test seam without requiring a GPU.

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
    config::DEFAULT_SEAT,
    keymap::Keymap,
    protocol::{Command, KeymapConfig, KeymapDefaults, ModifierState, SinkId},
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_keyboard::WlKeyboard;

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

/// Replays `wl_keyboard` events in arrival order, using the most recent keymap event for each key.
///
/// A press contributes its resolved character; a release does not.
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
                    // The test inputs use only Shift. Any nonzero depressed mask is interpreted as
                    // Shift.
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
    let mut compositor = TestCompositor::new();
    let (mut client, keyboard) = typing_client(&mut compositor);
    let before = keymaps(&client, &keyboard);

    // This input requires a synthetic layout, the seat's own layout, a second synthetic layout, and
    // the restore. The injected failure targets the second upload, leaving a synthetic layout loaded.
    // The cleanup restore must still run.
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
    // The first request's synthetic upload succeeds, but its restore is the injected second upload.
    // The next request on the same seat is native-only and would upload nothing unless the compositor
    // tracks the synthetic layout still loaded.
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
    // A request with no typing plan still restores a synthetic layout left by a failed restore.
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

    // This `Key` command follows `TypeText` on the same seat. It must use the restored layout.
    // It types `a`, not the synthetic layout's snowman.
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
    // Both sides use `KeymapDefaults::default()`, so the check does not depend on the machine's
    // environment.
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
