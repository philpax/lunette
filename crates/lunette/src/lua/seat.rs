//! Linux-only: the seat handle Lua holds.
//!
//! A `wl_seat` carries exactly one pointer and one keyboard, so two cursors need
//! two seats and the protocol offers nothing else. WayVR has one, which is why
//! pointing the off hand at a window steals hover from the main hand;
//! `lunette.newSeat` is the primitive that removes that limit, and the
//! collapse-to-one-seat mode `docs/input.md:39` describes is Lua policy over it
//! rather than a mode here.
//!
//! # What the keymap queries are for
//!
//! `docs/input.md:47-54` records the shape of the problem: Wayland clients want
//! an xkb keymap plus raw keycodes and do their own keysym translation, so
//! anything drawing a keyboard has to be able to ask what a key means. The three
//! queries here — the layout list, forward lookup, and reverse lookup — are
//! what let mullion draw a virtual keyboard with correct legends and produce
//! correct keycodes without reimplementing xkb in Lua.
//!
//! Every answer comes from the seat's own published layout, compiled on this
//! thread. The compositor cannot hand over a compiled keymap: libxkbcommon is
//! not thread-safe, so what crosses is text and each side compiles its own.
//!
//! # Focus is applied here, never decided here
//!
//! `seat:setFocus(sink)` is a request the caller makes deliberately. Nothing
//! infers focus from pointer motion, which is what WayVR does and what makes a
//! second hand steal focus by hovering.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::{
    keymap::{KeyStroke, Keymap},
    protocol::{
        Command, KeyModifier, KeyboardConfig, Keycode, KeymapConfig, Keysym, ModifierState,
        RepeatDelay, RepeatPolicy, RepeatRate, SeatId, SeatSnapshot,
    },
};
use mlua::{Lua, Table, UserData, UserDataFields, UserDataMethods, Value};

use crate::lua::{LuaTexture, Session, Sink, reject_unknown_options};

/// One `wl_seat`, as Lua holds it.
#[derive(Debug)]
pub struct Seat<T> {
    id: SeatId,
    session: Rc<Session<T>>,
    /// The name this seat was asked for, which is also what it reports before
    /// the compositor has created it and after it has gone.
    name: RefCell<String>,
    /// What the snapshot last said. Absent for a seat the compositor has not
    /// created yet, which is every seat in the frame `lunette.newSeat` was
    /// called in.
    known: RefCell<Option<SeatSnapshot>>,
}

impl<T> Seat<T> {
    pub(crate) fn new(session: Rc<Session<T>>, snapshot: &SeatSnapshot) -> Self {
        Self {
            id: snapshot.seat,
            session,
            name: RefCell::new(snapshot.name.clone()),
            known: RefCell::new(Some(snapshot.clone())),
        }
    }

    /// Brings the cache up to date, reporting whether the seat exists now.
    ///
    /// False both before the compositor has created the seat and after it has
    /// been destroyed. The two are indistinguishable from here and a caller
    /// treats them the same way: nothing can be delivered to a seat that is not
    /// there.
    fn refresh(&self) -> bool {
        let snapshot = self.session.snapshot();
        let Some(current) = snapshot.seats.iter().find(|seat| seat.seat == self.id) else {
            *self.known.borrow_mut() = None;
            return false;
        };
        *self.name.borrow_mut() = current.name.clone();
        *self.known.borrow_mut() = Some(current.clone());
        true
    }

    /// This seat's compiled layout, or `None` when the seat is not there.
    fn keymap(&self) -> Option<Rc<Keymap>> {
        if !self.refresh() {
            return None;
        }
        let text = self.known.borrow().as_ref()?.keymap.clone();
        self.session
            .with_keymaps(|cache| cache.compiled(self.id, &text))
    }

    /// The compositor's identifier, for the sink methods that address a seat.
    pub(crate) const fn id(&self) -> SeatId {
        self.id
    }

    /// The modifiers the snapshot last reported this seat holding.
    fn modifiers(&self) -> ModifierState {
        self.known
            .borrow()
            .as_ref()
            .map(|known| known.modifiers.clone())
            .unwrap_or_default()
    }
}

impl<T: LuaTexture> UserData for Seat<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        // The compositor's identifier for this seat.
        fields.add_field_method_get("id", |_, seat| Ok(seat.id.get()));

        // What clients see on `wl_seat.name`, and the only thing on the wire
        // that tells two seats apart.
        fields.add_field_method_get("name", |_, seat| {
            seat.refresh();
            Ok(seat.name.borrow().clone())
        });

        fields.add_field_method_get("dead", |_, seat| Ok(!seat.refresh()));

        // The modifiers this seat is holding, as clients were last told. An
        // array of names, in the order `KeyModifier` declares them.
        fields.add_field_method_get("modifiers", |lua, seat| {
            seat.refresh();
            modifier_names(lua, &seat.modifiers())
        });

        // Every layout the seat's keymap carries, as a user would read them:
        // 'English (US)', not 'us'. What a layout switcher puts on screen.
        fields.add_field_method_get("layouts", |lua, seat| {
            let Some(keymap) = seat.keymap() else {
                return lua.create_table();
            };
            let layouts = lua.create_table_with_capacity(keymap.layouts().len(), 0)?;
            for (index, layout) in (1..).zip(keymap.layouts()) {
                layouts.set(index, layout.as_str())?;
            }
            Ok(layouts)
        });
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("destroy", |_, seat, ()| Ok(destroy(seat)));

        methods.add_method(
            "setModifiers",
            |_, seat, names: Option<Table>| -> mlua::Result<bool> {
                let modifiers = read_modifiers(names.as_ref())?;
                if !seat.refresh() {
                    return Ok(false);
                }
                seat.session.queue(Command::Modifiers {
                    seat: seat.id,
                    modifiers,
                });
                Ok(true)
            },
        );

        methods.add_method("setFocus", |_, seat, sink: Option<mlua::AnyUserData>| {
            set_focus(seat, sink.as_ref())
        });

        methods.add_method(
            "symbolFor",
            |_, seat, (key, names): (u32, Option<Table>)| -> mlua::Result<Option<u32>> {
                let modifiers = read_modifiers(names.as_ref())?;
                Ok(seat
                    .keymap()
                    .and_then(|keymap| keymap.symbol(Keycode::from_evdev(key), &modifiers))
                    .map(Keysym::raw))
            },
        );

        methods.add_method(
            "characterFor",
            |_, seat, (key, names): (u32, Option<Table>)| -> mlua::Result<Option<String>> {
                let modifiers = read_modifiers(names.as_ref())?;
                Ok(seat
                    .keymap()
                    .and_then(|keymap| keymap.character(Keycode::from_evdev(key), &modifiers)))
            },
        );

        methods.add_method("strokeFor", |lua, seat, wanted: Value| {
            stroke_for(lua, seat, &wanted)
        });
    }
}

/// `lunette.newSeat(name, options)`: a seat with its own pointer and keyboard.
///
/// The handle comes back before the compositor has seen the request, so it
/// describes a seat that does not exist yet: `seat.dead` is true until the
/// snapshot lists it, which is the same rule `lunette.spawn` follows. A layout
/// that does not compile is reported in the log and the seat never appears.
///
/// # Errors
///
/// If the name is already spelled by another seat this frame, or an option is
/// not one this call takes.
pub(crate) fn new_seat<T: LuaTexture>(
    session: &Rc<Session<T>>,
    name: &str,
    options: Option<&Table>,
) -> mlua::Result<Seat<T>> {
    if name.trim().is_empty() {
        return Err(mlua::Error::runtime(
            "lunette: a seat needs a name; clients tell two seats apart by it and nothing else",
        ));
    }
    if session
        .snapshot()
        .seats
        .iter()
        .any(|seat| seat.name == name)
    {
        return Err(mlua::Error::runtime(format!(
            "lunette: a seat named '{name}' already exists, and a client cannot tell two seats \
             with one name apart"
        )));
    }

    let keyboard = match options {
        Some(options) => read_keyboard(options)?,
        None => KeyboardConfig::default(),
    };
    let id = session
        .mint_seat()
        .ok_or_else(|| mlua::Error::runtime("lunette: the seat identifier space is exhausted"))?;

    session.queue(Command::CreateSeat {
        seat: id,
        name: name.to_owned(),
        keyboard: Box::new(keyboard),
    });

    Ok(Seat {
        id,
        session: Rc::clone(session),
        name: RefCell::new(name.to_owned()),
        known: RefCell::new(None),
    })
}

/// `lunette.seats()`: every seat, as of this frame's snapshot.
///
/// # Errors
///
/// If the table could not be built.
pub(crate) fn seats<T: LuaTexture>(lua: &Lua, session: &Rc<Session<T>>) -> mlua::Result<Table> {
    let snapshot = session.snapshot();
    let seats = lua.create_table_with_capacity(snapshot.seats.len(), 0)?;

    for (index, seat) in (1..).zip(&snapshot.seats) {
        seats.set(index, Seat::new(Rc::clone(session), seat))?;
    }

    Ok(seats)
}

/// `seat:destroy()`: withdraws the seat's `wl_seat` global.
///
/// The default seat is refused. It exists before anything has run that could
/// have created it, every command that names no seat resolves to it, and a
/// session with no seat at all can deliver no input.
fn destroy<T>(seat: &Seat<T>) -> bool {
    if seat.id == lunette_compositor::state::DEFAULT_SEAT {
        return false;
    }
    if !seat.refresh() {
        return false;
    }

    seat.session.queue(Command::DestroySeat { seat: seat.id });
    true
}

/// `seat:setFocus(sink)`: gives this seat's keyboard to a sink, or takes it
/// away.
///
/// `nil` withdraws focus. A host sink is refused: the host desktop has one
/// keyboard focus, and which window holds it is the host compositor's decision
/// rather than lunette's.
fn set_focus<T: LuaTexture>(
    seat: &Seat<T>,
    sink: Option<&mlua::AnyUserData>,
) -> mlua::Result<bool> {
    let target = match sink {
        Some(sink) => {
            let sink = sink.borrow::<Sink<T>>()?;
            match sink.window_id() {
                Some(id) => Some(id),
                // A host sink names a monitor rather than a surface, so there
                // is nothing here that could hold a focus.
                None => return Ok(false),
            }
        }
        None => None,
    };

    if !seat.refresh() {
        return Ok(false);
    }
    seat.session.queue(Command::Focus {
        seat: seat.id,
        sink: target,
    });
    Ok(true)
}

/// `seat:strokeFor(value)`: which key and modifiers produce a character or a
/// keysym.
///
/// A string is read as the character to type, and a number as a keysym. Both
/// are wanted: a virtual keyboard resolves characters, and a caller replaying a
/// keysym it read from `seat:symbolFor` resolves numbers.
///
/// A string of more than one character is a caller mistake rather than a race —
/// a stroke produces one keysym — so it raises. Text is what `sink:typeText`
/// is for.
fn stroke_for<T: LuaTexture>(
    lua: &Lua,
    seat: &Seat<T>,
    wanted: &Value,
) -> mlua::Result<Option<Table>> {
    let Some(keymap) = seat.keymap() else {
        return Ok(None);
    };

    let stroke = match wanted {
        Value::Integer(raw) => u32::try_from(*raw)
            .ok()
            .and_then(|raw| keymap.stroke(Keysym::from_raw(raw))),
        Value::String(text) => {
            let text = text.to_str()?;
            let mut characters = text.chars();
            match (characters.next(), characters.next()) {
                (Some(character), None) => keymap.stroke_for(character),
                _ => {
                    return Err(mlua::Error::runtime(format!(
                        "lunette: '{}' is not a single character; a stroke produces one keysym, \
                         and sink:typeText is what enters text",
                        &*text
                    )));
                }
            }
        }
        other => {
            return Err(mlua::Error::runtime(format!(
                "lunette: strokeFor takes a character or a keysym, not a {}",
                other.type_name()
            )));
        }
    };

    stroke.map(|stroke| describe(lua, &stroke)).transpose()
}

/// A stroke as the table Lua reads: the keycode to send and the modifiers to
/// hold with it.
fn describe(lua: &Lua, stroke: &KeyStroke) -> mlua::Result<Table> {
    let table = lua.create_table_with_capacity(0, 2)?;
    table.set("keycode", stroke.key.evdev())?;
    table.set("modifiers", modifier_names(lua, &stroke.modifiers)?)?;
    Ok(table)
}

/// A modifier set as the array of names Lua reads and writes.
fn modifier_names(lua: &Lua, modifiers: &ModifierState) -> mlua::Result<Table> {
    let names = lua.create_table_with_capacity(modifiers.len(), 0)?;
    for (index, modifier) in (1..).zip(modifiers) {
        names.set(index, modifier.as_str())?;
    }
    Ok(names)
}

/// The modifier set an array of names describes.
///
/// An unrecognised name raises rather than being skipped: `'shft'` is a typo,
/// and a modifier that silently does nothing is harder to find than an error.
pub(crate) fn read_modifiers(names: Option<&Table>) -> mlua::Result<ModifierState> {
    let Some(names) = names else {
        return Ok(ModifierState::new());
    };

    let mut modifiers = ModifierState::new();
    for name in names.sequence_values::<mlua::LuaString>() {
        let name = name?;
        let name = name.to_string_lossy();
        let modifier = KeyModifier::from_name(&name).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "lunette: '{name}' is not a modifier; the modifiers are {MODIFIER_NAMES}"
            ))
        })?;
        modifiers.insert(modifier);
    }

    Ok(modifiers)
}

/// The modifiers [`read_modifiers`] accepts, for the error message that lists
/// them.
const MODIFIER_NAMES: &str = "shift, capsLock, control, alt, numLock, mod3, logo, mod5";

/// The keyboard a `lunette.newSeat` option table describes.
fn read_keyboard(options: &Table) -> mlua::Result<KeyboardConfig> {
    reject_unknown_options(options, SEAT_OPTIONS)?;

    Ok(KeyboardConfig {
        keymap: KeymapConfig {
            rules: options.get("rules")?,
            model: options.get("model")?,
            layout: options.get("layout")?,
            variant: options.get("variant")?,
            options: options.get("options")?,
        },
        repeat: RepeatPolicy {
            delay: options
                .get::<Option<u32>>("repeatDelay")?
                .map_or_else(|| RepeatPolicy::default().delay, RepeatDelay::from_millis),
            rate: options
                .get::<Option<u32>>("repeatRate")?
                .map_or_else(|| RepeatPolicy::default().rate, RepeatRate::per_second),
        },
    })
}

/// The options `lunette.newSeat` accepts.
///
/// The first five are the RMLVO names libxkbcommon compiles a layout from, and
/// an absent one takes the system default — which is what a user who has
/// configured a layout for their desktop expects lunette to inherit.
const SEAT_OPTIONS: &[&str] = &[
    "rules",
    "model",
    "layout",
    "variant",
    "options",
    "repeatDelay",
    "repeatRate",
];
