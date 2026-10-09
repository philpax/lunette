//! Safe mode in sessions whose configuration fails to load, driven through `lunctl`.
//!
//! Each run points the module roots at a missing directory, because safe mode must not
//! depend on them.

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

const STARTUP_BOUND: Duration = Duration::from_secs(30);

const SHUTDOWN_BOUND: Duration = Duration::from_secs(10);

const POLL: Duration = Duration::from_millis(20);

/// Distinct from LÖVR's own 1 and from any signal.
const STOPPED: i32 = 7;

/// Without safe mode, a configuration that does not compile leaves a black headset.
#[test]
fn a_main_lua_that_does_not_compile_produces_a_running_safe_mode() {
    let mut session = Session::start("safe-mode");
    session.wait_until_answering();

    let callbacks = session.lunctl(&[
        "return type(lovr.draw) .. ' ' .. type(lovr.update) .. ' ' .. type(lovr.keypressed)",
    ]);
    assert_eq!(code(&callbacks), 0, "stderr was:\n{}", stderr(&callbacks));
    assert_eq!(stdout(&callbacks), "function function function");

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

/// `boot.lua` raises before it reaches a chunk, which is a separate path to safe mode.
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

struct Session {
    child: Child,
    runtime: TempDir,
    _data: TempDir,
}

impl Session {
    fn start(fixture: &str) -> Self {
        let runtime = TempDir::with_prefix("lunette-safe-mode-run-")
            .expect("a runtime directory can be created");
        // lunette verifies the `0o700` mode the XDG specification requires.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");

        let (mut command, data) = session::command(fixture);
        let child = command
            .env("XDG_RUNTIME_DIR", runtime.path())
            .env(
                "LUNETTE_STDLIB_PATH",
                runtime.path().join("there-is-no-standard-library-here"),
            )
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

    /// The control socket binds before the Lua state boots, so readiness is a chunk
    /// response rather than the socket's existence.
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

    fn read_stderr(&mut self) -> String {
        let Some(mut pipe) = self.child.stderr.take() else {
            return String::new();
        };
        let mut written = String::new();
        // A read blocks while the writer runs, so each caller has established that the
        // child exited or is about to be killed.
        let _ = pipe.read_to_string(&mut written);
        written
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

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
