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
//! `monitor:mirror()` may put a portal dialog on the user's screen, and nothing
//! waits for it. The call returns immediately and `monitor.mirrored` becomes
//! true some frames later, or never, if the user declines. A configuration that
//! treats mirroring as synchronous draws an empty panel.
//!
//! `monitor:dismiss()` stops the capture: the stream is torn down and the
//! monitor has no ongoing cost until it is mirrored again. The portal session
//! is kept, so mirroring again does not prompt.

use std::{cell::RefCell, rc::Rc};

use lunette_capture::{mirror::MirrorOutcome, monitor::MonitorKey};
use mlua::Value;
use tracing::warn;

use crate::{
    control::wire::HandleKind,
    lua::{
        LuaTexture, Session, Sink,
        declarations::{Textured, handle},
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
    /// One of the user's own screens, mirrored through the screencast portal
    /// and not hosted by this compositor.
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

    /// Whether a mirror has been asked for and has not arrived. True while a
    /// portal dialog is on the user's screen, and false once the user accepts
    /// or declines.
    field pending(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().pending)
    }

    /// The monitor's resolution, which is the size a captured frame arrives at.
    /// Zero on both axes when the host reports no mode.
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

    /// Where input for this monitor goes: a sink in the host domain, present
    /// whether or not the monitor is mirrored. Pointing at the host desktop
    /// does not require lunette to be showing it.
    field sink(_lua, this) -> Sink<T> {
        this.refresh();
        Ok(Sink::host(Rc::clone(&this.session), this.key.clone()))
    }

    /// The latest captured frame of this monitor. False while the monitor is
    /// gone, while it is not mirrored, or while it has produced no frame yet.
    /// These cases return `false` and not an error; a still desktop has no
    /// frame, because a monitor that is not changing sends nothing.
    method getTexture(lua, this: Textured) -> MaybeTexture { get_texture(lua, this) }

    /// Requests this screen to be captured. True once a stream is running or
    /// has been asked for. A dialog the user has not answered is a true, and
    /// `pending` reports the frame has not landed.
    method mirror(_lua, this) -> bool { Ok(mirror(this)) }

    /// Stops capturing this screen, tearing the stream down. The portal
    /// session is kept, so mirroring again does not prompt.
    method dismiss(_lua, this) -> bool { Ok(dismiss(this)) }

    /// Stops the stream without giving up the session, for a panel that has
    /// left the user's view.
    method setPaused(_lua, this, paused: bool) -> bool { Ok(set_paused(this, paused)) }
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

/// `monitor:dismiss()`: stops capturing this screen.
///
/// The stream is torn down and not paused, so a dismissed monitor has no
/// ongoing cost. The portal session is kept, so `monitor:mirror()` afterwards
/// does not prompt again.
///
/// False when no stream is running; that is not an error. A second dismissal
/// asserts that the monitor is off.
fn dismiss<T>(monitor: &Monitor<T>) -> bool {
    monitor.session.mirrors().dismiss(&monitor.key)
}

/// `monitor:setPaused(paused)`: stops the stream without giving up the
/// session, for a panel that has left the user's view.
///
/// Undoing a pause is cheaper than re-mirroring after a dismissal, and
/// holding a paused stream costs more than holding none. Pause and dismissal
/// differ in that trade.
///
/// False when no stream is running to pause.
fn set_paused<T>(monitor: &Monitor<T>, paused: bool) -> bool {
    monitor.session.mirrors().set_paused(&monitor.key, paused)
}
