//! Linux-only: the process exit status a Lua session requests, and the one-shot sessions that
//! report their checks through it.
//!
//! `boot.lua` returns the status followed by a cookie, so reading the top of the stack would
//! hide nonzero statuses.

use std::fs;

use tempfile::TempDir;

use crate::session::assert_exit_status;

mod session;

#[test]
fn a_quit_status_reaches_the_process_exit_status() {
    assert_exit_status("quit-with-status", 3);
}

#[test]
fn a_quit_without_a_status_exits_zero() {
    assert_exit_status("quit-without-status", 0);
}

/// `luau_check.rs` checks the same fixture in the checker.
#[test]
fn a_relative_require_resolves_against_the_requiring_file() {
    assert_exit_status("require-relative", 9);
}

/// Ten reloads expose state that accumulates across runs, which one reload cannot show. The
/// fixture quits with a distinct status for each check that fails.
#[test]
fn ten_reloads_leave_the_session_where_one_does() {
    assert_exit_status("reload", 9);
}

/// Both execution modes boot, and a hot function computes the same result after promotion as before it.
#[test]
fn tiered_execution_promotes_without_changing_results() {
    for execution in ["interpreter", "tiered"] {
        let (mut command, _data) = session::command("tiered");
        let output = command
            .args(["--luau-execution", execution])
            .output()
            .unwrap_or_else(|error| panic!("the lunette binary could not be run: {error}"));
        assert_eq!(
            output.status.code(),
            Some(7),
            "{execution}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

/// The write goes to the save directory, which is mounted behind the module roots. The
/// `fixture` field tells the temporary tree apart from any other the session might resolve,
/// and the marker reaches the configuration as `arg[1]`.
#[test]
fn a_configuration_cannot_write_over_the_standard_library() {
    const ROOT_MODULE: &str = "return { fixture = true }\n";

    let standard_library = TempDir::with_prefix("lunette-standard-library-")
        .unwrap_or_else(|error| panic!("a temporary standard library: {error}"));
    let root = standard_library.path().join("lunette-plugin");
    let module = root.join("init.luau");
    if let Err(error) = fs::create_dir(&root).and_then(|()| fs::write(&module, ROOT_MODULE)) {
        panic!("the fixture's root module could not be written: {error}");
    }

    let (mut command, _data) = session::command("require-root");
    let output = command
        .env("LUNETTE_STDLIB_PATH", standard_library.path())
        .arg("fixture")
        .output()
        .unwrap_or_else(|error| panic!("the lunette binary could not be run: {error}"));

    // A Lua error and a failed mount appear in stderr and nowhere else.
    assert_eq!(
        output.status.code(),
        Some(9),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&module).ok().as_deref(),
        Some(ROOT_MODULE),
        "the run should not have modified {}",
        module.display()
    );
}
