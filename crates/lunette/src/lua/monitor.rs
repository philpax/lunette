//! Linux-only: the monitor handle Lua holds.
//!
//! A monitor is one of the user's own screens, not a window lunette hosts. The
//! handle names it by the identity `lunette-capture` resolved — a make and model
//! where the host reports one, a connector name where it does not — and reads
//! through to the mirror lifecycle on every access, for the reason
//! [`crate::lua::Window`] does: Rust holds no reference into Lua, so it cannot
//! walk the handles Lua is keeping at frame start.
//!
//! # Mirroring is a request
//!
//! `monitor:mirror()` may put a portal dialog on the user's screen, and nothing
//! waits for it. The call returns immediately and `monitor.mirrored` becomes
//! true some frames later, or never, if the user declines. A configuration that
//! treats mirroring as synchronous will draw an empty panel.
//!
//! `monitor:dismiss()` stops the capture for real: the stream is torn down and
//! the monitor costs nothing until it is mirrored again. The portal session is
//! kept, so re-adding does not prompt.

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

/// One of the host's screens, as Lua holds it.
#[derive(Debug)]
pub struct Monitor<T> {
    key: MonitorKey,
    session: Rc<Session<T>>,
    known: RefCell<MonitorState>,
}

impl<T> Monitor<T> {
    /// Builds a handle from the state it was found in.
    pub(crate) fn new(session: Rc<Session<T>>, state: MonitorState) -> Self {
        Self {
            key: state.key.clone(),
            session,
            known: RefCell::new(state),
        }
    }

    /// Brings the cache up to date, reporting whether the monitor is attached.
    ///
    /// A monitor absent from the registry has been unplugged. The handle is dead
    /// afterwards: it keeps answering with what it last knew, and every
    /// operation it offers is refused.
    fn refresh(&self) -> bool {
        let Some(state) = self.session.mirrors().state(&self.key) else {
            return false;
        };
        *self.known.borrow_mut() = state;
        true
    }
}

handle! {
    /// One of the user's screens, mirrored through the screencast portal.
    Monitor<T: LuaTexture> = HandleKind::Monitor;

    /// The monitor's stable identity, suitable for persistent per-monitor state.
    field id(_lua, this) -> String { Ok(this.key.to_string()) }

    /// A user-facing monitor name.
    field name(_lua, this) -> String {
        this.refresh();
        Ok(this.known.borrow().name.clone())
    }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// Whether a capture stream is running.
    field mirrored(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().mirrored)
    }

    /// Whether capture was requested but has not started.
    field pending(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().pending)
    }

    /// The captured frame width in pixels.
    field width(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().pixels.width)
    }

    field height(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().pixels.height)
    }

    /// The monitor's logical desktop position.
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

    /// The host sink receiving input for this monitor.
    field sink(_lua, this) -> Sink<T> {
        this.refresh();
        Ok(Sink::host(Rc::clone(&this.session), this.key.clone()))
    }

    /// The latest captured frame, or false if none is available.
    method getTexture(lua, this: Textured) -> MaybeTexture { get_texture(lua, this) }

    /// Requests capture; returns true once requested, including while authorization is pending.
    method mirror(_lua, this) -> bool { Ok(mirror(this)) }

    /// Stops capture while retaining the portal session.
    method dismiss(_lua, this) -> bool { Ok(dismiss(this)) }

    /// Pauses or resumes the capture stream without ending the session.
    method setPaused(_lua, this, paused: bool) -> bool { Ok(set_paused(this, paused)) }
}

/// Returns every screen lunette can mirror in stable identity order.
///
/// # Errors
///
/// If the monitor list cannot be built.
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

/// Returns the monitor's latest texture for this frame, or false if no frame is available.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, monitor: &Monitor<T>) -> mlua::Result<MaybeTexture> {
    if !monitor.refresh() {
        return Ok(MaybeTexture(Value::Boolean(false)));
    }

    // The push runs while the ledger is borrowed. That is safe here and only
    // here: it pushes a value, and no Lua the caller wrote runs until it
    // returns.
    monitor.session.with_monitor_textures(|textures| {
        textures
            .texture(&monitor.key)
            .map_or_else(|| Ok(Value::Boolean(false)), |texture| texture.push(lua))
            .map(MaybeTexture)
    })
}

/// Requests capture and returns whether the request was accepted or is pending.
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
        // Unreachable through the refresh above, which is what establishes that
        // the registry knows this monitor.
        MirrorOutcome::NoSuchMonitor => false,
    }
}

/// Stops capture and retains the portal session; returns false if no stream was running.
fn dismiss<T>(monitor: &Monitor<T>) -> bool {
    monitor.session.mirrors().dismiss(&monitor.key)
}

/// Pauses or resumes capture without ending the portal session.
fn set_paused<T>(monitor: &Monitor<T>, paused: bool) -> bool {
    monitor.session.mirrors().set_paused(&monitor.key, paused)
}
