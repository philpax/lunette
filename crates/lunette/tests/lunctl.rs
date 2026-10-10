//! `lunctl` against a real running lunette, over a real socket.
//!
//! Binding a real socket is the narrow exception `CONTRIBUTING.md` records for the
//! compositor's listener, because the session's listener at its documented path is under
//! test.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Output},
    thread,
    time::{Duration, Instant},
};

use pretty_assertions::assert_eq;
use tempfile::TempDir;

/// Covers LÖVR's whole boot on a cold cache. It applies only to a session that never answers.
const STARTUP_BOUND: Duration = Duration::from_secs(30);

struct Session {
    child: Child,
    runtime: TempDir,
    _data: TempDir,
}

impl Session {
    fn start() -> Self {
        let runtime = TempDir::with_prefix("lunette-lunctl-run-")
            .expect("a runtime directory can be created");
        // lunette verifies the `0o700` mode the XDG specification requires.
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700))
            .expect("the mode can be set");
        let data =
            TempDir::with_prefix("lunette-lunctl-data-").expect("a data directory can be created");

        let mut command = Command::new(env!("CARGO_BIN_EXE_lunette"));
        command
            // A mislaid fixture would otherwise load another configuration and pass.
            .env_remove("LUNETTE_CONFIG_PATH")
            .env("XDG_CONFIG_HOME", fixture_directory())
            .env("XDG_DATA_HOME", data.path())
            .env("XDG_RUNTIME_DIR", runtime.path())
            .env_remove("HOME")
            .env("LUNETTE_STDLIB_PATH", standard_library());

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

    /// The socket binds before the Lua state boots and the frame loop answers chunks, so
    /// readiness is a chunk response rather than the socket's existence.
    fn wait_until_answering(&mut self) {
        let socket = self.socket();
        let deadline = Instant::now() + STARTUP_BOUND;

        while Instant::now() < deadline {
            if socket.exists() {
                let ready = self.lunctl(&["return 'ready'"]);
                if ready.status.code() == Some(0) && stdout(&ready) == "ready" {
                    return;
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

    fn lunctl(&self, arguments: &[&str]) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_lunctl"));
        command.arg("--socket").arg(self.socket());
        command.args(arguments);
        command.output().expect("the lunctl binary can be run")
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

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

#[test]
fn a_chunk_is_evaluated_between_frames_and_its_nested_table_comes_back() {
    let mut session = Session::start();
    session.wait_until_answering();

    let scalar = session.lunctl(&["return answer"]);
    assert_eq!(code(&scalar), 0, "stderr was:\n{}", stderr(&scalar));
    assert_eq!(stdout(&scalar), "42");

    // A top-level string prints bare, so a shell can capture it.
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

    // The fixture never requires `lunette`, so the chunk reaches it through the evaluator's
    // module lookup, as the documented examples do.
    let windows = session.lunctl(&["return #lunette.windows()"]);
    assert_eq!(stdout(&windows), "0");
}

/// A shell script branches on these outcomes, so each keeps its own status.
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

/// Closing the connection on an oversized answer would report an absent session, status 6,
/// which misstates both the session and the chunk.
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
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}

#[test]
fn a_chunk_that_overruns_is_abandoned_and_the_session_carries_on() {
    let mut session = Session::start();
    session.wait_until_answering();

    let abandoned = session.lunctl(&["while true do end"]);

    assert_eq!(code(&abandoned), 3, "stderr was:\n{}", stderr(&abandoned));
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}

/// A chunk reaches the session's own state, so it can end the session.
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

fn fixture_directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("lunctl")
}

fn standard_library() -> PathBuf {
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("lua")
}
