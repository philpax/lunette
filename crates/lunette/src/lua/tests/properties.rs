//! The per-window property store, exercised through the Lua surface.
//!
//! The store itself is tested in `crates/lunette/src/properties.rs`, which needs
//! no Lua state. These tests cover the boundary: what a configuration is allowed
//! to store, what error a disallowed value raises, and what is still there after
//! the Lua state has been discarded and rebuilt.

use lunette_compositor::protocol::PixelSize;
use pretty_assertions::assert_eq;

use crate::lua::tests::{error, lua, run, session, snapshot, window};

#[test]
fn a_stored_value_survives_the_lua_state_being_discarded() {
    // A soft reload rebuilds the Lua state without rebuilding the session.
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);

    {
        let before = lua(&session);
        assert!(run::<bool>(
            &before,
            "local w = lunette.windows()[1]
             return w:setProperty('pose', '0 1.6 -1.5')
                and w:setProperty('metres', 0.8)
                and w:setProperty('placedByHand', true)",
        ));
    }

    let after = lua(&session);
    let (pose, metres, by_hand, id): (String, f64, bool, u64) = run(
        &after,
        "local w = lunette.windows()[1]
         return w:getProperty('pose'), w:getProperty('metres'), w:getProperty('placedByHand'), w.id",
    );

    assert_eq!(pose, "0 1.6 -1.5");
    assert_eq!(metres, 0.8);
    assert!(by_hand);
    assert_eq!(
        id, 1,
        "re-associating with a window after a reload rests on the identifier being the same one"
    );
}

#[test]
fn a_value_or_key_the_store_cannot_hold_is_refused_with_the_key_named() {
    // A table holds Lua values, so accepting one would move the store's
    // serialisation problem into the table's contents. A NaN is a defect in
    // the caller's maths and is harder to trace after a reload.
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    for (chunk, expected) in [
        (
            "lunette.windows()[1]:setProperty('layout', {})",
            "'layout' cannot hold",
        ),
        (
            "lunette.windows()[1]:setProperty('layout', { x = 1 })",
            "'layout' cannot hold",
        ),
        (
            "lunette.windows()[1]:setProperty('layout', print)",
            "'layout' cannot hold",
        ),
        (
            "lunette.windows()[1]:setProperty('metres', 0 / 0)",
            "finite",
        ),
        (
            "lunette.windows()[1]:setProperty('metres', 1 / 0)",
            "finite",
        ),
        (
            "lunette.windows()[1]:setProperty('', true)",
            "cannot be empty",
        ),
        ("lunette.windows()[1]:getProperty('')", "cannot be empty"),
    ] {
        let message = error(&lua, chunk);
        assert!(
            message.contains(expected),
            "unhelpful message for {chunk}: {message}"
        );
    }
    let message = error(&lua, "lunette.windows()[1]:setProperty('metres', 0 / 0)");
    assert!(
        message.contains("'metres'"),
        "the message names the key: {message}"
    );

    assert!(
        session.with_properties(|properties| properties.is_empty()),
        "a refused value must not be flattened or serialised into the store"
    );
}

#[test]
fn an_absent_key_is_nil_and_storing_nil_removes_the_key() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert_eq!(
        run::<Option<String>>(&lua, "return lunette.windows()[1]:getProperty('pose')"),
        None
    );

    let held: Option<String> = run(
        &lua,
        "local w = lunette.windows()[1]
         w:setProperty('pose', '0 1 0')
         w:setProperty('pose', nil)
         return w:getProperty('pose')",
    );

    assert_eq!(held, None);
    assert!(session.with_properties(|properties| properties.is_empty()));
}

#[test]
fn every_key_a_window_holds_can_be_enumerated() {
    // Without this, a configuration could read back keys it hardcoded and no
    // others. A key it computed, such as a tag name or a monitor identity, would
    // survive the reload unreachable.
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);

    {
        let lua = lua(&session);
        run::<()>(
            &lua,
            "local w = lunette.windows()[1]
             w:setProperty('tag:left', true)
             w:setProperty('tag:right', true)",
        );
    }

    let lua = lua(&session);
    let mut names: Vec<String> = run(
        &lua,
        "local names = {}
         for key in pairs(lunette.windows()[1]:properties()) do names[#names + 1] = key end
         return names",
    );
    names.sort();

    assert_eq!(names, vec!["tag:left".to_owned(), "tag:right".to_owned()]);
}

#[test]
fn a_windows_properties_go_when_the_window_does() {
    // Entries have the window's lifetime, not the Lua state's. The frame the
    // window closes in still returns them, because that is the frame
    // `lunwindowclosed` is dispatched in and a handler tidying up after a panel
    // reads them there.
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);
    run::<()>(
        &lua,
        "held = lunette.windows()[1] held:setProperty('pose', '0 1 0')",
    );

    for _ in 0..4 {
        session.begin(snapshot(
            vec![window(1, "editor", "foot", PixelSize::new(64, 32))],
            Vec::new(),
        ));
    }
    assert_eq!(
        run::<Option<String>>(&lua, "return held:getProperty('pose')"),
        Some("0 1 0".to_owned()),
        "a window that is still there keeps its properties across frames"
    );

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (dead, during): (bool, Option<String>) =
        run(&lua, "return held.dead, held:getProperty('pose')");
    assert!(dead);
    assert_eq!(
        during,
        Some("0 1 0".to_owned()),
        "the closed-window handler runs in this frame and is what wants to read them"
    );

    session.begin(snapshot(Vec::new(), Vec::new()));

    assert_eq!(
        run::<Option<String>>(&lua, "return held:getProperty('pose')"),
        None
    );
    assert!(session.with_properties(|properties| properties.is_empty()));
}

#[test]
fn storing_against_a_dead_handle_returns_false_and_keeps_nothing() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(Vec::new(), Vec::new()));
    session.begin(snapshot(Vec::new(), Vec::new()));

    assert!(!run::<bool>(
        &lua,
        "return held:setProperty('pose', '0 1 0')"
    ));
    assert!(
        session.with_properties(|properties| properties.is_empty()),
        "the window's entries are already gone, so there is nothing to store into"
    );
}

#[test]
fn two_windows_keep_their_own_properties() {
    let session = session(vec![
        window(1, "editor", "foot", PixelSize::new(64, 32)),
        window(2, "browser", "firefox", PixelSize::new(64, 32)),
    ]);
    let lua = lua(&session);

    let (first, second): (String, String) = run(
        &lua,
        "local w = lunette.windows()
         w[1]:setProperty('tag', 'left')
         w[2]:setProperty('tag', 'right')
         return w[1]:getProperty('tag'), w[2]:getProperty('tag')",
    );

    assert_eq!(first, "left");
    assert_eq!(second, "right");
}
