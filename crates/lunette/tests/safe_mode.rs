//! Safe mode is established by breaking a real configuration.
//!
//! Safe mode is what a user gets when their `main.lua` does not load. To
//! establish it, the tests must hand the real binary a `main.lua` that does not
//! load. The unit cases in `crates/lunette/src/safe_mode.rs` run the chunk and
//! the trigger against fakes. These tests run a whole session: `boot.lua`
//! produces the load failure, the host prepares the fallback, and `lunctl` can
//! communicate with the resulting session.
//!
//! The fixtures switch the audio, graphics, and headset modules off and open no
//! window, so no display, no XR runtime, and no sound device is needed. Each run
//! gets its own `XDG_RUNTIME_DIR` for the control socket and its own
//! `XDG_DATA_HOME`.
//!
//! No test waits for a duration. A chunk's answer reports that the session
//! is up and that safe mode is running, and a chunk stops the session, not a
//! signal.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    fs,
    io::Read,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    thread,
    time::{Duration, Instant},
};

use pretty_assertions::assert_eq;
use tempfile::TempDir;

/// A session has this long to start answering before the test gives up.
///
/// The bound limits a failure, not a wait for success. The poll returns as soon
/// as the session answers.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

/// The session has this long to stop after a chunk calls `lovr.event.quit`.
const SHUTDOWN_BOUND: Duration = Duration::from_secs(10);

/// The interval at which a condition is checked. The interval is short enough
/// not to pad a run.
const POLL: Duration = Duration::from_millis(20);

/// The session exits with the status a chunk requests. The status is distinct
/// from LÖVR's own 1 and from any signal.
const STOPPED: i32 = 7;

/// A `main.lua` that does not compile produces safe mode: a running session
/// with a panel and a reload key. The alternative is a black headset.
#[test]
fn a_main_lua_that_does_not_compile_produces_a_running_safe_mode() {
    let mut session = Session::start("safe-mode");
    session.wait_until_answering();

    // A frame calls safe mode's callbacks. `lovr.draw` renders the panel and
    // `lovr.keypressed` handles the reload key.
    let callbacks = session.lunctl(&[
        "return type(lovr.draw) .. ' ' .. type(lovr.update) .. ' ' .. type(lovr.keypressed)",
    ]);
    assert_eq!(code(&callbacks), 0, "stderr was:\n{}", stderr(&callbacks));
    assert_eq!(stdout(&callbacks), "function function function");

    // The failed configuration's own callback is gone and is not called
    // alongside safe mode's.
    assert_eq!(
        stdout(&session.lunctl(&["return running == nil"])),
        "true",
        "the broken configuration should not still be running its callbacks",
    );

    let outcome = session.stop();
    assert!(
        outcome.stderr.contains("safe mode is running"),
        "the session should say it is in safe mode:\n{}",
        outcome.stderr
    );
    assert!(
        outcome.stderr.contains("main.lua"),
        "the load error should name the file that did not load:\n{}",
        outcome.stderr
    );
}

/// There is no other way a configuration fails to load. `boot.lua` raises
/// before it reaches a chunk, which is a different code path producing
/// the same outcome.
#[test]
fn a_missing_main_lua_produces_safe_mode_too() {
    let mut session = Session::start("safe-mode-no-main");
    session.wait_until_answering();

    let drawn = session.lunctl(&["return type(lovr.draw)"]);
    assert_eq!(code(&drawn), 0, "stderr was:\n{}", stderr(&drawn));
    assert_eq!(stdout(&drawn), "function");

    let outcome = session.stop();
    assert!(
        outcome.stderr.contains("safe mode is running"),
        "{}",
        outcome.stderr
    );
}

/// Safe mode requires `lunette` and nothing else, because a broken standard
/// library is one of the reasons `main.lua` may have failed. The test points
/// the mount at a directory that does not exist, which is that failure.
#[test]
fn safe_mode_runs_with_no_standard_library_mounted() {
    let missing = TempDir::with_prefix("lunette-safe-mode-absent-")
        .expect("a temporary directory can be created");
    let absent = missing.path().join("there-is-no-standard-library-here");

    let mut session = Session::start_with(
        "safe-mode",
        &[("LUNETTE_STDLIB_PATH", &absent.to_string_lossy())],
    );
    session.wait_until_answering();

    let mounted = session.lunctl(&["return package.loaded['@lunette-plugin'] == nil"]);
    assert_eq!(code(&mounted), 0, "stderr was:\n{}", stderr(&mounted));
    assert_eq!(
        stdout(&mounted),
        "true",
        "no module root should have been loaded",
    );

    let drawn = session.lunctl(&["return type(lovr.draw)"]);
    assert_eq!(code(&drawn), 0, "stderr was:\n{}", stderr(&drawn));
    assert_eq!(stdout(&drawn), "function");

    session.stop();
}

/// A running lunette, which the test stops when the handle is dropped.
struct Session {
    child: Child,
    runtime: TempDir,
    /// The field is held for its `Drop`, which removes the directory the
    /// session writes into.
    _data: TempDir,
}

impl Session {
    fn start(fixture: &str) -> Self {
        Self::start_with(fixture, &[])
    }

    fn start_with(fixture: &str, environment: &[(&str, &str)]) -> Self {
        let runtime = TempDir::with_prefix("lunette-safe-mode-run-")
            .expect("a runtime directory can be created");
        // The XDG specification requires mode `0o700` on `$XDG_RUNTIME_DIR`,
        // and lunette verifies the mode.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        let data = TempDir::with_prefix("lunette-safe-mode-data-")
            .expect("a data directory can be created");

        let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
        command
            // `LUNETTE_CONFIG_PATH` is removed for the same reason `HOME` is:
            // a developer's shell exports either variable to point the session
            // at a working copy, and a mislaid fixture would then load the
            // shipped configuration and pass for the wrong reason.
            .env_remove("LUNETTE_CONFIG_PATH")
            .env("XDG_CONFIG_HOME", fixture_directory(fixture))
            .env("XDG_DATA_HOME", data.path())
            .env("XDG_RUNTIME_DIR", runtime.path())
            // `HOME` is removed so the developer's own configuration cannot be
            // reached if the fixture is ever mislaid. A mislaid fixture then
            // fails; it cannot pass by loading a real configuration.
            .env_remove("HOME")
            .env("LUNETTE_STDLIB_PATH", standard_library())
            // Stderr is piped and read after the session stops; the load error
            // and the safe-mode line are then assertable.
            .stderr(Stdio::piped());
        for (name, value) in environment {
            command.env(name, value);
        }

        let child = command.spawn().expect("the lunette binary can be run");

        Self {
            child,
            runtime,
            _data: data,
        }
    }

    fn socket(&self) -> PathBuf {
        self.runtime.path().join("lunette").join("lunette-0.sock")
    }

    /// Waits for the session to answer a chunk, not for a duration.
    ///
    /// The socket appearing is not that condition. The socket is bound before
    /// the Lua state boots, so a failure to bind is reported among the other
    /// startup failures (see `crates/lunette/src/main.rs`), which is before
    /// `main.lua` loads and fails and before safe mode replaces it. A test that
    /// started asking then would race the boot whose outcome it asserts.
    ///
    /// Answering is the condition and implies the rest: the frame loop services
    /// chunks, and after a failed load the only frame loop running is safe
    /// mode's.
    fn wait_until_answering(&mut self) -> PathBuf {
        let socket = self.socket();
        let deadline = Instant::now() + STARTUP_BOUND;

        while Instant::now() < deadline {
            if socket.exists() {
                let ready = self.lunctl(&["return 'ready'"]);
                if ready.status.code() == Some(0) && stdout(&ready) == "ready" {
                    return socket;
                }
            }
            if let Some(status) = self
                .child
                .try_wait()
                .expect("the child's status can be read")
            {
                panic!(
                    "the session exited {status} before it answered a chunk, so it fell out of \
                     safe mode rather than into it; stderr was:\n{}",
                    self.read_stderr()
                );
            }
            thread::sleep(POLL);
        }

        panic!(
            "the session at {} did not answer a chunk within {STARTUP_BOUND:?}",
            socket.display()
        );
    }

    fn lunctl(&self, arguments: &[&str]) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_lunctl"));
        command.arg("--socket").arg(self.socket());
        command.args(arguments);
        command.output().expect("the lunctl binary can be run")
    }

    /// Asks the session to quit through a chunk, waits for it, and reports what
    /// it wrote.
    ///
    /// A chunk stops the session, not a signal, because safe mode is a usable
    /// session; a session that a chunk can stop is the proof.
    fn stop(&mut self) -> Stopped {
        let stopping = self.lunctl(&[&format!("lovr.event.quit({STOPPED})")]);
        assert_eq!(
            code(&stopping),
            0,
            "safe mode should evaluate a chunk like any session; stderr was:\n{}",
            stderr(&stopping)
        );

        let deadline = Instant::now() + SHUTDOWN_BOUND;
        loop {
            if let Some(status) = self
                .child
                .try_wait()
                .expect("the child's status can be read")
            {
                let stderr = self.read_stderr();
                assert_eq!(
                    status.code(),
                    Some(STOPPED),
                    "safe mode should exit with the status the chunk asked for; stderr was:\n\
                     {stderr}"
                );
                return Stopped { stderr };
            }
            assert!(
                Instant::now() < deadline,
                "the session did not stop after a chunk asked it to"
            );
            thread::sleep(POLL);
        }
    }

    /// Returns everything the session has written to stderr so far.
    fn read_stderr(&mut self) -> String {
        let Some(mut pipe) = self.child.stderr.take() else {
            return String::new();
        };
        let mut written = String::new();
        // A read on a pipe whose writer has exited ends; one whose writer is
        // still running would block. Each caller has established that the
        // child exited or is about to be killed.
        let _ = pipe.read_to_string(&mut written);
        written
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // The child is a long-lived resource, cleaned up whatever the test
        // did. `kill` on a child that has already exited is a no-op; the
        // result is discarded with `let _`.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A stopped session leaves its stderr in the `Stopped` value.
struct Stopped {
    stderr: String,
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn code(output: &Output) -> i32 {
    output
        .status
        .code()
        .expect("lunctl exits rather than being signalled")
}

fn fixture_directory(fixture: &str) -> PathBuf {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(fixture);
    assert!(
        directory.join("lunette").join("conf.lua").is_file(),
        "the {fixture} fixture is missing its conf.lua"
    );
    directory
}

/// Returns the `lua/` directory of the working tree that built the test.
fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}
