//! Adapted from the seat and pointer command paths in WayVR's
//! `backend/wayvr/mod.rs` and the input methods in `backend/wayvr/client.rs`
//! (https://github.com/wayvr-org/wayvr), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Each command resolves its [`SeatId`] before delivery. An unknown seat is
//! refused; it is not routed to another seat.

use std::{error::Error, fmt, sync::Arc};

use smithay::{
    backend::input::{Axis, AxisSource, ButtonState, KeyState},
    input::{
        Seat,
        keyboard::{FilterResult, KeyboardHandle, KeyboardTarget, Keycode as XkbKeycode},
        pointer::{AxisFrame, ButtonEvent, MotionEvent, PointerHandle},
    },
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::{Logical, Point, SERIAL_COUNTER},
};
use tracing::{debug, info, warn};

use crate::{
    hit_test::{self, HitTarget},
    keymap::XKB_KEYCODE_OFFSET,
    protocol::{
        KeyboardConfig, Keycode, KeymapText, ModifierState, PixelPoint, PointerButton,
        SURFACE_UNITS_PER_DETENT, ScrollAxis, ScrollDelta, SeatId, SinkId,
    },
    seat::{self, MouseState, SeatEntry},
    state::compositor::CompositorState,
    type_text::{self, TypePlan, TypeStep},
    window::Window,
};

impl CompositorState {
    pub(super) fn create_seat(&mut self, seat: SeatId, name: &str, keyboard: &KeyboardConfig) {
        match self.seats.create(
            &mut self.seat_state,
            &self.display,
            seat,
            name,
            keyboard,
            &self.config.keymap_defaults,
        ) {
            Ok(entry) => {
                info!(seat = %entry.id(), name, "a seat was created");
                self.touch();
            }
            Err(error) => warn!(%error, "could not create a seat"),
        }
    }

    /// The compositor forwards every key event. Binding policy belongs to Lua,
    /// and the compositor must not swallow a key before the configuration sees
    /// it.
    pub(super) fn press_key(&mut self, seat: SeatId, key: Keycode, pressed: bool) {
        let Some(keyboard) = self.seats.get(seat).map(SeatEntry::keyboard) else {
            warn!(%seat, "a key was addressed to a seat that does not exist");
            return;
        };

        let serial = SERIAL_COUNTER.next_serial();
        let time = self.millis();
        let state = if pressed {
            KeyState::Pressed
        } else {
            KeyState::Released
        };

        keyboard.input::<(), _>(
            self,
            XkbKeycode::new(key.evdev().saturating_add(XKB_KEYCODE_OFFSET)),
            state,
            serial,
            time,
            |_, _, _| FilterResult::Forward,
        );
        self.touch();
    }

    /// A key sent to a seat without focus reaches no client.
    pub(super) fn set_focus(&mut self, seat: SeatId, sink: Option<SinkId>) {
        let Some(keyboard) = self.seats.get(seat).map(SeatEntry::keyboard) else {
            warn!(%seat, "focus was addressed to a seat that does not exist");
            return;
        };

        let surface = match sink {
            Some(sink) => match self.windows.by_sink(sink) {
                Some(window) => Some(window.toplevel().wl_surface().clone()),
                None => {
                    debug!(%sink, "focus was asked for a sink that is already gone");
                    return;
                }
            },
            None => None,
        };

        let serial = SERIAL_COUNTER.next_serial();
        keyboard.set_focus(self, surface, serial);
    }

    /// Updates the modifier mask without synthesising key presses, which would
    /// misreport the state and send unsolicited key events.
    ///
    /// smithay updates its own state without notifying the focused surface, so
    /// this method sends the update separately.
    pub(super) fn set_modifiers(&mut self, seat: SeatId, modifiers: &ModifierState) {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "modifiers were addressed to a seat that does not exist");
            return;
        };
        let keyboard = entry.keyboard();
        let handle = entry.seat().clone();

        self.apply_modifiers(&keyboard, &handle, modifiers);
        self.touch();
    }

    /// Types text the seat's layout may not be able to express.
    ///
    /// This method may upload a synthetic layout and attempts to restore the
    /// seat's layout before it returns. Do not interleave it with key events on
    /// the same seat.
    ///
    /// After a failure while typing, the method attempts to restore any
    /// synthetic layout already loaded. If that restore fails, the synthetic
    /// layout remains tracked, so later requests can repair it before native
    /// typing.
    pub(super) fn type_text(&mut self, seat: SeatId, text: &str) {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "text was addressed to a seat that does not exist");
            return;
        };
        let keyboard = entry.keyboard();
        let handle = entry.seat().clone();
        let original = Arc::clone(entry.keymap().text());
        let held = seat::held(keyboard.modifier_state());

        // Track smithay's actual layout, including one left by a failed restore,
        // so native chunks are not typed against a stale synthetic layout.
        let mut loaded: Option<Arc<KeymapText>> = entry.uploaded().map(Arc::clone);

        let plan = match type_text::plan(text, entry.keymap(), type_text::SPARE_KEYCODES) {
            Ok(plan) => (!plan.is_empty()).then_some(plan),
            Err(error) => {
                warn!(%seat, %error, "text could not be typed");
                None
            }
        };

        // A failed restore can leave a synthetic layout loaded even when this
        // request produces no typing plan, so keep running to repair it.
        if plan.is_none() && loaded.is_none() {
            return;
        }

        for chunk in plan.iter().flat_map(TypePlan::chunks) {
            let wanted = chunk.keymap().map(|text| Arc::new(text.clone()));
            if loaded != wanted {
                let text = wanted.as_deref().unwrap_or(&original);
                match self.upload_keymap(&keyboard, text) {
                    Ok(()) => loaded = wanted,
                    Err(error) => {
                        warn!(%seat, %error, "a layout could not be uploaded while typing");
                        break;
                    }
                }
            }

            for step in chunk.steps() {
                match step {
                    TypeStep::Modifiers(modifiers) => {
                        self.apply_modifiers(&keyboard, &handle, modifiers);
                    }
                    TypeStep::Tap(key) => self.tap(&keyboard, *key),
                }
            }
        }

        if loaded.is_some() {
            match self.upload_keymap(&keyboard, &original) {
                Ok(()) => loaded = None,
                Err(error) => {
                    warn!(%seat, %error, "the seat's own layout could not be restored");
                }
            }
        }

        if let Some(entry) = self.seats.get_mut(seat) {
            entry.set_uploaded(loaded);
        }
        self.apply_modifiers(&keyboard, &handle, &held);
        self.touch();
    }

    /// Routes all keymap changes through one path so the tracked layout stays
    /// synchronized with smithay's keyboard. Tests can inject a failure here
    /// because smithay normally rejects only an invalid layout, which the
    /// generator does not produce.
    fn upload_keymap(
        &mut self,
        keyboard: &KeyboardHandle<Self>,
        text: &KeymapText,
    ) -> Result<(), KeymapUploadError> {
        #[cfg(any(test, feature = "test-fakes"))]
        if self.take_upload_failure() {
            return Err(KeymapUploadError::Injected);
        }

        keyboard
            .set_keymap_from_string(self, text.as_str().to_owned())
            .map_err(|error| KeymapUploadError::Refused {
                message: error.to_string(),
            })
    }

    /// The press and release use different serials because a serial identifies
    /// an event. Reusing one would make them indistinguishable when a client
    /// quotes it back.
    fn tap(&mut self, keyboard: &KeyboardHandle<Self>, key: Keycode) {
        for state in [KeyState::Pressed, KeyState::Released] {
            let serial = SERIAL_COUNTER.next_serial();
            let time = self.millis();
            keyboard.input::<(), _>(
                self,
                XkbKeycode::new(key.evdev().saturating_add(XKB_KEYCODE_OFFSET)),
                state,
                serial,
                time,
                |_, _, _| FilterResult::Forward,
            );
        }
    }

    fn apply_modifiers(
        &mut self,
        keyboard: &KeyboardHandle<Self>,
        handle: &Seat<Self>,
        modifiers: &ModifierState,
    ) {
        if keyboard.set_modifier_state(seat::modifiers_state(modifiers)) == 0 {
            return;
        }
        if let Some(focus) = keyboard.current_focus() {
            let serial = SERIAL_COUNTER.next_serial();
            KeyboardTarget::modifiers(&focus, handle, self, keyboard.modifier_state(), serial);
        }
    }

    /// Sends pointer and keyboard leave events before destroying the seat.
    /// Removing the keyboard capability alone does not send `wl_keyboard.leave`.
    pub(super) fn destroy_seat(&mut self, seat: SeatId) {
        if self.seats.get(seat).is_none() {
            warn!(%seat, "a destroy was asked for a seat that does not exist");
            return;
        }

        self.move_pointer(seat, None);
        self.set_focus(seat, None);
        match self.seats.destroy(&self.display, seat) {
            Ok(()) => {
                info!(%seat, "a seat was destroyed");
                self.touch();
            }
            Err(error) => warn!(%error, "could not destroy a seat"),
        }
    }

    pub(super) fn move_pointer(&mut self, seat: SeatId, target: Option<(SinkId, PixelPoint)>) {
        let Some(pointer) = self.seats.get(seat).map(SeatEntry::pointer) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return;
        };

        let focus = target.and_then(|(sink, position)| self.focus_at(sink, position));

        let hovered = target.and_then(|(sink, position)| {
            Some(MouseState {
                hovered: self.windows.by_sink(sink)?.id(),
                position,
            })
        });
        if let Some(entry) = self.seats.get_mut(seat) {
            entry.set_mouse(hovered);
        }

        let location = target.map_or_else(
            || Point::from((-1.0, -1.0)),
            |(_, position)| Point::from((position.x, position.y)),
        );

        let event = MotionEvent {
            location,
            serial: SERIAL_COUNTER.next_serial(),
            time: self.millis(),
        };

        pointer.motion(self, focus, &event);
        pointer.frame(self);
    }

    /// Returns the pointer target and its origin for the given point. smithay
    /// subtracts the origin for surface-local coordinates, so popup and
    /// subsurface events use their own frame.
    fn focus_at(
        &self,
        sink: SinkId,
        position: PixelPoint,
    ) -> Option<(WlSurface, Point<f64, Logical>)> {
        let window = self.windows.by_sink(sink)?;
        let toplevel = window.toplevel().wl_surface().clone();

        let context = hit_test::context(&toplevel, window.size(), &|surface| {
            self.surfaces
                .get(surface)
                .and_then(|id| self.contents.get(&id))
                .map(|content| content.logical_size())
        });

        match context.target_at(position)? {
            HitTarget::Toplevel { .. } => Some((toplevel, Point::from((0.0, 0.0)))),
            HitTarget::Surface {
                surface, origin, ..
            }
            | HitTarget::Popup {
                surface, origin, ..
            } => Some((surface, Point::from((origin.x, origin.y)))),
        }
    }

    pub(super) fn press_button(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        button: PointerButton,
        pressed: bool,
    ) {
        let Some(pointer) = self.pointer_over(seat, sink, "a button was pressed") else {
            return;
        };

        let event = ButtonEvent {
            serial: SERIAL_COUNTER.next_serial(),
            time: self.millis(),
            button: evdev_button(button),
            state: if pressed {
                ButtonState::Pressed
            } else {
                ButtonState::Released
            },
        };

        pointer.button(self, &event);
        pointer.frame(self);
    }

    /// Sends one axis event in one `wl_pointer.frame`. A diagonal delta uses a
    /// separate call for each axis, so clients accumulate the components.
    ///
    /// Continuous and discrete deltas remain distinct. Clients use the
    /// difference for kinetic scrolling. A discrete delta carries both a
    /// distance and a step count, because clients older than version 5 receive
    /// `wl_pointer.axis` only.
    pub(super) fn scroll(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        axis: ScrollAxis,
        delta: ScrollDelta,
    ) {
        let Some(pointer) = self.pointer_over(seat, sink, "a scroll was sent") else {
            return;
        };

        let axis = match axis {
            ScrollAxis::Vertical => Axis::Vertical,
            ScrollAxis::Horizontal => Axis::Horizontal,
        };

        let frame = AxisFrame::new(self.millis());
        let frame = match delta {
            // A thumbstick has no release event, so `AxisSource::Finger` cannot
            // represent its lifecycle.
            ScrollDelta::Continuous(distance) => {
                frame.source(AxisSource::Continuous).value(axis, distance)
            }
            ScrollDelta::Discrete(steps) => frame
                .source(AxisSource::Wheel)
                .v120(axis, steps.saturating_mul(V120_PER_DETENT))
                .value(axis, f64::from(steps) * SURFACE_UNITS_PER_DETENT),
        };

        pointer.axis(self, frame);
        pointer.frame(self);
    }

    /// The seat's pointer, when that pointer is over the named sink. The sink
    /// must be the surface currently under this seat's pointer; another seat's
    /// pointer does not qualify.
    fn pointer_over(
        &self,
        seat: SeatId,
        sink: SinkId,
        what: &'static str,
    ) -> Option<PointerHandle<Self>> {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return None;
        };
        let pointer = entry.pointer();
        let hovering = entry.mouse();

        let Some(window) = self.windows.by_sink(sink).map(Window::id) else {
            debug!(%sink, "{what} over a sink that is already gone");
            return None;
        };

        match hovering {
            Some(mouse) if mouse.hovered == window => Some(pointer),
            _ => {
                warn!(
                    %seat,
                    %sink,
                    "{what} over a sink the seat's pointer is not on; move it first"
                );
                None
            }
        }
    }
}

/// What `wl_pointer.axis_value120` counts per wheel detent.
///
/// smithay accumulates these and emits `axis_discrete` for a client older than
/// version 8. A partial detent is preserved; it is not rounded away.
const V120_PER_DETENT: i32 = 120;

/// Describes a keymap upload failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum KeymapUploadError {
    /// Keeps smithay's diagnostic as text because its error type is not comparable.
    Refused { message: String },
    #[cfg(any(test, feature = "test-fakes"))]
    Injected,
}

impl fmt::Display for KeymapUploadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused { message } => write!(f, "keymap: smithay refused a layout: {message}"),
            #[cfg(any(test, feature = "test-fakes"))]
            Self::Injected => f.write_str("keymap: a test asked this upload to fail"),
        }
    }
}

impl Error for KeymapUploadError {}

/// Maps a pointer button onto the evdev code `wl_pointer.button` carries.
///
/// The side and extra buttons use the evdev codes applications expect for back
/// and forward actions.
pub(super) const fn evdev_button(button: PointerButton) -> u32 {
    match button {
        PointerButton::Left => 0x110,
        PointerButton::Right => 0x111,
        PointerButton::Middle => 0x112,
        PointerButton::Back => 0x113,
        PointerButton::Forward => 0x114,
    }
}
