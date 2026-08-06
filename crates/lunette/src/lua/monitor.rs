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
use mlua::{Table, UserData, UserDataFields, UserDataMethods};
use tracing::warn;

use crate::{
    lua::{LuaTexture, Session},
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

impl<T: LuaTexture> UserData for Monitor<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        // The saved identity, and what a Lua table of per-monitor state is keyed
        // by. Stable across a restart and across the monitor moving to another
        // port, which is what `lunette-v1.AC3.4` asks for.
        fields.add_field_method_get("id", |_, monitor| Ok(monitor.key.to_string()));

        // The identity as a user would recognise it: `Acme X24 on DP-1`.
        fields.add_field_method_get("name", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().name.clone())
        });

        fields.add_field_method_get("dead", |_, monitor| Ok(!monitor.refresh()));

        // Whether a capture stream is running for this monitor right now.
        fields.add_field_method_get("mirrored", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().mirrored)
        });

        // Whether a mirror has been asked for and has not arrived. True while a
        // portal dialog is on the user's screen, and false again whether they
        // accept or decline.
        fields.add_field_method_get("pending", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().pending)
        });

        // The monitor's resolution, which is the size a captured frame arrives
        // at. Zero on both axes when the host did not report a mode.
        fields.add_field_method_get("width", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().pixels.width)
        });

        fields.add_field_method_get("height", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().pixels.height)
        });

        // Where the monitor sits on the host desktop, and how large it is there,
        // in the compositor's logical coordinates. Not pixels: on a scaled
        // display the two differ by the scale factor, and a pointer is placed in
        // this space.
        fields.add_field_method_get("x", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().geometry.position.x)
        });

        fields.add_field_method_get("y", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().geometry.position.y)
        });

        fields.add_field_method_get("logicalWidth", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().geometry.size.width)
        });

        fields.add_field_method_get("logicalHeight", |_, monitor| {
            monitor.refresh();
            Ok(monitor.known.borrow().geometry.size.height)
        });
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("mirror", |_, monitor, ()| Ok(mirror(monitor)));
        methods.add_method("dismiss", |_, monitor, ()| Ok(dismiss(monitor)));
        methods.add_method("setPaused", |_, monitor, paused: bool| {
            Ok(set_paused(monitor, paused))
        });
    }
}

/// `lunette.monitors()`: every screen lunette can mirror, this frame.
///
/// Sorted by identity rather than by the order the host enumerated them, so an
/// arrangement derived from this list does not change when a cable is replugged
/// and nothing else has.
///
/// # Errors
///
/// If the table could not be built.
pub(crate) fn monitors<T: LuaTexture>(
    lua: &mlua::Lua,
    session: &Rc<Session<T>>,
) -> mlua::Result<Table> {
    let states = session.mirrors().monitors();
    let monitors = lua.create_table_with_capacity(states.len(), 0)?;

    for (index, state) in (1..).zip(states) {
        monitors.set(index, Monitor::new(Rc::clone(session), state))?;
    }

    Ok(monitors)
}

/// `monitor:mirror()`: asks for this screen to be captured.
///
/// Returns true once a stream is running or has been asked for, and false when
/// the portal refused outright or the monitor is gone. A dialog the user has not
/// answered yet is a true: the request was made, and `monitor.pending` is what
/// says it has not landed.
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

/// `monitor:dismiss()`: stops capturing this screen.
///
/// The stream is torn down rather than paused, so a dismissed monitor has no
/// ongoing cost. The portal session is kept, so `monitor:mirror()` afterwards
/// does not prompt again.
///
/// False when nothing was running, which is not an error: dismissing twice is
/// how a configuration says "make sure this is off".
fn dismiss<T>(monitor: &Monitor<T>) -> bool {
    monitor.session.mirrors().dismiss(&monitor.key)
}

/// `monitor:setPaused(paused)`: stops the stream without giving up the session.
///
/// For a panel that has left the user's view. Cheaper to undo than a dismissal
/// and more expensive to hold, which is the whole difference between the two.
///
/// False when no stream is running to pause.
fn set_paused<T>(monitor: &Monitor<T>, paused: bool) -> bool {
    monitor.session.mirrors().set_paused(&monitor.key, paused)
}
