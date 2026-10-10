//! Adapted from WayVR's `backend/wayvr/window.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Tracks Wayland toplevels, their assigned outputs, and their configure sizes.
//!
//! lunette adds the identifiers Lua sees, which are minted monotonically beside
//! the slotmap handles and never reused, the assigned output, the title and
//! app id, the toplevel states, the content-type hint, and whether current
//! imported content maps the window. A window stays tracked while unmapped,
//! and its `WindowId` and `SinkId` stay stable if it maps again. The client's
//! size limits are re-read on every commit, because a client may change them.

use std::rc::Rc;

use slotmap::{DenseSlotMap, new_key_type};
use smithay::utils::{Logical, Serial, Size};
use smithay::wayland::compositor::with_states;
use smithay::wayland::shell::xdg::{SurfaceCachedState, ToplevelSurface};

use crate::protocol::{
    ContentType, OutputId, PixelSize, ProcessId, SinkId, SourceCrop, SurfaceId,
    ToplevelState, ToplevelStates, WindowId, WindowSnapshot,
};

#[derive(Debug, Clone, Copy)]
pub struct PendingConfigure {
    pub size: Size<i32, Logical>,
    pub serial: Serial,
}

#[derive(Debug)]
pub struct Window {
    pub min_size: Size<i32, Logical>,
    pub max_size: Size<i32, Logical>,
    pub bounds: Size<i32, Logical>,
    pub size_x: u32,
    pub size_y: u32,
    pub toplevel: Rc<ToplevelSurface>,
    pub process: Option<ProcessId>,

    pub pending_configure: Option<PendingConfigure>,

    pub id: WindowId,
    pub sink: SinkId,
    pub surface: SurfaceId,
    /// The assigned output used for this window's bounds and snapshot.
    pub output: OutputId,
    pub title: Option<String>,
    pub app_id: Option<String>,
    pub states: ToplevelStates,
    /// The content-type hint promoted by the client's buffer commit.
    pub content_type: ContentType,
    /// The part of the buffer the client's viewport shows.
    pub source_crop: SourceCrop,
    /// Whether current imported content makes the window reportable.
    pub mapped: bool,
}

impl Window {
    fn new(
        toplevel: Rc<ToplevelSurface>,
        process: Option<ProcessId>,
        bounds: Size<i32, Logical>,
        min_size: Size<i32, Logical>,
        max_size: Size<i32, Logical>,
        ids: WindowIds,
    ) -> Self {
        Self {
            bounds,
            min_size,
            max_size: max_size.clamp(Size::new(160, 160), bounds),
            size_x: 0,
            size_y: 0,
            toplevel,
            process,
            pending_configure: None,
            id: ids.id,
            sink: ids.sink,
            surface: ids.surface,
            output: ids.output,
            title: None,
            app_id: None,
            states: ToplevelStates::new(),
            content_type: ContentType::None,
            source_crop: SourceCrop::FULL,
            mapped: false,
        }
    }

    pub fn clamp_configure_size(
        &self,
        size: Size<i32, Logical>,
        bounds: Size<i32, Logical>,
    ) -> Size<i32, Logical> {
        let min_size = Size::new(
            self.min_size.w.max(1).min(bounds.w),
            self.min_size.h.max(1).min(bounds.h),
        );

        let max_size = Size::new(
            self.max_size.w.max(min_size.w).min(bounds.w),
            self.max_size.h.max(min_size.h).min(bounds.h),
        );

        Size::new(size.w.max(1), size.h.max(1)).clamp(min_size, max_size)
    }

    fn send_size_configure(&mut self, size: Size<i32, Logical>, bounds: Size<i32, Logical>) {
        let clamped_size = self.clamp_configure_size(size, bounds);

        if self
            .pending_configure
            .is_some_and(|pending| pending.size == clamped_size)
        {
            return;
        }

        self.toplevel.with_pending_state(|state| {
            state.bounds = Some(bounds);
            state.size = Some(clamped_size);
        });

        let serial = self.toplevel.send_configure();

        self.bounds = bounds;
        self.pending_configure = Some(PendingConfigure {
            size: clamped_size,
            serial,
        });
    }

    pub fn request_size(&mut self, size: Size<i32, Logical>, bounds: Size<i32, Logical>) {
        self.send_size_configure(size, bounds);
    }

    pub fn remember_committed_size(
        &mut self,
        size: Size<i32, Logical>,
        configure_serial: Option<Serial>,
    ) -> bool {
        let size_x = size.w.max(1) as u32;
        let size_y = size.h.max(1) as u32;

        let changed = self.size_x != size_x || self.size_y != size_y;

        self.size_x = size_x;
        self.size_y = size_y;

        if self
            .pending_configure
            .is_some_and(|pending| Some(pending.serial) == configure_serial)
        {
            self.pending_configure = None;
        }

        changed
    }

    /// The last size the client committed. Configure requests do not change it
    /// until the client commits content.
    pub const fn size(&self) -> PixelSize {
        PixelSize::new(self.size_x, self.size_y)
    }

    /// Refreshes the client's size limits before sizing, with the same floor
    /// on the maximum that `new` applies.
    pub fn refresh_constraints(&mut self, bounds: Size<i32, Logical>) {
        let (min_size, max_size) = size_constraints(&self.toplevel, bounds);
        self.bounds = bounds;
        self.min_size = min_size;
        self.max_size = max_size.clamp(Size::new(160, 160), bounds);
    }

    /// Marks the window mapped after a buffer commit, and returns whether it
    /// was unmapped before.
    pub fn map(&mut self) -> bool {
        !std::mem::replace(&mut self.mapped, true)
    }

    /// Marks the window unmapped after a null-buffer commit. A later buffer
    /// commit can map the same window and retain its identifiers.
    pub fn unmap(&mut self) -> bool {
        self.pending_configure = None;
        std::mem::replace(&mut self.mapped, false)
    }

    pub fn set_title(&mut self, title: Option<String>) -> bool {
        replace_if_changed(&mut self.title, title)
    }

    pub fn set_app_id(&mut self, app_id: Option<String>) -> bool {
        replace_if_changed(&mut self.app_id, app_id)
    }

    pub fn set_state(&mut self, state: ToplevelState, held: bool) -> bool {
        if held {
            self.states.insert(state)
        } else {
            self.states.remove(&state)
        }
    }

    pub fn remember_content_type(&mut self, content_type: ContentType) -> bool {
        replace_if_changed(&mut self.content_type, content_type)
    }

    pub fn remember_source_crop(&mut self, source_crop: SourceCrop) -> bool {
        replace_if_changed(&mut self.source_crop, source_crop)
    }

    pub fn snapshot(&self) -> WindowSnapshot {
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
        }
    }
}

#[derive(Debug)]
pub struct WindowManager {
    pub windows: DenseSlotMap<WindowHandle, Window>,
    /// The last minted `WindowId` and `SinkId`.
    minted: u64,
}

pub struct CreateWindowParams {
    pub toplevel: Rc<ToplevelSurface>,
    pub process: Option<ProcessId>,
    pub bounds: Size<i32, Logical>,
    pub min_size: Size<i32, Logical>,
    pub max_size: Size<i32, Logical>,
    pub size_x: u32,
    pub size_y: u32,
    pub surface: SurfaceId,
    pub output: OutputId,
}

impl WindowManager {
    pub fn new() -> Self {
        Self {
            windows: Default::default(),
            minted: 0,
        }
    }

    pub fn find_window_handle(&self, toplevel: &ToplevelSurface) -> Option<WindowHandle> {
        for (handle, window) in &self.windows {
            if *window.toplevel == *toplevel {
                return Some(handle);
            }
        }
        None
    }

    pub fn create_window(&mut self, par: CreateWindowParams) -> WindowHandle {
        self.minted += 1;
        const NEVER_ZERO: &str =
            "the counter starts at one and only increases, so it is never zero";
        let ids = WindowIds {
            id: WindowId::new(self.minted).unwrap_or_else(|| unreachable!("{NEVER_ZERO}")),
            sink: SinkId::new(self.minted).unwrap_or_else(|| unreachable!("{NEVER_ZERO}")),
            surface: par.surface,
            output: par.output,
        };

        let mut window = Window::new(
            par.toplevel,
            par.process,
            par.bounds,
            par.min_size,
            par.max_size,
            ids,
        );
        window.remember_committed_size(Size::new(par.size_x as i32, par.size_y as i32), None);
        self.windows.insert(window)
    }

    pub fn remove_window(&mut self, window_handle: WindowHandle) -> Option<Window> {
        self.windows.remove(window_handle)
    }

    pub fn get(&self, id: WindowId) -> Option<&Window> {
        self.windows.values().find(|window| window.id == id)
    }

    pub fn get_mut(&mut self, id: WindowId) -> Option<&mut Window> {
        self.windows.values_mut().find(|window| window.id == id)
    }

    pub fn by_sink(&self, sink: SinkId) -> Option<&Window> {
        self.windows.values().find(|window| window.sink == sink)
    }

    pub fn by_surface(&self, surface: SurfaceId) -> Option<&Window> {
        self.windows.values().find(|window| window.surface == surface)
    }

    pub fn by_surface_mut(&mut self, surface: SurfaceId) -> Option<&mut Window> {
        self.windows
            .values_mut()
            .find(|window| window.surface == surface)
    }

    pub fn by_toplevel_mut(&mut self, toplevel: &ToplevelSurface) -> Option<&mut Window> {
        let handle = self.find_window_handle(toplevel)?;
        self.windows.get_mut(handle)
    }

    pub fn mapped(&self) -> impl Iterator<Item = &Window> {
        self.windows.values().filter(|window| window.mapped)
    }

    /// Includes unmapped windows so an output change configures them before their
    /// first buffer commit.
    pub fn on_output(&mut self, output: OutputId) -> impl Iterator<Item = &mut Window> {
        self.windows
            .values_mut()
            .filter(move |window| window.output == output)
    }

    /// Reassigns windows before a withdrawn output is rescaled. Snapshot
    /// identity and configure bounds use the window's output.
    pub fn move_to_output(&mut self, from: OutputId, to: OutputId) {
        for window in self.windows.values_mut() {
            if window.output == from {
                window.output = to;
            }
        }
    }
}

new_key_type! {
    pub struct WindowHandle;
}

/// The identifiers lunette gives a window, which Lua sees.
struct WindowIds {
    id: WindowId,
    sink: SinkId,
    surface: SurfaceId,
    output: OutputId,
}

/// Reads the current size limits from the surface's cached xdg state. An empty
/// minimum means one pixel, and an empty maximum means the supplied output bound.
pub fn size_constraints(
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
