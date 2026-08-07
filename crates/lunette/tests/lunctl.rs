//! `lunctl` against a real running lunette, over a real socket.
//!
//! `lunette-v1.AC8.1` and `AC8.2` are about what happens between two processes,
//! and neither can be established by a unit test on a Lua state a test built.
//! These drive the shipped binary: the session is the real one, the module is
//! the one the host registered, the socket is one lunette bound, and `lunctl` is
//! the binary a user would run.
//!
//! The fixture switches the audio, graphics, and headset modules off and opens
//! no window, so no display, no XR runtime, and no sound device is needed. Each
//! run gets its own `XDG_RUNTIME_DIR`, which is where the control socket goes,
//! and its own `XDG_DATA_HOME`.
//!
//! Binding a real socket is the narrow exception `CONTRIBUTING.md` records for
//! the compositor's listener, and it applies here for the same reason: the
//! listener, its mode, and the path it chose are part of what is under test.

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

/// How long a session gets to bind its socket before the test gives up.
///
/// Generous: this covers the whole of LÖVR's boot on a cold cache, and it is a
/// bound on a failure rather than a wait for a success — the poll below returns
/// as soon as the socket appears.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

/// A running lunette, stopped when the test lets go of it.
struct Session {
    child: Child,
    runtime: TempDir,
    /// Kept for its `Drop`, which removes the directory the session writes into.
    _data: TempDir,
}

impl Session {
    /// Starts a session against the `lunctl` fixture and waits for its socket.
    fn start() -> Self {
        Self::start_with(&[])
    }

    fn start_with(environment: &[(&str, &str)]) -> Self {
        let runtime = TempDir::with_prefix("lunette-lunctl-run-")
            .expect("a runtime directory can be created");
        // What the XDG specification requires of `$XDG_RUNTIME_DIR`, and what
        // lunette checks for rather than trusting.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        let data =
            TempDir::with_prefix("lunette-lunctl-data-").expect("a data directory can be created");

        let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
        command
            .env("XDG_CONFIG_HOME", fixture_directory())
            .env("XDG_DATA_HOME", data.path())
            .env("XDG_RUNTIME_DIR", runtime.path())
            // Removed so that the developer's own configuration cannot be
            // reached if the fixture is ever mislaid, which would turn a missing
            // fixture into a confusing pass.
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

    /// Where the session's control socket should be.
    fn socket(&self) -> PathBuf {
        self.runtime.path().join("lunette").join("lunette-0.sock")
    }

    /// Waits for the socket to appear, rather than for a duration.
    fn wait_for_socket(&mut self) -> PathBuf {
        let socket = self.socket();
        let deadline = Instant::now() + STARTUP_BOUND;

        while Instant::now() < deadline {
            if socket.exists() {
                return socket;
            }
            if let Some(status) = self
                .child
                .try_wait()
                .expect("the child's status can be read")
            {
                panic!("the session exited {status} before it bound a control socket");
            }
            thread::sleep(POLL);
        }

        panic!(
            "no control socket appeared at {} within {STARTUP_BOUND:?}",
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
        // A long-lived resource, so it is cleaned up whatever the test did.
        // `kill` on a child that has already exited is a no-op that reports.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// How often the socket is looked for. Short enough that startup is not padded.
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

/// The whole of `lunette-v1.AC8.1`: a chunk evaluated between frames, with
/// nested tables coming back.
#[test]
fn a_chunk_is_evaluated_between_frames_and_its_nested_table_comes_back() {
    let mut session = Session::start();
    session.wait_for_socket();

    let scalar = session.lunctl(&["return answer"]);
    assert_eq!(code(&scalar), 0, "stderr was:\n{}", stderr(&scalar));
    assert_eq!(stdout(&scalar), "42");

    // A top-level string prints bare, which is what makes lunctl composable in
    // a shell.
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
    session.wait_for_socket();

    let spawned = session.lunctl(&["return lunette.spawn{ argv = { 'true' } }"]);
    assert_eq!(code(&spawned), 0, "stderr was:\n{}", stderr(&spawned));
    assert_eq!(
        stdout(&spawned),
        "<process 1>",
        "a handle is its kind and its id, and nothing a client could dereference",
    );

    // `lunette` is a global here because the fixture required it, which is what
    // a chunk reaching the session's own surface looks like.
    let windows = session.lunctl(&["return #lunette.windows()"]);
    assert_eq!(stdout(&windows), "0");
}

/// The three outcomes a shell script branches on, each with its own status.
#[test]
fn each_failure_has_its_own_exit_status() {
    let mut session = Session::start();
    session.wait_for_socket();

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

/// A chunk that ran and answered more than one message holds. The session is
/// healthy and the chunk succeeded, so reporting it as a session that could not
/// be reached — which is what closing the connection amounts to — would be a lie
/// about both.
#[test]
fn an_answer_larger_than_a_message_is_named_rather_than_read_as_an_absent_session() {
    let mut session = Session::start();
    session.wait_for_socket();

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
    // And the session is still there, which the status above must not have
    // implied otherwise.
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}

/// `lunette-v1.AC8.2`'s first clause, end to end: the session keeps running.
#[test]
fn a_chunk_that_overruns_is_abandoned_and_the_session_carries_on() {
    let mut session = Session::start();
    session.wait_for_socket();

    let abandoned = session.lunctl(&["while true do end"]);

    assert_eq!(code(&abandoned), 3, "stderr was:\n{}", stderr(&abandoned));
    // The point of the whole mechanism: the frame loop was not stalled, so the
    // next chunk is answered as normal.
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}

/// `lunette-v1.AC8.2`'s second clause, measured on the socket a real session
/// bound rather than on one a test bound.
#[test]
fn the_socket_is_0600_inside_a_0700_directory_and_is_not_a_network_address() {
    let mut session = Session::start();
    let socket = session.wait_for_socket();

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

/// The switch `docs/lua-api.md` requires: a user who wants no evaluation
/// endpoint gets none.
#[test]
fn the_disable_switch_leaves_no_socket_to_connect_to() {
    no_socket_is_bound_with("off");
}

/// A user who reached for a spelling the switch does not know was still asking
/// for the endpoint to be closed. Unset already means open, so the only reason
/// to set the variable is to close it, and an unrecognised value that opened it
/// anyway would be the failure the switch exists to prevent.
#[test]
fn a_spelling_of_off_the_switch_does_not_know_still_leaves_no_socket() {
    no_socket_is_bound_with("false");
}

fn no_socket_is_bound_with(setting: &str) {
    let mut session = Session::start_with(&[("LUNETTE_CONTROL", setting)]);

    // There is no socket to wait for, so the session is stopped by the fixture's
    // own bound. What this asserts is that nothing appeared in the meantime.
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

/// A chunk can end the session, which is what the end-to-end shell tests use to
/// tear down.
#[test]
fn a_chunk_can_stop_the_session() {
    let mut session = Session::start();
    session.wait_for_socket();

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

/// The `lua/` directory of the working tree this test was built from.
fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}
