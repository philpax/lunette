//! The module's conversion of a snapshot into Lua, exercised without a
//! graphics device.
//!
//! A texture here is an integer, which is what the generic on [`Session`] is
//! for. Everything else — the handles, the dead-handle rule, the mutation
//! queue, the argument checking — is the production code path.
//!
//! The handles and the mutation queue are here; [`events`] holds the delivery
//! of `lovr.lun*` callbacks, which needs a poll loop the rest of the surface
//! does not.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

mod events;

use std::{ffi::OsStr, rc::Rc, sync::Arc};

use lunette_compositor::{
    protocol::{
        Command, PixelSize, PointerButton, ProcessId, ProcessSnapshot, SinkId, Snapshot, SurfaceId,
        ToplevelState, ToplevelStates, WindowId, WindowSnapshot,
    },
    state::DEFAULT_SEAT,
};
use mlua::{Lua, Table, Value};
use pretty_assertions::assert_eq;

use crate::{
    events::RecordingEventSink,
    import::formats::Alpha,
    lua::{LuaTexture, Session, install},
    texture::{CopyableTexture, TextureDescription, TextureRef},
};

/// Stands in for a LÖVR texture. Lua receives the number, which is enough to
/// tell one texture from another and from `false`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FakeTexture(i64);

impl LuaTexture for FakeTexture {
    fn push(&self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Integer(self.0))
    }
}

impl CopyableTexture for FakeTexture {
    /// Offset rather than equal, so that Lua can tell a stabilised copy from
    /// the imported texture it was made from.
    fn allocate_copy(&self) -> Option<Self> {
        Some(Self(self.0 + STABLE_OFFSET))
    }

    /// The copy itself is `texture.rs`'s to exercise; what matters here is that
    /// Lua is handed the same texture every time it asks.
    fn copy_to(&self, _: &Self) -> bool {
        true
    }
}

/// How far a stabilised copy's number sits from its source's.
const STABLE_OFFSET: i64 = 1000;

type TestSession = Rc<Session<FakeTexture>>;

fn window_id(raw: u64) -> WindowId {
    WindowId::new(raw).expect("non-zero")
}

fn surface_id(raw: u64) -> SurfaceId {
    SurfaceId::new(raw).expect("non-zero")
}

fn sink_id(raw: u64) -> SinkId {
    SinkId::new(raw).expect("non-zero")
}

/// A toplevel whose identifiers are all derived from one number, so a test
/// naming window 1 can also name surface 1 and sink 1 without restating them.
fn window(raw: u64, title: &str, app_id: &str, size: PixelSize) -> WindowSnapshot {
    WindowSnapshot {
        window: window_id(raw),
        surface: surface_id(raw),
        sink: sink_id(raw),
        process: None,
        output: None,
        title: Some(title.to_owned()),
        app_id: Some(app_id.to_owned()),
        size,
        min_size: None,
        max_size: None,
        parent: None,
        states: ToplevelStates::new(),
    }
}

fn snapshot(windows: Vec<WindowSnapshot>, processes: Vec<ProcessSnapshot>) -> Arc<Snapshot> {
    Arc::new(Snapshot {
        windows,
        processes,
        ..Snapshot::default()
    })
}

/// A session at the first frame, holding `windows`.
fn session(windows: Vec<WindowSnapshot>) -> TestSession {
    recording_session(windows).0
}

/// A session whose pushed events can be replayed, for the tests that need to.
fn recording_session(windows: Vec<WindowSnapshot>) -> (TestSession, RecordingEventSink) {
    let sink = RecordingEventSink::default();
    let session = Session::new(Box::new(sink.clone()));
    session.begin(snapshot(windows, Vec::new()));
    (session, sink)
}

/// A Lua state with the module installed and `lunette` already required, which
/// is the state a `main.lua` runs in.
///
/// The `lovr` table and its `handlers` are what `boot.lua:340-345` leaves
/// behind, reproduced here because the module's event dispatchers are installed
/// into them.
fn lua(session: &TestSession) -> Lua {
    let lua = Lua::new();
    install(&lua, session).expect("the module installs");
    lua.load("lovr = {} lovr.handlers = setmetatable({}, { __index = lovr })")
        .exec()
        .expect("the lovr scaffolding loads");
    lua.load("lunette = require 'lunette'")
        .exec()
        .expect("require resolves the module");
    lua
}

/// Runs `boot.lua`'s poll loop over what the session pushed.
///
/// `vendor/lovr/etc/boot.lua:193-198` reads a name and up to four payload
/// values out of `lovr.event.poll` and calls `lovr.handlers[name]` with them.
/// A `lun*` event carries no payload values, so the call takes none.
fn poll(lua: &Lua, sink: &RecordingEventSink) {
    let handlers: Table = lua
        .globals()
        .get::<Table>("lovr")
        .expect("the lovr table exists")
        .get("handlers")
        .expect("boot.lua's handlers table exists");

    for name in sink.take() {
        handlers
            .get::<mlua::Function>(name.as_str())
            .expect("a dispatcher is installed for every event the module pushes")
            .call::<()>(())
            .expect("a dispatcher reports a handler's error rather than raising");
    }
}

fn run<R: mlua::FromLuaMulti>(lua: &Lua, chunk: &str) -> R {
    lua.load(chunk).eval().expect("the chunk runs")
}

fn error(lua: &Lua, chunk: &str) -> String {
    lua.load(chunk)
        .exec()
        .expect_err("the chunk is expected to raise")
        .to_string()
}

#[test]
fn requiring_the_module_twice_is_the_same_module() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert!(
        run::<bool>(&lua, "return require('lunette') == lunette"),
        "require caches in package.loaded, so a second require is the first module"
    );
}

#[test]
fn a_snapshot_of_two_windows_becomes_two_handles() {
    let session = session(vec![
        window(1, "htop", "foot", PixelSize::new(1280, 720)),
        window(
            2,
            "editor",
            "org.gnome.TextEditor",
            PixelSize::new(1920, 1080),
        ),
    ]);
    let lua = lua(&session);

    let (count, first_title, first_app, first_width, first_height): (
        usize,
        String,
        String,
        u32,
        u32,
    ) = run(
        &lua,
        "local w = lunette.windows()
         return #w, w[1].title, w[1].appId, w[1].width, w[1].height",
    );

    assert_eq!(count, 2);
    assert_eq!(first_title, "htop");
    assert_eq!(first_app, "foot");
    assert_eq!(
        (first_width, first_height),
        (1280, 720),
        "the dimensions are pixels, which is what a panel converts a ray hit into"
    );

    let (second_title, second_width): (String, u32) = run(
        &lua,
        "local w = lunette.windows() return w[2].title, w[2].width",
    );
    assert_eq!(second_title, "editor");
    assert_eq!(second_width, 1920);
}

#[test]
fn windows_are_empty_before_anything_has_mapped() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert_eq!(run::<usize>(&lua, "return #lunette.windows()"), 0);
}

#[test]
fn a_window_reports_the_identifier_it_keeps_for_its_whole_life() {
    let session = session(vec![window(7, "term", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert_eq!(run::<u64>(&lua, "return lunette.windows()[1].id"), 7);
    assert!(!run::<bool>(&lua, "return lunette.windows()[1].dead"));
}

#[test]
fn a_handle_follows_its_window_across_frames() {
    let session = session(vec![window(1, "before", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(
        vec![window(1, "after", "foot", PixelSize::new(128, 64))],
        Vec::new(),
    ));

    let (title, width): (String, u32) = run(&lua, "return held.title, held.width");
    assert_eq!(title, "after");
    assert_eq!(width, 128);
}

#[test]
fn a_dead_handle_reads_its_last_known_values_and_raises_nothing() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (dead, title, app_id, width, height): (bool, String, String, u32, u32) = run(
        &lua,
        "return held.dead, held.title, held.appId, held.width, held.height",
    );

    assert!(dead);
    assert_eq!(title, "htop");
    assert_eq!(app_id, "foot");
    assert_eq!((width, height), (1280, 720));
}

#[test]
fn every_method_of_a_dead_handle_returns_false() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(1280, 720))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(11),
            TextureDescription {
                size: PixelSize::new(1280, 720),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1] sink = held.sink");

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (texture, pointer, button, sink_dead): (bool, bool, bool, bool) = run(
        &lua,
        "return held:getTexture(), sink:pointer(4, 5), sink:button('left', true), sink.dead",
    );

    assert!(!texture);
    assert!(!pointer);
    assert!(!button);
    assert!(sink_dead);
    assert!(
        session.flush().is_empty(),
        "a refused mutation must not reach the compositor"
    );
}

#[test]
fn get_texture_answers_with_the_texture_the_ledger_holds() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);

    assert_eq!(
        run::<i64>(&lua, "return lunette.windows()[1]:getTexture()"),
        42
    );
}

#[test]
fn get_texture_answers_false_before_the_client_has_committed_anything() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(!run::<bool>(
        &lua,
        "return lunette.windows()[1]:getTexture()"
    ));
}

#[test]
fn a_texture_handle_is_refused_once_its_frame_has_passed() {
    // Not reachable from Lua, which resolves a reference in the call that
    // built it. The ledger's rule is what `getTexture` relies on, so the test
    // states it at the boundary rather than only inside `texture.rs`.
    let session = session(Vec::new());
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });

    let obtained = session.generation();
    session.begin(snapshot(Vec::new(), Vec::new()));
    let current = session.generation();

    session.with_textures(|textures| {
        assert!(
            textures
                .lookup(TextureRef::new(surface_id(1), obtained), current)
                .is_err()
        );
        assert!(
            textures
                .lookup(TextureRef::new(surface_id(1), current), current)
                .is_ok()
        );
    });
}

#[test]
fn closing_asks_the_client_and_does_not_remove_the_window_itself() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(&lua, "return lunette.windows()[1]:close()"));
    assert_eq!(
        run::<usize>(&lua, "return #lunette.windows()"),
        1,
        "the client decides: it may prompt, or refuse, and the window goes when it unmaps"
    );

    match session.flush().as_slice() {
        [Command::CloseWindow { window }] => assert_eq!(*window, window_id(1)),
        other => panic!("expected a close command, got {other:?}"),
    }
}

#[test]
fn resizing_configures_the_toplevel_without_waiting_for_the_client() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.windows()[1]:resize(1920, 1080)"
    ));
    let (width, height): (u32, u32) = run(
        &lua,
        "local w = lunette.windows()[1] return w.width, w.height",
    );
    assert_eq!(
        (width, height),
        (64, 32),
        "the size reported is the one the client last committed, not the one asked of it"
    );

    match session.flush().as_slice() {
        [
            Command::ConfigureWindow {
                window,
                size,
                states,
            },
        ] => {
            assert_eq!(*window, window_id(1));
            assert_eq!(*size, Some(PixelSize::new(1920, 1080)));
            assert!(states.is_empty());
        }
        other => panic!("expected a configure command, got {other:?}"),
    }
}

#[test]
fn resizing_restates_the_states_the_window_is_already_in() {
    let mut maximized = window(1, "editor", "foot", PixelSize::new(64, 32));
    maximized.states = ToplevelStates::from_iter([ToplevelState::Maximized]);

    let session = session(vec![maximized]);
    let lua = lua(&session);
    run::<bool>(&lua, "return lunette.windows()[1]:resize(800, 600)");

    match session.flush().as_slice() {
        [Command::ConfigureWindow { states, .. }] => assert!(
            states.contains(&ToplevelState::Maximized),
            "a configure replaces the state set wholesale, so omitting them would unmaximise it"
        ),
        other => panic!("expected a configure command, got {other:?}"),
    }
}

#[test]
fn a_size_that_is_not_a_pair_of_pixel_counts_is_reported() {
    let session = session(vec![window(1, "editor", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    for chunk in [
        "lunette.windows()[1]:resize(0, 600)",
        "lunette.windows()[1]:resize(-1, 600)",
        "lunette.windows()[1]:resize(800, 0.5)",
        "lunette.windows()[1]:resize(800, 0 / 0)",
        "lunette.windows()[1]:resize(800, 2 ^ 40)",
    ] {
        let message = error(&lua, chunk);
        assert!(
            message.contains("is not a window size"),
            "unhelpful message for {chunk}: {message}"
        );
    }

    assert!(
        session.flush().is_empty(),
        "a refused configure must not reach the compositor"
    );
}

#[test]
fn stabilizing_hands_back_the_same_texture_while_the_buffer_rotates() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);

    let (stable, again, imported): (i64, i64, i64) = run(
        &lua,
        "local w = lunette.windows()[1]
         return w:stabilize(), w:stabilize(), w:getTexture()",
    );

    assert_eq!(
        stable, again,
        "a second call returns the same texture rather than allocating another"
    );
    assert_ne!(stable, imported, "the copy is lunette's, not the client's");

    // The client commits its next buffer, which is a different texture.
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(43),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    session.begin(snapshot(
        vec![window(1, "htop", "foot", PixelSize::new(64, 32))],
        Vec::new(),
    ));

    let (after, rotated): (i64, i64) = run(
        &lua,
        "local w = lunette.windows()[1] return w:stabilize(), w:getTexture()",
    );
    assert_eq!(
        after, stable,
        "the identity is what the copy exists to provide"
    );
    assert_eq!(rotated, 43, "the imported texture rotated underneath it");
}

#[test]
fn stabilizing_answers_false_before_the_client_has_committed_anything() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(!run::<bool>(
        &lua,
        "return lunette.windows()[1]:stabilize()"
    ));
}

#[test]
fn every_mutation_of_a_dead_handle_returns_false() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    session.with_textures(|textures| {
        textures.install(
            surface_id(1),
            FakeTexture(42),
            TextureDescription {
                size: PixelSize::new(64, 32),
                alpha: Alpha::Present,
            },
        )
    });
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.windows()[1]");

    session.begin(snapshot(Vec::new(), Vec::new()));

    let (closed, resized, stabilized): (bool, bool, bool) = run(
        &lua,
        "return held:close(), held:resize(800, 600), held:stabilize()",
    );

    assert!(!closed);
    assert!(!resized);
    assert!(!stabilized);
    assert!(
        session.flush().is_empty(),
        "a refused mutation must not reach the compositor"
    );
}

#[test]
fn a_pointer_event_queues_until_the_frame_ends() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.windows()[1].sink:pointer(12.5, 30)"
    ));
    assert_eq!(
        session.snapshot().windows.len(),
        1,
        "the mutation must not have changed what the frame reads"
    );

    let commands = session.flush();
    assert_eq!(commands.len(), 1);
    match &commands[0] {
        Command::Pointer {
            seat,
            sink,
            position,
        } => {
            assert_eq!(*seat, DEFAULT_SEAT);
            assert_eq!(*sink, sink_id(1));
            assert_eq!((position.x, position.y), (12.5, 30.0));
        }
        other => panic!("expected a pointer command, got {other:?}"),
    }

    assert!(
        session.flush().is_empty(),
        "a flushed command must not be sent twice"
    );
}

#[test]
fn a_button_event_carries_the_button_it_named() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    run::<bool>(
        &lua,
        "local s = lunette.windows()[1].sink
         s:button('left', true)
         s:button('right', false)
         return s:button('middle', true)",
    );

    let buttons: Vec<(PointerButton, bool)> = session
        .flush()
        .into_iter()
        .map(|command| match command {
            Command::Button {
                button, pressed, ..
            } => (button, pressed),
            other => panic!("expected a button command, got {other:?}"),
        })
        .collect();

    assert_eq!(
        buttons,
        vec![
            (PointerButton::Left, true),
            (PointerButton::Right, false),
            (PointerButton::Middle, true),
        ],
        "the queue keeps the order the callbacks made them in"
    );
}

#[test]
fn a_button_that_does_not_exist_is_reported_rather_than_guessed() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    let message = error(&lua, "lunette.windows()[1].sink:button('lft', true)");
    assert!(
        message.contains("'lft' is not a pointer button"),
        "unhelpful message: {message}"
    );
    assert!(session.flush().is_empty());
}

#[test]
fn a_coordinate_that_is_not_a_number_is_reported() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    let message = error(&lua, "lunette.windows()[1].sink:pointer(0 / 0, 3)");
    assert!(
        message.contains("is not a pixel coordinate"),
        "unhelpful message: {message}"
    );
    assert!(session.flush().is_empty());
}

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

#[test]
fn the_module_exposes_only_what_this_phase_implements() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let mut names: Vec<String> = run::<Table>(&lua, "return lunette")
        .pairs::<String, Value>()
        .map(|pair| pair.expect("the module's keys are strings").0)
        .collect();
    names.sort();

    assert_eq!(
        names,
        vec!["spawn".to_owned(), "windows".to_owned()],
        "a name added here is a promise; the rest of the surface arrives with the phase that \
         implements it"
    );
}
