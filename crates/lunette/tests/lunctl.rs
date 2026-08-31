//! `lunctl` against a real running lunette, over a real socket.
//!
//! Two acceptance requirements need two processes. No unit test on a Lua
//! state a test built can establish them. These tests drive the shipped
//! binary: the session is the process the binary started, the module is the
//! one the host registered, the socket is one lunette bound, and `lunctl` is
//! the binary a user would run.
//!
//! The fixture switches the audio, graphics, and headset modules off and opens
//! no window. No display, no XR runtime, and no sound device is needed. Each
//! run gets its own `XDG_RUNTIME_DIR`, where the control socket goes, and its
//! own `XDG_DATA_HOME`.
//!
//! Binding a real socket is the narrow exception `CONTRIBUTING.md` records for
//! the compositor's listener, and it applies here for the same reason: the
//! listener, its mode, and the path it selects are part of what is under test.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    fs,
    os::unix::fs::{FileTypeExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Child, Command, Output},
    thread,
    time::{Duration, Instant},
};

use pretty_assertions::assert_eq;
use tempfile::TempDir;

/// A session gets this long to start answering before the test stops.
///
/// The bound covers the whole of LÖVR's boot on a cold cache. The poll in
/// `wait_until_answering` returns as soon as the session answers, so the
/// bound applies to a session that never answers.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

/// A running lunette; the test stops it when it releases it.
struct Session {
    child: Child,
    runtime: TempDir,
    /// Kept for its `Drop`, which removes the directory the session writes into.
    _data: TempDir,
}

impl Session {
    /// Starts a session against the `lunctl` fixture.
    fn start() -> Self {
        Self::start_with(&[])
    }

    fn start_with(environment: &[(&str, &str)]) -> Self {
        let runtime = TempDir::with_prefix("lunette-lunctl-run-")
            .expect("a runtime directory can be created");
        // The XDG specification requires `$XDG_RUNTIME_DIR` to be private to
        // the user, and lunette requires the directory's mode to be 0700.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        let data =
            TempDir::with_prefix("lunette-lunctl-data-").expect("a data directory can be created");

        let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
        command
            // Removed for the same reason as `HOME`. A developer's shell
            // exports it to point a session at the working copy, and a mislaid
            // fixture would otherwise load the shipped configuration and pass
            // confusingly.
            .env_remove("LUNETTE_CONFIG_PATH")
            .env("XDG_CONFIG_HOME", fixture_directory())
            .env("XDG_DATA_HOME", data.path())
            .env("XDG_RUNTIME_DIR", runtime.path())
            // Removed so the session cannot reach the developer's own
            // configuration when the fixture is mislaid; a missing fixture
            // would otherwise become a confusing pass.
            .env_remove("HOME")
            .env("LUNETTE_STDLIB_PATH", standard_library());
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

    /// Returns the session's control socket path.
    fn socket(&self) -> PathBuf {
        self.runtime.path().join("lunette").join("lunette-0.sock")
    }

    /// Waits until the session answers a chunk.
    ///
    /// The socket appearing is not that condition. The socket is bound before
    /// the Lua state boots, so a failure to bind is reported among the other
    /// startup failures (`crates/lunette/src/main.rs`). A chunk sent in that
    /// window is not answered yet: chunks are answered by the frame loop.
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
                panic!("the session exited {status} before it answered a chunk");
            }
            thread::sleep(POLL);
        }

        panic!(
            "the session at {} did not answer a chunk within {STARTUP_BOUND:?}",
            socket.display()
        );
    }

    /// Runs `lunctl` against this session's socket.
    fn lunctl(&self, arguments: &[&str]) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_lunctl"));
        command.arg("--socket").arg(self.socket());
        command.args(arguments);
        command.output().expect("the lunctl binary can be run")
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // The child is a long-lived resource, so it is cleaned up whatever the
        // test did.
        // `kill` on a child that has already exited is a no-op that reports.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// How often the test polls the session. The interval is short enough that
/// startup is not padded.
const POLL: Duration = Duration::from_millis(20);

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned()
}

fn code(output: &Output) -> i32 {
    output
        .status
        .code()
        .expect("lunctl exits rather than being signalled")
}

/// The whole two-process acceptance case is exercised end to end: a chunk
/// evaluated between frames returns its nested tables.
#[test]
fn a_chunk_is_evaluated_between_frames_and_its_nested_table_comes_back() {
    let mut session = Session::start();
    session.wait_until_answering();

    let scalar = session.lunctl(&["return answer"]);
    assert_eq!(code(&scalar), 0, "stderr was:\n{}", stderr(&scalar));
    assert_eq!(stdout(&scalar), "42");

    // A top-level string prints bare, so a shell can capture the value
    // directly.
    let text = session.lunctl(&["return title"]);
    assert_eq!(stdout(&text), "a terminal");

    let table = session.lunctl(&["return nested"]);
    assert_eq!(code(&table), 0, "stderr was:\n{}", stderr(&table));
    let printed = stdout(&table);
    assert!(printed.contains("count = 2"), "{printed}");
    assert!(printed.contains("names = {"), "{printed}");
    assert!(printed.contains("'a',"), "{printed}");
    assert!(printed.contains("'b',"), "{printed}");
}

/// A handle comes back as an opaque id, and the id can be passed back in.
#[test]
fn a_handle_comes_back_as_an_opaque_id() {
    let mut session = Session::start();
    session.wait_until_answering();

    let spawned = session.lunctl(&["return lunette.spawn{ argv = { 'true' } }"]);
    assert_eq!(code(&spawned), 0, "stderr was:\n{}", stderr(&spawned));
    assert_eq!(
        stdout(&spawned),
        "<process 1>",
        "a handle is its kind and its id, and nothing a client could dereference",
    );

    // `lunette` is a global because the fixture sets it as one. A chunk
    // evaluates in the main state and cannot reach the fixture's locals.
    let windows = session.lunctl(&["return #lunette.windows()"]);
    assert_eq!(stdout(&windows), "0");
}

/// A shell script branches on three outcomes; each keeps its own status.
#[test]
fn each_failure_has_its_own_exit_status() {
    let mut session = Session::start();
    session.wait_until_answering();

    assert_eq!(
        code(&session.lunctl(&["error('deliberate')"])),
        1,
        "a chunk that raised",
    );
    assert_eq!(
        code(&session.lunctl(&["this is not lua {{{"])),
        2,
        "a chunk that did not compile",
    );
    assert_eq!(
        code(&session.lunctl(&["return function() end"])),
        4,
        "a chunk returning something the protocol cannot carry",
    );
}

/// A chunk's answer can exceed what one message carries. The session is
/// healthy and the chunk succeeded. The oversized answer keeps status 4, the
/// unrepresentable outcome. Closing the connection would report an absent
/// session, status 6, and misstate both.
#[test]
fn an_answer_larger_than_a_message_is_named_rather_than_read_as_an_absent_session() {
    let mut session = Session::start();
    session.wait_until_answering();

    let oversized = session.lunctl(&["return string.rep('x', 9 * 1024 * 1024)"]);

    assert_eq!(
        code(&oversized),
        4,
        "the answer does not fit, which is the protocol failing to carry it; stderr was:\n{}",
        stderr(&oversized),
    );
    assert!(
        stderr(&oversized).contains("one message carries at most"),
        "the client is told what actually happened: {}",
        stderr(&oversized),
    );
    // The session is still there. The status above reports the answer; it
    // does not report the session.
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}

/// The first acceptance clause is exercised end to end: the session keeps
/// running.
#[test]
fn a_chunk_that_overruns_is_abandoned_and_the_session_carries_on() {
    let mut session = Session::start();
    session.wait_until_answering();

    let abandoned = session.lunctl(&["while true do end"]);

    assert_eq!(code(&abandoned), 3, "stderr was:\n{}", stderr(&abandoned));
    // The abandoned chunk does not stall the frame loop; the next chunk is
    // answered as normal.
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}

/// The second acceptance clause is measured on the socket a real session
/// bound.
#[test]
fn the_socket_is_0600_inside_a_0700_directory_and_is_not_a_network_address() {
    let mut session = Session::start();
    let socket = session.wait_until_answering();

    let directory = socket.parent().expect("the socket is inside a directory");
    assert_eq!(mode_of(directory), 0o700, "{}", directory.display());
    assert_eq!(mode_of(&socket), 0o600, "{}", socket.display());
    assert!(
        fs::metadata(&socket)
            .expect("the socket exists")
            .file_type()
            .is_socket(),
        "the path is a unix socket, which is the only thing lunette can listen on",
    );
}

/// `docs/dev/lua-api.md` requires the switch; a user who wants no evaluation
/// endpoint gets none.
#[test]
fn the_disable_switch_leaves_no_socket_to_connect_to() {
    no_socket_is_bound_with("off");
}

/// The switch accepts `on` and `off`; any other value disables the endpoint.
/// Unset already means open, so a user who sets the variable wants it closed.
/// An unrecognised value keeps the endpoint closed; an open endpoint is the
/// failure the switch prevents.
#[test]
fn a_spelling_of_off_the_switch_does_not_know_still_leaves_no_socket() {
    no_socket_is_bound_with("false");
}

fn no_socket_is_bound_with(setting: &str) {
    let mut session = Session::start_with(&[("LUNETTE_CONTROL", setting)]);

    // There is no socket to wait for, so the session runs until the fixture's
    // own bound stops it. The loop asserts that no socket appears in the
    // meantime.
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        assert!(
            !session.socket().exists(),
            "a session started with LUNETTE_CONTROL={setting} bound a control socket anyway",
        );
        if session
            .child
            .try_wait()
            .expect("the child's status can be read")
            .is_some()
        {
            break;
        }
        thread::sleep(POLL);
    }

    let failed = session.lunctl(&["return answer"]);
    assert_eq!(
        code(&failed),
        6,
        "there is no session to reach, and that is its own status",
    );
}

/// A chunk can end the session. The end-to-end shell tests use it to tear a
/// session down.
#[test]
fn a_chunk_can_stop_the_session() {
    let mut session = Session::start();
    session.wait_until_answering();

    let stopping = session.lunctl(&["stop = true"]);
    assert_eq!(code(&stopping), 0, "stderr was:\n{}", stderr(&stopping));

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = session
            .child
            .try_wait()
            .expect("the child's status can be read")
        {
            assert_eq!(
                status.code(),
                Some(9),
                "the fixture quits 9 when a chunk asked it to",
            );
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the session did not stop after a chunk asked it to",
        );
        thread::sleep(POLL);
    }
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn mode_of(path: &Path) -> u32 {
    fs::metadata(path).expect("it exists").permissions().mode() & 0o7777
}

fn fixture_directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("lunctl")
}

/// The `lua/` directory of the working tree the test uses.
fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}
