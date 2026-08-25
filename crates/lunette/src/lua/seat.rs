//! Linux-only: the seat handle Lua holds.
//!
//! A `wl_seat` carries exactly one pointer and one keyboard, so two cursors need
//! two seats and the protocol offers no other model. WayVR has one seat, which
//! is why pointing the off hand at a window steals hover from the main hand;
//! `lunette.newSeat` removes that limit, and the collapse-to-one-seat mode is
//! Lua policy over it rather than a mode here.
//!
//! ## Keymap queries
//!
//! Wayland clients receive an xkb keymap plus raw keycodes and perform their own
//! keysym translation, so anything drawing a virtual keyboard must be able to
//! ask what a key means. The three queries here — the layout list, forward lookup,
//! and reverse lookup — let mullion draw a virtual keyboard with correct legends
//! and produce correct keycodes without reimplementing xkb in Lua.
//!
//! Every answer comes from the seat's own published layout, compiled on this
//! thread. The compositor cannot hand over a compiled keymap: libxkbcommon is
//! not thread-safe, so what crosses the boundary is text and each side compiles
//! its own copy.
//!
//! ## Focus handling model
//!
//! `seat:setFocus(sink)` is a request the caller makes deliberately. Focus does
//! not follow pointer motion, which differs from WayVR's behavior where a second
//! hand can steal focus by hovering.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::{
    keymap::Keymap,
    protocol::{
        Command, KeyModifier, KeyboardConfig, Keycode, KeymapConfig, Keysym, ModifierState,
        RepeatDelay, RepeatPolicy, RepeatRate, SeatId, SeatSnapshot,
    },
};
use mlua::{Lua, Table, UserDataRef, Value};

use crate::{
    control::wire::HandleKind,
    lua::{
        LuaTexture, Session, Sink,
        declarations::{Options, handle, record},
        values::StrokeQuery,
    },
};

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
    /// Returns false when the seat is not present in the snapshot.
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

handle! {
    /// A seat with its own pointer and keyboard.
    Seat<T: LuaTexture> = HandleKind::Seat;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    /// The name exposed to Wayland clients.
    field name(_lua, this) -> String {
        this.refresh();
        Ok(this.name.borrow().clone())
    }

    /// Whether the seat has not been created or has been destroyed.
    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// Whether this seat bridges the host clipboard and primary selection.
    field clipboardBridge(_lua, this) -> bool {
        this.refresh();
        Ok(this
            .known
            .borrow()
            .as_ref()
            .is_some_and(|known| known.clipboard_bridge))
    }

    /// The modifiers this seat is holding.
    field modifiers(_lua, this) -> Vec<String> {
        this.refresh();
        Ok(modifier_names(&this.modifiers()))
    }

    /// The user-facing layouts in this seat's keymap.
    field layouts(_lua, this) -> Vec<String> {
        let Some(keymap) = this.keymap() else {
            return Ok(Vec::new());
        };
        Ok(keymap
            .layouts()
            .iter()
            .map(|layout| layout.as_str().to_owned())
            .collect())
    }

    /// Destroys this seat, except for the default seat.
    method destroy(_lua, this) -> bool { Ok(destroy(this)) }

    /// Sets the modifiers reported to clients.
    method setModifiers(_lua, this, names: Option<Vec<String>>) -> bool {
        let modifiers = read_modifiers(names.as_deref())?;
        if !this.refresh() {
            return Ok(false);
        }
        this.session.queue(Command::Modifiers {
            seat: this.id,
            modifiers,
        });
        Ok(true)
    }

    /// Gives this seat's keyboard to a sink, or removes its focus.
    method setFocus(_lua, this, sink: Option<UserDataRef<Sink<T>>>) -> bool {
        set_focus(this, sink.as_deref())
    }

    /// Enables or disables this seat's host clipboard bridge.
    method setClipboardBridge(_lua, this, bridged: bool) -> bool {
        Ok(set_clipboard_bridge(this, bridged))
    }

    /// Returns the keysym produced by a keycode and modifier set.
    method symbolFor(_lua, this, key: u32, names: Option<Vec<String>>) -> Option<u32> {
        let modifiers = read_modifiers(names.as_deref())?;
        Ok(this
            .keymap()
            .and_then(|keymap| keymap.symbol(Keycode::from_evdev(key), &modifiers))
            .map(Keysym::raw))
    }

    /// Returns the character produced by a keycode and modifier set.
    method characterFor(_lua, this, key: u32, names: Option<Vec<String>>) -> Option<String> {
        let modifiers = read_modifiers(names.as_deref())?;
        Ok(this
            .keymap()
            .and_then(|keymap| keymap.character(Keycode::from_evdev(key), &modifiers)))
    }

    /// Returns the key and modifiers that produce a character or keysym.
    method strokeFor(_lua, this, wanted: StrokeQuery) -> Option<Stroke> {
        stroke_for(this, &wanted.0)
    }
}

/// `lunette.newSeat(name, options)`: a seat with its own pointer and keyboard.
///
/// The handle is initially dead until the snapshot lists the new seat. A layout
/// that does not compile is reported in the log, and the seat never appears.

///
/// # Errors
///
/// If the name is already spelled by another seat this frame, or an option is
/// not one this call takes.
pub(crate) fn new_seat<T: LuaTexture>(
    session: &Rc<Session<T>>,
    name: &str,
    options: Option<&Options<NewSeat>>,
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
        Some(options) => read_keyboard(options.table())?,
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

/// Returns every seat in the current frame's snapshot.
///
/// # Errors
///
/// If the seat list cannot be built.
pub(crate) fn seats<T: LuaTexture>(
    _lua: &Lua,
    session: &Rc<Session<T>>,
) -> mlua::Result<Vec<Seat<T>>> {
    let snapshot = session.snapshot();
    Ok(snapshot
        .seats
        .iter()
        .map(|seat| Seat::new(Rc::clone(session), seat))
        .collect())
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
fn set_focus<T: LuaTexture>(seat: &Seat<T>, sink: Option<&Sink<T>>) -> mlua::Result<bool> {
    let target = match sink {
        Some(sink) => {
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

/// `seat:setClipboardBridge(bridged)`: makes this seat's selections the host
/// desktop's, or stops them being.
///
/// One seat at a time, because the host has one clipboard and one primary
/// selection: bridging this seat takes the bridge off whichever seat had it.
/// Passing `false` on a seat that is not the bridged one does nothing, so a
/// configuration can call it without first asking which seat holds it.
///
/// `docs/input.md` records why the mapping is one designated seat rather than
/// last-writer-wins across all of them.
fn set_clipboard_bridge<T>(seat: &Seat<T>, bridged: bool) -> bool {
    if !seat.refresh() {
        return false;
    }
    let held = seat
        .known
        .borrow()
        .as_ref()
        .is_some_and(|known| known.clipboard_bridge);
    if held == bridged {
        return true;
    }

    seat.session.queue(Command::SetClipboardBridge {
        seat: bridged.then_some(seat.id),
    });
    true
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
fn stroke_for<T: LuaTexture>(seat: &Seat<T>, wanted: &Value) -> mlua::Result<Option<Stroke>> {
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

    Ok(stroke.map(|stroke| Stroke {
        keycode: stroke.key.evdev(),
        modifiers: modifier_names(&stroke.modifiers),
    }))
}

record! {
    /// A key and the modifiers to hold with it, which together produce one keysym.
    struct Stroke {
        /// The evdev keycode `sink:key` takes.
        keycode: u32,
        modifiers: Vec<String>,
    }
}

/// A modifier set as the array of names Lua reads and writes.
fn modifier_names(modifiers: &ModifierState) -> Vec<String> {
    modifiers
        .into_iter()
        .map(|modifier| modifier.as_str().to_owned())
        .collect()
}

/// The modifier set an array of names describes.
///
/// An unrecognised name raises rather than being skipped: `'shft'` is a typo,
/// and a modifier that silently does nothing is harder to find than an error.
pub(crate) fn read_modifiers(names: Option<&[String]>) -> mlua::Result<ModifierState> {
    let Some(names) = names else {
        return Ok(ModifierState::new());
    };

    let mut modifiers = ModifierState::new();
    for name in names {
        let modifier = KeyModifier::from_name(name).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "lunette: '{name}' is not a modifier; the modifiers are {}",
                KeyModifier::NAMES.join(", ")
            ))
        })?;
        modifiers.insert(modifier);
    }

    Ok(modifiers)
}

/// The keyboard a `lunette.newSeat` option table describes.
fn read_keyboard(options: &Table) -> mlua::Result<KeyboardConfig> {
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

record! {
    /// What `lunette.newSeat` takes. The first five are the RMLVO names libxkbcommon compiles a layout from, and an absent one takes the system default.
    options NewSeat as SeatOptions {
        rules: Option<String>,
        model: Option<String>,
        layout: Option<String>,
        variant: Option<String>,
        options: Option<String>,
        repeatDelay: Option<u32>,
        repeatRate: Option<u32>,
    }
}
