//! Tests safe mode through sessions whose configuration fails to load.
//!
//! These tests launch the binary because `boot.lua` and the host establish the fallback
//! configuration, which `lunctl` then addresses. Unit tests in `safe_mode.rs` cover the
//! chunk and trigger with fakes.
//!
//! Each run points the module roots at a missing directory, because safe mode must not
//! depend on them, and uses its own `XDG_RUNTIME_DIR`. A chunk response confirms that the
//! session is ready, and `lovr.event.quit` tests orderly session shutdown.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    fs,
    io::Read,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Output, Stdio},
    thread,
    time::{Duration, Instant},
};

use pretty_assertions::assert_eq;
use tempfile::TempDir;

mod session;

/// Caps readiness polling when a session does not answer.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

const SHUTDOWN_BOUND: Duration = Duration::from_secs(10);

const POLL: Duration = Duration::from_millis(20);

/// The session exits with the status a chunk requests. The status is distinct
/// from LÖVR's own 1 and from any signal.
const STOPPED: i32 = 7;

/// A `main.luau` that does not compile produces safe mode: a running session
/// with a panel and a reload key, and no module root loaded. The alternative is a
/// black headset.
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
    assert_eq!(
        stdout(&session.lunctl(&["return package.loaded['@lunette-plugin'] == nil"])),
        "true",
        "no module root should have been loaded",
    );

    let outcome = session.stop();
    assert!(
        outcome.stderr.contains("safe mode is running"),
        "the session should say it is in safe mode:\n{}",
        outcome.stderr
    );
    assert!(
        outcome.stderr.contains("main.luau"),
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
        let runtime = TempDir::with_prefix("lunette-safe-mode-run-")
            .expect("a runtime directory can be created");
        // The XDG specification requires mode `0o700` on `$XDG_RUNTIME_DIR`,
        // and lunette verifies the mode.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");

        let (mut command, data) = session::command(fixture);
        let child = command
            .env("XDG_RUNTIME_DIR", runtime.path())
            .env(
                "LUNETTE_STDLIB_PATH",
                runtime.path().join("there-is-no-standard-library-here"),
            )
            // Stderr is read after the session stops, so the load error and the
            // safe-mode line are assertable.
            .stderr(Stdio::piped())
            .spawn()
            .expect("the lunette binary can be run");

        Self {
            child,
            runtime,
            _data: data,
        }
    }

    fn socket(&self) -> PathBuf {
        self.runtime.path().join("lunette").join("lunette-0.sock")
    }

    /// Waits for a Lua response to confirm session readiness.
    ///
    /// The control socket binds before the Lua state boots. A successful chunk response
    /// confirms that the frame loop is running; after a failed configuration load, that
    /// loop belongs to safe mode.
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

    /// Stops the session through a chunk and returns its stderr.
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
