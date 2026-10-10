//! Tests Lua session handles without a graphics device.
//!
//! The texture type is an integer. Sessions otherwise use production handles, dead-handle behavior,
//! mutation queues, and argument validation.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

mod children;
mod drags;
mod events;
mod layers;
mod lunctl;
mod monitors;
mod outputs;
mod processes;
mod properties;
mod scene;
mod seats;
mod text;
mod windows;

use std::{rc::Rc, sync::Arc};

use lunette_compositor::{
    config::{DEFAULT_OUTPUT, DEFAULT_SEAT},
    protocol::{
        Command, ContentType, PixelSize, PointerButton, ProcessSnapshot, ScrollAxis, ScrollDelta,
        SeatId, SinkId, Snapshot, SourceCrop, SurfaceId, ToplevelStates, WindowId, WindowSnapshot,
    },
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

/// A test texture represented in Lua by its integer identifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FakeTexture(i64);

impl LuaTexture for FakeTexture {
    fn push(&self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Integer(self.0))
    }
}

impl CopyableTexture for FakeTexture {
    fn allocate_copy(&self) -> Option<Self> {
        Some(Self(self.0 + STABLE_OFFSET))
    }

    fn copy_to(&self, _: &Self) -> bool {
        true
    }
}

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

/// Creates a toplevel with matching window, surface, and sink identifiers.
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
        source_crop: SourceCrop::FULL,
        server_side_decorations: true,
        children: Vec::new(),
    }
}

fn snapshot(windows: Vec<WindowSnapshot>, processes: Vec<ProcessSnapshot>) -> Arc<Snapshot> {
    Arc::new(Snapshot {
        windows,
        processes,
        ..Snapshot::default()
    })
}

/// Creates a session at its first frame.
fn session(windows: Vec<WindowSnapshot>) -> TestSession {
    recording_session(windows).0
}

/// Creates a session with a recording event sink.
fn recording_session(windows: Vec<WindowSnapshot>) -> (TestSession, RecordingEventSink) {
    let (session, sink, _) = layered_session(windows, GENEROUS_LAYER_LIMIT);
    (session, sink)
}

/// Creates a session with an accessible layer pool and a reported layer limit.
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

/// Creates a session with fake host monitors and sinks.
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

const GENEROUS_LAYER_LIMIT: u32 = 128;

/// Creates a Lua session with the module and event dispatchers installed.
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

/// Dispatches queued event names through the Lua handlers installed for the session.
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
fn a_sink_refuses_an_argument_it_cannot_represent() {
    let session = session(vec![window(1, "htop", "foot", PixelSize::new(64, 32))]);
    let lua = lua(&session);

    for (chunk, expected) in [
        (
            "lunette.windows()[1].sink:button('lft', true)",
            "'lft' is not a pointer button",
        ),
        (
            "lunette.windows()[1].sink:pointer(0 / 0, 3)",
            "is not a pixel coordinate",
        ),
    ] {
        let message = error(&lua, chunk);
        assert!(message.contains(expected), "unhelpful message: {message}");
    }
    assert!(session.flush().is_empty());
}
