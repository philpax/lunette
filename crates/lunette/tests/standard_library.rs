//! Linux-only: the file-backed module roots are mounted where `require`
//! resolves them, and a configuration cannot write over them.
//!
//! The cases use `@lunette-plugin`, the plugin facade's root, which every
//! other root is written against; each mounted root is mounted by the same
//! code.
//!
//! The mount is installed by wrapping the `package.preload` entry LÖVR creates
//! `lovr.filesystem` from. `vendor/lovr/etc/boot.lua` creates that module and
//! runs `main.luau` on the same coroutine resume, leaving the host no moment
//! between the two. The wrapping is observable on a state the boot sequence
//! builds and not on a state a unit test creates, because LÖVR's virtual
//! filesystem does not exist there. A unit test has nothing to mount into.
//!
//! The test spawns the lunette binary for the same reason and under the same
//! terms as `exit_status.rs`, which records the full rationale. The fixture
//! switches off the audio, graphics, and headset modules and opens no window,
//! so no display, no XR runtime, and no sound device are needed; the run
//! neither sleeps nor touches the network, and every directory it writes is a
//! temporary one it removes.

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use tempfile::TempDir;

/// The root module of the plugin facade the tests write for themselves.
///
/// The run checks for the `fixture` field. A session that resolves some other
/// tree, an installed one or a developer's own, does not satisfy the check.
/// The suite cannot pass with the wrong module roots.
const FIXTURE_ROOT_MODULE: &str = "return { fixture = true }\n";

/// The field [`FIXTURE_ROOT_MODULE`] carries. Checking for the field verifies
/// contents, not paths.
const FIXTURE_MARKER: &str = "fixture";

/// The directory under a module tree that holds the root the cases require.
const ROOT: &str = "lunette-plugin";

/// The fixture quits with this status when every assertion holds.
const PASSED: i32 = 9;

#[test]
fn the_override_is_mounted_and_require_resolves_from_it() {
    let stdlib = standard_library_tree();

    let outcome = run(stdlib.path(), &["present", FIXTURE_MARKER]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
}

/// The repository's own `lua/` resolves as well as a tree the test writes.
///
/// The other cases supply their own trees. Without this case the suite would
/// pass with a facade whose root module is missing or unparseable.
#[test]
fn the_repository_standard_library_resolves() {
    let stdlib = repository_standard_library();

    let outcome = run(&stdlib, &["present"]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
}

/// A module tree that is not installed is not a boot failure.
///
/// A missing or broken installation is one of the reasons a configuration
/// fails to load, and safe mode needs a running session to recover from it,
/// so a missing mount leaves the session running, and `require` reports it.
#[test]
fn a_missing_standard_library_does_not_stop_the_session() {
    let absent = temporary_directory("lunette-standard-library-absent-");

    let outcome = run(&absent.path().join("never-installed"), &["absent"]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
}

/// A configuration cannot overwrite the module roots it is running on top of.
/// An overwrite is a failure no reload can repair.
///
/// The fixture writes over the root module's own path through
/// `lovr.filesystem.write` and then requires it again. The write goes to the
/// save directory, which is mounted behind the module roots, so the module
/// it loads is unchanged. The test asserts that the file on disk is untouched.
#[test]
fn a_configuration_cannot_write_over_the_standard_library() {
    let stdlib = standard_library_tree();
    let module = stdlib.path().join(ROOT).join("init.luau");

    let outcome = run(stdlib.path(), &["readOnly", FIXTURE_MARKER]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
    assert_eq!(
        fs::read_to_string(&module).ok().as_deref(),
        Some(FIXTURE_ROOT_MODULE),
        "the run should not have modified {}",
        module.display()
    );
}

/// A module tree holding a single marked root module.
fn standard_library_tree() -> TempDir {
    let directory = temporary_directory("lunette-standard-library-");
    let module = directory.path().join(ROOT);
    if let Err(error) = fs::create_dir(&module) {
        panic!("{} could not be created: {error}", module.display());
    }
    if let Err(error) = fs::write(module.join("init.luau"), FIXTURE_ROOT_MODULE) {
        panic!("the fixture's root module could not be written: {error}");
    }
    directory
}

/// The `lua/` directory of the working tree this test is built from.
fn repository_standard_library() -> PathBuf {
    // `crates/lunette` up two levels to the workspace root.
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    let lua = root.join("lua");
    assert!(
        lua.join(ROOT).join("init.luau").is_file(),
        "{} should hold the plugin facade",
        lua.display()
    );
    lua
}

fn temporary_directory(prefix: &str) -> TempDir {
    match TempDir::with_prefix(prefix) {
        Ok(directory) => directory,
        Err(error) => panic!("a temporary directory named {prefix}* could not be created: {error}"),
    }
}

/// The status and error output of one run of the binary.
struct Outcome {
    status: Option<i32>,
    /// Quoted on failure. A Lua error, a failed mount, and boot.lua's own
    /// complaints all say what went wrong. The message appears in stderr and
    /// nowhere else.
    stderr: String,
}

/// Runs the binary against the mount fixture. `arguments` reach the
/// configuration as `arg[1..]`.
fn run(standard_library: &Path, arguments: &[&str]) -> Outcome {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("require-root");
    // The check runs first. A mislaid fixture then fails at the assert that
    // names it, and boot.lua's "no main.luau" path is not reached.
    assert!(
        directory.join("lunette").join("main.luau").is_file(),
        "the require-root fixture is missing its main.luau"
    );

    // `boot.lua` creates `$XDG_DATA_HOME/LOVR/<identity>` on every run and
    // fails the boot when it cannot, and the read-only check writes into that
    // directory on purpose. A temporary one per run gives each run its own
    // tree and removes the dependency on `HOME`, which is not set in the run.
    let data_directory = temporary_directory("lunette-standard-library-data-");

    let output = Command::new(env!("CARGO_BIN_EXE_lunette"))
        // The fixture directory holds a `lunette` subdirectory, and
        // `$XDG_CONFIG_HOME/lunette` resolves to it. `HOME` is removed to
        // keep the run from reaching the developer's own configuration when
        // the fixture is mislaid. The run would otherwise pass confusingly.
        // `LUNETTE_CONFIG_PATH` is removed for the same reason as `HOME`: a
        // developer's shell exports it to point a session at the working
        // copy, and a mislaid fixture would otherwise load the shipped
        // configuration and pass confusingly.
        .env_remove("LUNETTE_CONFIG_PATH")
        .env("XDG_CONFIG_HOME", &directory)
        .env("XDG_DATA_HOME", data_directory.path())
        .env("LUNETTE_STDLIB_PATH", standard_library)
        .env_remove("HOME")
        .args(arguments)
        .output();

    let output = match output {
        Ok(output) => output,
        Err(error) => panic!("the lunette binary could not be run: {error}"),
    };

    Outcome {
        status: output.status.code(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}
