//! Linux-only: the exit status a Lua session asks for reaches the process.
//!
//! This is the regression test for reading the status from the wrong slot of
//! the coroutine's stack. `vendor/lovr/etc/boot.lua:374` finishes with
//! `return result, cookie`, so index -1 is the nil cookie and `lua_tointeger`
//! on it yields 0 — a host reading -1 reports success for every exit, silently.
//!
//! It spawns the real binary, which sets aside the "no real subprocesses" rule
//! in CONTRIBUTING.md's testing conventions. The exception is recorded there
//! and in `docs/decisions.md`, and the reason is that the exit status is an
//! observable property of the process rather than a value any function returns:
//! `boot::run` produces an `ExitCode`, which is opaque and has no accessor, and
//! the path that produces it needs a live LÖVR Lua thread that only the real
//! boot sequence can create. The fixtures below switch off the audio,
//! graphics, and headset modules and open no window, so no display, no XR
//! runtime, and no sound device are needed; nothing here sleeps, touches the
//! network, or writes to disk.

use std::{
    path::{Path, PathBuf},
    process::Command,
};

#[test]
fn a_quit_status_reaches_the_process_exit_status() {
    assert_exit_status("quit-with-status", 3);
}

#[test]
fn a_quit_without_a_status_exits_zero() {
    assert_exit_status("quit-without-status", 0);
}

/// Runs the binary against the named fixture and asserts the status it exited
/// with.
///
/// The child's stderr is quoted on failure, because the interesting failures —
/// boot.lua's usage message, a Lua error, a module that would not load — say
/// what went wrong there and nowhere else.
fn assert_exit_status(fixture: &str, expected: i32) {
    let directory = fixture_directory(fixture);
    // Checked before the run, so that a mislaid fixture fails as itself rather
    // than as boot.lua's "no main.lua" path.
    assert!(
        directory.join("lunette").join("main.lua").is_file(),
        "the {fixture} fixture is missing its main.lua"
    );

    let run = Command::new(env!("CARGO_BIN_EXE_lunette"))
        // The fixture directory holds a `lunette` subdirectory, which is what
        // `$XDG_CONFIG_HOME/lunette` resolves to. `HOME` is removed so that the
        // developer's own configuration cannot be reached if the fixture is
        // ever mislaid, which would otherwise turn a missing fixture into a
        // confusing pass.
        .env("XDG_CONFIG_HOME", &directory)
        .env_remove("HOME")
        .output();
    let output = match run {
        Ok(output) => output,
        Err(error) => panic!("the lunette binary could not be run: {error}"),
    };

    assert_eq!(
        output.status.code(),
        Some(expected),
        "the {fixture} fixture should have exited {expected}; stderr was:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn fixture_directory(fixture: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(fixture)
}
