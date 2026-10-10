//! Seats, keymap queries, and the two pipelines a key can travel.
//!
//! Everything here runs with a Lua state and no graphics device: a keymap is a
//! string the compositor would have published, and the answers come out of the
//! same compiled copy production uses.
//!
//! The host half is the mirroring contract this module establishes: a
//! keystroke addressed to a host sink reaches the provider, under the seat's
//! layout, after uploading that layout first, because `wl_virtual` disconnects
//! on a key sent before a keymap. A seat absent from the frame's snapshot has
//! no layout to upload, so its keystroke is refused.

use std::sync::Arc;

use lunette_compositor::{
    keymap::Keymap,
    protocol::{Command, KeymapConfig, KeymapDefaults, ModifierState, SeatSnapshot},
};
use pretty_assertions::assert_eq;

use super::*;
use crate::lua::tests::monitors::HostEvent;

/// `KEY_A`, in the evdev numbering the Lua surface takes.
const KEY_A: u32 = 30;

/// A seat carrying an explicitly named layout.
///
/// The name is explicit, so the assertions below hold whatever the
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
        // The default seat is the bridged one, which is the seat the compositor
        // starts with; a test that needs another constructs it with `seat`.
        clipboard_bridge: raw == 1,
        drag: None,
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
fn default_seat_is_chosen_by_id_and_nil_when_absent_and_a_retained_handle_goes_dead() {
    {
        let session = session(Vec::new());
        let lua = lua(&session);
        let mut default = seat(DEFAULT_SEAT.get(), "primary", "us");
        default.clipboard_bridge = false;
        let mut other = seat(2, "lunette", "de");
        other.clipboard_bridge = true;

        for seats in [
            vec![other.clone(), default.clone()],
            vec![default.clone(), other],
            vec![default],
        ] {
            session.begin(seated(Vec::new(), seats));

            let (id, name, dead, bridged): (u64, String, bool, bool) = run(
                &lua,
                "local s = lunette.defaultSeat()
                 return s.id, s.name, s.dead, s.clipboardBridge",
            );

            assert_eq!(id, DEFAULT_SEAT.get());
            assert_eq!(name, "primary");
            assert!(!dead);
            assert!(
                !bridged,
                "the clipboard bridge does not identify the default seat"
            );
            assert!(
                session.flush().is_empty(),
                "lookup must not queue a command"
            );
        }
    }
    {
        let session = session(Vec::new());
        let lua = lua(&session);

        assert!(run::<bool>(&lua, "return lunette.defaultSeat() == nil"));
        session.begin(seated(Vec::new(), vec![seat(2, "left", "us")]));
        assert!(run::<bool>(&lua, "return lunette.defaultSeat() == nil"));

        session.begin(seated(
            Vec::new(),
            vec![seat(DEFAULT_SEAT.get(), "primary", "us")],
        ));
        run::<()>(&lua, "held = lunette.defaultSeat() assert(not held.dead)");
        session.begin(seated(Vec::new(), vec![seat(2, "left", "us")]));

        let (absent, id, name, dead, focused, destroyed): (bool, u64, String, bool, bool, bool) =
            run(
                &lua,
                "return lunette.defaultSeat() == nil, held.id, held.name, held.dead,
                    held:setFocus(nil), held:destroy()",
            );

        assert!(
            absent,
            "the previous snapshot must not supply a default seat"
        );
        assert_eq!(id, DEFAULT_SEAT.get());
        assert_eq!(
            name, "primary",
            "a retained handle keeps its last-known name"
        );
        assert!(dead);
        assert!(!focused, "a dead seat cannot receive focus commands");
        assert!(!destroyed);
        assert!(session.flush().is_empty());
    }
}

#[test]
fn a_seat_reports_its_name() {
    let session = session(Vec::new());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    let name: String = run(&lua, "return lunette.seats()[1].name");

    assert_eq!(name, "lunette");
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

    // `KEY_LEFTSHIFT` has a keysym and no text.
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

    // The round trip is the reason this is worth asserting: whatever `strokeFor`
    // returns must produce the character the caller asked for when fed through
    // the forward path, which does not share code with the inversion.
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

    let (keycode, count): (u32, usize) = run(
        &lua,
        "local stroke = lunette.seats()[1]:strokeFor('a')
         return stroke.keycode, #stroke.modifiers",
    );

    assert_eq!(keycode, KEY_A);
    assert_eq!(count, 0);

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
fn reverse_lookup_of_a_character_the_layout_cannot_express_is_nil() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let stroke: Option<Table> = run(&lua, "return lunette.seats()[1]:strokeFor('\u{2603}')");

    assert!(stroke.is_none(), "a snowman is not on a us keyboard");
}

#[test]
fn a_lookup_refuses_a_string_or_modifier_it_cannot_read() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.seats()[1]:strokeFor('abc')");

    assert!(message.contains("typeText"), "{message}");

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
fn a_focus_request_names_the_sink_and_the_seat_and_can_be_withdrawn() {
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
fn bridging_a_seat_names_it_unbridging_names_no_seat_and_rebridging_queues_nothing() {
    let session = session(Vec::new());
    session.begin(seated(
        Vec::new(),
        vec![seat(1, "lunette", "us"), seat(2, "left", "us")],
    ));
    let lua = lua(&session);

    // A configuration may ask every frame without knowing which seat holds the bridge.
    run::<()>(
        &lua,
        "lunette.seats()[1]:setClipboardBridge(true)
         lunette.seats()[1]:setClipboardBridge(true)",
    );
    assert!(session.flush().is_empty());

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
fn a_new_seat_queues_its_creation_and_is_dead_until_the_compositor_reports_it() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    let dead: bool = run(
        &lua,
        "seat = lunette.newSeat { name = 'left', layout = 'de', repeatRate = 30 }
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
fn a_seat_without_a_name_is_refused() {
    let session = us_session(Vec::new());
    let lua = lua(&session);

    for chunk in ["lunette.newSeat {}", "lunette.newSeat { name = ' ' }"] {
        let message = error(&lua, chunk);
        assert!(message.contains("needs a name"), "{chunk}: {message}");
    }
    assert!(session.flush().is_empty());
}

#[test]
fn a_seat_name_is_refused_while_its_creation_is_queued_in_flight_or_published() {
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);

        let message = error(&lua, "lunette.newSeat { name = 'lunette' }");

        assert!(message.contains("already exists"), "{message}");
        assert!(session.flush().is_empty());
    }
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);
        run::<()>(&lua, "lunette.newSeat { name = 'laser.left' }");
        assert!(matches!(
            session.flush().as_slice(),
            [Command::CreateSeat { .. }]
        ));
        session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));

        let message = error(&lua, "lunette.newSeat { name = 'laser.left' }");

        assert!(message.contains("already exists"), "{message}");
        assert!(session.flush().is_empty());
    }
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);
        run::<()>(&lua, "lunette.newSeat { name = 'laser.left' }");

        let message = error(&lua, "lunette.newSeat { name = 'laser.left' }");

        assert!(message.contains("already exists"), "{message}");
        assert!(matches!(
            session.flush().as_slice(),
            [Command::CreateSeat { .. }]
        ));
    }
}

#[test]
fn a_destroyed_seat_name_can_be_reused_whether_or_not_the_seat_was_published() {
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);
        let old: u64 = run(
            &lua,
            "old = lunette.newSeat { name = 'laser.left' } return old.id",
        );
        assert!(matches!(
            session.flush().as_slice(),
            [Command::CreateSeat { .. }]
        ));
        session.begin(seated(
            Vec::new(),
            vec![seat(1, "lunette", "us"), seat(old, "laser.left", "us")],
        ));

        let replacement: u64 = run(
            &lua,
            "assert(old:destroy()) return lunette.newSeat { name = 'laser.left' }.id",
        );

        assert_ne!(old, replacement);
        match session.flush().as_slice() {
            [
                Command::DestroySeat { seat: destroyed },
                Command::CreateSeat {
                    seat: created,
                    name,
                    ..
                },
            ] => {
                assert_eq!(destroyed.get(), old);
                assert_eq!(created.get(), replacement);
                assert_eq!(name, "laser.left");
            }
            other => panic!("expected ordered destruction and recreation, got {other:?}"),
        }
    }
    {
        for flushed in [false, true] {
            let session = us_session(Vec::new());
            let lua = lua(&session);
            let old: u64 = run(
                &lua,
                "old = lunette.newSeat { name = 'laser.left' } return old.id",
            );
            if flushed {
                assert!(matches!(
                    session.flush().as_slice(),
                    [Command::CreateSeat { .. }]
                ));
                session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
            }

            let replacement: u64 = run(
                &lua,
                "assert(old.dead) assert(old:destroy()) assert(not old:destroy())
                 return lunette.newSeat { name = 'laser.left' }.id",
            );

            assert_ne!(old, replacement);
            let commands = session.flush();
            let mutations = if flushed {
                commands.as_slice()
            } else {
                &commands[1..]
            };
            match mutations {
                [
                    Command::DestroySeat { seat: destroyed },
                    Command::CreateSeat { seat: created, .. },
                ] => {
                    assert_eq!(destroyed.get(), old);
                    assert_eq!(created.get(), replacement);
                }
                other => panic!("expected cancellation and recreation, got {other:?}"),
            }
        }
    }
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);
        let id: u64 = run(&lua, "return lunette.newSeat { name = 'laser.left' }.id");
        let _ = session.flush();
        let snapshot = seated(
            Vec::new(),
            vec![seat(1, "lunette", "us"), seat(id, "laser.left", "us")],
        );
        session.begin(Arc::clone(&snapshot));
        run::<()>(&lua, "assert(lunette.seats()[2]:destroy())");
        assert!(matches!(
            session.flush().as_slice(),
            [Command::DestroySeat { .. }]
        ));
        session.begin(snapshot);

        run::<()>(&lua, "lunette.newSeat { name = 'laser.left' }");

        assert!(matches!(
            session.flush().as_slice(),
            [Command::CreateSeat { .. }]
        ));
    }
}

#[test]
fn a_seat_name_is_released_when_the_seat_disappears_and_not_reserved_by_a_delayed_cancellation() {
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);
        let id: u64 = run(&lua, "return lunette.newSeat { name = 'laser.left' }.id");
        let _ = session.flush();
        session.begin(seated(
            Vec::new(),
            vec![seat(1, "lunette", "us"), seat(id, "laser.left", "us")],
        ));
        session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));

        run::<()>(&lua, "lunette.newSeat { name = 'laser.left' }");

        assert!(matches!(
            session.flush().as_slice(),
            [Command::CreateSeat { .. }]
        ));
    }
    {
        let session = us_session(Vec::new());
        let lua = lua(&session);
        let id: u64 = run(
            &lua,
            "old = lunette.newSeat { name = 'laser.left' } return old.id",
        );
        let _ = session.flush();
        run::<()>(&lua, "assert(old:destroy())");
        let _ = session.flush();
        session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
        session.begin(seated(
            Vec::new(),
            vec![seat(1, "lunette", "us"), seat(id, "laser.left", "us")],
        ));

        run::<()>(&lua, "lunette.newSeat { name = 'laser.left' }");

        assert!(matches!(
            session.flush().as_slice(),
            [Command::CreateSeat { .. }]
        ));
    }
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
fn a_key_or_modifier_from_a_seat_absent_from_the_snapshot_is_refused_on_a_host_sink() {
    // The frame's snapshot carries no seats, so not even the default one.
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);

    let (key, modifiers): (bool, bool) = run(
        &lua,
        &format!(
            "local sink = lunette.monitors()[1].sink
             return sink:key({KEY_A}, true), sink:setModifiers({{ 'shift' }})"
        ),
    );

    assert!(!key, "a key with no layout to read it under was sent");
    assert!(
        !modifiers,
        "modifiers with no layout to read them under were set"
    );
    assert_eq!(host.events(), Vec::new());
}

#[test]
fn a_keycode_the_host_provider_never_declared_is_refused_rather_than_sent() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    // 84 is a gap in the evdev table, so no provider declares it.
    // A keymap cannot map a keycode outside the table.
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
        "lunette.monitors()[1].sink:setModifiers({ 'shift', 'control' })",
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
    // for `Mod3`. Sending shift alone would leave the host holding a modifier
    // the caller did not ask for.
    let applied: bool = run(
        &lua,
        "return lunette.monitors()[1].sink:setModifiers({ 'shift', 'mod3' })",
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
    // `docs/dev/lua-api.md` states that every method answers `false` on a dead
    // handle. A caller that trusts one method's answer and not another's has no
    // way to tell which is which.
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
fn a_host_sink_refuses_text_and_focus() {
    let (session, _, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);

    let typed: bool = run(&lua, "return lunette.monitors()[1].sink:typeText('hello')");

    assert!(
        !typed,
        "the technique needs a keymap lunette can take back, and the host's is not lunette's"
    );
    assert_eq!(host.events(), Vec::new());

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

    let (dead, name): (bool, String) = run(&lua, "return seat.dead, seat.name");
    assert!(dead);
    assert_eq!(name, "left", "a dead seat reads its last-known name");
}
