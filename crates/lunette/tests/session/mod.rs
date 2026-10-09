//! The environment a test gives the lunette binary it boots.
//!
//! The exit status, the module-root mount, a reload against `boot.lua`, and safe mode exist
//! only in a session the binary boots, so these tests spawn it. The fixtures switch off the
//! audio, graphics, and headset modules and open no window, so a run needs no display, XR
//! runtime, or sound device.
//!
//! `boot.lua` creates `$XDG_DATA_HOME/LOVR/<identity>` on every run and fails when it cannot.
//! Each run gets its own data directory, so parallel runs do not race to create one leaf and
//! the run does not depend on `HOME` or on a passwd entry for the running uid. `HOME` and
//! `LUNETTE_CONFIG_PATH` are removed, so a mislaid fixture fails rather than loading a
//! developer's own or the shipped configuration.

// `expect` would fail in a binary that uses every item, so this is an `allow`.
#![allow(
    dead_code,
    reason = "each test binary compiles this module and uses a different part of it"
)]

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use tempfile::TempDir;

/// A command that boots the binary against `fixture` with the working tree's module roots,
/// and the data directory it writes into, which is removed when dropped.
pub fn command(fixture: &str) -> (Command, TempDir) {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(fixture);
    assert!(
        directory.join("lunette").join("conf.luau").is_file(),
        "the {fixture} fixture is missing its conf.luau"
    );
    let data = TempDir::with_prefix("lunette-session-")
        .unwrap_or_else(|error| panic!("a temporary data directory: {error}"));

    let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
    command
        .env_remove("HOME")
        .env_remove("LUNETTE_CONFIG_PATH")
        .env("XDG_CONFIG_HOME", directory)
        .env("XDG_DATA_HOME", data.path())
        .env("LUNETTE_STDLIB_PATH", standard_library());
    (command, data)
}

/// Boots the binary against `fixture` and asserts the status it exited with, quoting its
/// stdout and stderr on failure. The fixtures print which assertion did not hold, and a Lua
/// error arrives on stderr.
pub fn assert_exit_status(fixture: &str, expected: i32) {
    let (mut command, data) = command(fixture);
    let output = command
        .output()
        .unwrap_or_else(|error| panic!("the lunette binary could not be run: {error}"));

    assert_eq!(
        output.status.code(),
        Some(expected),
        "the {fixture} fixture should have exited {expected}; stdout was:\n{}\nstderr was:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // A run that ignored `XDG_DATA_HOME` would write into the developer's own data
    // directory and still pass every assertion above.
    assert!(
        data.path().join("LOVR").is_dir(),
        "the {fixture} run should have written its save directory into {}",
        data.path().display()
    );
}

/// The `lua/` directory of the working tree this test is built from.
fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}
