//! Adapted from the seat-construction fragments in WayVR's
//! `backend/wayvr/mod.rs` and the hover state in `backend/wayvr/window.rs`
//! (https://github.com/wayvr-org/wayvr), at commit
//! `98f800c644719d3f23a20e50bd3237c29a8082cb`.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! A `wl_seat` exposes one pointer and one keyboard. Each simultaneous cursor
//! needs its own seat, and [`SeatRegistry`] keys per-seat state by [`SeatId`].
//!
//! `SeatHandler` callbacks receive a [`Seat`] but no [`SeatId`]. State used by
//! those callbacks is stored in `Seat::user_data`; state addressed by
//! [`SeatId`] is stored in [`SeatEntry`].
//!
//! Pointer hover and keyboard focus are independent. Callers choose focus,
//! while this module stores hover state for each seat.
//!
//! Smithay serials are global across seats. Input paths use smithay's shared
//! serial counter and do not keep a per-seat counter.

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
    keymap::{self, Keymap, KeymapError},
    protocol::{
        KeyModifier, KeyboardConfig, KeymapConfig, KeymapDefaults, KeymapText, ModifierState,
        PixelPoint, SeatId, SeatSnapshot, WindowId,
    },
    state::CompositorState,
};

/// Stores seats in creation order, which is the order clients observe their
/// `wl_seat` globals.
#[derive(Default)]
pub(crate) struct SeatRegistry {
    seats: Vec<SeatEntry>,
}

impl SeatRegistry {
    /// Creates a seat with one pointer, one keyboard, and a distinct
    /// `wl_seat.name`. It compiles the resolved keymap for this crate and for
    /// smithay; the copies must agree, and the text copy is required to answer
    /// keymap queries and restore `typeText` uploads.
    ///
    /// # Errors
    ///
    /// Returns [`SeatError`] for a duplicate identifier or name, an invalid
    /// keymap, or a keyboard that smithay refuses to create.
    pub(crate) fn create(
        &mut self,
        state: &mut SeatState<CompositorState>,
        display: &DisplayHandle,
        id: SeatId,
        name: &str,
        keyboard: &KeyboardConfig,
        defaults: &KeymapDefaults,
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

        let resolved = keymap::resolve(&keyboard.keymap, defaults);
        let keymap = Keymap::compile_resolved(&resolved).map_err(|error| SeatError {
            seat: id,
            kind: SeatErrorKind::Keymap { error },
        })?;

        let mut seat = state.new_wl_seat(display, name.to_owned());
        let pointer = seat.add_pointer();
        let handle = seat
            .add_keyboard(
                xkb_config(&resolved.names),
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
            uploaded: None,
            mouse: None,
        });
        self.seats
            .last()
            .ok_or_else(|| unreachable!("the entry was just pushed"))
    }

    /// Returns the seats and marks the one designated to bridge host selections.
    ///
    /// The registry does not own the bridge; [`crate::selection::SelectionBridge`]
    /// supplies its identifier.
    pub(crate) fn snapshot(&self, bridge: Option<SeatId>) -> Vec<SeatSnapshot> {
        self.seats
            .iter()
            .map(|entry| SeatSnapshot {
                seat: entry.id,
                name: entry.seat.name().to_owned(),
                keymap: Arc::clone(entry.keymap().text()),
                modifiers: held(entry.keyboard.modifier_state()),
                clipboard_bridge: bridge == Some(entry.id),
            })
            .collect()
    }

    /// Withdraws a seat's pointer, keyboard, and global.
    ///
    /// The caller must send pointer and keyboard leave events before calling this
    /// method. Smithay retains the seat handle in `SeatState`, but removing its
    /// capabilities and global prevents clients from using the withdrawn seat.
    ///
    /// # Errors
    ///
    /// Returns [`SeatError`] when no seat has the identifier.
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

    /// Maps a handler-provided smithay seat back to its [`SeatId`].
    ///
    /// Smithay passes the seat to per-compositor handlers without the identifier,
    /// so handlers use this mapping before accessing registry state.
    pub(crate) fn id_of(&self, seat: &Seat<CompositorState>) -> Option<SeatId> {
        self.seats
            .iter()
            .find(|entry| &entry.seat == seat)
            .map(SeatEntry::id)
    }
}

impl fmt::Debug for SeatRegistry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list().entries(self.seats.iter()).finish()
    }
}

pub(crate) struct SeatEntry {
    id: SeatId,
    seat: Seat<CompositorState>,
    pointer: PointerHandle<CompositorState>,
    keyboard: KeyboardHandle<CompositorState>,
    /// The keymap compiled in this crate for queries and restoration. Smithay
    /// compiles the same text in its own context because libxkbcommon keymaps
    /// are not thread-safe.
    keymap: Keymap,
    /// The synthetic keymap currently loaded in smithay, if any. Smithay does
    /// not expose its current keymap text, so this tracks failed restoration and
    /// prevents native strokes from being planned against the wrong layout.
    uploaded: Option<Arc<KeymapText>>,
    /// The window and pixel position currently hovered by this seat's pointer.
    mouse: Option<MouseState>,
}

impl SeatEntry {
    pub(crate) const fn id(&self) -> SeatId {
        self.id
    }

    pub(crate) fn pointer(&self) -> PointerHandle<CompositorState> {
        self.pointer.clone()
    }

    pub(crate) fn keyboard(&self) -> KeyboardHandle<CompositorState> {
        self.keyboard.clone()
    }

    pub(crate) const fn keymap(&self) -> &Keymap {
        &self.keymap
    }

    pub(crate) const fn uploaded(&self) -> Option<&Arc<KeymapText>> {
        self.uploaded.as_ref()
    }

    pub(crate) fn set_uploaded(&mut self, uploaded: Option<Arc<KeymapText>>) {
        self.uploaded = uploaded;
    }

    pub(crate) const fn mouse(&self) -> Option<MouseState> {
        self.mouse
    }

    pub(crate) const fn set_mouse(&mut self, mouse: Option<MouseState>) {
        self.mouse = mouse;
    }

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

/// The window and pixel position currently under a seat's pointer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct MouseState {
    pub(crate) hovered: WindowId,
    pub(crate) position: PixelPoint,
}

/// Stores the cursor image requested by a seat's focused client.
///
/// The handler receives no [`SeatId`], so the state is stored in that seat's
/// user-data map.
pub(crate) fn set_cursor_image(seat: &Seat<CompositorState>, image: CursorImageStatus) {
    seat.user_data().insert_if_missing(CursorImage::default);
    if let Some(cursor) = seat.user_data().get::<CursorImage>() {
        *cursor.status.borrow_mut() = image;
    }
}

/// Returns the cursor image recorded for a seat.
///
/// This test-only seam checks the per-seat `SeatHandler::cursor_image` state;
/// the compositor does not render the cursor itself.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) fn cursor_image(seat: &Seat<CompositorState>) -> CursorImageStatus {
    seat.user_data()
        .get::<CursorImage>()
        .map_or_else(CursorImageStatus::default_named, |cursor| {
            cursor.status.borrow().clone()
        })
}

/// Cursor state stored in a seat's thread-affine user-data map.
///
/// The compositor thread is the sole accessor. `RefCell` permits the handler to
/// update the value through the shared reference returned by `UserDataMap::get`;
/// `CursorImageStatus` contains a thread-affine `WlSurface`.
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SeatError {
    seat: SeatId,
    kind: SeatErrorKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum SeatErrorKind {
    DuplicateId,
    DuplicateName { name: String },
    Keymap { error: KeymapError },
    Keyboard { message: String },
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

/// Empty RMLVO names preserve libxkbcommon's default-name behavior.
fn xkb_config(keymap: &KeymapConfig) -> XkbConfig<'_> {
    fn name(value: &Option<String>) -> &str {
        value.as_deref().unwrap_or_default()
    }

    XkbConfig {
        rules: name(&keymap.rules),
        model: name(&keymap.model),
        layout: name(&keymap.layout),
        variant: name(&keymap.variant),
        options: keymap.options.clone(),
    }
}

/// Converts smithay's held modifiers to the protocol's closed set.
///
/// `Mod3` maps to smithay's `iso_level5_shift`, and `Mod5` maps to
/// `iso_level3_shift`.
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

/// Converts the protocol's modifier set to smithay's modifier state.
///
/// The serialized masks remain unset because smithay computes them from the
/// booleans and the active keymap.
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
