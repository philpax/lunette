//! Seats, keymap queries, and the two pipelines a key can travel.
//!
//! Everything here runs with a Lua state and no graphics device: a keymap is a
//! string the compositor would have published, and the answers come out of the
//! same compiled copy production uses.
//!
//! The host half is `lunette-v1.AC3.3`. What is established here is that a
//! keystroke addressed to a host sink reaches the provider, under the seat's
//! layout, having uploaded that layout first — the last of those being the
//! reason `wl_virtual` was left unconfigured before this.

use std::sync::Arc;

use lunette_compositor::{
    keymap::Keymap,
    protocol::{Command, KeyModifier, KeymapConfig, KeymapDefaults, ModifierState, SeatSnapshot},
};
use pretty_assertions::assert_eq;

use super::*;
use crate::lua::tests::monitors::HostEvent;

/// `KEY_A`, in the evdev numbering the Lua surface takes.
const KEY_A: u32 = 30;

/// A seat carrying an explicitly named layout.
///
/// Named rather than defaulted, so the assertions below hold whatever the
/// compositor's inherited default is.
fn seat(raw: u64, name: &str, layout: &str) -> SeatSnapshot {
    let keymap = Keymap::compile(
        &KeymapConfig {
            layout: Some(layout.to_owned()),
            ..KeymapConfig::default()
        },
        &KeymapDefaults::default(),
    )
    .expect("the layout compiles");

    SeatSnapshot {
        seat: SeatId::new(raw).expect("non-zero"),
        name: name.to_owned(),
        keymap: Arc::clone(keymap.text()),
        modifiers: ModifierState::new(),
        // The default seat is the bridged one, which is what the compositor
        // starts with; a test that wants another asks for it.
        clipboard_bridge: raw == 1,
    }
}

/// A snapshot carrying windows and seats, which the shared helper does not.
fn seated(windows: Vec<WindowSnapshot>, seats: Vec<SeatSnapshot>) -> Arc<Snapshot> {
    Arc::new(Snapshot {
        windows,
        seats,
        ..Snapshot::default()
    })
}

/// A session whose default seat is on the US layout.
fn us_session(windows: Vec<WindowSnapshot>) -> TestSession {
    let session = session(Vec::new());
    session.begin(seated(windows, vec![seat(1, "lunette", "us")]));
    session
}

#[test]
fn a_seat_reports_its_name_and_the_layouts_its_keymap_carries() {
    let session = session(Vec::new());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    let (name, layouts): (String, Table) = run(
        &lua,
        "local s = lunette.seats()[1] return s.name, s.layouts",
    );

    assert_eq!(name, "lunette");
    assert_eq!(layouts.len().expect("a sequence"), 1);
    let first: String = layouts.get(1).expect("the first layout");
    assert!(
        first.contains("US"),
        "the layout list does not name the compiled layout: {first}",
    );
}

#[test]
fn forward_lookup_answers_what_the_layout_defines() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let (plain, shifted): (String, String) = run(
        &lua,
        &format!(
            "local s = lunette.seats()[1]
             return s:characterFor({KEY_A}), s:characterFor({KEY_A}, {{'shift'}})"
        ),
    );

    assert_eq!(plain, "a");
    assert_eq!(shifted, "A", "the modifier argument was not applied");
}

#[test]
fn forward_lookup_reports_nothing_for_a_key_that_types_nothing() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    // `KEY_LEFTSHIFT`, which has a keysym and no text.
    let (character, symbol): (Option<String>, Option<u32>) = run(
        &lua,
        "local s = lunette.seats()[1] return s:characterFor(42), s:symbolFor(42)",
    );

    assert_eq!(character, None);
    assert!(symbol.is_some(), "a modifier key still has a keysym");
}

#[test]
fn reverse_lookup_returns_a_keycode_and_modifiers_lua_can_feed_back() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    // The round trip is what makes this worth asserting: whatever `strokeFor`
    // hands back has to produce the character it was asked about when fed
    // through the forward path, which does not share code with the inversion.
    let (keycode, modifiers, again): (u32, Table, String) = run(
        &lua,
        "local s = lunette.seats()[1]
         local stroke = s:strokeFor('A')
         return stroke.keycode, stroke.modifiers, s:characterFor(stroke.keycode, stroke.modifiers)",
    );

    assert_eq!(keycode, KEY_A);
    assert_eq!(modifiers.len().expect("a sequence"), 1);
    assert_eq!(
        modifiers.get::<String>(1).expect("the modifier's name"),
        "shift"
    );
    assert_eq!(again, "A");
}

#[test]
fn reverse_lookup_prefers_the_unmodified_key() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let (keycode, count): (u32, usize) = run(
        &lua,
        "local stroke = lunette.seats()[1]:strokeFor('a')
         return stroke.keycode, #stroke.modifiers",
    );

    assert_eq!(keycode, KEY_A);
    assert_eq!(count, 0);
}

#[test]
fn reverse_lookup_of_a_character_the_layout_cannot_express_is_nil() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let stroke: Option<Table> = run(&lua, "return lunette.seats()[1]:strokeFor('\u{2603}')");

    assert!(stroke.is_none(), "a snowman is not on a us keyboard");
}

#[test]
fn reverse_lookup_accepts_a_keysym_a_forward_lookup_produced() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let keycode: u32 = run(
        &lua,
        &format!(
            "local s = lunette.seats()[1]
             return s:strokeFor(s:symbolFor({KEY_A})).keycode"
        ),
    );

    assert_eq!(keycode, KEY_A);
}

#[test]
fn reverse_lookup_refuses_a_string_that_is_not_one_character() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.seats()[1]:strokeFor('abc')");

    assert!(message.contains("typeText"), "{message}");
}

#[test]
fn an_unrecognised_modifier_name_raises_rather_than_being_skipped() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.seats()[1]:characterFor(30, {'shft'})");

    assert!(message.contains("is not a modifier"), "{message}");
}

#[test]
fn a_key_on_a_window_sink_queues_a_command_for_the_seat_that_sent_it() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    run::<()>(
        &lua,
        &format!("lunette.windows()[1].sink:key({KEY_A}, true)"),
    );

    match session.flush().as_slice() {
        [Command::Key { seat, key, pressed }] => {
            assert_eq!(*seat, DEFAULT_SEAT);
            assert_eq!(key.evdev(), KEY_A);
            assert!(pressed);
        }
        other => panic!("expected one key command, got {other:?}"),
    }
}

#[test]
fn a_focus_request_names_the_sink_and_the_seat() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    run::<()>(
        &lua,
        "lunette.seats()[1]:setFocus(lunette.windows()[1].sink)",
    );

    match session.flush().as_slice() {
        [Command::Focus { seat, sink }] => {
            assert_eq!(*seat, DEFAULT_SEAT);
            assert_eq!(*sink, Some(sink_id(1)));
        }
        other => panic!("expected one focus command, got {other:?}"),
    }
}

#[test]
fn focus_can_be_withdrawn() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    run::<()>(&lua, "lunette.seats()[1]:setFocus(nil)");

    match session.flush().as_slice() {
        [Command::Focus { sink: None, .. }] => {}
        other => panic!("expected a withdrawal, got {other:?}"),
    }
}

#[test]
fn a_seat_reports_whether_its_selections_are_the_hosts() {
    let session = session(Vec::new());
    session.begin(seated(
        Vec::new(),
        vec![seat(1, "lunette", "us"), seat(2, "left", "us")],
    ));
    let lua = lua(&session);

    let (first, second): (bool, bool) = run(
        &lua,
        "local s = lunette.seats() return s[1].clipboardBridge, s[2].clipboardBridge",
    );

    assert!(
        first,
        "the default seat starts bridged to the host clipboard"
    );
    assert!(!second, "two seats claimed the one bridge");
}

#[test]
fn bridging_a_seat_names_it_and_unbridging_names_no_seat() {
    let session = session(Vec::new());
    session.begin(seated(
        Vec::new(),
        vec![seat(1, "lunette", "us"), seat(2, "left", "us")],
    ));
    let lua = lua(&session);

    run::<()>(&lua, "lunette.seats()[2]:setClipboardBridge(true)");

    match session.flush().as_slice() {
        [Command::SetClipboardBridge { seat }] => {
            assert_eq!(*seat, Some(SeatId::new(2).expect("non-zero")));
        }
        other => panic!("expected one bridge command, got {other:?}"),
    }

    run::<()>(&lua, "lunette.seats()[1]:setClipboardBridge(false)");

    match session.flush().as_slice() {
        [Command::SetClipboardBridge { seat: None }] => {}
        other => panic!("expected the bridge to be taken away, got {other:?}"),
    }
}

#[test]
fn asking_for_the_bridge_a_seat_already_has_queues_nothing() {
    // A configuration may call this every frame without knowing which seat
    // holds it, and a command per frame would republish the snapshot forever.
    let session = us_session(Vec::new());
    let lua = lua(&session);

    run::<()>(
        &lua,
        "lunette.seats()[1]:setClipboardBridge(true)
         lunette.seats()[1]:setClipboardBridge(true)",
    );

    assert!(session.flush().is_empty());
}

#[test]
fn a_new_seat_queues_its_creation_and_is_dead_until_the_compositor_reports_it() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let dead: bool = run(
        &lua,
        "seat = lunette.newSeat('left', { layout = 'de', repeatRate = 30 })
         return seat.dead",
    );
    assert!(dead, "a seat exists only once the compositor has made it");

    match session.flush().as_slice() {
        [
            Command::CreateSeat {
                seat,
                name,
                keyboard,
            },
        ] => {
            assert_eq!(*seat, SeatId::new(2).expect("non-zero"));
            assert_eq!(name, "left");
            assert_eq!(keyboard.keymap.layout.as_deref(), Some("de"));
            assert_eq!(keyboard.repeat.rate.get(), 30);
        }
        other => panic!("expected one seat creation, got {other:?}"),
    }
}

#[test]
fn a_second_seat_with_an_existing_name_is_refused() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.newSeat('lunette')");

    assert!(message.contains("already exists"), "{message}");
    assert!(session.flush().is_empty());
}

#[test]
fn a_seat_option_that_does_not_exist_is_refused() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.newSeat('left', { laoyut = 'de' })");

    assert!(message.contains("is not an option here"), "{message}");
}

#[test]
fn the_default_seat_refuses_to_be_destroyed() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let destroyed: bool = run(&lua, "return lunette.seats()[1]:destroy()");

    assert!(!destroyed, "a session with no seat can deliver no input");
    assert!(session.flush().is_empty());
}

#[test]
fn a_key_on_a_host_sink_uploads_the_layout_before_the_keystroke() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    run::<()>(
        &lua,
        &format!("lunette.monitors()[1].sink:key({KEY_A}, true)"),
    );

    match host.events().as_slice() {
        [HostEvent::Keymap { text }, HostEvent::Key { key, pressed }] => {
            assert!(
                text.contains("xkb_keymap"),
                "the host was not given a keymap"
            );
            assert_eq!(key.evdev_code(), 30);
            assert!(pressed);
        }
        other => panic!("expected a keymap then a key, got {other:?}"),
    }
}

#[test]
fn a_keycode_the_host_provider_never_declared_is_refused_rather_than_sent() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    // 84 is a gap in the evdev table, so no provider declares it.
    let sent: bool = run(&lua, "return lunette.monitors()[1].sink:key(84, true)");

    assert!(!sent);
    assert_eq!(
        host.events(),
        Vec::new(),
        "a key the kernel would silently drop was sent anyway"
    );
}

#[test]
fn modifiers_on_a_host_sink_reach_the_provider_as_a_mask() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    run::<()>(
        &lua,
        "lunette.monitors()[1].sink:modifiers({ 'shift', 'control' })",
    );

    let masks: Vec<_> = host
        .events()
        .into_iter()
        .filter_map(|event| match event {
            HostEvent::Modifiers { modifiers } => Some(modifiers),
            _ => None,
        })
        .collect();
    assert_eq!(masks.len(), 1);
    assert!(masks[0].contains(lunette_capture::hid::KeyModifiers::SHIFT));
    assert!(masks[0].contains(lunette_capture::hid::KeyModifiers::CTRL));
}

#[test]
fn a_modifier_the_host_cannot_represent_is_refused_rather_than_partly_applied() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    // Neither `zwp_virtual_keyboard_v1`'s mask nor uinput's key table has a bit
    // for `Mod3`. Sending shift alone would leave the host holding something
    // the caller did not ask for.
    let applied: bool = run(
        &lua,
        "return lunette.monitors()[1].sink:modifiers({ 'shift', 'mod3' })",
    );

    assert!(!applied);
    assert_eq!(host.events(), Vec::new());
}

#[test]
fn a_window_sink_scroll_queues_one_command_per_moving_axis() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    run::<()>(&lua, "lunette.windows()[1].sink:scroll(0, -15)");

    match session.flush().as_slice() {
        [Command::Scroll { axis, delta, .. }] => {
            assert_eq!(*axis, ScrollAxis::Vertical, "a still axis was sent anyway");
            assert_eq!(*delta, ScrollDelta::Continuous(-15.0));
        }
        other => panic!("expected one scroll command, got {other:?}"),
    }
}

#[test]
fn a_discrete_scroll_stays_discrete() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    run::<()>(&lua, "lunette.windows()[1].sink:scrollDiscrete(1, 2)");

    let deltas: Vec<_> = session
        .flush()
        .into_iter()
        .filter_map(|command| match command {
            Command::Scroll { axis, delta, .. } => Some((axis, delta)),
            _ => None,
        })
        .collect();
    assert_eq!(
        deltas,
        vec![
            (ScrollAxis::Horizontal, ScrollDelta::Discrete(1)),
            (ScrollAxis::Vertical, ScrollDelta::Discrete(2)),
        ],
    );
}

#[test]
fn a_scroll_distance_that_is_not_finite_raises() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    let message = error(&lua, "lunette.windows()[1].sink:scroll(0, 0/0)");

    assert!(message.contains("is not a scroll distance"), "{message}");
}

#[test]
fn leaving_a_window_sink_withdraws_the_pointer_without_touching_focus() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    run::<()>(&lua, "lunette.windows()[1].sink:leave()");

    match session.flush().as_slice() {
        [Command::PointerLeave { seat }] => assert_eq!(*seat, DEFAULT_SEAT),
        other => panic!("expected one leave, got {other:?}"),
    }
}

#[test]
fn leaving_a_sink_whose_window_is_gone_reports_false_like_every_other_method() {
    // `docs/lua-api.md` promises that every method answers `false` on a dead
    // handle, and a caller that trusts one method's answer and not another's has
    // no way to tell which is which.
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);
    run::<()>(&lua, "sink = lunette.windows()[1].sink");
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));

    let left: bool = run(&lua, "return sink:leave()");

    assert!(!left, "a sink whose window has gone reported a withdrawal");
    assert!(session.flush().is_empty());
}

#[test]
fn type_text_on_a_window_sink_queues_the_text_for_the_compositor() {
    let session = us_session(vec![window(1, "term", "foot", PixelSize::new(800, 600))]);
    let lua = lua(&session);

    run::<()>(&lua, "lunette.windows()[1].sink:typeText('ls \u{2603}')");

    match session.flush().as_slice() {
        [Command::TypeText { seat, text }] => {
            assert_eq!(*seat, DEFAULT_SEAT);
            assert_eq!(text, "ls \u{2603}");
        }
        other => panic!("expected one typeText command, got {other:?}"),
    }
}

#[test]
fn type_text_is_refused_on_a_host_sink() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    let typed: bool = run(&lua, "return lunette.monitors()[1].sink:typeText('hello')");

    assert!(
        !typed,
        "the technique needs a keymap lunette can take back, and the host's is not lunette's"
    );
    assert_eq!(host.events(), Vec::new());
}

#[test]
fn a_host_sink_cannot_be_focused() {
    let (session, _, _) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    let focused: bool = run(
        &lua,
        "return lunette.seats()[1]:setFocus(lunette.monitors()[1].sink)",
    );

    assert!(
        !focused,
        "which host window holds the keyboard is the host compositor's decision"
    );
    assert!(session.flush().is_empty());
}

#[test]
fn a_seat_command_names_the_seat_the_caller_passed_rather_than_the_default() {
    let session = session(Vec::new());
    session.begin(seated(
        vec![window(1, "term", "foot", PixelSize::new(800, 600))],
        vec![seat(1, "lunette", "us"), seat(2, "left", "us")],
    ));
    let lua = lua(&session);

    run::<()>(
        &lua,
        &format!(
            "local left = lunette.seats()[2]
             lunette.windows()[1].sink:key({KEY_A}, true, left)"
        ),
    );

    match session.flush().as_slice() {
        [Command::Key { seat, .. }] => {
            assert_eq!(*seat, SeatId::new(2).expect("non-zero"));
        }
        other => panic!("expected one key command, got {other:?}"),
    }
}

#[test]
fn a_seat_the_snapshot_no_longer_lists_is_dead_and_answers_from_what_it_knew() {
    let session = session(Vec::new());
    session.begin(seated(Vec::new(), vec![seat(2, "left", "us")]));
    let lua = lua(&session);
    run::<()>(&lua, "seat = lunette.seats()[1]");

    session.begin(seated(Vec::new(), Vec::new()));

    let (dead, name, layouts): (bool, String, Table) =
        run(&lua, "return seat.dead, seat.name, seat.layouts");
    assert!(dead);
    assert_eq!(name, "left", "a dead seat reads its last-known name");
    assert_eq!(
        layouts.len().expect("a sequence"),
        0,
        "a seat that is gone has no layout to report"
    );
}

#[test]
fn the_modifiers_a_seat_holds_are_readable() {
    let mut held = seat(1, "lunette", "us");
    held.modifiers = ModifierState::from_iter([KeyModifier::Shift, KeyModifier::CapsLock]);

    let session = session(Vec::new());
    session.begin(seated(Vec::new(), vec![held]));
    let lua = lua(&session);

    let names: Vec<String> = run(&lua, "return lunette.seats()[1].modifiers");

    assert_eq!(names, vec!["shift".to_owned(), "capsLock".to_owned()]);
}
