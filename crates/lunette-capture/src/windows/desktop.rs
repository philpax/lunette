//! Windows-only: enumerates the interactive desktop in physical pixels.

use std::{ffi::c_void, mem::size_of};

use ::windows::{
    Win32::{
        Foundation::{HWND, LPARAM, RECT},
        Graphics::{
            Dwm::{DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Gdi::{
                EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW,
            },
        },
        UI::{
            HiDpi::{
                DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
                SetThreadDpiAwarenessContext,
            },
            WindowsAndMessaging::{
                EnumWindows, GWL_EXSTYLE, GetWindowLongPtrW, GetWindowRect, GetWindowTextLengthW,
                GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible, WS_EX_TOOLWINDOW,
            },
        },
    },
    core::{BOOL, Error, Result},
};

/// A rectangle in the virtual desktop's physical pixel coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl Bounds {
    fn from_rect(rect: RECT) -> Option<Self> {
        let width = u32::try_from(rect.right.checked_sub(rect.left)?).ok()?;
        let height = u32::try_from(rect.bottom.checked_sub(rect.top)?).ok()?;
        (width > 0 && height > 0).then_some(Self {
            x: rect.left,
            y: rect.top,
            width,
            height,
        })
    }
}

/// An HWND accompanied by the owner observed during enumeration.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct WindowId {
    handle: isize,
    process: u32,
    thread: u32,
}

impl WindowId {
    #[must_use]
    pub fn process_id(self) -> u32 {
        self.process
    }

    pub(super) fn from_handle(handle: HWND) -> Option<Self> {
        let mut process = 0;
        // SAFETY: Windows writes the process ID into the supplied storage and validates the HWND.
        let thread = unsafe { GetWindowThreadProcessId(handle, Some(&raw mut process)) };
        (process != 0 && thread != 0).then_some(Self {
            handle: handle.0 as isize,
            process,
            thread,
        })
    }

    pub(super) fn live_handle(self) -> Option<HWND> {
        let handle = HWND(self.handle as *mut c_void);
        (Self::from_handle(handle) == Some(self)).then_some(handle)
    }
}

/// A window available for explicit selection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Window {
    pub id: WindowId,
    pub title: String,
    pub bounds: Bounds,
}

/// A display handle paired with its GDI device name.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MonitorId {
    handle: isize,
    device: String,
}

impl MonitorId {
    #[must_use]
    pub fn device(&self) -> &str {
        &self.device
    }

    pub(super) fn live_handle(&self) -> Option<HMONITOR> {
        let handle = HMONITOR(self.handle as *mut c_void);
        monitor_info(handle)
            .filter(|monitor| monitor.id == *self)
            .map(|_| handle)
    }
}

/// An attached display with its current virtual-desktop position.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Monitor {
    pub id: MonitorId,
    pub bounds: Bounds,
}

/// Lists visible top-level application windows from other processes.
///
/// # Errors
///
/// Returns the Win32 enumeration error if the desktop cannot be queried.
pub fn windows() -> Result<Vec<Window>> {
    let _dpi = DpiContext::enter();
    let mut windows = Vec::new();
    // SAFETY: EnumWindows invokes callbacks synchronously and the vector lives throughout.
    unsafe {
        EnumWindows(Some(visit_window), LPARAM((&raw mut windows) as isize))?;
    }
    Ok(windows)
}

unsafe extern "system" fn visit_window(handle: HWND, context: LPARAM) -> BOOL {
    if let Some(window) = window_info(handle) {
        // SAFETY: windows passes this exclusive pointer for the lifetime of the enumeration.
        unsafe { &mut *(context.0 as *mut Vec<Window>) }.push(window);
    }
    TRUE
}

fn window_info(handle: HWND) -> Option<Window> {
    let id = WindowId::from_handle(handle)?;
    // SAFETY: all these queries accept an HWND that may disappear and report failure.
    unsafe {
        if id.process_id() == std::process::id()
            || !IsWindowVisible(handle).as_bool()
            || GetWindowLongPtrW(handle, GWL_EXSTYLE) & WS_EX_TOOLWINDOW.0 as isize != 0
        {
            return None;
        }
        let mut cloaked = 0u32;
        if DwmGetWindowAttribute(
            handle,
            DWMWA_CLOAKED,
            (&raw mut cloaked).cast(),
            size_of::<u32>() as u32,
        )
        .is_ok()
            && cloaked != 0
        {
            return None;
        }
        let length = GetWindowTextLengthW(handle);
        if length <= 0 {
            return None;
        }
        let mut title = vec![0; (length as usize).min(32_767) + 1];
        let read = usize::try_from(GetWindowTextW(handle, &mut title)).ok()?;
        if read == 0 {
            return None;
        }
        let bounds = window_bounds(handle)?;
        (id.live_handle().is_some()).then(|| Window {
            id,
            title: String::from_utf16_lossy(&title[..read]),
            bounds,
        })
    }
}

pub(super) fn window_bounds(handle: HWND) -> Option<Bounds> {
    let mut rect = RECT::default();
    // SAFETY: both APIs write a RECT into local storage on success.
    unsafe {
        if DwmGetWindowAttribute(
            handle,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&raw mut rect).cast(),
            size_of::<RECT>() as u32,
        )
        .is_err()
        {
            GetWindowRect(handle, &raw mut rect).ok()?;
        }
    }
    Bounds::from_rect(rect)
}

/// Lists the displays attached to the interactive desktop.
///
/// # Errors
///
/// Returns the Win32 enumeration error if the desktop cannot be queried.
pub fn monitors() -> Result<Vec<Monitor>> {
    let _dpi = DpiContext::enter();
    let mut monitors = Vec::new();
    // SAFETY: the callback is synchronous and its context points to the local vector.
    let ok = unsafe {
        EnumDisplayMonitors(
            None,
            None,
            Some(visit_monitor),
            LPARAM((&raw mut monitors) as isize),
        )
    };
    if !ok.as_bool() {
        return Err(Error::from_thread());
    }
    Ok(monitors)
}

unsafe extern "system" fn visit_monitor(
    handle: HMONITOR,
    _: HDC,
    _: *mut RECT,
    context: LPARAM,
) -> BOOL {
    if let Some(monitor) = monitor_info(handle) {
        // SAFETY: monitors passes this exclusive pointer for the lifetime of the enumeration.
        unsafe { &mut *(context.0 as *mut Vec<Monitor>) }.push(monitor);
    }
    TRUE
}

fn monitor_info(handle: HMONITOR) -> Option<Monitor> {
    let mut info = MONITORINFOEXW::default();
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    // SAFETY: MONITORINFOEXW starts with MONITORINFO and cbSize advertises the larger allocation.
    if !unsafe { GetMonitorInfoW(handle, (&raw mut info).cast::<MONITORINFO>()) }.as_bool() {
        return None;
    }
    let length = info.szDevice.iter().position(|&value| value == 0)?;
    Some(Monitor {
        id: MonitorId {
            handle: handle.0 as isize,
            device: String::from_utf16_lossy(&info.szDevice[..length]),
        },
        bounds: Bounds::from_rect(info.monitorInfo.rcMonitor)?,
    })
}

const TRUE: BOOL = BOOL(1);

pub(super) struct DpiContext(DPI_AWARENESS_CONTEXT);

impl DpiContext {
    pub(super) fn enter() -> Self {
        // SAFETY: this changes only the calling thread and Drop restores the previous context.
        Self(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) })
    }
}

impl Drop for DpiContext {
    fn drop(&mut self) {
        if !self.0.0.is_null() {
            // SAFETY: the value came from SetThreadDpiAwarenessContext on this thread.
            unsafe { SetThreadDpiAwarenessContext(self.0) };
        }
    }
}
