//! Linux-only: runs the `lua/spec/` suite, which covers the optional `mullion`
//! library, the desktop's persistence, and the shared vocabulary.
//!
//! The workspace's checks compile Rust, and those modules are Lua.
//! Without the `cargo test` the specs would need a manual run; with it they
//! run with everything else.
//!
//! The test spawns the real binary because the devshell ships no LuaJIT and
//! because the specs are required through LÖVR's virtual filesystem, not the
//! process's. A standalone interpreter would resolve a different set of paths
//! than a session does. The fixture switches off the audio, graphics, and
//! headset modules and opens no window; no display, no XR runtime, and no
//! sound device are needed. The test neither sleeps nor touches the network,
//! and every directory it writes is a temporary one it removes.

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use tempfile::TempDir;

/// The fixture quits with this status when every case passes.
const PASSED: i32 = 9;

#[test]
fn every_lua_spec_passes() {
    let outcome = run();

    assert_eq!(
        outcome.status,
        Some(PASSED),
        "\n{}\n{}",
        outcome.stdout,
        outcome.stderr
    );
}

/// The `lua/` directory of the working tree the test was built from. The run
/// mounts it, and the specs cover the tree as installed, with no copy
/// assembled for them.
fn repository_standard_library() -> PathBuf {
    // `crates/lunette` is two levels below the workspace root.
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

struct Outcome {
    status: Option<i32>,
    /// The runner's report, which names every failing case.
    stdout: String,
    /// A Lua error that stops the run before the report is printed appears in
    /// this field and nowhere else.
    stderr: String,
}

fn run() -> Outcome {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("lua-spec");
    // Checked before the run. A mislaid fixture then fails as itself, and
    // boot.lua's "no main.lua" path never runs.
    assert!(
        directory.join("lunette").join("main.lua").is_file(),
        "the lua-spec fixture is missing its main.lua"
    );

    // `boot.lua` creates `$XDG_DATA_HOME/LOVR/<identity>` on every run and
    // fails the boot when it cannot. A temporary directory per run also
    // removes the dependency on `HOME`, which the command unsets.
    let data_directory = match TempDir::with_prefix("lunette-lua-spec-data-") {
        Ok(directory) => directory,
        Err(error) => panic!("a temporary data directory could not be created: {error}"),
    };

    let output = Command::new(env!("CARGO_BIN_EXE_lunette"))
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
