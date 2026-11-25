//! Windows-only: enumerates the interactive desktop in physical pixels.

use std::{
    ffi::c_void,
    mem::size_of,
    os::windows::io::{FromRawHandle, OwnedHandle},
};

use ::windows::{
    Win32::{
        Foundation::{E_INVALIDARG, HWND, LPARAM, RECT},
        Graphics::{
            Dwm::{DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute},
            Gdi::{
                DISPLAY_DEVICEW, EnumDisplayDevicesW, EnumDisplayMonitors, GetMonitorInfoW, HDC,
                HMONITOR, MONITORINFO, MONITORINFOEXW,
            },
        },
        System::Threading::{
            OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
            QueryFullProcessImageNameW,
        },
        UI::{
            HiDpi::{
                DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
                SetThreadDpiAwarenessContext,
            },
            WindowsAndMessaging::{
                EDD_GET_DEVICE_INTERFACE_NAME, EnumWindows, GWL_EXSTYLE, GetWindowLongPtrW,
                GetWindowRect, GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId,
                IsIconic, IsWindowVisible, IsZoomed, SWP_ASYNCWINDOWPOS, SWP_NOACTIVATE,
                SWP_NOMOVE, SWP_NOZORDER, SetWindowPos, WS_EX_TOOLWINDOW,
            },
        },
    },
    core::{BOOL, Error, PCWSTR, PWSTR, Result},
};
use lunette_compositor::protocol::PixelSize;

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

    /// Opens the current owner only while the selected HWND still belongs to it.
    pub fn process(self) -> std::io::Result<super::WindowsProcess> {
        let gone = || std::io::Error::new(std::io::ErrorKind::NotFound, "the window disappeared");
        self.live_handle().ok_or_else(gone)?;
        let process = super::WindowsProcess::open(self.process)?;
        self.live_handle().ok_or_else(gone)?;
        Ok(process)
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

    /// Returns the device interface for an attached physical display, if Windows exposes one.
    #[must_use]
    pub fn interface(&self) -> Option<String> {
        let device: Vec<_> = self.device.encode_utf16().chain([0]).collect();
        let mut display = DISPLAY_DEVICEW {
            cb: size_of::<DISPLAY_DEVICEW>() as u32,
            ..DISPLAY_DEVICEW::default()
        };
        // SAFETY: the GDI device name is null-terminated and display is writable for its stated size.
        if !unsafe {
            EnumDisplayDevicesW(
                PCWSTR(device.as_ptr()),
                0,
                &raw mut display,
                EDD_GET_DEVICE_INTERFACE_NAME,
            )
        }
        .as_bool()
        {
            return None;
        }
        let end = display.DeviceID.iter().position(|&unit| unit == 0)?;
        (end != 0).then(|| String::from_utf16_lossy(&display.DeviceID[..end]))
    }

    pub(super) fn live_handle(&self) -> Option<HMONITOR> {
        let handle = HMONITOR(self.handle as *mut c_void);
        self.live_bounds().map(|_| handle)
    }

    pub(super) fn live_bounds(&self) -> Option<Bounds> {
        monitor_info(HMONITOR(self.handle as *mut c_void))
            .filter(|monitor| monitor.id == *self)
            .map(|monitor| monitor.bounds)
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

/// Revalidates an explicitly selected window before starting capture.
pub fn window(id: WindowId) -> Option<Window> {
    let _dpi = DpiContext::enter();
    window_info(id.live_handle()?).filter(|window| window.id == id)
}

/// Identifies an application's windows across desktop sessions.
#[must_use]
pub fn app_id(id: WindowId) -> Option<String> {
    id.live_handle()?;
    // SAFETY: OpenProcess returns an owned handle on success. OwnedHandle closes it on every exit.
    let process =
        unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, id.process_id()) }.ok()?;
    let _process = unsafe { OwnedHandle::from_raw_handle(process.0) };
    let mut path = vec![0u16; 32_768];
    let mut length = path.len() as u32;
    // SAFETY: the process handle remains owned and the UTF-16 buffer has the advertised capacity.
    unsafe {
        QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(path.as_mut_ptr()),
            &raw mut length,
        )
    }
    .ok()?;
    id.live_handle()?;
    let name = String::from_utf16_lossy(path.get(..length as usize)?);
    let name = std::path::Path::new(&name).file_name()?.to_str()?;
    Some(format!("windows:{}", name.to_lowercase()))
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
            || IsIconic(handle).as_bool()
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
        let title = read_title(handle)?;
        let bounds = window_bounds(handle)?;
        (id.live_handle().is_some()).then(|| Window { id, title, bounds })
    }
}

fn read_title(handle: HWND) -> Option<String> {
    // SAFETY: top-level foreign window text is read into an owned buffer. A closed handle fails.
    unsafe {
        let length = GetWindowTextLengthW(handle);
        if length <= 0 {
            return None;
        }
        let mut title = vec![0; (length as usize).min(32_767) + 1];
        let read = usize::try_from(GetWindowTextW(handle, &mut title)).ok()?;
        (read != 0).then(|| String::from_utf16_lossy(&title[..read]))
    }
}

/// Reads the latest caption, or returns `None` when the selected window has gone.
#[must_use]
pub fn window_title(id: WindowId) -> Option<Option<String>> {
    let title = read_title(id.live_handle()?);
    id.live_handle().map(|_| title)
}

/// Requests a size in visible capture pixels for a restored window.
///
/// # Errors
///
/// Returns a Win32 error if the outer bounds cannot be read or the size cannot be requested.
pub fn resize_window(id: WindowId, size: PixelSize) -> Result<bool> {
    let _dpi = DpiContext::enter();
    let Some(handle) = id.live_handle() else {
        return Ok(false);
    };
    // SAFETY: the window handle was revalidated and Win32 handles a concurrent close.
    if unsafe { IsIconic(handle).as_bool() || IsZoomed(handle).as_bool() } {
        return Ok(false);
    }
    let Some(visible) = window_bounds(handle) else {
        return Ok(false);
    };
    let mut outer = RECT::default();
    // SAFETY: this writes only the rectangle supplied for the revalidated window.
    unsafe { GetWindowRect(handle, &raw mut outer) }?;
    let width = outer_dimension(size.width, visible.width, outer.left, outer.right)?;
    let height = outer_dimension(size.height, visible.height, outer.top, outer.bottom)?;
    if id.live_handle() != Some(handle) {
        return Ok(false);
    }
    // SAFETY: no user buffer is retained. Windows queues the resize to the window's own input thread.
    unsafe {
        SetWindowPos(
            handle,
            None,
            0,
            0,
            width,
            height,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS,
        )
    }?;
    Ok(true)
}

fn outer_dimension(requested: u32, visible: u32, begin: i32, end: i32) -> Result<i32> {
    let extent = i64::from(requested) + i64::from(end) - i64::from(begin) - i64::from(visible);
    i32::try_from(extent)
        .ok()
        .filter(|size| *size > 0)
        .ok_or_else(|| {
            Error::new(
                E_INVALIDARG,
                "the requested window size is outside Win32 limits",
            )
        })
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
