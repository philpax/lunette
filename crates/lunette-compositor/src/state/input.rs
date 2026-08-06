//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/mod.rs (the seat and pointer command paths at :1128-1226) and backend/wayvr/client.rs (the input methods at :229-408), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! What the main thread's input commands do.
//!
//! Split from [`crate::state::compositor`] because the two answer different
//! questions and together they are past the size threshold: that file owns the
//! globals and the state they are served from, and this one owns what arrives
//! over the protocol in [`crate::protocol::Command`] and where it is delivered.
//!
//! Every path here starts by resolving a [`SeatId`], because a command that
//! names a seat lunette does not have is refused rather than routed to whichever
//! seat happens to exist. That is the whole difference from WayVR, where one
//! seat is reached directly and a second hand has nowhere to go.

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
        KeyboardConfig, Keycode, KeymapText, ModifierState, PixelPoint, PointerButton, ScrollAxis,
        ScrollDelta, SeatId, SinkId,
    },
    seat::{self, MouseState, SeatEntry},
    state::compositor::CompositorState,
    type_text::{self, TypeStep},
    window::Window,
};

impl CompositorState {
    /// Creates a seat with its own pointer, keyboard, focus, and hover.
    pub(super) fn create_seat(&mut self, seat: SeatId, name: &str, keyboard: &KeyboardConfig) {
        match self
            .seats
            .create(&mut self.seat_state, &self.display, seat, name, keyboard)
        {
            Ok(entry) => {
                info!(seat = %entry.id(), name, "a seat was created");
                self.touch();
            }
            Err(error) => warn!(%error, "could not create a seat"),
        }
    }

    /// Presses or releases a key on a seat's keyboard.
    ///
    /// The filter always forwards, as WayVR's does (`client.rs:229-245`): the
    /// compositor never intercepts a binding, because binding policy is Lua's
    /// and a key swallowed here would be a key a configuration could not see.
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

    /// Gives a seat's keyboard focus to a sink, or takes it away.
    ///
    /// Focus is applied here, never decided here. WayVR infers it from pointer
    /// motion (`mod.rs:1128-1148`); with two hands that heuristic is per-seat
    /// policy, and `docs/input.md` puts policy in Lua.
    ///
    /// A key delivered to a seat with no focus reaches nobody, which is what
    /// `KeyboardHandle::input_forward` does with an empty focus and is the
    /// correct behaviour: an unfocused keyboard has no client to talk to.
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

    /// Replaces a seat's modifier state wholesale.
    ///
    /// The mask is set directly rather than synthesised as presses of a
    /// representative key per bit, which is what WayVR does
    /// (`mod.rs:1215-1226`). Faking modifiers as keypresses misreports the state
    /// to a client that queries it and produces key events nothing asked for;
    /// `docs/input.md:51` asks for explicit state, and this is it.
    ///
    /// smithay updates its own authoritative state but does not broadcast, so
    /// the focused surface is told separately. Without that the client would
    /// only learn about the change with the next keystroke.
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
    /// Stateful, and documented as such: it uploads a temporary layout and puts
    /// the seat's own back, so interleaving it with [`Command::Key`] on the same
    /// seat would drive keys against whichever layout happened to be loaded.
    ///
    /// The restore is unconditional. `lunette-v1.AC4.3` requires the client's own
    /// keymap handling to work afterwards, and a client left holding lunette's
    /// synthetic layout has a keyboard on which every key types the wrong thing
    /// — which is worse than whatever failure produced it. This is the one place
    /// in the phase where a failure path does not simply propagate.
    ///
    /// [`Command::Key`]: crate::protocol::Command::Key
    pub(super) fn type_text(&mut self, seat: SeatId, text: &str) {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "text was addressed to a seat that does not exist");
            return;
        };
        let keyboard = entry.keyboard();
        let handle = entry.seat().clone();
        let original = Arc::clone(entry.keymap().text());
        let held = seat::held(keyboard.modifier_state());

        let plan = match type_text::plan(text, entry.keymap(), type_text::SPARE_KEYCODES) {
            Ok(plan) => plan,
            Err(error) => {
                warn!(%seat, %error, "text could not be typed");
                return;
            }
        };
        if plan.is_empty() {
            return;
        }

        // The synthetic layout smithay is holding, which is not assumed to be
        // absent: a restore that failed on an earlier call left one loaded, and
        // a native chunk run against it would type whatever that layout binds.
        // Every way out of the loop — including a chunk that failed — passes
        // through the restore below, and what is recorded afterwards is what
        // smithay actually holds rather than what was asked for.
        let mut loaded: Option<Arc<KeymapText>> = entry.uploaded().map(Arc::clone);

        for chunk in plan.chunks() {
            let wanted = chunk.keymap().map(|text| Arc::new(text.clone()));
            if loaded != wanted {
                let text = wanted.as_deref().unwrap_or(&original);
                match self.upload_keymap(&keyboard, text) {
                    // A failed upload leaves smithay's own keymap untouched, so
                    // `loaded` is still accurate on this branch.
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

    /// Hands a layout to smithay's own copy of the keyboard.
    ///
    /// The one place an upload happens, so the record of what smithay holds
    /// cannot drift from the uploads that produced it. Its failure is injectable
    /// under test, because the restore path is the whole reason
    /// `lunette-v1.AC4.3` names the failure case and a real upload only fails on
    /// a keymap that does not compile — which is what the generator already
    /// refuses to produce.
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

    /// Presses and releases one key, with a serial and a timestamp of its own.
    ///
    /// Two serials rather than one: a serial identifies an event, and a client
    /// that sees a press and a release quoting the same number cannot tell them
    /// apart when it quotes one back.
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

    /// Brings a seat's modifiers to a set and tells its focused client.
    ///
    /// The same two halves [`Self::set_modifiers`] performs, factored out
    /// because typing changes modifiers many times per call and the seat has
    /// already been resolved by then.
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

    /// Destroys a seat, after taking its pointer and its focus off whatever
    /// they were on.
    ///
    /// Both withdrawals happen first so the clients involved see a leave.
    /// Without the pointer's, the surface keeps a pointer that has stopped
    /// existing and a toolkit that tracks hover keeps drawing the highlight;
    /// without the keyboard's, the focused client keeps its focus ring, its
    /// caret, and any input-method state alive for a seat that no longer exists.
    /// `Seat::remove_keyboard` does not do this — it clears the capability and
    /// re-sends `wl_seat.capabilities`, and sends no `wl_keyboard.leave`.
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

    /// Moves a seat's pointer onto a sink, or withdraws it.
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

    /// Which surface a point over a sink lands on, and where that surface sits.
    ///
    /// The origin is what smithay subtracts to produce the surface-local
    /// coordinates a client receives, so a popup or a subsurface is delivered to
    /// in its own frame rather than the window's. Nothing, when the point is
    /// over no surface at all; the pointer then leaves whatever it was on.
    ///
    /// The context is built per event rather than cached. A window's tree is
    /// tens of surfaces at most, and a cache would have to be invalidated from
    /// every commit, every subsurface move, and every popup configure — three
    /// places for it to go stale against one walk that is already cheap.
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

    /// Presses or releases a pointer button over a sink.
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

    /// Scrolls one axis over a sink.
    ///
    /// One axis per call, and one `wl_pointer.frame` around it. A caller with a
    /// diagonal delta sends two, which a client accumulates: the protocol's own
    /// axis events are per-axis, and folding two into one frame would make a
    /// vertical-only scroll indistinguishable from a diagonal one that happened
    /// to have a zero horizontal component.
    ///
    /// The two delta forms stay apart all the way down, because a client uses
    /// the difference to decide whether to scroll kinetically. A discrete step
    /// carries the notch count as well as a distance, since `wl_pointer.axis` is
    /// the one event every version receives and a client older than version 5
    /// sees nothing else.
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
            // No steps and no stop event: `AxisSource::Finger` would oblige the
            // caller to say when the finger lifted, and nothing above this knows
            // that — a thumbstick deflection has no lift.
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

    /// The seat's pointer, when that pointer is over the named sink.
    ///
    /// An event goes to whatever this seat's pointer is over, which the protocol
    /// requires and a caller can get wrong by naming a sink it never moved that
    /// seat's pointer onto. Another seat hovering the sink does not qualify: its
    /// pointer is a different pointer.
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

/// How many surface-local units `wl_pointer.axis` carries per wheel detent.
///
/// The convention every toolkit reads a continuous scroll under, and what the
/// Lua side divides by when it converts the other way.
const SURFACE_UNITS_PER_DETENT: f64 = 10.0;

/// What `wl_pointer.axis_value120` counts per wheel detent.
///
/// smithay accumulates these and emits `axis_discrete` for a client older than
/// version 8, so a partial detent is carried rather than rounded away.
const V120_PER_DETENT: i32 = 120;

/// Why a layout could not be handed to smithay's copy of the keyboard.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum KeymapUploadError {
    /// smithay would not compile the text. Its `Error` is not `PartialEq` and
    /// what a caller does with it is report it, so the message is kept instead.
    Refused { message: String },
    /// A failure a test asked for, to exercise the restore path.
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
/// The side and extra buttons are what libinput reports for back and forward,
/// which is what applications listen for; `BTN_BACK` and `BTN_FORWARD` exist
/// but are sent by almost nothing.
pub(super) const fn evdev_button(button: PointerButton) -> u32 {
    match button {
        PointerButton::Left => 0x110,
        PointerButton::Right => 0x111,
        PointerButton::Middle => 0x112,
        PointerButton::Back => 0x113,
        PointerButton::Forward => 0x114,
    }
}
