//! Whether lunette renders a scene of its own, from the configuration's side.
//!
//! [`crate::scene`] covers the gate itself against a fake `lovr.headset`.
//! This module covers the session side: when a change takes effect, and what
//! the gate receives on a frame that copied into a layer.

use mlua::Lua;
use pretty_assertions::assert_eq;

use crate::{
    lua::{
        install,
        tests::{TestSession, run, session},
    },
    scene::{Gate, SceneRendering},
};

/// A state with the module installed and a `lovr.headset` for the gate to wrap,
/// which the plain [`crate::lua::tests::lua`] state lacks.
fn gated_lua(session: &TestSession) -> Lua {
    let lua = crate::test_lua::session_lua();
    lua.load(
        r"
        headset = { passes = 0 }
        headset.getPass = function()
          headset.passes = headset.passes + 1
          return 'pass'
        end
        package.preload['lovr.headset'] = function() return headset end
        ",
    )
    .exec()
    .expect("the fake headset module loads");

    install(&lua, session).expect("the module installs");
    // boot.lua sets up the `lovr` scaffolding, and the module's event
    // dispatchers install into it.
    lua.load("lovr = {} lovr.handlers = setmetatable({}, { __index = lovr })")
        .exec()
        .expect("the lovr scaffolding loads");
    lua.load("lunette = require '@lunette'")
        .exec()
        .expect("require resolves the module");
    lua
}

#[test]
fn the_scene_is_drawn_until_a_configuration_says_otherwise() {
    let session = session(Vec::new());
    let lua = gated_lua(&session);

    assert!(run::<bool>(&lua, "return lunette.sceneEnabled()"));
    assert_eq!(session.scene(), SceneRendering::Drawn);
    assert_eq!(session.scene_gate(), Gate::Through);
}

#[test]
fn turning_the_scene_off_takes_effect_at_the_next_frame_boundary() {
    // The change does not take effect mid-frame: the frame's `setLayers` has
    // already gone out with `main` true, and a gate that answers nothing after
    // that would leave the runtime compositing a projection layer with nothing
    // drawn into it.
    let session = session(Vec::new());
    let lua = gated_lua(&session);

    run::<()>(&lua, "lunette.setSceneEnabled(false)");

    assert!(!run::<bool>(&lua, "return lunette.sceneEnabled()"));
    assert_eq!(
        session.scene(),
        SceneRendering::Drawn,
        "the frame that asked keeps the scene it was already drawing"
    );

    session.begin(session.snapshot());
    assert_eq!(session.scene(), SceneRendering::Skipped);
}

#[test]
fn a_skipped_frame_answers_nothing_where_boot_lua_asks_for_a_pass() {
    let session = session(Vec::new());
    let lua = gated_lua(&session);
    run::<()>(&lua, "lunette.setSceneEnabled(false)");
    session.begin(session.snapshot());

    let pass: Option<String> = run(&lua, "return require('lovr.headset').getPass()");

    assert_eq!(pass, None);
    assert_eq!(
        run::<u32>(&lua, "return headset.passes"),
        0,
        "the acquire and its swapchain wait are the whole of the saving"
    );
}

#[test]
fn the_frame_that_copied_into_a_layer_is_the_one_that_flushes() {
    // The flush is taken, not read: the first gated call consumes it, so a
    // frame's second gated call does not submit LÖVR's stream a second time.
    let session = session(Vec::new());
    session.set_scene(SceneRendering::Skipped);
    session.begin(session.snapshot());

    assert_eq!(session.scene_gate(), Gate::Skip);

    session.note_copies_recorded();
    assert_eq!(session.scene_gate(), Gate::SkipAfterFlush);
    assert_eq!(session.scene_gate(), Gate::Skip);
}

#[test]
fn a_frames_copies_do_not_carry_into_the_next_frame() {
    // A frame that draws a scene submits its own copies through `lovr.draw`'s
    // pass, so the next frame has nothing left to flush.
    let session = session(Vec::new());
    session.set_scene(SceneRendering::Skipped);
    session.begin(session.snapshot());
    session.note_copies_recorded();

    session.begin(session.snapshot());

    assert_eq!(session.scene_gate(), Gate::Skip);
}

#[test]
fn turning_the_scene_back_on_restores_the_pass() {
    let session = session(Vec::new());
    let lua = gated_lua(&session);
    run::<()>(&lua, "lunette.setSceneEnabled(false)");
    session.begin(session.snapshot());

    run::<()>(&lua, "lunette.setSceneEnabled(true)");
    session.begin(session.snapshot());

    let pass: Option<String> = run(&lua, "return require('lovr.headset').getPass()");
    assert_eq!(pass, Some("pass".to_owned()));
}

#[test]
fn the_scene_switch_reads_its_argument_the_way_lua_reads_a_condition() {
    // The switch reads its argument by truthiness, as Lua reads a condition,
    // and does not check the argument's type. A configuration writes
    // `lunette.setSceneEnabled(panel.anyInScene())` and passes the result,
    // which may be any truthy or falsy value. Calling the switch with no
    // argument turns the scene off and does not raise.
    let session = session(Vec::new());
    let lua = gated_lua(&session);

    run::<()>(&lua, "lunette.setSceneEnabled()");
    assert!(!run::<bool>(&lua, "return lunette.sceneEnabled()"));

    run::<()>(&lua, "lunette.setSceneEnabled('anything')");
    assert!(run::<bool>(&lua, "return lunette.sceneEnabled()"));
}
