//! Adapted from WayVR's `backend/wayvr/window.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Tracks Wayland toplevels and their configure sizes.
//!
//! lunette adds fields for the identifiers Lua sees, which are minted
//! monotonically beside the slotmap handles and never reused, the assigned
//! output, the title and app id, the toplevel states, the content-type hint,
//! the source crop, whether current imported content maps the window, and
//! the popups and subsurfaces the snapshot reports.
//! `crate::window` holds lunette's methods over them.

use std::rc::Rc;

use slotmap::{DenseSlotMap, new_key_type};
use smithay::utils::{Logical, Serial, Size};
use smithay::wayland::shell::xdg::ToplevelSurface;

use crate::protocol::{
    ChildSurface, ContentType, OutputId, ProcessId, SinkId, SourceCrop, SurfaceId, ToplevelStates,
    WindowId,
};
use crate::window::WindowIds;

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
    /// The popups and subsurfaces with content, as the snapshot reports them.
    pub children: Vec<ChildSurface>,
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
            children: Vec::new(),
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
}

new_key_type! {
    pub struct WindowHandle;
}
