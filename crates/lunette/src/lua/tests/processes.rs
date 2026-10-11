//! `lunette.spawn` and the handle it returns.
//!
//! The handle comes back before the compositor has seen the request. It
//! describes a process that does not exist yet: `alive` is false until the
//! snapshot lists it. A spawn that fails to start is reported through
//! `lovr.lunprocessexited`; the call does not raise.

use std::ffi::OsStr;

use lunette_compositor::protocol::{
    Command, ProcessId, ProcessObservation, ProcessObservationFailure, ProcessSnapshot,
};
use mlua::Value;
use pretty_assertions::assert_eq;

use crate::lua::tests::{error, lua, run, session, snapshot, window};

#[test]
fn spawning_queues_a_request_under_a_distinct_identifier_it_returned() {
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

    let second: u64 = run(&lua, "return lunette.spawn{ argv = { 'foot' } }.id");
    assert_ne!(id, second, "every spawn is minted a distinct identifier");
    assert_eq!(session.flush().len(), 1);
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
fn window_process_handle_association() {
    let session = session(Vec::new());
    let lua = lua(&session);
    let id = ProcessId::new(17).expect("non-zero");
    let mut associated = window(1, "Playback", "example.player", Default::default());
    associated.process = Some(id);
    let unattributed = window(2, "Other", "example.other", Default::default());
    session.begin(snapshot(
        vec![associated, unattributed],
        vec![ProcessSnapshot {
            process: id,
            pid: lunette_compositor::protocol::Pid::new(4242),
            instance: None,
            observation: ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied),
            external: true,
            alive: true,
        }],
    ));
    run::<()>(
        &lua,
        "local processes = lunette.processes()
         assert(#processes == 1 and not processes[1].dead)
         local windows = lunette.windows()
         kept = windows[1]
         assert(kept.process == processes[1])
         assert(windows[2].process == nil)",
    );
    session.begin(snapshot(Vec::new(), session.snapshot().processes.clone()));
    assert!(run::<bool>(
        &lua,
        "return kept.dead and kept.process == lunette.processes()[1] and not kept.process.dead",
    ));
    session.begin(snapshot(Vec::new(), Vec::new()));
    assert!(run::<bool>(
        &lua,
        "return #lunette.processes() == 0 and kept.process.dead",
    ));
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
fn a_process_handle_reports_what_the_snapshot_says() {
    let session = session(Vec::new());
    let lua = lua(&session);
    run::<()>(&lua, "proc = lunette.spawn{ argv = { 'foot' } }");

    assert!(
        run::<bool>(&lua, "return proc.dead"),
        "the compositor has not been told about the process yet"
    );

    let id = ProcessId::new(run::<u64>(&lua, "return proc.id")).expect("non-zero");
    session.begin(snapshot(
        Vec::new(),
        vec![ProcessSnapshot {
            process: id,
            pid: lunette_compositor::protocol::Pid::new(4242),
            instance: None,
            observation: ProcessObservation::Unavailable(ProcessObservationFailure::AccessDenied),
            external: false,
            alive: true,
        }],
    ));

    assert!(!run::<bool>(&lua, "return proc.dead"));

    session.begin(snapshot(Vec::new(), Vec::new()));
    assert!(
        run::<bool>(&lua, "return proc.dead"),
        "a process absent from the snapshot has ended"
    );
}
