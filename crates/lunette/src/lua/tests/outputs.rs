//! `lunette.newOutput`, the output handle, and the unit conversion at the Lua boundary.
//!
//! These tests run with a Lua state and no compositor. A queued command
//! records the request the compositor would receive, and a handle reads its
//! values back from the frame's snapshot.

use lunette_compositor::protocol::{
    OutputId, OutputMode, OutputScale, OutputSnapshot, RefreshRate,
};
use pretty_assertions::assert_eq;

use super::*;

fn output_id(raw: u64) -> OutputId {
    OutputId::new(raw).expect("non-zero")
}

fn mode(width: u32, height: u32, scale: f64, hertz: u32) -> OutputMode {
    OutputMode {
        size: PixelSize::new(width, height),
        scale: OutputScale::new(scale).expect("the test names a positive scale"),
        refresh: RefreshRate::from_millihertz(hertz * 1_000),
    }
}

/// A snapshot carrying outputs, which the shared helper does not.
fn with_outputs(outputs: Vec<OutputSnapshot>) -> Arc<Snapshot> {
    Arc::new(Snapshot {
        outputs,
        ..Snapshot::default()
    })
}

/// The single command the session queued. A different number of queued
/// commands fails the assertion, naming the set.
fn only_command(session: &TestSession) -> Command {
    let mut commands = session.flush();
    assert_eq!(
        commands.len(),
        1,
        "expected exactly one command, found {commands:?}"
    );
    commands.remove(0)
}

#[test]
fn creating_an_output_asks_the_compositor_for_the_mode_that_was_named() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let id: u64 = run(
        &lua,
        "local out = lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }
         return out.id",
    );

    // The default output already holds the first identifier, so the first
    // output the call creates takes the second.
    assert_eq!(id, 2);
    match only_command(&session) {
        Command::CreateOutput { output, mode } => {
            assert_eq!(output, output_id(2));
            assert_eq!(mode.size, PixelSize::new(1920, 1080));
            assert_eq!(mode.scale.get(), 1.5);
            // Lua takes hertz; the wire carries millihertz.
            assert_eq!(mode.refresh.millihertz(), 90_000);
        }
        other => panic!("expected a create, found {other:?}"),
    }
}

#[test]
fn an_output_that_names_no_scale_or_refresh_takes_the_defaults() {
    let session = session(Vec::new());
    let lua = lua(&session);

    run::<()>(&lua, "lunette.newOutput{ width = 1280, height = 720 }");

    match only_command(&session) {
        Command::CreateOutput { mode, .. } => {
            assert_eq!(mode.scale.get(), 1.0);
            assert_eq!(mode.refresh.millihertz(), 60_000);
        }
        other => panic!("expected a create, found {other:?}"),
    }
}

#[test]
fn a_handle_is_dead_until_the_snapshot_lists_its_output() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert!(
        run::<bool>(
            &lua,
            "return lunette.newOutput{ width = 800, height = 600 }.dead"
        ),
        "the compositor has not seen the request in the frame that made it"
    );
}

#[test]
fn a_handle_reports_the_mode_it_was_asked_for_before_the_compositor_answers() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let (width, height, scale, refresh): (u32, u32, f64, f64) = run(
        &lua,
        "local out = lunette.newOutput{ width = 1920, height = 1080, scale = 2, refresh = 144 }
         return out.width, out.height, out.scale, out.refresh",
    );

    assert_eq!((width, height), (1920, 1080));
    assert_eq!(scale, 2.0);
    // The handle reports hertz; the wire carries millihertz.
    assert_eq!(refresh, 144.0);
}

#[test]
fn the_output_list_reports_what_the_snapshot_holds() {
    let session = session(Vec::new());
    session.begin(with_outputs(vec![
        OutputSnapshot {
            output: output_id(1),
            mode: mode(2560, 1440, 1.0, 60),
        },
        OutputSnapshot {
            output: output_id(2),
            mode: mode(1920, 1080, 1.5, 90),
        },
    ]));
    let lua = lua(&session);

    let (count, second_id, second_scale, second_refresh): (usize, u64, f64, f64) = run(
        &lua,
        "local outs = lunette.outputs()
         return #outs, outs[2].id, outs[2].scale, outs[2].refresh",
    );

    assert_eq!(count, 2);
    assert_eq!(second_id, 2);
    assert_eq!(second_scale, 1.5);
    assert_eq!(second_refresh, 90.0);
}

#[test]
fn set_mode_keeps_the_fields_it_was_not_given() {
    let session = session(Vec::new());
    session.begin(with_outputs(vec![OutputSnapshot {
        output: output_id(1),
        mode: mode(2560, 1440, 1.0, 60),
    }]));
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.outputs()[1]:setMode{ scale = 2 }"
    ));

    match only_command(&session) {
        Command::ReconfigureOutput { output, mode } => {
            assert_eq!(output, output_id(1));
            assert_eq!(mode.scale.get(), 2.0);
            assert_eq!(mode.size, PixelSize::new(2560, 1440));
            assert_eq!(mode.refresh.millihertz(), 60_000);
        }
        other => panic!("expected a reconfigure, found {other:?}"),
    }
}

#[test]
fn destroying_an_output_asks_the_compositor_to_withdraw_it() {
    let session = session(Vec::new());
    session.begin(with_outputs(vec![OutputSnapshot {
        output: output_id(2),
        mode: mode(1920, 1080, 1.0, 60),
    }]));
    let lua = lua(&session);

    assert!(run::<bool>(&lua, "return lunette.outputs()[1]:destroy()"));
    match only_command(&session) {
        Command::DestroyOutput { output } => assert_eq!(output, output_id(2)),
        other => panic!("expected a destroy, found {other:?}"),
    }
}

#[test]
fn every_method_answers_false_on_an_output_that_is_gone() {
    let session = session(Vec::new());
    let lua = lua(&session);

    // The handle names an output the compositor has not created. A caller
    // cannot distinguish that state from a destroyed output, and the methods
    // answer false for both.
    let (destroyed, remoded): (bool, bool) = run(
        &lua,
        "local out = lunette.newOutput{ width = 800, height = 600 }
         return out:destroy(), out:setMode{ scale = 2 }",
    );

    assert!(!destroyed);
    assert!(!remoded);
}

#[test]
fn an_output_with_an_invalid_argument_is_refused() {
    let session = session(Vec::new());
    let lua = lua(&session);

    for (chunk, expected) in [
        ("lunette.newOutput{ scale = 2 }", "width and a height"),
        (
            "lunette.newOutput{ width = 1920.5, height = 1080 }",
            "size in pixels",
        ),
        (
            "lunette.newOutput{ width = 0, height = 1080 }",
            "size in pixels",
        ),
        (
            "lunette.newOutput{ width = -1920, height = 1080 }",
            "size in pixels",
        ),
        (
            "lunette.newOutput{ width = 1920, height = 1080, scale = 0 }",
            "",
        ),
        (
            "lunette.newOutput{ width = 1920, height = 1080, scale = -1 }",
            "",
        ),
        (
            "lunette.newOutput{ width = 1920, height = 1080, refresh = 0 }",
            "",
        ),
        (
            "lunette.newOutput{ width = 1920, height = 1080, refresh = -60 }",
            "",
        ),
        (
            "lunette.newOutput{ width = 1920, height = 1080, transform = 'flipped' }",
            "transform",
        ),
    ] {
        let message = error(&lua, chunk);
        assert!(!message.is_empty(), "{chunk} was accepted");
        assert!(
            message.contains(expected),
            "the message for {chunk} does not name the problem: {message}"
        );
    }
}

#[test]
fn a_spawn_can_name_the_output_its_client_is_shown_or_leave_it_on_the_default() {
    let session = session(Vec::new());
    session.begin(with_outputs(vec![OutputSnapshot {
        output: output_id(2),
        mode: mode(1920, 1080, 1.0, 60),
    }]));
    let lua = lua(&session);

    run::<()>(
        &lua,
        "lunette.spawn{ argv = { 'foot' }, output = lunette.outputs()[1] }",
    );

    match only_command(&session) {
        Command::Spawn(request) => assert_eq!(request.output, Some(output_id(2))),
        other => panic!("expected a spawn, found {other:?}"),
    }

    run::<()>(&lua, "lunette.spawn{ argv = { 'foot' } }");
    match only_command(&session) {
        Command::Spawn(request) => assert_eq!(
            request.output, None,
            "a spawn that names no output leaves the client on the default one"
        ),
        other => panic!("expected a spawn, found {other:?}"),
    }
}

#[test]
fn a_spawn_output_that_is_not_an_output_handle_is_refused() {
    let session = session(Vec::new());
    let lua = lua(&session);

    for chunk in [
        "lunette.spawn{ argv = { 'foot' }, output = 2 }",
        "lunette.spawn{ argv = { 'foot' }, output = 'lunette-2' }",
        "lunette.spawn{ argv = { 'foot' }, output = {} }",
    ] {
        let message = error(&lua, chunk);
        assert!(
            message.contains("output handle"),
            "the message does not say what was wanted: {message}"
        );
    }

    // A seat is userdata with a handle metafield, so it passes the type check
    // and the borrow refuses it.
    let message = error(
        &lua,
        "lunette.spawn{ argv = { 'foot' }, output = lunette.newSeat { name = 'left' } }",
    );
    assert!(
        !message.is_empty(),
        "a seat handle was accepted where an output was wanted"
    );
}

#[test]
fn the_scale_ladder_reaches_lua_as_the_one_the_layer_pool_keys_on() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let steps: Vec<f64> = run(&lua, "return lunette.scaleSteps()");

    let expected: Vec<f64> = crate::scale::STEPS
        .iter()
        .map(|step| f64::from(step.in_120ths()) / f64::from(crate::scale::ScaleStep::DENOMINATOR))
        .collect();
    assert_eq!(steps, expected);
    // The assertions pin the two ends the ladder declares. A change to one end
    // that does not update the other fails this test at the point where a
    // per-frame panel allocation would encounter the mismatch.
    assert_eq!(steps.first(), Some(&1.0));
    assert_eq!(steps.last(), Some(&3.0));
}
