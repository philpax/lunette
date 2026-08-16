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
mod layers;
mod lunctl;
mod monitors;
mod outputs;
mod processes;
mod properties;
mod scene;
mod seats;
mod windows;

use std::{rc::Rc, sync::Arc};

use lunette_compositor::{
    protocol::{
        Command, ContentType, PixelSize, PointerButton, ProcessSnapshot, ScrollAxis, ScrollDelta,
        SeatId, SinkId, Snapshot, SurfaceId, ToplevelStates, WindowId, WindowSnapshot,
    },
    state::{DEFAULT_OUTPUT, DEFAULT_SEAT},
};
use mlua::{Lua, Table, Value};
use pretty_assertions::assert_eq;

use crate::{
    events::RecordingEventSink,
    host::NoHostSinks,
    layers::LayerPool,
    lua::{
        LuaTexture, PoolRegistry, Session, install,
        tests::{
            layers::FakeLayers,
            monitors::{FakeMirrors, RecordingHost},
        },
    },
    mirrors::NoMonitors,
    texture::CopyableTexture,
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
        output: DEFAULT_OUTPUT,
        title: Some(title.to_owned()),
        app_id: Some(app_id.to_owned()),
        size,
        min_size: None,
        max_size: None,
        parent: None,
        states: ToplevelStates::new(),
        content_type: ContentType::None,
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
    let (session, sink, _) = layered_session(windows, GENEROUS_LAYER_LIMIT);
    (session, sink)
}

/// A session whose pool is reachable, for the tests that drive frame boundaries.
///
/// `limit` is what the runtime reports, not what the pool will spend.
fn layered_session(
    windows: Vec<WindowSnapshot>,
    limit: u32,
) -> (
    TestSession,
    RecordingEventSink,
    Rc<PoolRegistry<FakeLayers>>,
) {
    let sink = RecordingEventSink::default();
    let registry = Rc::new(PoolRegistry::new(LayerPool::new(FakeLayers::new(limit))));
    let session = Session::new(
        Box::new(sink.clone()),
        Rc::clone(&registry) as Rc<_>,
        Rc::new(NoMonitors) as Rc<_>,
        Rc::new(NoHostSinks) as Rc<_>,
    );
    session.begin(snapshot(windows, Vec::new()));
    (session, sink, registry)
}

/// A session whose monitors are reachable, for the tests about them.
fn mirrored_session(
    windows: Vec<WindowSnapshot>,
    monitors: Rc<FakeMirrors>,
) -> (TestSession, Rc<FakeMirrors>, Rc<RecordingHost>) {
    let sink = RecordingEventSink::default();
    let registry = Rc::new(PoolRegistry::new(LayerPool::new(FakeLayers::new(
        GENEROUS_LAYER_LIMIT,
    ))));
    let host = Rc::new(RecordingHost::default());
    let session = Session::new(
        Box::new(sink),
        registry as Rc<_>,
        Rc::clone(&monitors) as Rc<_>,
        Rc::clone(&host) as Rc<_>,
    );
    session.begin(snapshot(windows, Vec::new()));
    (session, monitors, host)
}

/// A runtime limit generous enough that the pool is never the reason a test
/// fails, for the tests that are not about layers.
const GENEROUS_LAYER_LIMIT: u32 = 128;

/// A Lua state with the module installed and `lunette` already required, which
/// is the state a `main.lua` runs in.
///
/// The `lovr` table and its `handlers` are what `boot.lua:340-345` leaves
/// behind, reproduced here because the module's event dispatchers are installed
/// into them.
fn lua(session: &TestSession) -> Lua {
    let lua = crate::test_lua::session_lua();
    install(&lua, session).expect("the module installs");
    lua.load("lovr = {} lovr.handlers = setmetatable({}, { __index = lovr })")
        .exec()
        .expect("the lovr scaffolding loads");
    lua.load("lunette = require '@lunette'")
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
        run::<bool>(&lua, "return require('@lunette') == lunette"),
        "require caches in package.loaded, so a second require is the first module"
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

/// AC5.5's entry point. A restart is asked for through LÖVR's own event, which
/// `vendor/lovr/etc/boot.lua:196` reads out of the queue at the end of the
/// frame, so what this checks is that the call reaches that function.
#[test]
fn a_restart_is_asked_for_through_lovrs_own_event() {
    let session = session(Vec::new());
    let lua = lua(&session);
    run::<()>(
        &lua,
        "restarts = 0
         lovr.event = { restart = function() restarts = restarts + 1 end }",
    );

    run::<()>(&lua, "lunette.restart()");

    assert_eq!(
        run::<i64>(&lua, "return restarts"),
        1,
        "the call should have reached lovr.event.restart exactly once"
    );
}

/// Nothing is performed by the call, so a configuration that asks twice in one
/// frame is asking for the same restart twice rather than recursing the way a
/// reload from inside a reload would.
#[test]
fn a_restart_asked_for_twice_is_not_refused() {
    let session = session(Vec::new());
    let lua = lua(&session);
    run::<()>(
        &lua,
        "restarts = 0
         lovr.event = { restart = function() restarts = restarts + 1 end }",
    );

    run::<()>(&lua, "lunette.restart() lunette.restart()");

    assert_eq!(
        run::<i64>(&lua, "return restarts"),
        2,
        "there is no re-entry guard, because the event is read after the frame"
    );
}

/// A LÖVR without the event module is a broken build rather than a mistake in
/// the configuration, so it is reported as such instead of as a nil call.
#[test]
fn a_restart_with_no_event_module_is_reported() {
    let session = session(Vec::new());
    let lua = lua(&session);

    let message = error(&lua, "lunette.restart()");
    assert!(
        message.contains("lovr.event.restart could not be reached"),
        "unhelpful message: {message}"
    );
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
        vec![
            "claimLayer".to_owned(),
            "modifierNames".to_owned(),
            "monitors".to_owned(),
            "newOutput".to_owned(),
            "newSeat".to_owned(),
            "outputs".to_owned(),
            "reload".to_owned(),
            "restart".to_owned(),
            "scaleSteps".to_owned(),
            "sceneEnabled".to_owned(),
            "seats".to_owned(),
            "setSceneEnabled".to_owned(),
            "spawn".to_owned(),
            "windows".to_owned(),
        ],
        "a name added here is a promise; the rest of the surface arrives with the phase that \
         implements it"
    );
}

#[test]
fn the_shipped_configuration_is_valid_lua() {
    // The one thing about `etc/xdg/lunette/main.lua` that can be checked
    // without a graphics device and an XR runtime. It is the configuration a
    // fresh installation runs, so a syntax error in it is a broken build that
    // nothing else in the suite would notice.
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../etc/xdg/lunette/main.lua"
    );
    let source = std::fs::read_to_string(path).expect("the shipped configuration is readable");

    crate::test_lua::session_lua()
        .load(&source)
        .into_function()
        .expect("the shipped configuration parses");
}
