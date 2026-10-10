//! `lunctl` against a real running lunette, over a real socket.
//!
//! Binding a real socket is the narrow exception `CONTRIBUTING.md` records for the
//! compositor's listener, because the session's listener at its documented path is under
//! test.

use pretty_assertions::assert_eq;

use crate::session::{Running, code, stderr, stdout};

mod session;

fn start() -> Running {
    Running::start("lunctl", |_, _| ())
}

#[test]
fn a_chunk_is_evaluated_between_frames_and_its_nested_table_comes_back() {
    let mut session = start();
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
    let mut session = start();
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
    let mut session = start();
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
    let mut session = start();
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
    let mut session = start();
    session.wait_until_answering();

    let abandoned = session.lunctl(&["while true do end"]);

    assert_eq!(code(&abandoned), 3, "stderr was:\n{}", stderr(&abandoned));
    let after = session.lunctl(&["return answer"]);
    assert_eq!(code(&after), 0, "stderr was:\n{}", stderr(&after));
    assert_eq!(stdout(&after), "42");
}
