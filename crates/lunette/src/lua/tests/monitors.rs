//! `lunette.monitors()` and the monitor handle, against a recording registry.
//!
//! The lifecycle's own transitions are tested in `lunette-capture`.

use std::cell::RefCell;

use lunette_capture::{
    hid::{
        KeyModifiers, PanelPoint, PointerButton as HostButton, VirtualKey, WheelDelta, XkbKeymap,
    },
    mirror::{MirrorOutcome, SelectionOutcome, SelectionState},
    monitor::{
        ConnectorKind, ConnectorName, LogicalGeometry, LogicalPosition, LogicalSize, MonitorKey,
        PixelExtent,
    },
    stream::FrameTransform,
};
use lunette_compositor::protocol::PixelPoint;
use pretty_assertions::assert_eq;

use super::*;
use crate::{
    host::HostSinks,
    import::formats::Alpha,
    mirrors::{MirrorRegistry, MonitorState},
    texture::TextureDescription,
};

/// A registry over a fixed set of monitors, recording every request it receives.
#[derive(Debug, Default)]
pub(super) struct FakeMirrors {
    states: RefCell<Vec<MonitorState>>,
    appeared: RefCell<Vec<MonitorKey>>,
    calls: RefCell<Vec<Call>>,
}

/// One call the registry records.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Call {
    Mirror(MonitorKey),
    Dismiss(MonitorKey),
    SetPaused(MonitorKey, bool),
    SelectMonitors,
}

impl FakeMirrors {
    /// A registry holding one monitor on `DP-1`, not mirrored.
    pub(super) fn one() -> Rc<Self> {
        let registry = Rc::new(Self::default());
        registry.states.borrow_mut().push(state(1, false));
        registry
    }

    fn calls(&self) -> Vec<Call> {
        self.calls.borrow().clone()
    }

    /// Detaches every monitor, as unplugging them does.
    fn detach_all(&self) {
        self.states.borrow_mut().clear();
    }

    fn set_mirrored(&self, mirrored: bool) {
        for state in self.states.borrow_mut().iter_mut() {
            state.mirrored = mirrored;
        }
    }
}

impl MirrorRegistry for FakeMirrors {
    fn poll(&self) -> Vec<MonitorKey> {
        std::mem::take(&mut self.appeared.borrow_mut())
    }

    fn monitors(&self) -> Vec<MonitorState> {
        self.states.borrow().clone()
    }

    fn state(&self, monitor: &MonitorKey) -> Option<MonitorState> {
        self.states
            .borrow()
            .iter()
            .find(|state| &state.key == monitor)
            .cloned()
    }

    fn mirror(&self, monitor: &MonitorKey) -> MirrorOutcome {
        self.calls.borrow_mut().push(Call::Mirror(monitor.clone()));
        MirrorOutcome::Requested
    }

    fn dismiss(&self, monitor: &MonitorKey) -> bool {
        self.calls.borrow_mut().push(Call::Dismiss(monitor.clone()));
        self.state(monitor).is_some_and(|state| state.mirrored)
    }

    fn set_paused(&self, monitor: &MonitorKey, paused: bool) -> bool {
        self.calls
            .borrow_mut()
            .push(Call::SetPaused(monitor.clone(), paused));
        true
    }

    fn select_monitors(&self) -> SelectionOutcome {
        self.calls.borrow_mut().push(Call::SelectMonitors);
        SelectionOutcome::Requested
    }

    fn selection_state(&self) -> SelectionState {
        if self.calls.borrow().contains(&Call::SelectMonitors) {
            SelectionState::Pending
        } else {
            SelectionState::Idle
        }
    }
}

/// A host desktop that records the events that reach it, so no test touches
/// `/dev/uinput`.
#[derive(Debug, Default)]
pub(super) struct RecordingHost {
    events: RefCell<Vec<HostEvent>>,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) enum HostEvent {
    Pointer {
        monitor: MonitorKey,
        hit: PanelPoint,
    },
    Button {
        button: HostButton,
        pressed: bool,
    },
    Wheel {
        delta: WheelDelta,
    },
    Key {
        key: VirtualKey,
        pressed: bool,
    },
    Modifiers {
        modifiers: KeyModifiers,
    },
    Keymap {
        text: String,
    },
    Committed,
}

impl RecordingHost {
    pub(super) fn events(&self) -> Vec<HostEvent> {
        self.events.borrow().clone()
    }
}

impl HostSinks for RecordingHost {
    fn pointer(&self, monitor: &MonitorKey, hit: PanelPoint) -> bool {
        self.events.borrow_mut().push(HostEvent::Pointer {
            monitor: monitor.clone(),
            hit,
        });
        true
    }

    fn button(&self, button: HostButton, pressed: bool) {
        self.events
            .borrow_mut()
            .push(HostEvent::Button { button, pressed });
    }

    fn wheel(&self, delta: WheelDelta) {
        self.events.borrow_mut().push(HostEvent::Wheel { delta });
    }

    fn key(&self, key: VirtualKey, pressed: bool) -> bool {
        self.events
            .borrow_mut()
            .push(HostEvent::Key { key, pressed });
        true
    }

    fn modifiers(&self, modifiers: KeyModifiers) -> bool {
        self.events
            .borrow_mut()
            .push(HostEvent::Modifiers { modifiers });
        true
    }

    fn set_keymap(&self, keymap: &XkbKeymap) -> bool {
        self.events.borrow_mut().push(HostEvent::Keymap {
            text: keymap.as_str().to_owned(),
        });
        true
    }

    fn commit(&self) {
        self.events.borrow_mut().push(HostEvent::Committed);
    }
}

fn key(index: u32) -> MonitorKey {
    MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, index))
}

fn state(index: u32, mirrored: bool) -> MonitorState {
    MonitorState {
        key: key(index),
        name: format!("Acme X24 on DP-{index}"),
        geometry: LogicalGeometry::new(
            LogicalPosition::new(i32::try_from(index - 1).expect("a small index") * 1920, 0),
            LogicalSize::new(1920, 1080),
        ),
        pixels: PixelExtent::new(3840, 2160),
        mirrored,
        pending: false,
    }
}

#[test]
fn a_session_with_no_monitor_source_lists_none() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert_eq!(
        lua.load("return #lunette.monitors()")
            .eval::<usize>()
            .expect("the call returns a list"),
        0,
    );
}

#[test]
fn fresh_monitor_selection_reaches_the_registry_or_reports_refusal() {
    let (session, mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);
    let result: (String, bool, Option<String>, String) = lua
        .load(
            "local before = lunette.monitorSelection().state
             local accepted, message = lunette.selectMonitors()
             return before, accepted, message, lunette.monitorSelection().state",
        )
        .eval()
        .expect("the selection API answers");
    assert_eq!(
        result,
        ("idle".to_owned(), true, None, "pending".to_owned())
    );
    assert_eq!(mirrors.calls(), vec![Call::SelectMonitors]);

    let bare = super::session(Vec::new());
    let bare_lua = super::lua(&bare);
    let result: (bool, Option<String>) = bare_lua
        .load("return lunette.selectMonitors()")
        .eval()
        .expect("the selection API answers");
    assert_eq!(
        result,
        (
            false,
            Some("monitor selection: no host monitors are available".to_owned())
        ),
        "a session without host integration refuses",
    );
}

#[test]
fn a_monitor_reports_its_identity_and_its_resolution() {
    let (session, _mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);

    let fields: (String, String, u32, u32, i32, u32) = lua
        .load(
            "local m = lunette.monitors()[1]
             return m.id, m.name, m.width, m.height, m.x, m.logicalWidth",
        )
        .eval()
        .expect("the fields read");

    assert_eq!(
        fields,
        (
            "DP-1".to_owned(),
            "Acme X24 on DP-1".to_owned(),
            3840,
            2160,
            0,
            1920,
        ),
        "width and height are pixels, because that is the size a captured frame arrives at",
    );
}

#[test]
fn captured_frame_transform_reads_through_reused_monitor_textures() {
    let (session, mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);
    lua.load("monitor = lunette.monitors()[1]")
        .exec()
        .expect("the handle is held");
    assert_eq!(
        lua.load("return monitor.frameTransform")
            .eval::<Option<String>>()
            .expect("field reads"),
        None
    );
    session.with_monitor_textures(|textures| {
        textures.install(
            key(1),
            None,
            FakeTexture(7),
            TextureDescription {
                size: PixelSize::new(1920, 1080),
                alpha: Alpha::Opaque,
            },
            FrameTransform::Undefined,
        );
    });
    session.with_monitor_textures(|textures| {
        textures.refresh_frame(&key(1), FrameTransform::Rotated90);
    });
    let fields: (String, i64) = lua
        .load("return monitor.frameTransform, monitor:getTexture()")
        .eval()
        .expect("frame fields read");
    assert_eq!(fields, ("rot90".to_owned(), 7));
    mirrors.detach_all();
    assert_eq!(
        lua.load("return monitor.frameTransform")
            .eval::<Option<String>>()
            .expect("field reads"),
        None
    );
}

#[test]
fn mirroring_reaches_the_lifecycle_once() {
    let (session, mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);

    assert!(
        lua.load("return lunette.monitors()[1]:mirror()")
            .eval::<bool>()
            .expect("the call answers"),
        "a request that may still prompt is a true; monitor.pending is what says it has not landed",
    );
    assert_eq!(mirrors.calls(), vec![Call::Mirror(key(1))]);
}

#[test]
fn dismissing_reports_whether_anything_was_running() {
    let (session, mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);

    assert!(
        !lua.load("return lunette.monitors()[1]:dismiss()")
            .eval::<bool>()
            .expect("the call answers"),
    );

    mirrors.set_mirrored(true);
    assert!(
        lua.load("return lunette.monitors()[1]:dismiss()")
            .eval::<bool>()
            .expect("the call answers"),
    );
    assert_eq!(
        mirrors.calls(),
        vec![Call::Dismiss(key(1)), Call::Dismiss(key(1))],
        "dismissing twice is how a configuration says 'make sure this is off'",
    );
}

#[test]
fn pausing_is_a_separate_request_from_dismissing() {
    let (session, mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);

    assert!(
        lua.load("return lunette.monitors()[1]:setPaused(true)")
            .eval::<bool>()
            .expect("the call answers"),
    );
    assert_eq!(mirrors.calls(), vec![Call::SetPaused(key(1), true)]);
}

#[test]
fn a_handle_reads_through_to_the_lifecycle_rather_than_caching_a_frame() {
    let (session, mirrors, _host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);

    lua.load("monitor = lunette.monitors()[1]")
        .exec()
        .expect("the handle is held across the change");
    assert!(
        !lua.load("return monitor.mirrored")
            .eval::<bool>()
            .expect("the field reads")
    );

    mirrors.set_mirrored(true);

    assert!(
        lua.load("return monitor.mirrored")
            .eval::<bool>()
            .expect("the field reads"),
        "Rust holds no reference into Lua, so a handle has to refresh on read",
    );
}

#[test]
fn an_unplugged_monitor_and_its_sink_go_inert_rather_than_raising() {
    let (session, mirrors, host) = mirrored_session(Vec::new(), FakeMirrors::one());
    let lua = lua(&session);
    lua.load("monitor = lunette.monitors()[1] sink = monitor.sink")
        .exec()
        .expect("the handle is held across the change");

    mirrors.detach_all();

    let (dead, name, mirrored) = lua
        .load("return monitor.dead, monitor.name, monitor:mirror()")
        .eval::<(bool, String, bool)>()
        .expect("a dead handle answers rather than raising");

    assert!(dead);
    assert_eq!(
        name, "Acme X24 on DP-1",
        "a dead handle keeps answering with what it last knew",
    );
    assert!(!mirrored);
    assert!(
        mirrors.calls().is_empty(),
        "a monitor that has gone must not reach the lifecycle at all",
    );

    let (dead, moved) = lua
        .load("return sink.dead, sink:pointer(0, 0)")
        .eval::<(bool, bool)>()
        .expect("a dead sink answers rather than raising");

    assert!(dead);
    assert!(!moved);
    assert!(
        host.events().is_empty(),
        "a monitor that has gone must not reach the host desktop at all",
    );
}

#[test]
fn a_monitors_sink_is_in_the_host_domain_and_a_windows_in_the_window_domain() {
    let (session, _mirrors, _host) = mirrored_session(
        vec![window(1, "htop", "st", PixelSize::new(800, 600))],
        FakeMirrors::one(),
    );
    let lua = lua(&session);

    let (domain, id, monitor) = lua
        .load(
            "local s = lunette.monitors()[1].sink
             return s.domain, s.id, s.monitor.id",
        )
        .eval::<(String, Option<u64>, String)>()
        .expect("the fields read");

    assert_eq!(domain, "host");
    assert_eq!(
        id, None,
        "a mirrored monitor is not a wl_surface and has no sink identifier",
    );
    assert_eq!(monitor, "DP-1");

    let (domain, id, monitor) = lua
        .load(
            "local s = lunette.windows()[1].sink
             return s.domain, s.id, s.monitor",
        )
        .eval::<(String, Option<u64>, Option<Value>)>()
        .expect("the fields read");

    assert_eq!(domain, "window");
    assert_eq!(id, Some(1));
    assert!(monitor.is_none(), "a window sink reaches no monitor");
}

#[test]
fn two_sinks_in_different_domains_route_independently_in_one_frame() {
    // WayVR's global `InputFocus` cannot express two pointers aimed at two
    // kinds of surface at the same time.
    let (session, _mirrors, host) = mirrored_session(
        vec![window(1, "htop", "st", PixelSize::new(800, 600))],
        FakeMirrors::one(),
    );
    let lua = lua(&session);

    lua.load(
        "lunette.windows()[1].sink:pointer(10, 20)
         lunette.monitors()[1].sink:pointer(0, 0)
         lunette.windows()[1].sink:button('left', true)
         lunette.monitors()[1].sink:button('right', true)",
    )
    .exec()
    .expect("both sinks accept input in the same frame");

    match session.flush().as_slice() {
        [
            Command::Pointer {
                sink: pointed,
                position,
                ..
            },
            Command::Button {
                sink: clicked,
                button,
                pressed,
                ..
            },
        ] => {
            assert_eq!(*pointed, sink_id(1));
            assert_eq!(*position, PixelPoint::new(10.0, 20.0));
            assert_eq!(*clicked, sink_id(1));
            assert_eq!(*button, PointerButton::Left);
            assert!(*pressed);
        }
        other => panic!("expected the window's two commands and nothing else, got {other:?}"),
    }
    assert_eq!(
        host.events(),
        vec![
            HostEvent::Pointer {
                monitor: key(1),
                hit: PanelPoint::TOP_LEFT,
            },
            HostEvent::Button {
                button: HostButton::Right,
                pressed: true,
            },
        ],
    );
}
