//! Safe mode, established by actually breaking a configuration.
//!
//! `lunette-v1.AC8.4` is about what a user gets when their `main.lua` does not
//! load, and the only way to establish it is to hand the real binary a
//! `main.lua` that does not load. The unit cases in
//! `crates/lunette/src/safe_mode.rs` drive the chunk and the trigger against
//! fakes; these drive a whole session, so the load failure is one `boot.lua`
//! produced, the fallback is the one the host armed, and the session that comes
//! out of it is one `lunctl` can talk to.
//!
//! The fixtures switch the audio, graphics, and headset modules off and open no
//! window, so no display, no XR runtime, and no sound device is needed. Each run
//! gets its own `XDG_RUNTIME_DIR` for the control socket and its own
//! `XDG_DATA_HOME`.
//!
//! Nothing here waits for a duration. A chunk's answer is what says the session
//! is up and that safe mode is running, and the session is stopped by a chunk
//! rather than by a signal.

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

/// How long a session gets to start answering before the test gives up.
///
/// A bound on a failure rather than a wait for a success: the poll returns as
/// soon as the session answers.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

/// How long the session gets to stop once a chunk has told it to.
const SHUTDOWN_BOUND: Duration = Duration::from_secs(10);

/// How often a condition is looked at. Short enough not to pad a run.
const POLL: Duration = Duration::from_millis(20);

/// The status a chunk asks the session to exit with, chosen so that it cannot
/// be confused with LÖVR's own 1 or with a signal.
const STOPPED: i32 = 7;

/// `lunette-v1.AC8.4`: a `main.lua` that does not compile produces safe mode,
/// which is a running session with a panel and a reload key rather than a black
/// headset.
#[test]
fn a_main_lua_that_does_not_compile_produces_a_running_safe_mode() {
    let mut session = Session::start("safe-mode");
    session.wait_until_answering();

    // Safe mode's callbacks, which are what a frame calls. `lovr.draw` is the
    // panel and `lovr.keypressed` is the reload key.
    let callbacks = session.lunctl(&[
        "return type(lovr.draw) .. ' ' .. type(lovr.update) .. ' ' .. type(lovr.keypressed)",
    ]);
    assert_eq!(code(&callbacks), 0, "stderr was:\n{}", stderr(&callbacks));
    assert_eq!(stdout(&callbacks), "function function function");

    // The failed configuration's own callback is gone rather than being called
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

/// The other way a configuration fails to load: there is none. `boot.lua`
/// raises before it ever reaches a chunk, which is a different code path
/// producing the same outcome.
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
/// library is one of the reasons `main.lua` may have failed. This points the
/// mount at a directory that does not exist, which is that failure.
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

    let mounted = session.lunctl(&["return package.loaded.mullion == nil"]);
    assert_eq!(code(&mounted), 0, "stderr was:\n{}", stderr(&mounted));
    assert_eq!(
        stdout(&mounted),
        "true",
        "no standard library should have been loaded",
    );

    let drawn = session.lunctl(&["return type(lovr.draw)"]);
    assert_eq!(code(&drawn), 0, "stderr was:\n{}", stderr(&drawn));
    assert_eq!(stdout(&drawn), "function");

    session.stop();
}

/// A running lunette, stopped when the test lets go of it.
struct Session {
    child: Child,
    runtime: TempDir,
    /// Kept for its `Drop`, which removes the directory the session writes into.
    _data: TempDir,
}

impl Session {
    fn start(fixture: &str) -> Self {
        Self::start_with(fixture, &[])
    }

    fn start_with(fixture: &str, environment: &[(&str, &str)]) -> Self {
        let runtime = TempDir::with_prefix("lunette-safe-mode-run-")
            .expect("a runtime directory can be created");
        // What the XDG specification requires of `$XDG_RUNTIME_DIR`, and what
        // lunette checks for rather than trusting.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        let data = TempDir::with_prefix("lunette-safe-mode-data-")
            .expect("a data directory can be created");

        let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
        command
            .env("XDG_CONFIG_HOME", fixture_directory(fixture))
            .env("XDG_DATA_HOME", data.path())
            .env("XDG_RUNTIME_DIR", runtime.path())
            // Removed so that the developer's own configuration cannot be
            // reached if the fixture is ever mislaid, which would turn a missing
            // fixture into a confusing pass.
            .env_remove("HOME")
            .env("LUNETTE_STDLIB_PATH", standard_library())
            // Read after the session stops, which is what makes the load error
            // and the safe-mode line assertable.
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

    /// Waits for the session to answer a chunk, rather than for a duration.
    ///
    /// The socket appearing is not that condition. It is bound before the Lua
    /// state boots, so that a failure to bind is reported among the other
    /// startup failures (`crates/lunette/src/main.rs:188`) — which is before
    /// `main.lua` is loaded, before it fails, and before safe mode replaces it.
    /// A test that started asking then would be racing the boot it is meant to
    /// be asserting the outcome of.
    ///
    /// Answering is the condition, and it implies the rest: chunks are serviced
    /// by the frame loop, and the only frame loop running after a failed load
    /// is safe mode's.
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

    /// Asks the session to quit through a chunk, waits for it, and answers what
    /// it wrote.
    ///
    /// Through a chunk rather than a signal because safe mode is meant to be a
    /// usable session, and a session that can be told to quit is the proof.
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

    /// Everything the session has written to stderr so far.
    fn read_stderr(&mut self) -> String {
        let Some(mut pipe) = self.child.stderr.take() else {
            return String::new();
        };
        let mut written = String::new();
        // A read on a pipe whose writer has gone ends; one whose writer is still
        // running would not, which is why every caller has already established
        // that the child has exited or is about to be killed.
        let _ = pipe.read_to_string(&mut written);
        written
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // A long-lived resource, so it is cleaned up whatever the test did.
        // `kill` on a child that has already exited is a no-op that reports.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// What a stopped session left behind.
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

/// The `lua/` directory of the working tree this test was built from.
fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}
