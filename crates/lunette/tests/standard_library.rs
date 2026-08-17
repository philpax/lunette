//! Linux-only: the `mullion` standard library is mounted where it was asked
//! for, and a configuration cannot write over it.
//!
//! The mount is installed by wrapping the `package.preload` entry LÖVR creates
//! `lovr.filesystem` from, because `vendor/lovr/etc/boot.lua` creates that
//! module and runs `main.lua` on the same coroutine resume, leaving the host no
//! moment between the two. That wrapping is only observable on a state the real
//! boot sequence built: LÖVR's virtual filesystem does not exist on a state a
//! unit test creates, so there is nothing for a unit test to mount into.
//!
//! It spawns the real binary, for the same reason and under the same terms as
//! `exit_status.rs`, which carries the full note. The fixture switches off the
//! audio, graphics, and headset modules and opens no window, so no display, no
//! XR runtime, and no sound device are needed; nothing here sleeps or touches
//! the network, and every directory it writes is a temporary one it removes.

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

use tempfile::TempDir;

/// The root module of the standard library the tests write for themselves.
///
/// The `fixture` field is what the run checks, so a session that resolved some
/// other `mullion` — an installed one, a developer's own — fails rather than
/// passing on the wrong tree.
const FIXTURE_ROOT_MODULE: &str = "return { fixture = true }\n";

/// The field [`FIXTURE_ROOT_MODULE`] carries, named to the fixture so that it
/// checks contents rather than paths.
const FIXTURE_MARKER: &str = "fixture";

/// The status the fixture quits with when every assertion held.
const PASSED: i32 = 9;

#[test]
fn the_override_is_mounted_and_require_resolves_from_it() {
    let stdlib = standard_library_tree();

    let outcome = run(stdlib.path(), &["present", FIXTURE_MARKER]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
}

/// The repository's own `lua/` resolves, not only a tree the test wrote.
///
/// Without this the suite would pass on a standard library whose root module was
/// missing or unparseable, since every other case here supplies its own.
#[test]
fn the_repository_standard_library_resolves() {
    let stdlib = repository_standard_library();

    let outcome = run(&stdlib, &["present"]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
}

/// A standard library that is not installed is not a boot failure.
///
/// `docs/lua-api.md` makes a configuration that never mentions `mullion` a
/// supported configuration, so a missing mount has to leave the session running
/// and let `require` be the thing that reports it.
#[test]
fn a_missing_standard_library_does_not_stop_the_session() {
    let absent = temporary_directory("lunette-standard-library-absent-");

    let outcome = run(&absent.path().join("never-installed"), &["absent"]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
}

/// A configuration cannot overwrite the standard library it is running on top
/// of, which is a failure no reload could repair.
///
/// The fixture writes over the root module's own path through
/// `lovr.filesystem.write` and then requires it again. The write lands in the
/// save directory, which is mounted behind the standard library, so the module
/// it loads is unchanged — and the file on disk is untouched, which is what is
/// asserted here.
#[test]
fn a_configuration_cannot_write_over_the_standard_library() {
    let stdlib = standard_library_tree();
    let module = stdlib.path().join("mullion").join("init.lua");

    let outcome = run(stdlib.path(), &["readOnly", FIXTURE_MARKER]);

    assert_eq!(outcome.status, Some(PASSED), "{}", outcome.stderr);
    assert_eq!(
        fs::read_to_string(&module).ok().as_deref(),
        Some(FIXTURE_ROOT_MODULE),
        "the run should not have modified {}",
        module.display()
    );
}

/// A standard library tree holding nothing but a marked root module.
fn standard_library_tree() -> TempDir {
    let directory = temporary_directory("lunette-standard-library-");
    let module = directory.path().join("mullion");
    if let Err(error) = fs::create_dir(&module) {
        panic!("{} could not be created: {error}", module.display());
    }
    if let Err(error) = fs::write(module.join("init.lua"), FIXTURE_ROOT_MODULE) {
        panic!("the fixture's root module could not be written: {error}");
    }
    directory
}

/// The `lua/` directory of the working tree this test was built from.
fn repository_standard_library() -> PathBuf {
    // `crates/lunette` up two levels to the workspace root.
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    let lua = root.join("lua");
    assert!(
        lua.join("mullion").join("init.lua").is_file(),
        "{} should hold the standard library",
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

/// What one run of the binary reported.
struct Outcome {
    status: Option<i32>,
    /// Quoted on failure, because a Lua error, a failed mount, and boot.lua's
    /// own complaints all say what went wrong there and nowhere else.
    stderr: String,
}

/// Runs the binary against the mount fixture, with `arguments` reaching the
/// configuration as `arg[1..]`.
fn run(standard_library: &Path, arguments: &[&str]) -> Outcome {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("require-mullion");
    // Checked before the run, so that a mislaid fixture fails as itself rather
    // than as boot.lua's "no main.lua" path.
    assert!(
        directory.join("lunette").join("main.lua").is_file(),
        "the require-mullion fixture is missing its main.lua"
    );

    // `boot.lua` creates `$XDG_DATA_HOME/LOVR/<identity>` on every run and fails
    // the boot when it cannot, and the read-only check writes into that
    // directory on purpose. A temporary one per run gives each its own tree, and
    // also removes the dependency on `HOME`, which is unset below.
    let data_directory = temporary_directory("lunette-standard-library-data-");

    let output = Command::new(env!("CARGO_BIN_EXE_lunette"))
        // The fixture directory holds a `lunette` subdirectory, which is what
        // `$XDG_CONFIG_HOME/lunette` resolves to. `HOME` is removed so that the
        // developer's own configuration cannot be reached if the fixture is ever
        // mislaid, which would otherwise turn a missing fixture into a confusing
        // pass.
        // Removed for the reason `HOME` is: a developer's shell exports it to
        // point a session at the working copy, and a fixture that is mislaid
        // would otherwise load the shipped configuration and pass confusingly.
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
