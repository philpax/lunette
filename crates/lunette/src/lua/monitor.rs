//! Linux-only: the monitor handle Lua holds.
//!
//! A monitor is one of the user's own screens, not a window lunette hosts. The
//! handle names it by the identity `lunette-capture` resolved: a make and model
//! where the host reports one, a connector name where it does not. Every access
//! reads the monitor's state from the mirror lifecycle, for the same reason
//! [`crate::lua::Window`] does: Rust holds no reference into Lua, so it cannot
//! walk the handles Lua is keeping at frame start.
//!
//! # The mirroring request
//!
//! `monitor:mirror()` prefers direct host capture and falls back to the portal.
//! Portal permission is asynchronous; direct setup inherits the pinned client's
//! synchronous initialization. A stream can be installed before its first frame.
//!
//! `monitor:dismiss()` removes the active mirror and texture. PipeWire joins its
//! worker and keeps the portal session; the pinned direct worker may remain
//! detached. Direct pause is likewise an upstream no-op.

use std::{cell::RefCell, rc::Rc};

use lunette_capture::{
    mirror::{MirrorOutcome, SelectionOutcome, SelectionState},
    monitor::MonitorKey,
    stream::FrameTransform,
};
use lunette_luau::Type;
use mlua::{IntoLua, Lua, Value};
use tracing::warn;

use crate::{
    control::wire::HandleKind,
    lua::{
        LuaTexture, Session, Sink,
        declarations::{Textured, Typed, handle, record},
        values::MaybeTexture,
    },
    mirrors::MonitorState,
};

/// One of the user's own screens, as Lua holds it.
#[derive(Debug)]
pub struct Monitor<T> {
    key: MonitorKey,
    session: Rc<Session<T>>,
    known: RefCell<MonitorState>,
}

impl<T> Monitor<T> {
    pub(crate) fn new(session: Rc<Session<T>>, state: MonitorState) -> Self {
        Self {
            key: state.key.clone(),
            session,
            known: RefCell::new(state),
        }
    }

    /// Brings the cache up to date, reporting whether the monitor is attached.
    ///
    /// A monitor absent from the registry is unplugged. The handle is dead
    /// afterwards: it keeps answering from the last-known state, and every
    /// operation is refused.
    fn refresh(&self) -> bool {
        let Some(state) = self.session.mirrors().state(&self.key) else {
            return false;
        };
        *self.known.borrow_mut() = state;
        true
    }
}

handle! {
    /// One of the user's own screens, mirrored by direct capture or the
    /// screencast portal and not hosted by this compositor.
    Monitor<T: LuaTexture> = HandleKind::Monitor;

    /// The saved identity, and what a table of per-monitor state is keyed by.
    /// Stable across a restart and across the monitor moving to another port.
    field id(_lua, this) -> String { Ok(this.key.to_string()) }

    /// The identity as a user would recognise it, such as `Acme X24 on DP-1`.
    field name(_lua, this) -> String {
        this.refresh();
        Ok(this.known.borrow().name.clone())
    }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// Whether a capture stream is running for this monitor.
    field mirrored(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().mirrored)
    }

    /// Whether the active stream uses wlr-screencopy, with no portal selection.
    field directCapture(_lua, this) -> bool {
        Ok(this.refresh() && this.session.mirrors().is_direct(&this.key))
    }

    /// Whether a mirror has been asked for and has not arrived. True while a
    /// portal dialog is on the user's screen, and false once the user accepts
    /// or declines.
    field pending(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().pending)
    }

    /// The host-reported mode in pixels, not necessarily the captured texture
    /// size. Zero on both axes when the host reports no mode.
    field width(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().pixels.width)
    }

    field height(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().pixels.height)
    }

    /// Where the monitor is on the host desktop, in the compositor's logical
    /// coordinates and not in pixels. A pointer is placed in this space.
    field x(_lua, this) -> i32 {
        this.refresh();
        Ok(this.known.borrow().geometry.position.x)
    }

    field y(_lua, this) -> i32 {
        this.refresh();
        Ok(this.known.borrow().geometry.position.y)
    }

    field logicalWidth(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().geometry.size.width)
    }

    field logicalHeight(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().geometry.size.height)
    }

    /// The current frame's UV transform, or nil before a frame is installed.
    /// Undefined and normal sample unchanged; rotations and flips follow WayVR.
    field frameTransform(_lua, this) -> Option<CaptureTransform> {
        if !this.refresh() { return Ok(None); }
        Ok(this.session.with_monitor_textures(|textures| {
            textures.frame_transform(&this.key).map(CaptureTransform)
        }))
    }

    /// Where input for this monitor goes: a sink in the host domain, present
    /// whether or not the monitor is mirrored. Pointing at the host desktop
    /// does not require lunette to be showing it.
    field sink(_lua, this) -> Sink<T> {
        this.refresh();
        Ok(Sink::host(Rc::clone(&this.session), this.key.clone()))
    }

    /// The latest captured frame of this monitor. False while the monitor is
    /// gone, while it is not mirrored, or while it has produced no frame yet.
    /// Read again each frame rather than caching a rotating capture texture.
    method getTexture(lua, this: Textured) -> MaybeTexture { get_texture(lua, this) }

    /// Requests this screen to be captured, preferring direct capture. True
    /// once a stream is installed or requested, not necessarily producing.
    /// The portal fallback may prompt asynchronously.
    method mirror(_lua, this) -> bool { Ok(mirror(this)) }

    /// Removes the active mirror and texture. PipeWire joins its worker and
    /// keeps the portal session; the pinned direct worker may remain detached.
    method dismiss(_lua, this) -> bool { Ok(dismiss(this)) }

    /// Deactivates PipeWire without giving up its session. The pinned direct
    /// backend accepts the request but implements pause and resume as no-ops.
    method setPaused(_lua, this, paused: bool) -> bool { Ok(set_paused(this, paused)) }
}

#[derive(Debug)]
pub(crate) struct CaptureTransform(FrameTransform);

impl IntoLua for CaptureTransform {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        match self.0 {
            FrameTransform::Undefined => "undefined",
            FrameTransform::Normal => "normal",
            FrameTransform::Rotated90 => "rot90",
            FrameTransform::Rotated180 => "rot180",
            FrameTransform::Rotated270 => "rot270",
            FrameTransform::Flipped => "flipped",
            FrameTransform::Flipped90 => "flipped90",
            FrameTransform::Flipped180 => "flipped180",
            FrameTransform::Flipped270 => "flipped270",
        }
        .into_lua(lua)
    }
}

impl Typed for CaptureTransform {
    fn luau() -> Type {
        Type::literals(&[
            "undefined",
            "normal",
            "rot90",
            "rot180",
            "rot270",
            "flipped",
            "flipped90",
            "flipped180",
            "flipped270",
        ])
    }
}

/// Starts a fresh portal selection, retaining active capture until a successful grant.
pub(crate) fn select_monitors<T>(session: &Rc<Session<T>>) -> (bool, Option<String>) {
    match session.mirrors().select_monitors() {
        SelectionOutcome::Requested => (true, None),
        SelectionOutcome::Busy => (
            false,
            Some("monitor selection: a request is already pending".to_owned()),
        ),
        SelectionOutcome::NoMonitors => (
            false,
            Some("monitor selection: no host monitors are available".to_owned()),
        ),
        SelectionOutcome::Refused(error) => (false, Some(error.to_string())),
    }
}

/// Reports asynchronous selection progress without changing capture state.
pub(crate) fn monitor_selection<T>(session: &Rc<Session<T>>) -> MonitorSelection {
    let state = session.mirrors().selection_state();
    let message = match &state {
        SelectionState::Failed(error) => Some(error.to_string()),
        _ => None,
    };
    MonitorSelection {
        state: SelectionName(state),
        message,
    }
}

record! {
    /// The latest fresh monitor-selection request's state, independent of running capture.
    struct MonitorSelection {
        /// idle, pending, ready, or failed. Ready describes the portal grant, not a received frame.
        state: SelectionName,
        /// The portal error when state is failed.
        message: Option<String>,
    }
}

#[derive(Debug)]
pub(crate) struct SelectionName(SelectionState);

impl IntoLua for SelectionName {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        match self.0 {
            SelectionState::Idle => "idle",
            SelectionState::Pending => "pending",
            SelectionState::Ready => "ready",
            SelectionState::Failed(_) => "failed",
        }
        .into_lua(lua)
    }
}

impl Typed for SelectionName {
    fn luau() -> Type {
        Type::literals(&["idle", "pending", "ready", "failed"])
    }
}

/// `lunette.monitors()`: every screen lunette can mirror, this frame.
///
/// Sorted by identity and not by the order the host enumerated the monitors.
/// An arrangement derived from this list does not change when a cable is
/// replugged and nothing else has.
///
/// # Errors
///
/// If the table could not be built.
pub(crate) fn monitors<T: LuaTexture>(
    _lua: &mlua::Lua,
    session: &Rc<Session<T>>,
) -> mlua::Result<Vec<Monitor<T>>> {
    Ok(session
        .mirrors()
        .monitors()
        .into_iter()
        .map(|state| Monitor::new(Rc::clone(session), state))
        .collect())
}

/// `monitor:getTexture()`: the texture holding this monitor's latest frame.
///
/// Valid for this frame alone, for the same reason `window:getTexture()` is:
/// PipeWire cycles a small pool of buffers and the texture rotates with them.
/// Call it again each frame and do not cache it.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, monitor: &Monitor<T>) -> mlua::Result<MaybeTexture> {
    if !monitor.refresh() {
        return Ok(MaybeTexture(Value::Boolean(false)));
    }

    // The push runs while the ledger is borrowed. That is safe here and
    // nowhere else: it pushes a value, and no Lua the caller wrote runs until
    // it returns.
    monitor.session.with_monitor_textures(|textures| {
        textures
            .texture(&monitor.key)
            .map_or_else(|| Ok(Value::Boolean(false)), |texture| texture.push(lua))
            .map(MaybeTexture)
    })
}

/// `monitor:mirror()`: requests this screen to be captured.
///
/// Returns false when the portal refused the request or the monitor is gone.
fn mirror<T>(monitor: &Monitor<T>) -> bool {
    if !monitor.refresh() {
        return false;
    }

    match monitor.session.mirrors().mirror(&monitor.key) {
        MirrorOutcome::Mirroring | MirrorOutcome::AlreadyMirroring | MirrorOutcome::Requested => {
            true
        }
        MirrorOutcome::Refused(error) => {
            warn!(monitor = %monitor.key, %error, "a monitor could not be mirrored");
            false
        }
        // Unreachable through the refresh above, which establishes that the
        // registry holds this monitor.
        MirrorOutcome::NoSuchMonitor => false,
    }
}

/// `monitor:dismiss()`: removes the active mirror and texture.
///
/// PipeWire drops and joins its worker, retaining the portal session. The
/// pinned direct worker has no cancellation or joined-drop contract.
/// Returns false when no mirror was active.
fn dismiss<T>(monitor: &Monitor<T>) -> bool {
    monitor.session.mirrors().dismiss(&monitor.key)
}

/// `monitor:setPaused(paused)`: forwards the backend's pause request.
///
/// PipeWire changes stream activity while retaining its session. The pinned
/// direct backend's pause and resume methods are no-ops.
/// Returns false when no mirror was active.
fn set_paused<T>(monitor: &Monitor<T>, paused: bool) -> bool {
    monitor.session.mirrors().set_paused(&monitor.key, paused)
}
