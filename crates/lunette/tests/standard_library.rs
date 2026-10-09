//! Linux-only: a configuration cannot write over the mounted module roots.

use std::{fs, path::Path};

use tempfile::TempDir;

mod session;

/// The `fixture` field tells this tree apart from any other the session might resolve.
const FIXTURE_ROOT_MODULE: &str = "return { fixture = true }\n";

const FIXTURE_MARKER: &str = "fixture";

const ROOT: &str = "lunette-plugin";

const PASSED: i32 = 9;

/// The write goes to the save directory, which is mounted behind the module roots.
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

fn temporary_directory(prefix: &str) -> TempDir {
    match TempDir::with_prefix(prefix) {
        Ok(directory) => directory,
        Err(error) => panic!("a temporary directory named {prefix}* could not be created: {error}"),
    }
}

struct Outcome {
    status: Option<i32>,
    /// A Lua error and a failed mount appear in stderr and nowhere else.
    stderr: String,
}

/// `arguments` reach the configuration as `arg[1..]`.
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
