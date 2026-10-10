//! The session side of the scene gate: when a change takes effect, and what the
//! gate receives on a frame that copied into a layer.

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
    // The module's event dispatchers install into the scaffolding boot.lua sets up.
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
    let _lua = gated_lua(&session);

    assert_eq!(session.scene(), SceneRendering::Drawn);
    assert_eq!(session.scene_gate(), Gate::Through);
}

#[test]
fn turning_the_scene_off_and_on_takes_effect_at_the_next_frame_boundary() {
    // A mid-frame change would leave the runtime compositing a projection
    // layer that the frame's `setLayers` already announced with nothing drawn.
    let session = session(Vec::new());
    let lua = gated_lua(&session);

    run::<()>(&lua, "lunette.setSceneEnabled(false)");

    assert_eq!(
        session.scene(),
        SceneRendering::Drawn,
        "the frame that asked keeps the scene it was already drawing"
    );

    session.begin(session.snapshot());
    assert_eq!(session.scene(), SceneRendering::Skipped);

    let pass: Option<String> = run(&lua, "return require('lovr.headset').getPass()");
    assert_eq!(pass, None);
    assert_eq!(
        run::<u32>(&lua, "return headset.passes"),
        0,
        "the acquire and its swapchain wait are the whole of the saving"
    );

    run::<()>(&lua, "lunette.setSceneEnabled(true)");
    session.begin(session.snapshot());

    let pass: Option<String> = run(&lua, "return require('lovr.headset').getPass()");
    assert_eq!(pass, Some("pass".to_owned()));
}

#[test]
fn the_frame_that_copied_into_a_layer_is_the_one_that_flushes() {
    // The first gated call consumes the flush, so a second gated call does not
    // submit LÖVR's stream again.
    let session = session(Vec::new());
    session.set_scene(SceneRendering::Skipped);
    session.begin(session.snapshot());

    assert_eq!(session.scene_gate(), Gate::Skip);

    session.note_copies_recorded();
    assert_eq!(session.scene_gate(), Gate::SkipAfterFlush);
    assert_eq!(session.scene_gate(), Gate::Skip);

    session.note_copies_recorded();
    session.begin(session.snapshot());
    assert_eq!(
        session.scene_gate(),
        Gate::Skip,
        "a frame's copies do not carry into the next frame"
    );
}
