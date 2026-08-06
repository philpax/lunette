//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/mod.rs (the seat construction fragment at :184-188 and :261-263) and backend/wayvr/window.rs (the hover state at :109-119), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The seats lunette serves, one per hand.
//!
//! A `wl_seat` carries exactly one pointer and one keyboard, so two cursors
//! need two seats; the protocol offers nothing else. WayVR has one seat held by
//! value (`mod.rs:184-188`, `client.rs:39-40`) and every input path hardcoded to
//! it, which is why pointing the off hand at a window steals hover from the main
//! hand. [`SeatRegistry`] replaces that with a collection keyed by [`SeatId`],
//! which is the identifier every input command already carries.
//!
//! # Where per-seat state lives
//!
//! Two homes, and which one a piece of state gets is decided by what can reach
//! it.
//!
//! State a caller reaches by [`SeatId`] — the hover in [`SeatEntry`] — lives in
//! the entry, because every path that reads it arrives holding the identifier.
//!
//! State a smithay handler reaches lives in `Seat::user_data`, because
//! `SeatHandler` is per-compositor with the seat passed in as an argument
//! (`smithay-0.7.0/src/input/mod.rs:145-165`): inside `cursor_image` the seat is
//! the only thing distinguishing one call from another, and there is no
//! identifier to look up. That is the whole discipline for multi-seat
//! correctness — a `SeatHandler` method that ignores its `seat` argument is a
//! latent bug, and WayVR's `cursor_image` (`comp.rs:341-343`) is the example.
//!
//! # What is deliberately not here
//!
//! The serial counter. Serials are effectively global in smithay — a client
//! compares them across seats and against its own requests — so one counter is
//! correct and per-seat counters would collide. WayVR keeps it in the per-seat
//! struct (`client.rs:41`); lunette keeps it on the compositor state, where the
//! keyboard and the pointer of every seat draw from the same sequence.
//!
//! Focus policy. WayVR drives keyboard focus from pointer motion
//! (`mod.rs:1128-1148`). With two seats that heuristic becomes per-seat policy,
//! and policy is Lua's; this module applies focus, it does not choose it.

use std::{cell::RefCell, error::Error, fmt, sync::Arc};

use smithay::{
    input::{
        Seat, SeatState,
        keyboard::{KeyboardHandle, ModifiersState, SerializedMods, XkbConfig},
        pointer::{CursorImageStatus, PointerHandle},
    },
    reexports::wayland_server::DisplayHandle,
};

use crate::{
    keymap::{Keymap, KeymapError},
    protocol::{
        KeyModifier, KeyboardConfig, ModifierState, PixelPoint, SeatId, SeatSnapshot, WindowId,
    },
    state::CompositorState,
};

/// Every seat lunette serves, in the order they were created.
///
/// A `Vec` rather than a map: there is one seat per pointing device, so the
/// count is in the low single digits, and creation order is the order a client
/// sees the `wl_seat` globals arrive in.
#[derive(Default)]
pub(crate) struct SeatRegistry {
    seats: Vec<SeatEntry>,
}

impl SeatRegistry {
    /// Creates a seat with its own `wl_seat` global, pointer, and keyboard.
    ///
    /// The keymap is compiled twice, once by this crate and once by smithay,
    /// from the same RMLVO names. That is not waste: smithay's copy lives
    /// behind its own context because libxkbcommon is not thread-safe, and this
    /// crate's copy is what answers the queries `docs/input.md:50-52` asks for
    /// and what `typeText` restores.
    ///
    /// # Errors
    ///
    /// Returns [`SeatError`] when the identifier is already in use, when another
    /// seat already advertises the name — a client tells two seats apart by
    /// `wl_seat.name`, so two seats sharing one is a configuration a client
    /// cannot act on — or when the layout does not compile.
    pub(crate) fn create(
        &mut self,
        state: &mut SeatState<CompositorState>,
        display: &DisplayHandle,
        id: SeatId,
        name: &str,
        keyboard: &KeyboardConfig,
    ) -> Result<&SeatEntry, SeatError> {
        if self.get(id).is_some() {
            return Err(SeatError {
                seat: id,
                kind: SeatErrorKind::DuplicateId,
            });
        }
        if self.seats.iter().any(|entry| entry.seat.name() == name) {
            return Err(SeatError {
                seat: id,
                kind: SeatErrorKind::DuplicateName {
                    name: name.to_owned(),
                },
            });
        }

        let keymap = Keymap::compile(&keyboard.keymap).map_err(|error| SeatError {
            seat: id,
            kind: SeatErrorKind::Keymap { error },
        })?;

        let mut seat = state.new_wl_seat(display, name.to_owned());
        let pointer = seat.add_pointer();
        let handle = seat
            .add_keyboard(
                xkb_config(keyboard),
                keyboard.repeat.delay.millis(),
                keyboard.repeat.rate.get(),
            )
            .map_err(|error| SeatError {
                seat: id,
                kind: SeatErrorKind::Keyboard {
                    message: error.to_string(),
                },
            })?;
        seat.user_data().insert_if_missing(CursorImage::default);

        self.seats.push(SeatEntry {
            id,
            seat,
            pointer,
            keyboard: handle,
            keymap,
            mouse: None,
        });
        self.seats
            .last()
            .ok_or_else(|| unreachable!("the entry was just pushed"))
    }

    /// Every seat, as the main thread reads them.
    pub(crate) fn snapshot(&self) -> Vec<SeatSnapshot> {
        self.seats
            .iter()
            .map(|entry| SeatSnapshot {
                seat: entry.id,
                name: entry.seat.name().to_owned(),
                keymap: Arc::clone(entry.keymap().text()),
                modifiers: held(entry.keyboard.modifier_state()),
            })
            .collect()
    }

    /// Withdraws a seat's global and its capabilities.
    ///
    /// The caller moves the pointer off whatever it was over first, so clients
    /// see a leave rather than a cursor that stops existing where it stood.
    ///
    /// smithay 0.7 has no way to remove a seat from its `SeatState`
    /// (`src/input/mod.rs:168-170` is a private `Vec` with no removal), so the
    /// handle stays in that vector for the life of the compositor. Withdrawing
    /// the global stops a new client from binding it and removing the pointer
    /// tells the clients that already have that the capability is gone, so what
    /// remains is a few hundred bytes per seat ever created, not a seat a client
    /// can still use.
    ///
    /// # Errors
    ///
    /// Returns [`SeatError`] when no seat has that identifier.
    pub(crate) fn destroy(&mut self, display: &DisplayHandle, id: SeatId) -> Result<(), SeatError> {
        let index = self
            .seats
            .iter()
            .position(|entry| entry.id == id)
            .ok_or(SeatError {
                seat: id,
                kind: SeatErrorKind::Unknown,
            })?;

        let mut entry = self.seats.remove(index);
        entry.seat.remove_pointer();
        entry.seat.remove_keyboard();
        if let Some(global) = entry.seat.global() {
            display.remove_global::<CompositorState>(global);
        }
        Ok(())
    }

    pub(crate) fn get(&self, id: SeatId) -> Option<&SeatEntry> {
        self.seats.iter().find(|entry| entry.id == id)
    }

    pub(crate) fn get_mut(&mut self, id: SeatId) -> Option<&mut SeatEntry> {
        self.seats.iter_mut().find(|entry| entry.id == id)
    }
}

impl fmt::Debug for SeatRegistry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list().entries(self.seats.iter()).finish()
    }
}

/// One seat and everything lunette tracks about it.
pub(crate) struct SeatEntry {
    id: SeatId,
    seat: Seat<CompositorState>,
    pointer: PointerHandle<CompositorState>,
    keyboard: KeyboardHandle<CompositorState>,
    /// This crate's own copy of the layout the keyboard is running, which is
    /// what answers a query and what a restore uploads. smithay's copy is
    /// inside its own context and cannot be read back as text
    /// (`smithay-0.7.0/src/input/keyboard/mod.rs` exposes only
    /// `with_xkb_state`), so without this one there would be nothing to restore
    /// to and `lunette-v1.AC4.3` would be unreachable.
    keymap: Keymap,
    /// Where this seat's pointer is, and over which window. Independent per
    /// seat: WayVR keeps one for the whole compositor (`window.rs:109-119`),
    /// which is what makes the off hand steal hover from the main hand.
    mouse: Option<MouseState>,
}

impl SeatEntry {
    pub(crate) const fn id(&self) -> SeatId {
        self.id
    }

    /// The pointer handle, cloned because delivering an event takes `&mut` on
    /// the compositor state this entry is borrowed from.
    pub(crate) fn pointer(&self) -> PointerHandle<CompositorState> {
        self.pointer.clone()
    }

    /// The keyboard handle, cloned for the reason the pointer is.
    pub(crate) fn keyboard(&self) -> KeyboardHandle<CompositorState> {
        self.keyboard.clone()
    }

    pub(crate) const fn keymap(&self) -> &Keymap {
        &self.keymap
    }

    pub(crate) const fn mouse(&self) -> Option<MouseState> {
        self.mouse
    }

    pub(crate) const fn set_mouse(&mut self, mouse: Option<MouseState>) {
        self.mouse = mouse;
    }

    /// The smithay seat, which every `KeyboardTarget` call takes as its first
    /// argument.
    pub(crate) const fn seat(&self) -> &Seat<CompositorState> {
        &self.seat
    }
}

impl fmt::Debug for SeatEntry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SeatEntry")
            .field("id", &self.id)
            .field("name", &self.seat.name())
            .field("keymap", &self.keymap)
            .field("mouse", &self.mouse)
            .finish()
    }
}

/// Where a seat's pointer is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct MouseState {
    pub(crate) hovered: WindowId,
    pub(crate) position: PixelPoint,
}

/// Records the cursor a seat's focused client asked for.
///
/// Called from `SeatHandler::cursor_image`, which is handed the seat and
/// nothing else.
pub(crate) fn set_cursor_image(seat: &Seat<CompositorState>, image: CursorImageStatus) {
    seat.user_data().insert_if_missing(CursorImage::default);
    if let Some(cursor) = seat.user_data().get::<CursorImage>() {
        *cursor.status.borrow_mut() = image;
    }
}

/// What the seat's focused client last asked its cursor to look like.
///
/// Nothing in the compositor draws a cursor — the panel does, in Lua — so the
/// only reader today is the test that holds the per-seat storage honest. The
/// gate comes off when Phase 6 renders it.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) fn cursor_image(seat: &Seat<CompositorState>) -> CursorImageStatus {
    seat.user_data()
        .get::<CursorImage>()
        .map_or_else(CursorImageStatus::default_named, |cursor| {
            cursor.status.borrow().clone()
        })
}

/// The cursor a seat's client last asked for.
///
/// A `RefCell` because `UserDataMap::get` hands out a shared reference and this
/// is written from a `&mut self` handler; the compositor thread is the only
/// thread that touches it, so nothing stronger is wanted. The map is the
/// thread-affine one for the same reason — [`CursorImageStatus`] holds a
/// `WlSurface`, and the surface belongs to this thread anyway.
struct CursorImage {
    status: RefCell<CursorImageStatus>,
}

impl Default for CursorImage {
    fn default() -> Self {
        Self {
            status: RefCell::new(CursorImageStatus::default_named()),
        }
    }
}

/// Why a seat could not be created or destroyed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SeatError {
    seat: SeatId,
    kind: SeatErrorKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum SeatErrorKind {
    DuplicateId,
    DuplicateName {
        name: String,
    },
    Keymap {
        error: KeymapError,
    },
    /// smithay's `KeyboardError`, kept as its message: the type is not
    /// `PartialEq`, and what a caller does with it is report it.
    Keyboard {
        message: String,
    },
    Unknown,
}

impl fmt::Display for SeatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.kind {
            SeatErrorKind::DuplicateId => {
                write!(f, "seat: {} already exists", self.seat)
            }
            SeatErrorKind::DuplicateName { name } => write!(
                f,
                "seat: another seat is already named {name}, and a client tells two seats apart \
                 by name"
            ),
            SeatErrorKind::Keymap { error } => write!(f, "seat: {}: {error}", self.seat),
            SeatErrorKind::Keyboard { message } => write!(
                f,
                "seat: {} could not be given a keyboard: {message}",
                self.seat
            ),
            SeatErrorKind::Unknown => write!(f, "seat: {} does not exist", self.seat),
        }
    }
}

impl Error for SeatError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match &self.kind {
            SeatErrorKind::Keymap { error } => Some(error),
            _ => None,
        }
    }
}

/// The RMLVO names smithay compiles its own copy of the layout from.
///
/// The same five names [`Keymap::compile`] uses, so the two copies agree. An
/// absent field becomes the empty string, which is how libxkbcommon spells "the
/// default".
fn xkb_config(keyboard: &KeyboardConfig) -> XkbConfig<'_> {
    fn name(value: &Option<String>) -> &str {
        value.as_deref().unwrap_or_default()
    }

    XkbConfig {
        rules: name(&keyboard.keymap.rules),
        model: name(&keyboard.keymap.model),
        layout: name(&keyboard.keymap.layout),
        variant: name(&keyboard.keymap.variant),
        options: keyboard.keymap.options.clone(),
    }
}

/// smithay's modifier state as the closed set the protocol carries.
///
/// smithay names the modifiers by what they mean and lunette names them the
/// same way, so this is a rename rather than a reinterpretation — with one
/// exception worth noting: smithay calls `Mod3` `iso_level5_shift`
/// (`input/keyboard/modifiers_state.rs`), which is what that modifier does on
/// the layouts that use it.
pub(crate) fn held(state: ModifiersState) -> ModifierState {
    let present = [
        (KeyModifier::Shift, state.shift),
        (KeyModifier::CapsLock, state.caps_lock),
        (KeyModifier::Control, state.ctrl),
        (KeyModifier::Alt, state.alt),
        (KeyModifier::NumLock, state.num_lock),
        (KeyModifier::Mod3, state.iso_level5_shift),
        (KeyModifier::Logo, state.logo),
        (KeyModifier::Mod5, state.iso_level3_shift),
    ];

    present
        .into_iter()
        .filter_map(|(modifier, held)| held.then_some(modifier))
        .collect()
}

/// The closed set as smithay's modifier state.
///
/// The serialised masks are left at their defaults: `set_modifier_state`
/// recomputes them from the booleans against the keymap
/// (`ModifiersState::serialize_back`), because only the keymap knows which bit
/// each modifier occupies.
pub(crate) fn modifiers_state(modifiers: &ModifierState) -> ModifiersState {
    ModifiersState {
        shift: modifiers.contains(&KeyModifier::Shift),
        caps_lock: modifiers.contains(&KeyModifier::CapsLock),
        ctrl: modifiers.contains(&KeyModifier::Control),
        alt: modifiers.contains(&KeyModifier::Alt),
        num_lock: modifiers.contains(&KeyModifier::NumLock),
        iso_level5_shift: modifiers.contains(&KeyModifier::Mod3),
        logo: modifiers.contains(&KeyModifier::Logo),
        iso_level3_shift: modifiers.contains(&KeyModifier::Mod5),
        serialized: SerializedMods::default(),
    }
}
