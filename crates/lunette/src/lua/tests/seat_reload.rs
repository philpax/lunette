//! Seats kept across a source reload.
//!
//! A configuration releases its seats as its plugins close, and the replacement creates them
//! again. A seat released during the reload waits for the replacement: one it asks for by name is
//! handed over with its identifier, global, and clients, and one it leaves unclaimed is destroyed
//! once the replacement has loaded.

use lunette_compositor::protocol::{KeyboardConfig, KeymapConfig};
use mlua::Function;
use pretty_assertions::assert_eq;

use super::*;
use crate::lua::tests::seats::{seat, seated};

/// The configuration a laser plugin amounts to: it releases the seat it held, if any, as its
/// owner closes, and asks for one by the same name.
const LASER: &str = "local lunette = require '@lunette'
    if held then assert(held:destroy()) end
    held = lunette.newSeat { name = 'laser.left' }";

#[test]
fn a_seat_released_and_asked_for_again_during_a_reload_is_handed_over_with_its_identifier() {
    let (session, lua, id) = laser_session();

    run::<()>(&lua, "before = held");
    reload(&lua);

    // A seat kept across a reload is neither destroyed nor created again.
    expect_reset(&session.flush(), id, Some(&KeyboardConfig::default()));
    let (now, same): (u64, bool) = run(&lua, "return held.id, before == held");
    assert_eq!(now, id.get(), "the replacement was given a new seat");
    assert!(same, "a handle from before the reload names the same seat");
    assert!(
        !run::<bool>(&lua, "return held.dead"),
        "the handed-over seat is live in the snapshot it was already in"
    );
}

#[test]
fn a_seat_released_and_not_asked_for_again_is_destroyed_once_the_replacement_has_loaded() {
    let (session, lua, id) = laser_session();

    set_main(
        &lua,
        "if held then assert(held:destroy()) end
         assert(not held:destroy(), 'a released seat cannot be released twice')
         held = nil",
    );
    reload(&lua);

    expect_destroyed(&session.flush(), id);
}

#[test]
fn a_seat_released_by_a_replacement_that_fails_is_destroyed_with_the_failure() {
    let (session, lua, id) = laser_session();

    set_main(
        &lua,
        "if held then assert(held:destroy()) end error('a deliberate defect')",
    );
    let loaded: bool = run(&lua, "return (lunette.reload())");

    assert!(!loaded);
    expect_destroyed(&session.flush(), id);
}

#[test]
fn a_seat_asked_for_with_another_keyboard_is_handed_over_with_that_keyboard() {
    let (session, lua, id) = laser_session();

    set_main(
        &lua,
        "if held then assert(held:destroy()) end
         held = require('@lunette').newSeat { name = 'laser.left', layout = 'de' }",
    );
    reload(&lua);

    let german = KeyboardConfig {
        keymap: KeymapConfig {
            layout: Some("de".to_owned()),
            ..KeymapConfig::default()
        },
        ..KeyboardConfig::default()
    };
    expect_reset(&session.flush(), id, Some(&german));

    // The next reload supplies the replacement owner's resolved keyboard.
    set_main(&lua, LASER);
    reload(&lua);
    expect_reset(&session.flush(), id, Some(&KeyboardConfig::default()));
}

#[test]
fn ten_reloads_keep_one_seat_and_its_name_stays_reserved() {
    let (session, lua, id) = laser_session();

    for _ in 0..10 {
        reload(&lua);
        expect_reset(&session.flush(), id, Some(&KeyboardConfig::default()));
        assert_eq!(run::<u64>(&lua, "return held.id"), id.get());
    }

    let message = error(&lua, "lunette.newSeat { name = 'laser.left' }");
    assert!(message.contains("already exists"), "{message}");
}

#[test]
fn a_reclaimed_name_cannot_be_reclaimed_twice_and_the_default_seat_is_never_released() {
    let (session, lua, id) = laser_session();

    set_main(
        &lua,
        "local lunette = require '@lunette'
         assert(held:destroy())
         assert(not lunette.defaultSeat():destroy())
         held = lunette.newSeat { name = 'laser.left' }
         ok, message = pcall(lunette.newSeat, { name = 'laser.left' })
         default, defaultMessage = pcall(lunette.newSeat, { name = 'lunette' })",
    );
    reload(&lua);

    expect_reset(&session.flush(), id, Some(&KeyboardConfig::default()));
    let (ok, message): (bool, String) = run(&lua, "return ok, tostring(message)");
    assert!(!ok && message.contains("already exists"), "{message}");
    let (ok, message): (bool, String) = run(&lua, "return default, tostring(defaultMessage)");
    assert!(!ok && message.contains("already exists"), "{message}");
}

#[test]
fn a_seat_destroyed_outside_a_reload_is_destroyed_at_once() {
    let (session, lua, id) = laser_session();

    run::<()>(&lua, "assert(held:destroy())");

    expect_destroyed(&session.flush(), id);
}

/// A session whose configuration holds one published laser seat.
fn laser_session() -> (TestSession, Lua, SeatId) {
    let session = session(Vec::new());
    session.begin(seated(Vec::new(), vec![seat(1, "lunette", "us")]));
    let lua = lua(&session);
    set_main(&lua, LASER);
    run::<()>(&lua, "require 'main'");

    let id = match session.flush().as_slice() {
        [Command::CreateSeat { seat, .. }] => *seat,
        other => panic!("expected one seat creation, got {other:?}"),
    };
    session.begin(seated(
        Vec::new(),
        vec![seat(1, "lunette", "us"), seat(id.get(), "laser.left", "us")],
    ));
    (session, lua, id)
}

fn expect_reset(commands: &[Command], id: SeatId, expected: Option<&KeyboardConfig>) {
    match commands {
        [Command::ResetSeat { seat, keyboard }] => {
            assert_eq!(*seat, id);
            assert_eq!(keyboard.as_deref(), expected);
        }
        other => panic!("expected one hand-over of {id}, got {other:?}"),
    }
}

fn expect_destroyed(commands: &[Command], id: SeatId) {
    match commands {
        [Command::DestroySeat { seat }] => assert_eq!(*seat, id),
        other => panic!("expected one destruction of {id}, got {other:?}"),
    }
}

fn set_main(lua: &Lua, source: &str) {
    let chunk: Function = lua
        .load(source)
        .set_name("@main.luau")
        .into_function()
        .expect("the fixture configuration compiles");
    lua.globals()
        .get::<Table>("package")
        .expect("package exists")
        .get::<Table>("preload")
        .expect("package.preload exists")
        .set("main", chunk)
        .expect("the configuration is reachable");
}

fn reload(lua: &Lua) {
    let (loaded, message): (bool, Option<String>) = run(lua, "return lunette.reload()");
    assert!(loaded, "the reload failed: {message:?}");
}
