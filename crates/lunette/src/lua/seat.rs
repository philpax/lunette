//! Linux-only: implements seat handles for Lua.
//!
//! Each Wayland seat provides one pointer and keyboard, so multiple pointers require multiple
//! seats. The Lua thread compiles its own keymaps because libxkbcommon is not thread-safe.

use std::{cell::RefCell, collections::HashMap, rc::Rc};

use lunette_compositor::{
    config::DEFAULT_SEAT,
    keymap::Keymap,
    protocol::{
        Command, KeyboardConfig, Keycode, KeymapConfig, Keysym, ModifierState, RepeatDelay,
        RepeatPolicy, RepeatRate, SeatId, SeatSnapshot,
    },
};
use mlua::{Lua, Table, UserDataRef, Value};

use crate::{
    control::wire::HandleKind,
    lua::{
        Drag, LuaTexture, Session, Sink,
        declarations::{Options, handle, record},
        keys::ModifierName,
        values::StrokeQuery,
    },
};

/// One `wl_seat`, as Lua holds it.
#[derive(Debug)]
pub struct Seat<T> {
    id: SeatId,
    session: Rc<Session<T>>,
    /// The requested name. `seat.name` reports it before the compositor
    /// creates the seat and after the seat is gone.
    name: RefCell<String>,
    /// The state the snapshot last reported. Absent for a seat the compositor
    /// has not created yet.
    known: RefCell<Option<SeatSnapshot>>,
}

/// Two handles are equal when they name the same seat.
impl<T> PartialEq for Seat<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
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

    /// Returns this seat's compiled keymap, or `None` when the seat is absent.
    fn keymap(&self) -> Option<Rc<Keymap>> {
        if !self.refresh() {
            return None;
        }
        let text = self.known.borrow().as_ref()?.keymap.clone();
        self.session
            .with_keymaps(|cache| cache.compiled(self.id, &text))
    }

    pub(crate) const fn id(&self) -> SeatId {
        self.id
    }
}

handle! {
    /// A seat with its own pointer and keyboard. Clients see it as `wl_seat`.
    Seat<T: LuaTexture> = HandleKind::Seat;

    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    /// What clients see on `wl_seat.name`, the only thing on the wire that tells two seats apart.
    field name(_lua, this) -> String {
        this.refresh();
        Ok(this.name.borrow().clone())
    }

    /// True before the compositor creates the seat and after the seat is destroyed.
    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// Whether this seat's clipboard and primary selection are the host desktop's. At most one seat's are.
    field clipboardBridge(_lua, this) -> bool {
        this.refresh();
        Ok(this
            .known
            .borrow()
            .as_ref()
            .is_some_and(|known| known.clipboard_bridge))
    }

    /// The drag this seat's pointer carries, or nil. A client starts one from a press, and it
    /// lasts until the release or a cancellation.
    field drag(_lua, this) -> Option<Drag<T>> {
        this.refresh();
        let known = this.known.borrow();
        Ok(known.as_ref().and_then(|known| {
            known
                .drag
                .as_ref()
                .map(|drag| Drag::new(Rc::clone(&this.session), this.id, drag))
        }))
    }

    /// Withdraws this seat's `wl_seat` global or cancels its pending creation. The default seat cannot be removed.
    method destroy(_lua, this) -> bool { Ok(destroy(this)) }

    /// Assigns keyboard focus to a window sink, or clears it. The host compositor controls host
    /// focus, so host sinks are refused.
    method setFocus(_lua, this, sink: Option<UserDataRef<Sink<T>>>) -> bool {
        set_focus(this, sink.as_deref())
    }

    /// Bridges this seat's clipboard and primary selection to the host desktop. Only one seat can
    /// be bridged.
    method setClipboardBridge(_lua, this, bridged: bool) -> bool {
        Ok(set_clipboard_bridge(this, bridged))
    }

    /// Returns the keysym for a keycode and modifier set in this seat's keymap.
    method symbolFor(_lua, this, key: u32, names: Option<Vec<ModifierName>>) -> Option<u32> {
        let modifiers = read_modifiers(names.as_deref());
        Ok(this
            .keymap()
            .and_then(|keymap| keymap.symbol(Keycode::from_evdev(key), &modifiers))
            .map(Keysym::raw))
    }

    /// Returns the character for a keycode and modifier set.
    method characterFor(_lua, this, key: u32, names: Option<Vec<ModifierName>>) -> Option<String> {
        let modifiers = read_modifiers(names.as_deref());
        Ok(this
            .keymap()
            .and_then(|keymap| keymap.character(Keycode::from_evdev(key), &modifiers)))
    }

    /// Returns the keycode and modifiers that produce a character or keysym.
    /// A string must contain one character; a number names a keysym.
    method strokeFor(_lua, this, wanted: StrokeQuery) -> Option<Stroke> {
        stroke_for(this, &wanted.0)
    }
}

/// Creates a seat with its own pointer and keyboard.
///
/// The returned handle is dead until the compositor reports the seat in a snapshot. A keymap
/// compilation failure is logged and prevents the seat from appearing.
///
/// # Errors
///
/// Returns an error if the name is missing, empty, or already in use, or an option is unknown.
pub(crate) fn new_seat<T: LuaTexture>(
    session: &Rc<Session<T>>,
    options: &Options<NewSeat>,
) -> mlua::Result<Seat<T>> {
    let options = options.table();
    let name: String = options.get::<Option<String>>("name")?.unwrap_or_default();
    let name = name.as_str();
    if name.trim().is_empty() {
        return Err(mlua::Error::runtime(
            "lunette: a seat needs a name; clients tell two seats apart by it and nothing else",
        ));
    }
    if session.seat_names.borrow().in_use(name) {
        return Err(mlua::Error::runtime(format!(
            "lunette: a seat named '{name}' already exists, and a client cannot tell two seats \
             with one name apart"
        )));
    }

    let keyboard = read_keyboard(options)?;
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

/// Returns the default seat from this frame's snapshot, or `None` when it is absent.
pub(crate) fn default_seat<T: LuaTexture>(session: &Rc<Session<T>>) -> Option<Seat<T>> {
    session
        .snapshot()
        .seats
        .iter()
        .find(|seat| seat.seat == DEFAULT_SEAT)
        .map(|seat| Seat::new(Rc::clone(session), seat))
}

/// Withdraws a non-default seat's `wl_seat` global.
fn destroy<T>(seat: &Seat<T>) -> bool {
    if seat.id == DEFAULT_SEAT {
        return false;
    }
    if !seat.session.seat_names.borrow().can_destroy(seat.id) {
        return false;
    }

    seat.session.queue(Command::DestroySeat { seat: seat.id });
    true
}

/// Tracks requested names across command flushes and delayed compositor snapshots.
#[derive(Debug, Default)]
pub(super) struct SeatNames {
    seats: HashMap<SeatId, SeatName>,
}

#[derive(Debug)]
enum SeatName {
    Creating(String),
    Published(String),
    CancelledCreation,
    Destroying,
}

impl SeatNames {
    pub(super) fn in_use(&self, name: &str) -> bool {
        self.seats.values().any(|state| match state {
            SeatName::Creating(existing) | SeatName::Published(existing) => existing == name,
            SeatName::CancelledCreation | SeatName::Destroying => false,
        })
    }

    fn can_destroy(&self, seat: SeatId) -> bool {
        matches!(
            self.seats.get(&seat),
            Some(SeatName::Creating(_) | SeatName::Published(_))
        )
    }

    pub(super) fn apply(&mut self, command: &Command) {
        match command {
            Command::CreateSeat { seat, name, .. } => {
                self.seats.insert(*seat, SeatName::Creating(name.clone()));
            }
            Command::DestroySeat { seat } => {
                let state = match self.seats.get(seat) {
                    Some(SeatName::Creating(_) | SeatName::CancelledCreation) => {
                        SeatName::CancelledCreation
                    }
                    _ => SeatName::Destroying,
                };
                self.seats.insert(*seat, state);
            }
            _ => {}
        }
    }

    pub(super) fn reconcile(&mut self, seats: &[SeatSnapshot]) {
        // Absence cannot acknowledge a creation: failed requests publish no result.
        // Destruction suppresses stale snapshots until the old seat disappears.
        self.seats.retain(|id, state| match state {
            SeatName::Creating(_) | SeatName::CancelledCreation => true,
            SeatName::Published(_) | SeatName::Destroying => {
                seats.iter().any(|seat| seat.seat == *id)
            }
        });
        for seat in seats {
            let state = self
                .seats
                .entry(seat.seat)
                .or_insert_with(|| SeatName::Published(seat.name.clone()));
            *state = match state {
                SeatName::Creating(_) | SeatName::Published(_) => {
                    SeatName::Published(seat.name.clone())
                }
                SeatName::CancelledCreation | SeatName::Destroying => SeatName::Destroying,
            };
        }
    }
}

/// Assigns this seat's keyboard focus to a window sink, or clears it.
///
/// Host sinks are refused because the host compositor controls host focus.
fn set_focus<T: LuaTexture>(seat: &Seat<T>, sink: Option<&Sink<T>>) -> mlua::Result<bool> {
    let target = match sink {
        Some(sink) => {
            match sink.window_id() {
                Some(id) => Some(id),
                // A host sink names a monitor, which has no focus target.
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

/// Bridges this seat's clipboard and primary selection to the host desktop.
///
/// Only one seat is bridged at a time. Enabling this seat replaces the previous bridge. Disabling
/// an unbridged seat has no effect.
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

/// Returns the key and modifiers that produce a character or keysym.
///
/// A string must contain one character; a number is treated as a keysym. Text entry uses
/// `sink:typeText`.
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
        modifiers: named(&stroke.modifiers),
    }))
}

record! {
    /// A key and the modifiers to hold with it. Together they produce one keysym.
    struct Stroke {
        /// The evdev keycode `sink:key` takes.
        keycode: u32,
        modifiers: Vec<ModifierName>,
    }
}

/// A modifier set as the array of names Lua reads.
fn named(modifiers: &ModifierState) -> Vec<ModifierName> {
    modifiers.into_iter().copied().map(ModifierName).collect()
}

/// Converts modifier names to a modifier set. Converting each name refused any outside the set.
pub(crate) fn read_modifiers(names: Option<&[ModifierName]>) -> ModifierState {
    let mut modifiers = ModifierState::new();
    for name in names.unwrap_or_default() {
        modifiers.insert(name.0);
    }
    modifiers
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
    /// What `lunette.newSeat` takes. `rules` through `options` are the RMLVO
    /// names libxkbcommon compiles a layout from; an absent one takes the
    /// system default.
    options NewSeat as SeatOptions {
        /// What clients see on `wl_seat.name`. It must be non-empty and unused by another seat.
        name: String,
        rules: Option<String>,
        model: Option<String>,
        layout: Option<String>,
        variant: Option<String>,
        options: Option<String>,
        /// Milliseconds a key is held before it repeats. 500 when absent.
        repeatDelay: Option<u32>,
        /// Repeats per second once a held key repeats. 50 when absent.
        repeatRate: Option<u32>,
    }
}
