//! Applies the seat and input commands.
//!
//! Each command resolves its [`SeatId`] before delivery. An unknown seat is
//! refused; it is not routed to another seat. The delivery itself runs
//! through WayVR's input methods on [`WayVRCompositor`], one seat's view of
//! the state, in `src/wayvr/client.rs`. This module adds what lunette's
//! commands need beyond them: per-seat hover, keyboard focus, explicit
//! modifier state, typing text through a synthetic layout, and continuous
//! scrolling.

use std::{error::Error, fmt, sync::Arc};

use glam::{DVec2, Vec2};
use smithay::{
    backend::input::{Axis, AxisSource},
    input::{Seat, keyboard::KeyboardTarget, pointer::AxisFrame},
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::SERIAL_COUNTER,
};
use tracing::{debug, info, warn};

use crate::{
    keymap::XKB_KEYCODE_OFFSET,
    protocol::{
        KeyboardConfig, Keycode, KeymapText, ModifierState, PixelPoint, PointerButton, ScrollAxis,
        ScrollDelta, SeatId, SinkId,
    },
    seat::{self, MouseState},
    type_text::{self, TypePlan, TypeStep},
    wayvr::{
        client::{WayVRCompositor, WheelDelta},
        comp::Application,
        hit_test::{self, WvrHitTarget},
    },
};

impl Application {
    pub(crate) fn create_seat(&mut self, seat: SeatId, name: &str, keyboard: &KeyboardConfig) {
        match self.seats.create(
            &mut self.seat_state,
            &self.display_handle,
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
    pub(crate) fn press_key(&mut self, seat: SeatId, key: Keycode, pressed: bool) {
        let Some(mut compositor) = self.seat_view(seat) else {
            warn!(%seat, "a key was addressed to a seat that does not exist");
            return;
        };

        compositor.send_key(xkb_keycode(key), pressed);
        self.touch();
    }

    /// A key sent to a seat without focus reaches no client.
    pub(crate) fn set_focus(&mut self, seat: SeatId, sink: Option<SinkId>) {
        let Some(keyboard) = self
            .seats
            .get(seat)
            .map(|entry| entry.seat_keyboard.clone())
        else {
            warn!(%seat, "focus was addressed to a seat that does not exist");
            return;
        };

        let surface = match sink {
            Some(sink) => match self.windows.by_sink(sink) {
                Some(window) => Some(window.toplevel.wl_surface().clone()),
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
    pub(crate) fn set_modifiers(&mut self, seat: SeatId, modifiers: &ModifierState) {
        let Some(handle) = self.seats.get(seat).map(|entry| entry.seat().clone()) else {
            warn!(%seat, "modifiers were addressed to a seat that does not exist");
            return;
        };
        let Some(mut compositor) = self.seat_view(seat) else {
            return;
        };

        compositor.apply_modifiers(&handle, modifiers);
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
    pub(crate) fn type_text(&mut self, seat: SeatId, text: &str) {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "text was addressed to a seat that does not exist");
            return;
        };
        let handle = entry.seat().clone();
        let original = Arc::clone(entry.keymap().text());
        let held = seat::held(entry.seat_keyboard.modifier_state());

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

        let Some(mut compositor) = self.seat_view(seat) else {
            return;
        };

        for chunk in plan.iter().flat_map(TypePlan::chunks) {
            let wanted = chunk.keymap().map(|text| Arc::new(text.clone()));
            if loaded != wanted {
                let text = wanted.as_deref().unwrap_or(&original);
                match compositor.upload_keymap(text) {
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
                        compositor.apply_modifiers(&handle, modifiers);
                    }
                    TypeStep::Tap(key) => compositor.tap(*key),
                }
            }
        }

        if loaded.is_some() {
            match compositor.upload_keymap(&original) {
                Ok(()) => loaded = None,
                Err(error) => {
                    warn!(%seat, %error, "the seat's own layout could not be restored");
                }
            }
        }

        compositor.apply_modifiers(&handle, &held);
        if let Some(entry) = self.seats.get_mut(seat) {
            entry.set_uploaded(loaded);
        }
        self.touch();
    }

    /// Sends pointer and keyboard leave events before destroying the seat.
    /// Removing the keyboard capability alone does not send `wl_keyboard.leave`.
    pub(crate) fn destroy_seat(&mut self, seat: SeatId) {
        if self.seats.get(seat).is_none() {
            warn!(%seat, "a destroy was asked for a seat that does not exist");
            return;
        }

        self.cancel_drag(seat);
        self.move_pointer(seat, None);
        self.set_focus(seat, None);
        match self.seats.destroy(&self.display_handle, seat) {
            Ok(()) => {
                info!(%seat, "a seat was destroyed");
                self.touch();
            }
            Err(error) => warn!(%error, "could not destroy a seat"),
        }
    }

    /// Moves the seat's pointer onto a sink, or withdraws it.
    ///
    /// The relative motion is the distance from the seat's last position on the
    /// same window, and nothing when the pointer arrives from elsewhere, as
    /// upstream's `get_mouse_relative` has it.
    pub(crate) fn move_pointer(&mut self, seat: SeatId, target: Option<(SinkId, PixelPoint)>) {
        let Some(previous) = self.seats.get(seat).map(seat::SeatEntry::mouse) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return;
        };

        let focus = target.and_then(|(sink, position)| self.focus_at(sink, position));

        let hovered = target.and_then(|(sink, position)| {
            Some(MouseState {
                hovered: self.windows.by_sink(sink)?.id,
                position,
            })
        });
        let delta = match (previous, hovered) {
            (Some(previous), Some(hovered)) if previous.hovered == hovered.hovered => DVec2::new(
                hovered.position.x - previous.position.x,
                hovered.position.y - previous.position.y,
            ),
            _ => DVec2::ZERO,
        };
        if let Some(entry) = self.seats.get_mut(seat) {
            entry.set_mouse(hovered);
        }

        let global_pos = target.map_or(DVec2::new(-1.0, -1.0), |(_, position)| {
            DVec2::new(position.x, position.y)
        });

        if let Some(mut compositor) = self.seat_view(seat) {
            compositor.send_mouse_move(focus, global_pos, delta, delta);
        }
    }

    /// Returns the pointer target and its origin for the given point. smithay
    /// subtracts the origin for surface-local coordinates, so popup and
    /// subsurface events use their own frame.
    fn focus_at(&self, sink: SinkId, position: PixelPoint) -> Option<(WlSurface, Vec2)> {
        let window = self.windows.by_sink(sink)?;
        let toplevel = window.toplevel.wl_surface().clone();

        let size = window.size();
        let context =
            hit_test::build_hit_context(&toplevel, &self.popup_manager, [size.width, size.height]);

        #[expect(
            clippy::cast_possible_truncation,
            reason = "upstream's hit test works in f32, which is exact for any point on a window"
        )]
        let client_pos = Vec2::new(position.x as f32, position.y as f32);

        match context.hit_target_at(client_pos)? {
            WvrHitTarget::Toplevel { .. } => Some((toplevel, Vec2::ZERO)),
            WvrHitTarget::Surface {
                surface, origin, ..
            }
            | WvrHitTarget::Popup {
                surface, origin, ..
            } => Some((surface, origin)),
        }
    }

    /// Presses or releases a button over a sink.
    ///
    /// A press needs the seat's pointer over the sink. A release is also
    /// accepted on the sink the button was pressed on, wherever the pointer
    /// has moved since: the pressed client holds the pointer until the
    /// release, and a drag drops on it.
    pub(crate) fn press_button(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        button: PointerButton,
        pressed: bool,
    ) {
        let window = self.windows.by_sink(sink).map(|window| window.id);
        let held_here = !pressed
            && window.is_some_and(|window| {
                self.seats
                    .get(seat)
                    .is_some_and(|entry| entry.pressed_on(button, window))
            });
        let what = if pressed {
            "a button was pressed"
        } else {
            "a button was released"
        };
        if !held_here && !self.pointer_over(seat, sink, what) {
            return;
        }
        if let (Some(window), Some(entry)) = (window, self.seats.get_mut(seat)) {
            entry.remember_press(button, window, pressed);
        }
        if let Some(mut compositor) = self.seat_view(seat) {
            compositor.send_pointer_button(button, pressed);
        }
    }

    /// Sends one axis event in one `wl_pointer.frame`. A diagonal delta uses a
    /// separate call for each axis, so clients accumulate the components.
    ///
    /// Continuous and discrete deltas remain distinct. Clients use the
    /// difference for kinetic scrolling. A discrete delta carries both a
    /// distance and a step count, because clients older than version 5 receive
    /// `wl_pointer.axis` only.
    pub(crate) fn scroll(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        axis: ScrollAxis,
        delta: ScrollDelta,
    ) {
        if !self.pointer_over(seat, sink, "a scroll was sent") {
            return;
        }
        let Some(mut compositor) = self.seat_view(seat) else {
            return;
        };

        match delta {
            ScrollDelta::Continuous(distance) => {
                compositor.send_pointer_axis_continuous(axis, distance);
            }
            ScrollDelta::Discrete(steps) => {
                // smithay accumulates the v120 units and emits `axis_discrete`
                // for a client older than version 8. A partial detent is
                // preserved; it is not rounded away.
                let v120 = steps.saturating_mul(V120_PER_DETENT);
                compositor.send_pointer_axis_wheel_raw(match axis {
                    ScrollAxis::Vertical => WheelDelta { x: 0, y: v120 },
                    ScrollAxis::Horizontal => WheelDelta { x: v120, y: 0 },
                });
            }
        }
    }

    /// Whether the seat's pointer is over the named sink. The sink must be the
    /// surface currently under this seat's pointer; another seat's pointer
    /// does not qualify.
    fn pointer_over(&self, seat: SeatId, sink: SinkId, what: &'static str) -> bool {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return false;
        };

        let Some(window) = self.windows.by_sink(sink).map(|window| window.id) else {
            debug!(%sink, "{what} over a sink that is already gone");
            return false;
        };

        match entry.mouse() {
            Some(mouse) if mouse.hovered == window => true,
            _ => {
                warn!(
                    %seat,
                    %sink,
                    "{what} over a sink the seat's pointer is not on; move it first"
                );
                false
            }
        }
    }

    /// Takes the named seat's view of the state, which the input methods run
    /// against, with the compositor clock read once for its timestamps.
    pub(crate) fn seat_view(&mut self, seat: SeatId) -> Option<WayVRCompositor<'_>> {
        let entry = self.seats.get(seat)?;
        let seat_keyboard = entry.seat_keyboard.clone();
        let seat_pointer = entry.seat_pointer.clone();
        let millis = self.millis();
        let micros = u64::try_from(self.elapsed().as_micros()).unwrap_or(u64::MAX);

        Some(WayVRCompositor {
            state: self,
            seat_keyboard,
            seat_pointer,
            serial_counter: &SERIAL_COUNTER,
            millis,
            micros,
        })
    }
}

impl WayVRCompositor<'_> {
    /// Routes all keymap changes through one path so the tracked layout stays
    /// synchronized with smithay's keyboard. Tests can inject a failure here
    /// because smithay normally rejects only an invalid layout, which the
    /// generator does not produce.
    fn upload_keymap(&mut self, text: &KeymapText) -> Result<(), KeymapUploadError> {
        #[cfg(any(test, feature = "test-fakes"))]
        if self.state.take_upload_failure() {
            return Err(KeymapUploadError::Injected);
        }

        self.set_keymap(text)
    }

    /// The press and release use different serials because a serial identifies
    /// an event. Reusing one would make them indistinguishable when a client
    /// quotes it back.
    fn tap(&mut self, key: Keycode) {
        self.send_key(xkb_keycode(key), true);
        self.send_key(xkb_keycode(key), false);
    }

    /// smithay updates its own modifier state without notifying the focused
    /// surface, so this sends the update separately.
    fn apply_modifiers(&mut self, handle: &Seat<Application>, modifiers: &ModifierState) {
        let keyboard = &self.seat_keyboard;
        if keyboard.set_modifier_state(seat::modifiers_state(modifiers)) == 0 {
            return;
        }
        if let Some(focus) = keyboard.current_focus() {
            let serial = self.serial_counter.next_serial();
            KeyboardTarget::modifiers(
                &focus,
                handle,
                self.state,
                keyboard.modifier_state(),
                serial,
            );
        }
    }

    /// A thumbstick has no release event, so `AxisSource::Finger` cannot
    /// represent its lifecycle, and a continuous scroll is reported as
    /// `AxisSource::Continuous`.
    fn send_pointer_axis_continuous(&mut self, axis: ScrollAxis, distance: f64) {
        let axis = match axis {
            ScrollAxis::Vertical => Axis::Vertical,
            ScrollAxis::Horizontal => Axis::Horizontal,
        };
        let frame = AxisFrame::new(self.millis)
            .source(AxisSource::Continuous)
            .value(axis, distance);

        self.seat_pointer.axis(self.state, frame);
        self.seat_pointer.frame(self.state);
    }
}

/// What `wl_pointer.axis_value120` counts per wheel detent.
const V120_PER_DETENT: i32 = 120;

/// The XKB keycode for an evdev keycode, which upstream's `send_key` takes.
fn xkb_keycode(key: Keycode) -> u32 {
    key.evdev().saturating_add(XKB_KEYCODE_OFFSET)
}

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
