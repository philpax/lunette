//! `lunette.spawn` and the handle it returns.
//!
//! The handle comes back before the compositor has seen the request. It
//! describes a process that does not exist yet: `alive` is false until the
//! snapshot lists it. A spawn that fails to start is reported through
//! `lovr.lunprocessexited`; the call does not raise.

use std::{ffi::OsStr, rc::Rc};

use lunette_capture::audio::{
    AudioService, RecordedAudioCommand, RecordingAudioBackend, Source, SourceLimits,
};
use lunette_compositor::{
    protocol::{
        Command, Pid, ProcessId, ProcessObservation, ProcessObservationFailure, ProcessSnapshot,
    },
    testing::{FakeInspector, adopted_process_snapshots},
};
use mlua::Value;
use pretty_assertions::assert_eq;

use crate::{
    audio::{AudioRegistry, NativeAudioRegistry},
    events::RecordingEventSink,
    host::NoHostSinks,
    layers::LayerPool,
    lua::{
        PoolRegistry, Session,
        tests::{error, layers::FakeLayers, lua, run, session, snapshot, window},
    },
    mirrors::NoMonitors,
};

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
fn adjacent_adopted_process_ids_remain_distinct_in_native_lua_and_capture_snapshots() {
    let processes = adopted_process_snapshots(&[
        Pid::new(4242).expect("positive pid"),
        Pid::new(4243).expect("positive pid"),
    ]);
    let ids = [processes[0].process, processes[1].process];
    assert_eq!(
        ids[0].get() - 1,
        ids[1].get(),
        "actually allocated adjacent ids"
    );

    let (backend, control) = RecordingAudioBackend::new();
    let registry = Rc::new(
        NativeAudioRegistry::new(
            AudioService::new(Box::new(backend), SourceLimits::default()),
            Box::new(FakeInspector::default()),
        )
        .expect("the observation worker starts"),
    );
    let session = Session::new_with_audio(
        Box::new(RecordingEventSink::default()),
        Rc::new(PoolRegistry::new(LayerPool::new(FakeLayers::new(128)))),
        Rc::new(NoMonitors),
        Rc::new(NoHostSinks),
        Rc::clone(&registry) as Rc<_>,
    );
    let mut first = window(1, "First playback", "example.first", Default::default());
    first.process = Some(ids[0]);
    let mut second = window(2, "Second playback", "example.second", Default::default());
    second.process = Some(ids[1]);
    let frame = snapshot(vec![first, second], processes);
    session.begin(frame.clone());
    registry.begin_frame(frame.as_ref());
    let lua = lua(&session);
    run::<()>(&lua, "
        local processes = lunette.processes()
        assert(#processes == 2 and not processes[1].dead and not processes[2].dead)
        assert(processes[1] ~= processes[2], 'process userdata equality must distinguish applications')
        assert(processes[1].id ~= processes[2].id, 'numeric process ids must distinguish applications')
        assert(processes[1].id - 1 == processes[2].id, 'adjacent ids must remain exact')
        local keys = { [processes[1].id] = 'first', [processes[2].id] = 'second' }
        assert(keys[processes[1].id] == 'first' and keys[processes[2].id] == 'second')
        local windows = lunette.windows()
        assert(windows[1].process == processes[1] and windows[2].process == processes[2])
        firstCapture = lunette.openAudio{ kind = 'process', process = windows[1].process }
        sameCapture = lunette.openAudio{ kind = 'process', process = processes[1] }
        secondCapture = lunette.openAudio{ kind = 'process', process = windows[2].process }
        local first = firstCapture:snapshot().source.process
        local same = sameCapture:snapshot().source.process
        local second = secondCapture:snapshot().source.process
        assert(first == processes[1] and same == first and second == processes[2])
        assert(first ~= second and first.id ~= second.id, 'capture snapshot source identities must be distinct')
    ");
    let starts: Vec<_> = control
        .commands()
        .into_iter()
        .filter_map(|command| match command {
            RecordedAudioCommand::Start(_, source) => Some(source),
            _ => None,
        })
        .collect();
    assert_eq!(
        starts,
        [Source::Process(ids[0]), Source::Process(ids[1])],
        "two readers of one native process share a stream, while different processes do not"
    );
    run::<()>(
        &lua,
        "firstCapture:close() sameCapture:close() secondCapture:close()",
    );
}

#[test]
fn managed_process_ids_stop_before_the_adopted_range_without_queuing_a_spawn() {
    let session = session(Vec::new());
    let lua = lua(&session);
    let maximum = (1_u64 << 52) - 1;
    session.frame.borrow_mut().processes = maximum - 1;
    assert_eq!(
        run::<u64>(&lua, "return lunette.spawn{ argv = { 'player' } }.id"),
        maximum
    );
    assert_eq!(session.flush().len(), 1);
    for _ in 0..2 {
        assert!(
            error(&lua, "lunette.spawn{ argv = { 'player' } }")
                .contains("process identifier space is exhausted")
        );
        assert!(
            session.flush().is_empty(),
            "exhaustion must not publish an illegal id"
        );
        assert_eq!(session.frame.borrow().processes, maximum);
    }
}

#[test]
fn managed_process_ids_refuse_an_out_of_range_counter_without_overflowing() {
    let session = session(Vec::new());
    let lua = lua(&session);
    for invalid in [1_u64 << 52, (1_u64 << 53) - 1, u64::MAX] {
        session.frame.borrow_mut().processes = invalid;
        assert!(
            error(&lua, "lunette.spawn{ argv = { 'player' } }")
                .contains("process identifier space is exhausted")
        );
        assert!(session.flush().is_empty());
        assert_eq!(session.frame.borrow().processes, invalid);
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
