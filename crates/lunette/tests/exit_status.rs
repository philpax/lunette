//! Linux-specific test for the process exit status requested by a Lua session.
//!
//! `boot.lua` returns the requested status followed by a cookie. Reading stack index -1
//! reads the nil cookie, which converts to zero and hides nonzero exit statuses.
//!
//! `boot::run` returns an opaque `ExitCode`, and the boot sequence creates the LÖVR Lua
//! thread that determines it. The test launches the binary to observe its exit status.
//!
//! Fixtures disable audio, graphics, and headset modules and open no window. The test needs
//! no display, XR runtime, sound device, sleep, or network access. `setIdentity` writes to
//! LÖVR's save directory, so each run sets `XDG_DATA_HOME` to a temporary directory.

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

/// Checks that a configuration can require `lunette` in the LÖVR-created state.
///
/// The fixture reports through distinct exit statuses because it has no other output channel.
#[test]
fn a_configuration_can_require_the_lunette_module() {
    assert_exit_status("require-lunette", 9);
}

/// A relative require resolves against the requiring file, in the session as
/// in the checker. `luau_check.rs` checks the same fixture.
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
    // Validate the fixture path and report absence without launching the binary.
    assert!(
        directory.join("lunette").join("main.luau").is_file(),
        "the {fixture} fixture is missing its main.luau"
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
