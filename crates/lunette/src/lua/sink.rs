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
//!
//! A key sent to a host sink reaches the host through `HidProvider::send_key`,
//! under the layout of the seat it was
//! addressed to — uploaded to the host first, because
//! `zwp_virtual_keyboard_v1` treats a key sent before a keymap as a protocol
//! error and disconnects the provider.
//!
//! Focus is the one thing a host sink refuses. Which window on the host desktop
//! holds the keyboard is the host compositor's decision, and lunette does not
//! get a say in it.
//!
//! # Which seat
//!
//! Every method takes an optional trailing seat. Absent means the default seat,
//! which is the one a configuration that never called `lunette.newSeat` has.
//! A host sink ignores it and says so in `docs/lua-api.md`: the host has one
//! cursor and one keyboard focus however many hands point at it.

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
        LuaTexture, Monitor, Seat, Session, Window,
        declarations::{Nil, handle},
        seat::read_modifiers,
        values::{HostDomain, PointerButtonName, SinkDomain, WindowDomain},
    },
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

handle! {
    /// Somewhere pixel input can be delivered. Discriminated on `domain`, which is what says whether `window` or `monitor` names something: testing it is how a caller reaches the handle behind a sink without a nil check that cannot fail.
    Sink<T: LuaTexture> = HandleKind::Sink, variants = [WindowSink, HostSink];

    /// Whether anything is still listening. A window sink is alive while its window is in the snapshot, and a host sink while its monitor is attached.
    field dead(_lua, this) -> bool { Ok(!this.alive()) }

    /// Which pipeline this sink's events travel. Read rather than inferred from the handle it came from, so a list of sinks can report what each one reaches.
    field domain(_lua, this) -> SinkDomain as [WindowDomain, HostDomain] {
        Ok(SinkDomain(this.domain()))
    }

    /// The compositor's identifier for a window sink, and nothing for a host one: a mirrored monitor is not a `wl_surface` and has nothing the compositor could address.
    field id(_lua, this) -> Option<u64> {
        Ok(match &this.target {
            SinkTarget::Window(id) => Some(id.get()),
            SinkTarget::Host(_) => None,
        })
    }

    /// The window this sink reaches. A fresh handle each read: it holds an identifier and an `Rc`, so there is nothing to gain by caching one and a stale cache to lose.
    field window(_lua, this) -> Option<Window<T>> as [Option<Window<T>>, Nil] {
        let SinkTarget::Window(id) = &this.target else {
            return Ok(None);
        };
        let snapshot = this.session.snapshot();
        Ok(snapshot
            .windows
            .iter()
            .find(|window| window.sink == *id)
            .map(|window| Window::new(Rc::clone(&this.session), window)))
    }

    /// The monitor this sink reaches, behind which is the user's own desktop.
    field monitor(_lua, this) -> Option<Monitor<T>> as [Nil, Option<Monitor<T>>] {
        let SinkTarget::Host(monitor) = &this.target else {
            return Ok(None);
        };
        Ok(this
            .session
            .mirrors()
            .state(monitor)
            .map(|state| Monitor::new(Rc::clone(&this.session), state)))
    }

    /// Moves the pointer to a pixel of the surface. The seat defaults to the one every session starts with.
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

    /// Takes the pointer off this sink, which is what ends a hover.
    method leave(_lua, this, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(leave(this, seat))
    }

    /// Scrolls by a distance in surface pixels. A client uses the difference from `scrollDiscrete` to decide whether to scroll kinetically.
    method scroll(_lua, this, dx: f64, dy: f64, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let (dx, dy) = scroll_delta(dx, dy)?;
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(scroll(
            this,
            seat,
            ScrollDelta::Continuous(dx),
            ScrollDelta::Continuous(dy),
        ))
    }

    /// Scrolls by whole wheel clicks.
    method scrollDiscrete(_lua, this, dx: i32, dy: i32, seat: Option<UserDataRef<Seat<T>>>) -> bool {
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(scroll(
            this,
            seat,
            ScrollDelta::Discrete(dx),
            ScrollDelta::Discrete(dy),
        ))
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
    method modifiers(
        _lua,
        this,
        names: Option<Vec<String>>,
        seat: Option<UserDataRef<Seat<T>>>,
    ) -> bool {
        let modifiers = read_modifiers(names.as_deref())?;
        let seat = seat_of(seat.as_deref());
        if !this.alive() {
            return Ok(false);
        }
        Ok(modifiers_held(this, seat, &modifiers))
    }
}

/// Which seat an argument named, defaulting to the one every session has.
///
/// A configuration that never called `lunette.newSeat` addresses the default
/// seat by leaving the argument off, which is what keeps the single-handed
/// examples in `docs/input.md` correct.
fn seat_of<T: LuaTexture>(seat: Option<&Seat<T>>) -> SeatId {
    seat.map_or(DEFAULT_SEAT, Seat::id)
}

/// `sink:pointer(x, y)`: moves the pointer to a pixel coordinate on this sink.
///
/// The exhaustive match is the routing. A window's position goes to the
/// compositor as a queued command, flushed at frame end; a monitor's is
/// normalised over the monitor's own resolution and handed to the host desktop,
/// which maps it into that monitor's logical rectangle.
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
/// Hover, not focus. A panel library highlights what a hand is pointing at
/// without that hand taking the keyboard from the other one, which is exactly
/// what a compositor inferring focus from motion makes impossible.
///
/// Refused on a host sink: the host cursor is always somewhere on the host
/// desktop, and there is no position that means "nowhere". Refused on a dead
/// handle too, like every other method: a window whose client has exited has
/// already had its pointer withdrawn, and reporting success would tell a caller
/// something happened that did not.
fn leave<T>(sink: &Sink<T>, seat: SeatId) -> bool {
    match &sink.target {
        SinkTarget::Window(_) => {
            sink.session.queue(Command::PointerLeave { seat });
            true
        }
        SinkTarget::Host(_) => false,
    }
}

/// `sink:scroll(dx, dy, seat)` and `sink:scrollDiscrete(dx, dy, seat)`.
///
/// Two axes in one call because that is how a caller has them — a thumbstick
/// deflection, a trackpad delta — and two requests would make a diagonal scroll
/// arrive as two separate gestures. An axis whose delta is zero sends nothing.
///
/// The host takes only the vertical axis: `HidProvider::wheel` is one number,
/// which is what both `zwlr_virtual_pointer_v1`'s axis request and uinput's
/// `REL_WHEEL` carry in the form the providers were built around.
fn scroll<T>(sink: &Sink<T>, seat: SeatId, horizontal: ScrollDelta, vertical: ScrollDelta) -> bool {
    match &sink.target {
        SinkTarget::Window(id) => {
            for (axis, delta) in [
                (ScrollAxis::Horizontal, horizontal),
                (ScrollAxis::Vertical, vertical),
            ] {
                if is_still(delta) {
                    continue;
                }
                sink.session.queue(Command::Scroll {
                    seat,
                    sink: *id,
                    axis,
                    delta,
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

/// Whether a scroll delta asks for nothing.
fn is_still(delta: ScrollDelta) -> bool {
    match delta {
        ScrollDelta::Continuous(distance) => distance == 0.0,
        ScrollDelta::Discrete(steps) => steps == 0,
    }
}

/// A scroll delta in the detents the host provider counts in.
///
/// The inverse of what the compositor does to a discrete count on its way to a
/// client, so it divides by the same constant that path multiplies by. A
/// discrete count is already detents.
fn detents(delta: ScrollDelta) -> f64 {
    match delta {
        ScrollDelta::Continuous(distance) => distance / SURFACE_UNITS_PER_DETENT,
        ScrollDelta::Discrete(steps) => f64::from(steps),
    }
}

/// `sink:key(keycode, pressed, seat)`: presses or releases a key.
///
/// The window path reaches the seat's keyboard, and so reaches whichever client
/// that seat is focused on — nothing here chooses that, and a seat with no
/// focus delivers to nobody.
///
/// The seat's layout is uploaded to the host first: `zwp_virtual_keyboard_v1`
/// treats a key before a keymap as a
/// protocol error, so the provider would be disconnected by its very first
/// keystroke otherwise. A keycode the provider never declared is refused rather
/// than sent, because the kernel would drop it without a word.
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

/// `sink:modifiers(names, seat)`: replaces the modifiers held on this sink.
///
/// Explicit state rather than synthesised keypresses, which is what
/// `docs/input.md:51` asks for on the window side and what the host provider
/// already implements on the other.
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
/// An escape hatch, and explicitly stateful: it generates and uploads a
/// temporary keymap, so it must not be interleaved with `sink:key` on the same
/// seat. `docs/input.md:58-62` records what it is for — clipboard-less paste,
/// dictation, and `lunctl` telling a terminal to run a command.
///
/// Refused on a host sink. The technique needs a keymap that can be uploaded
/// and then taken back, and lunette does not own the host's keyboard well
/// enough to promise the second half: another application may set its own
/// layout in between, and a host left holding lunette's synthetic one is a
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
/// Called before every host keystroke rather than once at startup. The provider
/// itself skips an upload that would change nothing, so the repetition costs a
/// comparison; doing it here is what makes a seat whose layout changed reach
/// the host with the layout it actually has.
///
/// False when the seat is not in this frame's snapshot, which is the one case
/// where there is no layout to send.
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
