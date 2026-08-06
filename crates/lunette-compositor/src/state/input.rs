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
    backend::input::ButtonState,
    input::pointer::{ButtonEvent, MotionEvent},
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::{Logical, Point},
};
use tracing::{debug, info, warn};

use crate::{
    hit_test::{self, HitTarget},
    protocol::{PixelPoint, PointerButton, SeatId, SinkId},
    seat::{MouseState, SeatEntry},
    state::compositor::CompositorState,
    window::Window,
};

impl CompositorState {
    /// Creates a seat with its own pointer, focus, and hover.
    pub(super) fn create_seat(&mut self, seat: SeatId, name: &str) {
        match self
            .seats
            .create(&mut self.seat_state, &self.display, seat, name)
        {
            Ok(entry) => info!(seat = %entry.id(), name, "a seat was created"),
            Err(error) => warn!(%error, "could not create a seat"),
        }
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
            Ok(()) => info!(%seat, "a seat was destroyed"),
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
