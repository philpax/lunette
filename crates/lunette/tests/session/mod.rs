//! The environment a test gives the lunette binary it boots.
//!
//! Each run gets its own data directory, so parallel runs do not race to create LÖVR's save
//! directory. `HOME` and `LUNETTE_CONFIG_PATH` are removed, so a mislaid fixture fails rather
//! than loading another configuration.

// `expect` would fail in a binary that uses every item, so this is an `allow`.
#![allow(
    dead_code,
    reason = "each test binary compiles this module and uses a different part of it"
)]

use std::{
    fs,
    io::Read,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Output},
    thread,
    time::{Duration, Instant},
};

use tempfile::TempDir;

/// Covers LÖVR's whole boot on a cold cache. It applies only to a session that never answers.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

const SHUTDOWN_BOUND: Duration = Duration::from_secs(10);

const POLL: Duration = Duration::from_millis(20);

/// A command that boots the binary against `fixture` with the working tree's module roots,
/// and the data directory it writes into, which is removed when dropped.
pub fn command(fixture: &str) -> (Command, TempDir) {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(fixture);
    assert!(
        directory.join("lunette").join("conf.luau").is_file(),
        "the {fixture} fixture is missing its conf.luau"
    );
    let data = TempDir::with_prefix("lunette-session-")
        .unwrap_or_else(|error| panic!("a temporary data directory: {error}"));

    let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
    command
        .env_remove("HOME")
        .env_remove("LUNETTE_CONFIG_PATH")
        .env("XDG_CONFIG_HOME", directory)
        .env("XDG_DATA_HOME", data.path())
        .env("LUNETTE_STDLIB_PATH", standard_library());
    (command, data)
}

/// Boots the binary against `fixture` and asserts its exit status, quoting stdout and stderr
/// on failure.
pub fn assert_exit_status(fixture: &str, expected: i32) {
    let (mut command, data) = command(fixture);
    let output = command
        .output()
        .unwrap_or_else(|error| panic!("the lunette binary could not be run: {error}"));

    assert_eq!(
        output.status.code(),
        Some(expected),
        "the {fixture} fixture should have exited {expected}; stdout was:\n{}\nstderr was:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // A run that ignored `XDG_DATA_HOME` would write into the developer's own data
    // directory and still pass every assertion above.
    assert!(
        data.path().join("LOVR").is_dir(),
        "the {fixture} run should have written its save directory into {}",
        data.path().display()
    );
}

/// The `lua/` directory of the working tree this test is built from.
fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}

/// A session running against a fixture, with its control socket in a runtime directory of
/// its own. The session is killed when dropped.
pub struct Running {
    child: Child,
    runtime: TempDir,
    _data: TempDir,
}

impl Running {
    /// Starts the binary against `fixture`. `adjust` changes the command before it spawns,
    /// and receives the runtime directory.
    pub fn start(fixture: &str, adjust: impl FnOnce(&mut Command, &Path)) -> Self {
        let runtime = TempDir::with_prefix("lunette-session-run-")
            .unwrap_or_else(|error| panic!("a temporary runtime directory: {error}"));
        // lunette verifies the `0o700` mode the XDG specification requires.
        if let Err(error) = fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700)) {
            panic!("the runtime directory's mode could not be set: {error}");
        }

        let (mut command, data) = command(fixture);
        command.env("XDG_RUNTIME_DIR", runtime.path());
        adjust(&mut command, runtime.path());
        let child = command
            .spawn()
            .unwrap_or_else(|error| panic!("the lunette binary could not be run: {error}"));

        Self {
            child,
            runtime,
            _data: data,
        }
    }

    pub fn socket(&self) -> PathBuf {
        self.runtime.path().join("lunette").join("lunette-0.sock")
    }

    /// The socket binds before the Lua state boots and the frame loop answers chunks, so
    /// readiness is a chunk response rather than the socket's existence.
    pub fn wait_until_answering(&mut self) {
        let socket = self.socket();
        let deadline = Instant::now() + STARTUP_BOUND;

        while Instant::now() < deadline {
            if socket.exists() {
                let ready = self.lunctl(&["return 'ready'"]);
                if ready.status.code() == Some(0) && stdout(&ready) == "ready" {
                    return;
                }
            }
            if let Some(status) = self.try_wait() {
                panic!(
                    "the session exited {status} before it answered a chunk; stderr was:\n{}",
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

    pub fn lunctl(&self, arguments: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_lunctl"))
            .arg("--socket")
            .arg(self.socket())
            .args(arguments)
            .output()
            .unwrap_or_else(|error| panic!("the lunctl binary could not be run: {error}"))
    }

    /// Ends the session with a chunk, asserts that it exits `expected`, and returns its
    /// stderr, which is empty unless the caller piped it.
    pub fn stop(&mut self, expected: i32) -> String {
        let stopping = self.lunctl(&[&format!("lovr.event.quit({expected})")]);
        assert_eq!(
            code(&stopping),
            0,
            "the session should evaluate the chunk that stops it; stderr was:\n{}",
            stderr(&stopping)
        );

        let deadline = Instant::now() + SHUTDOWN_BOUND;
        loop {
            if let Some(status) = self.try_wait() {
                let stderr = self.read_stderr();
                assert_eq!(
                    status.code(),
                    Some(expected),
                    "the session should exit with the status the chunk asked for; stderr \
                     was:\n{stderr}"
                );
                return stderr;
            }
            assert!(
                Instant::now() < deadline,
                "the session did not stop after a chunk asked it to"
            );
            thread::sleep(POLL);
        }
    }

    fn try_wait(&mut self) -> Option<ExitStatus> {
        self.child
            .try_wait()
            .unwrap_or_else(|error| panic!("the child's status could not be read: {error}"))
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

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned()
}

pub fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

pub fn code(output: &Output) -> i32 {
    output
        .status
        .code()
        .unwrap_or_else(|| panic!("lunctl was signalled rather than exiting"))
}
