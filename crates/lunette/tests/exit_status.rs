//! Linux-only: the exit status a Lua session asks for reaches the process.
//!
//! This test covers reading the status from the wrong slot of the
//! coroutine's stack. `vendor/lovr/etc/boot.lua` finishes with
//! `return result, cookie`; index -1 is then the nil cookie, and
//! `lua_tointeger` on it yields 0. A host that reads -1 reports success for
//! every exit, silently.
//!
//! The test spawns the real binary. CONTRIBUTING.md's testing conventions
//! and `docs/dev/build-and-development.md` record the exception to the "no real
//! subprocesses" rule: the exit status is an observable property of the
//! process, not a value any function returns. `boot::run` produces an
//! `ExitCode`, which is opaque and has no accessor, and the path that
//! produces it needs a live LÖVR Lua thread that only the real boot sequence
//! can create. The fixtures below switch off the audio, graphics, and
//! headset modules and open no window; no display, no XR runtime, and no
//! sound device are needed. The test neither sleeps nor touches the network.
//! The one write is LÖVR's save directory.
//! `lovr.filesystem.setIdentity` creates it unconditionally; each run points
//! `XDG_DATA_HOME` at its own temporary directory, the write lands there,
//! and the directory is removed when the test ends.

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use tempfile::TempDir;

#[test]
fn a_quit_status_reaches_the_process_exit_status() {
    assert_exit_status("quit-with-status", 3);
}

#[test]
fn a_quit_without_a_status_exits_zero() {
    assert_exit_status("quit-without-status", 0);
}

/// The `lunette` module is reachable from a configuration, on the state
/// LÖVR created, not on one a test built.
///
/// A fixture has no reporting channel other than the exit status. The
/// fixture's `main.lua` quits with 9 when every assertion held and with a
/// distinct status for each that did not.
#[test]
fn a_configuration_can_require_the_lunette_module() {
    assert_exit_status("require-lunette", 9);
}

/// A relative require resolves against the requiring file, in the session as
/// in the checker. `require_relative_check.rs` checks the same fixture.
#[test]
fn a_relative_require_resolves_against_the_requiring_file() {
    assert_exit_status("require-relative", 9);
}

/// Runs the binary against the named fixture and asserts the status it
/// exited with.
///
/// The child's stderr is quoted on failure. The interesting failures
/// (boot.lua's usage message, a Lua error, a module that would not load)
/// say what went wrong there and nowhere else.
fn assert_exit_status(fixture: &str, expected: i32) {
    let directory = fixture_directory(fixture);
    // Checked before the run. A mislaid fixture then fails as itself, and
    // boot.lua's "no main.lua" path never runs.
    assert!(
        directory.join("lunette").join("main.lua").is_file(),
        "the {fixture} fixture is missing its main.lua"
    );

    // `boot.lua` calls `lovr.filesystem.setIdentity` on every run, which
    // creates `$XDG_DATA_HOME/LOVR/<identity>` and fails the boot when it
    // cannot. With the default directory, two of these tests running in
    // parallel race to create the same leaf and the loser exits 1. A
    // temporary directory per run gives each its own tree and removes the
    // dependency on `HOME` (which the command unsets) and on `getpwuid`
    // having an entry for the running uid, which a container need not
    // provide.
    let data_directory = match TempDir::with_prefix("lunette-exit-status-") {
        Ok(directory) => directory,
        Err(error) => panic!("a temporary data directory could not be created: {error}"),
    };

    let run = Command::new(env!("CARGO_BIN_EXE_lunette"))
        // The fixture directory holds a `lunette` subdirectory, and
        // `$XDG_CONFIG_HOME/lunette` resolves to it. `HOME` is removed; a
        // mislaid fixture would otherwise reach the developer's own
        // configuration and pass confusingly.
        // `LUNETTE_CONFIG_PATH` is removed for the same reason: a developer's
        // shell exports it to point a session at the working copy, and a
        // mislaid fixture would otherwise load the shipped configuration and
        // pass confusingly.
        .env_remove("LUNETTE_CONFIG_PATH")
        .env("XDG_CONFIG_HOME", &directory)
        .env("XDG_DATA_HOME", data_directory.path())
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
    // A run that ignored `XDG_DATA_HOME` would write its save directory into
    // the developer's own data directory, and would still pass every
    // assertion above.
    assert!(
        data_directory.path().join("LOVR").is_dir(),
        "the {fixture} run should have written its save directory into {}",
        data_directory.path().display()
    );
}

fn fixture_directory(fixture: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(fixture)
}
