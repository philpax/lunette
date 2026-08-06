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

use smithay::{
    backend::input::{ButtonState, KeyState},
    input::{
        keyboard::{FilterResult, KeyboardTarget, Keycode as XkbKeycode},
        pointer::{ButtonEvent, MotionEvent},
    },
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::{Logical, Point},
};
use tracing::{debug, info, warn};

use crate::{
    hit_test::{self, HitTarget},
    keymap::XKB_KEYCODE_OFFSET,
    protocol::{KeyboardConfig, Keycode, ModifierState, PixelPoint, PointerButton, SeatId, SinkId},
    seat::{self, MouseState, SeatEntry},
    state::compositor::CompositorState,
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

        let serial = self.serials.next_serial();
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

        let serial = self.serials.next_serial();
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

        if keyboard.set_modifier_state(seat::modifiers_state(modifiers)) == 0 {
            return;
        }

        if let Some(focus) = keyboard.current_focus() {
            let serial = self.serials.next_serial();
            KeyboardTarget::modifiers(&focus, &handle, self, keyboard.modifier_state(), serial);
        }
        self.touch();
    }

    /// Destroys a seat, after taking its pointer off whatever it was over.
    ///
    /// The withdrawal happens first so the client under the pointer sees a
    /// leave. Without it the surface keeps a pointer that has stopped existing,
    /// and a toolkit that tracks hover keeps drawing the highlight.
    pub(super) fn destroy_seat(&mut self, seat: SeatId) {
        if self.seats.get(seat).is_none() {
            warn!(%seat, "a destroy was asked for a seat that does not exist");
            return;
        }

        self.move_pointer(seat, None);
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
            serial: self.serials.next_serial(),
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
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return;
        };
        let pointer = entry.pointer();
        let hovering = entry.mouse();

        let Some(window) = self.windows.by_sink(sink).map(Window::id) else {
            debug!(%sink, "a button was pressed over a sink that is already gone");
            return;
        };

        // A button goes to whatever this seat's pointer is over, which the
        // protocol requires and a caller can get wrong by naming a sink it never
        // moved that seat's pointer onto. Another seat hovering the sink does
        // not qualify: its pointer is a different pointer.
        match hovering {
            Some(mouse) if mouse.hovered == window => {}
            _ => {
                warn!(
                    %seat,
                    %sink,
                    "a button was pressed over a sink the seat's pointer is not on; move it first"
                );
                return;
            }
        }

        let event = ButtonEvent {
            serial: self.serials.next_serial(),
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
}

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
