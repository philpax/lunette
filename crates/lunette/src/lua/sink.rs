//! Linux-only: the input sink handle Lua holds.
//!
//! A sink takes pixel coordinates. Everything above it — the ray, the plane
//! intersection, the conversion from a surface hit to a pixel — is Lua's, and
//! is why `docs/input.md` puts the native boundary exactly here: Rust knows
//! nothing about the scene, so an input method it has never heard of works
//! without a change on this side.
//!
//! # Two domains, one handle
//!
//! A sink names either a window this compositor hosts or one of the user's own
//! monitors, and the two route down entirely different pipelines: a window's
//! events go through the compositor's seat, and a monitor's go through
//! `lunette-capture`'s `HidProvider` to the host desktop. A caller holds the
//! same kind of handle either way, and `sink.domain` is how it asks which.
//!
//! The dispatch is an exhaustive match on [`SinkTarget`] rather than a flag, so
//! a domain added later cannot be silently unhandled. Two sinks in different
//! domains are independent: pointing at a window and at a mirror in the same
//! frame reaches the client and the host, and neither reaches the other.
//!
//! # What the host cannot do
//!
//! Every host sink shares one cursor and one keyboard focus, because the host
//! has one of each. `docs/host-desktop.md` records why that is exposed rather
//! than papered over. A key sent to a host sink reaches whatever the host
//! compositor currently focuses, and lunette does not choose what that is and
//! must not try.

use std::rc::Rc;

use lunette_capture::{hid::PanelPoint, monitor::MonitorKey};
use lunette_compositor::{
    protocol::{Command, InputDomain, PixelPoint, PointerButton, SinkId},
    state::DEFAULT_SEAT,
};
use mlua::{UserData, UserDataFields, UserDataMethods};

use crate::{
    host::host_button,
    lua::{LuaTexture, Monitor, POINTER_BUTTONS, Session, Window, pointer_button},
};

/// Somewhere pixel-space input can be delivered.
#[derive(Debug)]
pub struct Sink<T> {
    target: SinkTarget,
    session: Rc<Session<T>>,
}

/// What a sink names, and so how its input routes.
#[derive(Clone, Debug)]
enum SinkTarget {
    /// A surface this compositor hosts.
    Window(SinkId),
    /// One of the user's own screens, mirrored.
    Host(MonitorKey),
}

impl<T> Sink<T> {
    /// A sink delivering to a window this compositor hosts.
    pub(crate) fn window(session: Rc<Session<T>>, id: SinkId) -> Self {
        Self {
            target: SinkTarget::Window(id),
            session,
        }
    }

    /// A sink delivering to the host desktop, behind a mirrored monitor.
    pub(crate) fn host(session: Rc<Session<T>>, monitor: MonitorKey) -> Self {
        Self {
            target: SinkTarget::Host(monitor),
            session,
        }
    }

    const fn domain(&self) -> InputDomain {
        match self.target {
            SinkTarget::Window(_) => InputDomain::Window,
            SinkTarget::Host(_) => InputDomain::Host,
        }
    }

    /// Whether anything is still listening.
    ///
    /// A window sink belongs to the window that owns it, so it is alive exactly
    /// while that window is in the snapshot. A host sink belongs to a monitor,
    /// so it is alive exactly while that monitor is attached — whether or not it
    /// is being mirrored, because pointing at the host desktop does not require
    /// lunette to be showing it.
    ///
    /// Delivering to a sink whose target has gone is not an error a script
    /// should have to guard against: a client can exit, and a monitor can be
    /// unplugged, between the raycast and the click.
    fn alive(&self) -> bool {
        match &self.target {
            SinkTarget::Window(id) => self
                .session
                .snapshot()
                .windows
                .iter()
                .any(|window| window.sink == *id),
            SinkTarget::Host(monitor) => self.session.mirrors().state(monitor).is_some(),
        }
    }
}

impl<T: LuaTexture> UserData for Sink<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        // Which pipeline this sink's events travel: 'window' or 'host'. Read
        // rather than inferred from the handle it came from, so a panel library
        // holding a list of sinks can report what each one reaches.
        fields.add_field_method_get("domain", |_, sink| Ok(sink.domain().as_str()));

        // The compositor's identifier for a window sink, and nil for a host one:
        // a mirrored monitor is not a `wl_surface` and has no such identifier.
        // `sink.monitor` is what names a host sink.
        fields.add_field_method_get("id", |_, sink| {
            Ok(match &sink.target {
                SinkTarget::Window(id) => Some(id.get()),
                SinkTarget::Host(_) => None,
            })
        });

        // The monitor a host sink reaches, and nil for a window sink. A fresh
        // handle each read, for the reason `window.sink` is: it holds an
        // identity and an `Rc`, so there is nothing to gain by caching one and a
        // stale cache to lose.
        fields.add_field_method_get("monitor", |_, sink| {
            let SinkTarget::Host(monitor) = &sink.target else {
                return Ok(None);
            };
            Ok(sink
                .session
                .mirrors()
                .state(monitor)
                .map(|state| Monitor::new(Rc::clone(&sink.session), state)))
        });

        // The window a window sink reaches, and nil for a host sink.
        fields.add_field_method_get("window", |_, sink| {
            let SinkTarget::Window(id) = &sink.target else {
                return Ok(None);
            };
            let snapshot = sink.session.snapshot();
            Ok(snapshot
                .windows
                .iter()
                .find(|window| window.sink == *id)
                .map(|window| Window::new(Rc::clone(&sink.session), window)))
        });

        fields.add_field_method_get("dead", |_, sink| Ok(!sink.alive()));
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("pointer", |_, sink, (x, y): (f64, f64)| {
            let position = pixel_point(x, y)?;
            if !sink.alive() {
                return Ok(false);
            }
            Ok(pointer(sink, position))
        });

        methods.add_method(
            "button",
            |_, sink, (name, pressed): (mlua::LuaString, bool)| {
                let name = name.to_string_lossy();
                let button = pointer_button(&name).ok_or_else(|| {
                    mlua::Error::runtime(format!(
                        "lunette: '{name}' is not a pointer button; the buttons are \
                         {POINTER_BUTTONS}"
                    ))
                })?;
                if !sink.alive() {
                    return Ok(false);
                }
                Ok(button_pressed(sink, button, pressed))
            },
        );
    }
}

/// `sink:pointer(x, y)`: moves the pointer to a pixel coordinate on this sink.
///
/// The exhaustive match is the routing. A window's position goes to the
/// compositor as a queued command, flushed at frame end; a monitor's is
/// normalised over the monitor's own resolution and handed to the host desktop,
/// which maps it into that monitor's logical rectangle.
fn pointer<T>(sink: &Sink<T>, position: PixelPoint) -> bool {
    match &sink.target {
        SinkTarget::Window(id) => {
            sink.session.queue(Command::Pointer {
                seat: DEFAULT_SEAT,
                sink: *id,
                position,
            });
            true
        }
        SinkTarget::Host(monitor) => {
            let Some(hit) = normalise(sink, monitor, position) else {
                return false;
            };
            sink.session.host().pointer(monitor, hit)
        }
    }
}

/// `sink:button(name, pressed)`: presses or releases a button on this sink.
fn button_pressed<T>(sink: &Sink<T>, button: PointerButton, pressed: bool) -> bool {
    match &sink.target {
        SinkTarget::Window(id) => {
            sink.session.queue(Command::Button {
                seat: DEFAULT_SEAT,
                sink: *id,
                button,
                pressed,
            });
            true
        }
        SinkTarget::Host(_) => {
            sink.session.host().button(host_button(button), pressed);
            true
        }
    }
}

/// Turns a pixel coordinate on a mirrored monitor into a hit on its surface.
///
/// `None` for a monitor whose resolution the host did not report, which is the
/// one case the division cannot be done in: there is no size to normalise
/// against, and assuming one would put the cursor somewhere arbitrary.
fn normalise<T>(sink: &Sink<T>, monitor: &MonitorKey, position: PixelPoint) -> Option<PanelPoint> {
    let pixels = sink.session.mirrors().state(monitor)?.pixels;
    if pixels.is_empty() {
        return None;
    }

    Some(PanelPoint::new(
        position.x / f64::from(pixels.width),
        position.y / f64::from(pixels.height),
    ))
}

/// Checks a coordinate before it is sent to a client.
///
/// A `NaN` reaching a client's pointer handler is a defect in the caller's
/// maths — an intersection against a degenerate plane, usually — and it is
/// worth reporting where it was produced rather than letting a toolkit decide
/// what to do with it. Validated before the liveness check, so a typo is
/// reported whether or not the window happens to still be there.
fn pixel_point(x: f64, y: f64) -> mlua::Result<PixelPoint> {
    if !x.is_finite() || !y.is_finite() {
        return Err(mlua::Error::runtime(format!(
            "lunette: ({x}, {y}) is not a pixel coordinate"
        )));
    }

    Ok(PixelPoint::new(x, y))
}
