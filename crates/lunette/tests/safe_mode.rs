//! Safe mode in sessions whose configuration fails to load, driven through `lunctl`.
//!
//! Each run points the module roots at a missing directory, because safe mode must not
//! depend on them.

use std::process::Stdio;

use pretty_assertions::assert_eq;

use crate::session::{Running, code, stderr, stdout};

mod session;

/// Distinct from LÖVR's own 1 and from any signal.
const STOPPED: i32 = 7;

/// Without safe mode, a configuration that does not compile leaves a black headset.
#[test]
fn a_main_lua_that_does_not_compile_produces_a_running_safe_mode() {
    let mut session = start("safe-mode");
    session.wait_until_answering();

    let callbacks = session.lunctl(&[
        "return type(lovr.draw) .. ' ' .. type(lovr.update) .. ' ' .. type(lovr.keypressed)",
    ]);
    assert_eq!(code(&callbacks), 0, "stderr was:\n{}", stderr(&callbacks));
    assert_eq!(stdout(&callbacks), "function function function");

    assert_eq!(
        stdout(&session.lunctl(&["return running == nil"])),
        "true",
        "the broken configuration should not still be running its callbacks",
    );
    assert_eq!(
        stdout(&session.lunctl(&["return package.loaded['@lunette-plugin'] == nil"])),
        "true",
        "no module root should have been loaded",
    );

    let log = session.stop(STOPPED);
    assert!(
        log.contains("safe mode is running"),
        "the session should say it is in safe mode:\n{log}"
    );
    assert!(
        log.contains("main.luau"),
        "the load error should name the file that did not load:\n{log}"
    );
}

/// `boot.lua` raises before it reaches a chunk, which is a separate path to safe mode.
#[test]
fn a_missing_main_lua_produces_safe_mode_too() {
    let mut session = start("safe-mode-no-main");
    session.wait_until_answering();

    let drawn = session.lunctl(&["return type(lovr.draw)"]);
    assert_eq!(code(&drawn), 0, "stderr was:\n{}", stderr(&drawn));
    assert_eq!(stdout(&drawn), "function");

    let log = session.stop(STOPPED);
    assert!(log.contains("safe mode is running"), "{log}");
}

/// Starts `fixture` with the module roots pointed at a missing directory and stderr piped.
fn start(fixture: &str) -> Running {
    Running::start(fixture, |command, runtime| {
        command
            .env(
                "LUNETTE_STDLIB_PATH",
                runtime.join("there-is-no-standard-library-here"),
            )
            .stderr(Stdio::piped());
    })
}
