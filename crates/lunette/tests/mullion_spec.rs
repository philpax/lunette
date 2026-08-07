//! Linux-only: runs the `lua/spec/` suite, which covers the `mullion` standard
//! library.
//!
//! The workspace's checks compile Rust and the standard library is Lua, so
//! without this the specs would be a thing somebody had to remember to run. It
//! is a `cargo test` so that they run with everything else.
//!
//! It spawns the real binary rather than a standalone interpreter, for two
//! reasons: the devshell ships no LuaJIT, and the tree the specs are required
//! through is LÖVR's virtual filesystem rather than the process's, so a bare
//! interpreter would be resolving a different set of paths than a session does.
//! The fixture switches off the audio, graphics, and headset modules and opens
//! no window, so no display, no XR runtime, and no sound device are needed;
//! nothing here sleeps or touches the network, and every directory it writes is
//! a temporary one it removes.

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use tempfile::TempDir;

/// The status the fixture quits with when every case passed.
const PASSED: i32 = 9;

#[test]
fn every_mullion_spec_passes() {
    let outcome = run();

    assert_eq!(
        outcome.status,
        Some(PASSED),
        "\n{}\n{}",
        outcome.stdout,
        outcome.stderr
    );
}

/// The `lua/` directory of the working tree this test was built from, which is
/// what the run mounts: the specs cover the tree as it is installed, not a copy
/// assembled for them.
fn repository_standard_library() -> PathBuf {
    // `crates/lunette` up two levels to the workspace root.
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    let lua = root.join("lua");
    assert!(
        lua.join("spec").join("runner.lua").is_file(),
        "{} should hold the spec runner",
        lua.display()
    );
    lua
}

/// What one run of the suite reported.
struct Outcome {
    status: Option<i32>,
    /// The runner's own report, which names every failing case.
    stdout: String,
    /// A Lua error that stopped the run before the report was printed says so
    /// here and nowhere else.
    stderr: String,
}

fn run() -> Outcome {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("mullion-spec");
    // Checked before the run, so that a mislaid fixture fails as itself rather
    // than as boot.lua's "no main.lua" path.
    assert!(
        directory.join("lunette").join("main.lua").is_file(),
        "the mullion-spec fixture is missing its main.lua"
    );

    // `boot.lua` creates `$XDG_DATA_HOME/LOVR/<identity>` on every run and fails
    // the boot when it cannot. A temporary one per run also removes the
    // dependency on `HOME`, which is unset below.
    let data_directory = match TempDir::with_prefix("lunette-mullion-spec-data-") {
        Ok(directory) => directory,
        Err(error) => panic!("a temporary data directory could not be created: {error}"),
    };

    let output = Command::new(env!("CARGO_BIN_EXE_lunette"))
        // The fixture directory holds a `lunette` subdirectory, which is what
        // `$XDG_CONFIG_HOME/lunette` resolves to. `HOME` is removed so that the
        // developer's own configuration cannot be reached if the fixture is ever
        // mislaid, which would otherwise turn a missing fixture into a confusing
        // pass.
        .env("XDG_CONFIG_HOME", &directory)
        .env("XDG_DATA_HOME", data_directory.path())
        .env("LUNETTE_STDLIB_PATH", repository_standard_library())
        .env_remove("HOME")
        .output();

    let output = match output {
        Ok(output) => output,
        Err(error) => panic!("the lunette binary could not be run: {error}"),
    };

    Outcome {
        status: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}
