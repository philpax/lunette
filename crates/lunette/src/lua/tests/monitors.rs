//! `lunette.monitors()` and the monitor handle, against a recording registry.
//!
//! The lifecycle's own transitions belong to `lunette-capture`, which exercises
//! them against the scripted portal. What is under test here is the projection:
//! that a handle reads through on every access, that a detached monitor goes
//! inert rather than raising, and that mirroring and dismissing reach the
//! registry once each.

use std::cell::RefCell;

use lunette_capture::{
    mirror::MirrorOutcome,
    monitor::{
        ConnectorKind, ConnectorName, LogicalGeometry, LogicalPosition, LogicalSize, MonitorKey,
        PixelExtent,
    },
};
use pretty_assertions::assert_eq;

use super::*;
use crate::mirrors::{MirrorRegistry, MonitorState};

/// A registry over a fixed set of monitors, recording what it was asked.
#[derive(Debug, Default)]
pub(super) struct FakeMirrors {
    states: RefCell<Vec<MonitorState>>,
    appeared: RefCell<Vec<MonitorKey>>,
    calls: RefCell<Vec<Call>>,
}

/// One thing the registry was asked to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Call {
    Mirror(MonitorKey),
    Dismiss(MonitorKey),
    SetPaused(MonitorKey, bool),
}

impl FakeMirrors {
    /// A registry holding one monitor on `DP-1`, not mirrored.
    fn one() -> Rc<Self> {
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
fn a_monitor_reports_its_identity_and_its_resolution() {
    let (session, _sink, _mirrors) = mirrored_session(FakeMirrors::one());
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
fn mirroring_reaches_the_lifecycle_once() {
    let (session, _sink, mirrors) = mirrored_session(FakeMirrors::one());
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
    let (session, _sink, mirrors) = mirrored_session(FakeMirrors::one());
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
    let (session, _sink, mirrors) = mirrored_session(FakeMirrors::one());
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
    let (session, _sink, mirrors) = mirrored_session(FakeMirrors::one());
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
fn an_unplugged_monitor_goes_inert_rather_than_raising() {
    let (session, _sink, mirrors) = mirrored_session(FakeMirrors::one());
    let lua = lua(&session);
    lua.load("monitor = lunette.monitors()[1]")
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
}
