//! The drag each seat's pointer carries.
//!
//! smithay runs a drag as a pointer grab and reports its start and its drop
//! through `ClientDndGrabHandler`, whose handlers in `src/wayvr/comp.rs` call
//! [`Application::begin_drag`] and [`Application::end_drag`]. The record kept
//! here is what the seat snapshot reports: which drag is under way, and the
//! icon that follows the pointer.
//!
//! A drag ends when the seat's buttons are released, which Lua sends to the
//! window that was pressed wherever the pointer has moved since. Lua sends no
//! release to a window that has gone, so a drag whose window closes, or whose
//! data source is destroyed, is cancelled here instead: the pointer leaves the
//! drag's target, and the grab is unset with nothing under it, which cancels
//! the source.

use glam::DVec2;
use smithay::{
    reexports::wayland_server::{
        Resource,
        protocol::{wl_data_source::WlDataSource, wl_surface::WlSurface},
    },
    utils::SERIAL_COUNTER,
    wayland::compositor::{SurfaceAttributes, with_states},
};
use tracing::debug;

use crate::{
    protocol::{
        DragIcon, DragId, DragSnapshot, PixelSize, SeatId, SurfaceId, SurfaceOffset, WindowId,
    },
    surface::committed_view,
    wayvr::comp::Application,
};

/// A drag a client started from a press of one seat's pointer.
#[derive(Debug)]
pub(crate) struct ActiveDrag {
    id: DragId,
    /// The window the press that started the drag went to.
    origin: Option<WindowId>,
    /// The data the drag carries. A drag within one client may carry none.
    source: Option<WlDataSource>,
    icon: Option<(WlSurface, SurfaceId)>,
    /// The icon's top-left corner relative to the pointer, accumulated from
    /// the offsets the client committed to the icon.
    offset: SurfaceOffset,
}

impl ActiveDrag {
    pub(crate) fn snapshot(&self) -> DragSnapshot {
        let icon = self.icon.as_ref().and_then(|(surface, id)| {
            let (size, source_crop) = with_states(surface, committed_view)?;
            Some(DragIcon {
                surface: *id,
                size: PixelSize::new(
                    u32::try_from(size.w).unwrap_or(0),
                    u32::try_from(size.h).unwrap_or(0),
                ),
                source_crop,
                offset: self.offset,
            })
        });
        DragSnapshot {
            drag: self.id,
            icon,
        }
    }
}

impl Application {
    /// Records the drag a client started with `seat`'s pointer.
    ///
    /// The record is made in the handler, not after dispatch, because a
    /// client commits its icon's first content in the same dispatch as the
    /// request that starts the drag.
    pub(crate) fn begin_drag(
        &mut self,
        seat: SeatId,
        source: Option<WlDataSource>,
        icon: Option<WlSurface>,
    ) {
        let icon = icon.map(|surface| {
            let id = self.surfaces.id_for(&surface);
            (surface, id)
        });
        let id = self.seats.mint_drag();
        let Some(entry) = self.seats.get_mut(seat) else {
            return;
        };
        let drag = ActiveDrag {
            id,
            origin: entry.pressed_window(),
            source,
            icon,
            offset: SurfaceOffset::default(),
        };
        debug!(%seat, drag = %id, icon = drag.icon.is_some(), "a client started a drag");
        entry.set_drag(Some(drag));
        self.touch();
    }

    /// Forgets the drag `seat`'s pointer carried, after a drop or a
    /// cancellation.
    pub(crate) fn end_drag(&mut self, seat: SeatId) {
        let Some(entry) = self.seats.get_mut(seat) else {
            return;
        };
        if let Some(drag) = entry.set_drag(None) {
            debug!(%seat, drag = %drag.id, "a drag ended");
            self.touch();
        }
    }

    /// Cancels each drag whose window has gone or whose data source the
    /// client destroyed.
    pub(crate) fn cancel_orphaned_drags(&mut self) {
        let orphaned: Vec<SeatId> = self
            .seats
            .iter()
            .filter(|entry| {
                entry.drag().is_some_and(|drag| {
                    let window_gone = drag.origin.is_some_and(|origin| {
                        self.windows.get(origin).is_none_or(|window| !window.mapped)
                    });
                    let source_gone = drag
                        .source
                        .as_ref()
                        .is_some_and(|source| !source.is_alive());
                    window_gone || source_gone
                })
            })
            .map(|entry| entry.id())
            .collect();
        for seat in orphaned {
            debug!(%seat, "the window or data a drag started from is gone; cancelling it");
            self.cancel_drag(seat);
        }
    }

    /// Ends `seat`'s drag without a drop.
    ///
    /// A motion onto nothing leaves the drag's target and withdraws its offer,
    /// so the grab, once unset, finds nothing to drop on and cancels its
    /// source. The seat's pointer then returns to the window Lua last put it
    /// over.
    pub(crate) fn cancel_drag(&mut self, seat: SeatId) {
        let Some(entry) = self.seats.get(seat) else {
            return;
        };
        if entry.drag().is_none() {
            return;
        }
        let pointer = entry.seat_pointer.clone();
        let mouse = entry.mouse();

        if let Some(mut compositor) = self.seat_view(seat) {
            compositor.send_mouse_move(None, DVec2::new(-1.0, -1.0), DVec2::ZERO, DVec2::ZERO);
        }
        let serial = SERIAL_COUNTER.next_serial();
        let time = self.millis();
        pointer.unset_grab(self, serial, time);
        // The grab's drop ends the record; a grab smithay had already
        // replaced would leave it.
        self.end_drag(seat);

        let hovered = mouse.and_then(|mouse| {
            let window = self.windows.get(mouse.hovered)?;
            window.mapped.then_some((window.sink, mouse.position))
        });
        if hovered.is_some() {
            self.move_pointer(seat, hovered);
        }
    }

    /// Accumulates the offset a drag icon's commit carries, and republishes
    /// the icon's content.
    ///
    /// `wl_surface.offset`, or the position given to `wl_surface.attach`
    /// before version 5, moves the icon relative to its previous position.
    pub(crate) fn remember_drag_icon(&mut self, surface: &WlSurface) {
        let Some(entry) = self.seats.iter_mut().find(|entry| {
            entry
                .drag()
                .and_then(|drag| drag.icon.as_ref())
                .is_some_and(|(icon, _)| icon == surface)
        }) else {
            return;
        };
        let delta = with_states(surface, |states| {
            states
                .cached_state
                .get::<SurfaceAttributes>()
                .current()
                .buffer_delta
                .take()
        });
        if let (Some(delta), Some(drag)) = (delta, entry.drag_mut()) {
            drag.offset = SurfaceOffset {
                x: drag.offset.x.saturating_add(delta.x),
                y: drag.offset.y.saturating_add(delta.y),
            };
        }
        self.touch();
    }
}
