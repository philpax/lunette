//! Linux-only: the input sink handle Lua holds.
//!
//! A sink takes pixel coordinates. Everything above it, the ray, the plane
//! intersection, and the conversion from a surface hit to a pixel, belongs to
//! Lua. `docs/dev/input.md` puts the native boundary exactly here for that reason:
//! Rust has no scene model, so any input method works without a change on this
//! side.
//!
//! # Two domains, one handle
//!
//! A sink names either a window this compositor hosts or one of the user's own
//! monitors. The two delivery paths differ entirely: a window's events go
//! through the compositor's seat, and a monitor's go through
//! `lunette-capture`'s `HidProvider` to the host desktop. A caller holds the
//! same kind of handle either way and reads `sink.domain` to learn which.
//!
//! The dispatch is an exhaustive match on [`SinkTarget`]; a flag approach
//! would permit a domain added later to go silently unhandled. Two sinks in
//! different domains are independent: pointing at a window and at a mirror in
//! the same frame reaches the client and the host, and neither reaches the
//! other.
//!
//! # What the host cannot do
//!
//! Every host sink shares one cursor and one keyboard focus, because the host
//! has one of each. `docs/dev/host-desktop.md` records why lunette exposes that
//! limitation. A key sent to a host sink reaches whatever the host compositor
//! currently focuses. A host key is translated under the layout of the seat it
//! addresses and reaches the host through `HidProvider::send_key`.
//!
//! A host sink does not deliver focus. Which window on the host desktop holds
//! the keyboard is the host compositor's decision, and lunette does not
//! attempt to change it.
//!
//! # Which seat
//!
//! Every method takes an optional trailing seat. Absent means the default
//! seat, the seat a configuration that never calls `lunette.newSeat` has. A
//! host sink ignores the argument, as `docs/guide/native-api.md` records: the host has
//! one cursor and one keyboard focus however many hands point at it.

use std::rc::Rc;

use lunette_capture::{
    hid::{PanelPoint, WheelDelta, XkbKeymap as HostKeymap},
    monitor::MonitorKey,
};
use lunette_compositor::{
    protocol::{
        Command, InputDomain, Keycode, ModifierState, PixelPoint, PointerButton,
        SURFACE_UNITS_PER_DETENT, ScrollAxis, ScrollDelta, SeatId, SinkId,
    },
    state::DEFAULT_SEAT,
};
use mlua::UserDataRef;

use crate::{
    control::wire::HandleKind,
    host::{host_button, host_key, host_modifiers},
    lua::{
        LuaTexture, Seat, Session,
        declarations::handle,
        keys::ModifierName,
        seat::read_modifiers,
        values::{PointerButtonName, SinkDomain},
    },
};

/// Somewhere pixel-space input can be delivered.
#[derive(Debug)]
pub struct Sink<T> {
    target: SinkTarget,
    session: Rc<Session<T>>,
}

/// Two handles are equal when they deliver to the same target.
impl<T> PartialEq for Sink<T> {
    fn eq(&self, other: &Self) -> bool {
        self.target == other.target
    }
}

/// What a sink names and how its input routes.
#[derive(Clone, Debug, PartialEq, Eq)]
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

    /// The compositor's identifier for a window sink.
    ///
    /// `None` for a host sink: a mirrored monitor is not a `wl_surface` and has
    /// nothing the compositor could address.
    pub(crate) const fn window_id(&self) -> Option<SinkId> {
        match self.target {
            SinkTarget::Window(id) => Some(id),
            SinkTarget::Host(_) => None,
        }
    }

    const fn domain(&self) -> InputDomain {
        match self.target {
            SinkTarget::Window(_) => InputDomain::Window,
            SinkTarget::Host(_) => InputDomain::Host,
        }
    }

    /// Whether the sink still has a live target.
    ///
    /// A window sink belongs to the window it names, so it is alive exactly
    /// while that window is in the snapshot. A host sink belongs to a monitor,
    /// so it is alive exactly while that monitor is attached, whether or not
    /// it is being mirrored: pointing at the host desktop does not require
    /// lunette to be showing it.
    ///
    /// Delivering to a sink whose target has gone is not an error a script
    /// must guard against: a client can exit, and a monitor can be unplugged,
    /// between the raycast and the click.
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

handle! {
    /// Somewhere pixel input can be delivered. `domain` names the pipeline
    /// its events travel: `window` or `host`.
    Sink<T: LuaTexture> = HandleKind::Sink;

    /// Whether the sink still has a live target. A window sink is alive
    /// while its window is in the snapshot, and a host sink while its monitor
    /// is attached.
    field dead(_lua, this) -> bool { Ok(!this.alive()) }

    /// Which pipeline this sink's events travel. The value is stored on the
    /// sink, so a list of sinks can report what each one reaches; the handle a
    /// sink came from does not reveal the domain.
    field domain(_lua, this) -> SinkDomain {
        Ok(SinkDomain(this.domain()))
    }

    /// The compositor's identifier for a window sink, and nothing for a host
    /// one: a mirrored monitor is not a `wl_surface` and has nothing the
    /// compositor could address.
    field id(_lua, this) -> Option<u64> {
        Ok(match &this.target {
            SinkTarget::Window(id) => Some(id.get()),
            SinkTarget::Host(_) => None,
        })
    }

    /// Moves the pointer to a pixel of the surface. The seat argument
    /// defaults to the seat every session starts with.
    method pointer(_lua, this, x: f64, y: f64, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let position = pixel_point(x, y)?;
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(pointer(this, seat, position))
    }

    /// Presses or releases a pointer button.
    method button(
        _lua,
        this,
        button: PointerButtonName,
        pressed: bool,
        seat: Option<UserDataRef<Seat<T>>>,
    ) -> bool {
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(button_pressed(this, seat, button.0, pressed))
    }

    /// Takes the pointer off this sink, ending a hover.
    method leave(_lua, this, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(leave(this, seat))
    }

    /// Scrolls by a distance in surface pixels.
    method scroll(_lua, this, dx: f64, dy: f64, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let (dx, dy) = scroll_delta(dx, dy)?;
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(scroll(this, seat, dx, dy))
    }

    /// Presses or releases an evdev keycode on the seat's keyboard.
    method key(_lua, this, key: u32, pressed: bool, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(key_pressed(this, seat, Keycode::from_evdev(key), pressed))
    }

    /// Enters text, which the seat resolves to the strokes that produce it.
    method typeText(_lua, this, text: String, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(type_text(this, seat, text))
    }

    /// Sets which modifiers the seat holds while delivering to this sink.
    method setModifiers(
        _lua,
        this,
        names: Option<Vec<ModifierName>>,
        seat: Option<UserDataRef<Seat<T>>>,
    ) -> bool {
        let modifiers = read_modifiers(names.as_deref());
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(modifiers_held(this, seat, &modifiers))
    }
}

/// Which seat an argument named. The default is the seat every session starts
/// with.
///
/// A configuration that never calls `lunette.newSeat` addresses the default
/// seat by leaving the argument off. This keeps the single-handed examples in
/// `docs/dev/input.md` correct.
fn seat_of<T: LuaTexture>(seat: Option<&Seat<T>>) -> SeatId {
    seat.map_or(DEFAULT_SEAT, Seat::id)
}

/// `sink:pointer(x, y)`: moves the pointer to a pixel coordinate on this sink.
///
/// The exhaustive match is the routing. A window's position goes to the
/// compositor as a queued command, flushed at frame end. A monitor's position
/// is normalised over the monitor's own resolution and passed to the host
/// desktop, which maps it into that monitor's logical rectangle.
fn pointer<T>(sink: &Sink<T>, seat: SeatId, position: PixelPoint) -> bool {
    match &sink.target {
        SinkTarget::Window(id) => {
            sink.session.queue(Command::Pointer {
                seat,
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

/// `sink:button(name, pressed, seat)`: presses or releases a button on this
/// sink.
fn button_pressed<T>(sink: &Sink<T>, seat: SeatId, button: PointerButton, pressed: bool) -> bool {
    match &sink.target {
        SinkTarget::Window(id) => {
            sink.session.queue(Command::Button {
                seat,
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

/// `sink:leave(seat)`: takes a seat's pointer off whatever it is over.
///
/// Leaving ends a hover. Focus stays where it is: a panel library highlights
/// what a hand is pointing at without that hand taking the keyboard from the
/// other one, and a compositor inferring focus from motion makes this
/// impossible.
///
/// A host sink returns false: the host cursor is always somewhere on the
/// host desktop, and no position means "nowhere". A dead handle returns
/// false too, as every method does: the compositor withdraws a window's
/// pointer when its client exits, so success would report a withdrawal that
/// did not happen.
fn leave<T>(sink: &Sink<T>, seat: SeatId) -> bool {
    match &sink.target {
        SinkTarget::Window(_) => {
            sink.session.queue(Command::PointerLeave { seat });
            true
        }
        SinkTarget::Host(_) => false,
    }
}

/// `sink:scroll(dx, dy, seat)`: scrolls by a distance in surface pixels.
///
/// Two axes arrive in one call: a caller has them together, as a thumbstick
/// deflection or a trackpad delta, and two requests would make a diagonal
/// scroll arrive as two separate gestures. An axis whose delta is zero sends
/// nothing.
///
/// The host takes the vertical axis. `HidProvider::wheel` is one number,
/// the form both `zwlr_virtual_pointer_v1`'s axis request and uinput's
/// `REL_WHEEL` carry.
fn scroll<T>(sink: &Sink<T>, seat: SeatId, horizontal: f64, vertical: f64) -> bool {
    match &sink.target {
        SinkTarget::Window(id) => {
            for (axis, delta) in [
                (ScrollAxis::Horizontal, horizontal),
                (ScrollAxis::Vertical, vertical),
            ] {
                if delta == 0.0 {
                    continue;
                }
                sink.session.queue(Command::Scroll {
                    seat,
                    sink: *id,
                    axis,
                    delta: ScrollDelta::Continuous(delta),
                });
            }
            true
        }
        SinkTarget::Host(_) => {
            let delta = WheelDelta::new(detents(horizontal), detents(vertical));
            if delta.is_zero() {
                return true;
            }
            sink.session.host().wheel(delta);
            true
        }
    }
}

/// A scroll distance in the detents the host provider counts in.
///
/// The inverse of the compositor's conversion: the compositor multiplies a
/// detent count by `SURFACE_UNITS_PER_DETENT`, and this divides a distance by
/// the same constant.
fn detents(distance: f64) -> f64 {
    distance / SURFACE_UNITS_PER_DETENT
}

/// `sink:key(keycode, pressed, seat)`: presses or releases a key.
///
/// The window path reaches the seat's keyboard, and so reaches whichever client
/// that seat is focused on. The window path does not set the focus; a seat
/// with no focus delivers to nobody.
///
/// On a host sink the key is translated under the seat's layout. The layout is
/// uploaded to the host first: `zwp_virtual_keyboard_v1` treats a key before a
/// keymap as a protocol error and disconnects the provider, so the provider
/// would drop its first keystroke otherwise. A keycode the provider never
/// declared is refused, because the kernel would drop that key.
fn key_pressed<T>(sink: &Sink<T>, seat: SeatId, key: Keycode, pressed: bool) -> bool {
    match &sink.target {
        SinkTarget::Window(_) => {
            sink.session.queue(Command::Key { seat, key, pressed });
            true
        }
        SinkTarget::Host(_) => {
            let Some(key) = host_key(key) else {
                return false;
            };
            if !upload_layout(sink, seat) {
                return false;
            }
            sink.session.host().key(key, pressed)
        }
    }
}

/// `sink:setModifiers(names, seat)`: replaces the modifiers held on this sink.
///
/// Modifiers are explicit state: the caller names them with `sink:setModifiers`,
/// they are not synthesised keypresses. `docs/dev/input.md` requires that on the
/// window side, and the host provider already implements it on the other.
fn modifiers_held<T>(sink: &Sink<T>, seat: SeatId, modifiers: &ModifierState) -> bool {
    match &sink.target {
        SinkTarget::Window(_) => {
            sink.session.queue(Command::Modifiers {
                seat,
                modifiers: modifiers.clone(),
            });
            true
        }
        SinkTarget::Host(_) => {
            let Some(modifiers) = host_modifiers(modifiers) else {
                return false;
            };
            if !upload_layout(sink, seat) {
                return false;
            }
            sink.session.host().modifiers(modifiers)
        }
    }
}

/// `sink:typeText(text, seat)`: enters text the active layout may not express.
///
/// The method is stateful: it generates and uploads a temporary keymap, so it
/// must not be interleaved with `sink:key` on the same seat. It exists for
/// text the active layout may not express, in the roles `docs/dev/input.md`
/// records: clipboard-less paste, dictation, and `lunctl` running a command
/// in a terminal.
///
/// A host sink returns false. The technique needs a keymap that can be
/// uploaded and then taken back, but lunette does not own the host's keyboard
/// well enough to guarantee the second half: another application may set its
/// own layout in between, and a host left holding lunette's synthetic one is a
/// desktop whose keyboard has stopped working.
fn type_text<T>(sink: &Sink<T>, seat: SeatId, text: String) -> bool {
    match &sink.target {
        SinkTarget::Window(_) => {
            sink.session.queue(Command::TypeText { seat, text });
            true
        }
        SinkTarget::Host(_) => false,
    }
}

/// Gives the host the layout a seat's keycodes should be read under.
///
/// Upload happens before every host keystroke, not once at startup. The
/// provider itself skips an upload that would change nothing, so the
/// repetition costs a comparison. A seat whose layout changed then reaches
/// the host with that layout.
///
/// Returns false when the seat is not in this frame's snapshot; in that case
/// there is no layout to send.
fn upload_layout<T>(sink: &Sink<T>, seat: SeatId) -> bool {
    let snapshot = sink.session.snapshot();
    let Some(entry) = snapshot.seats.iter().find(|entry| entry.seat == seat) else {
        return false;
    };
    let Some(keymap) = HostKeymap::new(entry.keymap.as_str()) else {
        return false;
    };

    sink.session.host().set_keymap(&keymap)
}

/// Turns a pixel coordinate on a mirrored monitor into a hit on its surface.
///
/// Returns `None` for a monitor whose resolution the host did not report. The
/// division cannot be done without a size, and assuming one would put the
/// cursor somewhere arbitrary.
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

/// Checks a scroll delta before it is sent.
///
/// A `NaN` here is a defect in the caller's maths for the reason a `NaN`
/// coordinate is, and a client that receives one scrolls to an undefined place.
fn scroll_delta(dx: f64, dy: f64) -> mlua::Result<(f64, f64)> {
    if !dx.is_finite() || !dy.is_finite() {
        return Err(mlua::Error::runtime(format!(
            "lunette: ({dx}, {dy}) is not a scroll distance"
        )));
    }

    Ok((dx, dy))
}

/// Checks a coordinate before it is sent to a client.
///
/// A `NaN` reaching a client's pointer handler is a defect in the caller's
/// maths, usually an intersection against a degenerate plane. Reporting it at
/// the source stops a toolkit from deciding what to do with it. Validation
/// runs before the liveness check, so a typo is reported whether or not the
/// window is still there.
fn pixel_point(x: f64, y: f64) -> mlua::Result<PixelPoint> {
    if !x.is_finite() || !y.is_finite() {
        return Err(mlua::Error::runtime(format!(
            "lunette: ({x}, {y}) is not a pixel coordinate"
        )));
    }

    Ok(PixelPoint::new(x, y))
}
