//! lunette's methods over WayVR's windows: what Lua's window snapshot
//! reports, the lookups by lunette's identifiers, and the size limits.
//!
//! A window stays tracked while unmapped, and its `WindowId` and `SinkId` stay
//! stable if it maps again. The client's size limits are read again at every
//! commit, because a client may change them; upstream reads them once, in
//! `tick_events`, where `size_constraints` comes from.

use smithay::{
    utils::{Logical, Size},
    wayland::{
        compositor::with_states,
        shell::xdg::{SurfaceCachedState, ToplevelSurface},
    },
};

use crate::{
    protocol::{
        ContentType, OutputId, PixelSize, SinkId, SourceCrop, SurfaceId, ToplevelState, WindowId,
        WindowSnapshot,
    },
    wayvr::window::{Window, WindowManager},
};

impl Window {
    /// The last size the client committed. Configure requests do not change it
    /// until the client commits content.
    pub(crate) const fn size(&self) -> PixelSize {
        PixelSize::new(self.size_x, self.size_y)
    }

    /// Refreshes the client's size limits before sizing, with the same floor
    /// on the maximum that `new` applies.
    pub(crate) fn refresh_constraints(&mut self, bounds: Size<i32, Logical>) {
        let (min_size, max_size) = size_constraints(&self.toplevel, bounds);
        self.bounds = bounds;
        self.min_size = min_size;
        self.max_size = max_size.clamp(Size::new(160, 160), bounds);
    }

    /// Marks the window mapped after a buffer commit, and returns whether it
    /// was unmapped before.
    pub(crate) fn map(&mut self) -> bool {
        !std::mem::replace(&mut self.mapped, true)
    }

    /// Marks the window unmapped after a null-buffer commit. A later buffer
    /// commit can map the same window and retain its identifiers.
    pub(crate) fn unmap(&mut self) -> bool {
        self.pending_configure = None;
        std::mem::replace(&mut self.mapped, false)
    }

    pub(crate) fn set_title(&mut self, title: Option<String>) -> bool {
        replace_if_changed(&mut self.title, title)
    }

    pub(crate) fn set_app_id(&mut self, app_id: Option<String>) -> bool {
        replace_if_changed(&mut self.app_id, app_id)
    }

    pub(crate) fn set_state(&mut self, state: ToplevelState, held: bool) -> bool {
        if held {
            self.states.insert(state)
        } else {
            self.states.remove(&state)
        }
    }

    pub(crate) fn remember_content_type(&mut self, content_type: ContentType) -> bool {
        replace_if_changed(&mut self.content_type, content_type)
    }

    pub(crate) fn remember_source_crop(&mut self, source_crop: SourceCrop) -> bool {
        replace_if_changed(&mut self.source_crop, source_crop)
    }

    /// The decoration mode is kept per surface by `Application`, which
    /// passes it in.
    pub(crate) fn snapshot(&self, server_side_decorations: bool) -> WindowSnapshot {
        WindowSnapshot {
            window: self.id,
            surface: self.surface,
            sink: self.sink,
            process: self.process,
            output: self.output,
            title: self.title.clone(),
            app_id: self.app_id.clone(),
            size: self.size(),
            min_size: Some(pixel_size(self.min_size)),
            max_size: Some(pixel_size(self.max_size)),
            parent: None,
            states: self.states.clone(),
            content_type: self.content_type,
            source_crop: self.source_crop,
            server_side_decorations,
        }
    }
}

impl WindowManager {
    pub(crate) fn get(&self, id: WindowId) -> Option<&Window> {
        self.windows.values().find(|window| window.id == id)
    }

    pub(crate) fn get_mut(&mut self, id: WindowId) -> Option<&mut Window> {
        self.windows.values_mut().find(|window| window.id == id)
    }

    pub(crate) fn by_sink(&self, sink: SinkId) -> Option<&Window> {
        self.windows.values().find(|window| window.sink == sink)
    }

    pub(crate) fn by_surface(&self, surface: SurfaceId) -> Option<&Window> {
        self.windows
            .values()
            .find(|window| window.surface == surface)
    }

    pub(crate) fn by_surface_mut(&mut self, surface: SurfaceId) -> Option<&mut Window> {
        self.windows
            .values_mut()
            .find(|window| window.surface == surface)
    }

    pub(crate) fn by_toplevel_mut(&mut self, toplevel: &ToplevelSurface) -> Option<&mut Window> {
        let handle = self.find_window_handle(toplevel)?;
        self.windows.get_mut(handle)
    }

    pub(crate) fn mapped(&self) -> impl Iterator<Item = &Window> {
        self.windows.values().filter(|window| window.mapped)
    }

    /// Includes unmapped windows so an output change configures them before their
    /// first buffer commit.
    pub(crate) fn on_output(&mut self, output: OutputId) -> impl Iterator<Item = &mut Window> {
        self.windows
            .values_mut()
            .filter(move |window| window.output == output)
    }

    /// Reassigns windows before a withdrawn output is rescaled. Snapshot
    /// identity and configure bounds use the window's output.
    pub(crate) fn move_to_output(&mut self, from: OutputId, to: OutputId) {
        for window in self.windows.values_mut() {
            if window.output == from {
                window.output = to;
            }
        }
    }
}

/// Reads the current size limits from the surface's cached xdg state. An empty
/// minimum means one pixel, and an empty maximum means the supplied output bound.
/// The identifiers lunette gives a window, which Lua sees.
pub(crate) struct WindowIds {
    pub(crate) id: WindowId,
    pub(crate) sink: SinkId,
    pub(crate) surface: SurfaceId,
    pub(crate) output: OutputId,
}

pub(crate) fn size_constraints(
    toplevel: &ToplevelSurface,
    bounds: Size<i32, Logical>,
) -> (Size<i32, Logical>, Size<i32, Logical>) {
    with_states(toplevel.wl_surface(), |state| {
        let mut guard = state.cached_state.get::<SurfaceCachedState>();
        let current = guard.current();

        let mut min_size = current.min_size;
        let mut max_size = current.max_size;

        if min_size.is_empty() {
            min_size = Size::new(1, 1);
        }

        if max_size.is_empty() {
            max_size = bounds;
        } else {
            max_size = max_size.clamp(Size::new(1, 1), bounds);
        }

        (min_size, max_size)
    })
}

fn replace_if_changed<T: PartialEq>(slot: &mut T, value: T) -> bool {
    if *slot == value {
        return false;
    }
    *slot = value;
    true
}

fn pixel_size(size: Size<i32, Logical>) -> PixelSize {
    PixelSize::new(size.w.max(0) as u32, size.h.max(0) as u32)
}
