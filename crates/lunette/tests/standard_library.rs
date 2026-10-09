//! Linux-only: the file-backed module roots are mounted where `require`
//! resolves them, and a configuration cannot write over them.
//!
//! The cases use `@lunette-plugin`, the plugin facade's root; every mounted root is mounted
//! by the same code. The mount wraps the `package.preload` entry LÖVR creates
//! `lovr.filesystem` from, which exists only in a state the boot sequence builds, so the
//! test spawns the binary; `session` records the terms.

use std::{
    fs,
    path::{Path, PathBuf},
};

use tempfile::TempDir;

mod session;

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
    let (mut command, _data) = session::command("require-root");
    let output = command
        .env("LUNETTE_STDLIB_PATH", standard_library)
        .args(arguments)
        .output()
        .unwrap_or_else(|error| panic!("the lunette binary could not be run: {error}"));

    Outcome {
        status: output.status.code(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}
