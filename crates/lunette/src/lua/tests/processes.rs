//! `lunette.spawn` and the handle it answers with.
//!
//! The handle comes back before the compositor has seen the request, so it
//! describes a process that does not exist yet: `alive` is false until the
//! snapshot lists it, and a spawn that fails outright reports through
//! `lovr.lunprocessexited` rather than by the call raising.

use std::ffi::OsStr;

use lunette_compositor::protocol::{Command, ProcessId, ProcessSnapshot};
use mlua::Value;
use pretty_assertions::assert_eq;

use crate::lua::tests::{error, lua, run, session, snapshot};

#[test]
fn spawning_queues_a_request_under_the_identifier_it_returned() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let id: u64 = run(
        &lua,
        "local p = lunette.spawn{ argv = { 'foot', '-e', 'htop' } }
         return p.id",
    );

    let commands = session.flush();
    assert_eq!(commands.len(), 1);
    match &commands[0] {
        Command::Spawn(request) => {
            assert_eq!(request.process, ProcessId::new(id).expect("non-zero"));
            assert_eq!(request.argv.program(), OsStr::new("foot"));
            assert_eq!(
                request.argv.arguments(),
                [OsStr::new("-e"), OsStr::new("htop")]
            );
            assert!(request.env.is_empty());
            assert_eq!(request.cwd, None);
            assert!(!request.xwayland);
            assert_eq!(request.output, None);
        }
        other => panic!("expected a spawn command, got {other:?}"),
    }
}

#[test]
fn every_spawn_is_minted_a_distinct_identifier() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let (first, second): (u64, u64) = run(
        &lua,
        "return lunette.spawn{ argv = { 'foot' } }.id, lunette.spawn{ argv = { 'foot' } }.id",
    );

    assert_ne!(first, second);
    assert_eq!(session.flush().len(), 2);
}

#[test]
fn a_spawn_carries_the_environment_directory_and_x_setting_it_was_given() {
    let session = session(Vec::new());
    let lua = lua(&session);

    run::<Value>(
        &lua,
        "return lunette.spawn{
             argv = { 'xterm' },
             env = { TERM = 'foot', SHELL = '/bin/sh' },
             cwd = '/home/user',
             xwayland = true,
         }",
    );

    match session.flush().into_iter().next() {
        Some(Command::Spawn(request)) => {
            assert_eq!(
                request.env,
                vec![
                    ("SHELL".into(), "/bin/sh".into()),
                    ("TERM".into(), "foot".into()),
                ]
            );
            assert_eq!(
                request.cwd.as_deref(),
                Some(std::path::Path::new("/home/user"))
            );
            assert!(request.xwayland);
        }
        other => panic!("expected a spawn command, got {other:?}"),
    }
}

#[test]
fn a_spawn_without_a_program_is_refused() {
    let session = session(Vec::new());
    let lua = lua(&session);

    for chunk in ["lunette.spawn{}", "lunette.spawn{ argv = {} }"] {
        let message = error(&lua, chunk);
        assert!(
            message.contains("spawn needs an argv"),
            "unhelpful message: {message}"
        );
    }
    assert!(
        session.flush().is_empty(),
        "a refused spawn must not mint a process the compositor never hears about"
    );
}

#[test]
fn an_option_this_build_cannot_honour_is_refused_rather_than_ignored() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.spawn{ argv = { 'foot' }, otuput = 1 }");
    assert!(
        message.contains("'otuput' is not an option here"),
        "unhelpful message: {message}"
    );
    assert!(session.flush().is_empty());
}

#[test]
fn a_process_handle_reports_what_the_snapshot_says() {
    let session = session(Vec::new());
    let lua = lua(&session);
    run::<()>(&lua, "proc = lunette.spawn{ argv = { 'foot' } }");

    assert!(
        !run::<bool>(&lua, "return proc.alive"),
        "the compositor has not been told about the process yet"
    );

    let id = ProcessId::new(run::<u64>(&lua, "return proc.id")).expect("non-zero");
    session.begin(snapshot(
        Vec::new(),
        vec![ProcessSnapshot {
            process: id,
            pid: lunette_compositor::protocol::Pid::new(4242),
            external: false,
            alive: true,
        }],
    ));

    let (alive, pid, external): (bool, i32, bool) =
        run(&lua, "return proc.alive, proc.pid, proc.external");
    assert!(alive);
    assert_eq!(pid, 4242);
    assert!(!external);

    session.begin(snapshot(Vec::new(), Vec::new()));
    let (alive, pid): (bool, i32) = run(&lua, "return proc.alive, proc.pid");
    assert!(!alive, "a process absent from the snapshot has ended");
    assert_eq!(pid, 4242, "an ended process reads its last-known pid");
}
