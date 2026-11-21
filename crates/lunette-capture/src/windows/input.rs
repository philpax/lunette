//! Windows-only: routes explicit input to a visible native window.

use std::mem::size_of;

use ::windows::{
    Win32::{
        Foundation::{E_FAIL, HWND, LPARAM, NO_ERROR, POINT, SetLastError, WPARAM},
        Graphics::Gdi::{HMONITOR, MONITOR_DEFAULTTONULL, MonitorFromPoint, MonitorFromWindow},
        UI::{
            Input::KeyboardAndMouse::{
                GetKeyboardLayout, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT,
                KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE,
                MAPVK_VSC_TO_VK_EX, MOUSE_EVENT_FLAGS, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN,
                MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP,
                MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_WHEEL, MOUSEEVENTF_XDOWN,
                MOUSEEVENTF_XUP, MOUSEINPUT, MapVirtualKeyExW, SendInput, ToUnicodeEx, VK_CAPITAL,
                VK_CONTROL, VK_MENU, VK_RMENU, VK_SHIFT,
            },
            WindowsAndMessaging::{
                GA_ROOT, GUITHREADINFO, GetAncestor, GetCursorPos, GetForegroundWindow,
                GetGUIThreadInfo, GetWindowThreadProcessId, PostMessageW, SetCursorPos,
                SetForegroundWindow, WM_CLOSE, WindowFromPoint,
            },
        },
    },
    core::{Error, Result},
};

use lunette_compositor::protocol::{KeyModifier, Keycode, ModifierState, ScrollAxis};
use tracing::debug;

use crate::{
    hid::PanelPoint,
    windows::desktop::{DpiContext, MonitorId, WindowId, window_bounds},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Button {
    Left,
    Middle,
    Right,
    Back,
    Forward,
}

/// Requests that a native application close its window.
///
/// # Errors
///
/// Returns the Win32 delivery error if it could not post the request.
pub fn close(window: WindowId) -> Result<bool> {
    let Some(handle) = window.live_handle() else {
        return Ok(false);
    };
    // SAFETY: this message has no caller-owned payload.
    unsafe { PostMessageW(Some(handle), WM_CLOSE, WPARAM(0), LPARAM(0))? };
    Ok(true)
}

/// Requests foreground activation and reports whether Windows granted it.
pub fn focus(window: WindowId) -> bool {
    let Some(handle) = window.live_handle() else {
        return false;
    };
    // SAFETY: Windows validates both handles and may deny foreground activation.
    unsafe { GetForegroundWindow() == handle || SetForegroundWindow(handle).as_bool() }
}

/// Checks Windows foreground ownership before delivering keyboard input.
pub fn is_foreground(window: WindowId) -> bool {
    // SAFETY: queries the active window without retaining caller-owned data.
    window
        .live_handle()
        .is_some_and(|handle| unsafe { GetForegroundWindow() } == handle)
}

#[derive(Clone, Copy, Debug)]
pub enum PointerInput {
    Move,
    Press(Button),
    Scroll(ScrollAxis, i32),
}

/// Moves the pointer and sends the input only to an exposed point on the window.
/// Wheel input requires foreground ownership because routing depends on Windows settings.
///
/// # Errors
///
/// Returns any error moving the pointer or sending the input.
pub fn pointer(window: WindowId, x: f64, y: f64, input: PointerInput) -> Result<bool> {
    let _dpi = DpiContext::enter();
    let Some(handle) = window.live_handle() else {
        return Ok(false);
    };
    if matches!(input, PointerInput::Scroll(..)) && !is_foreground(window) {
        return Ok(false);
    }
    let Some(bounds) = window_bounds(handle) else {
        return Ok(false);
    };
    let Some(x) = pointer_coordinate(bounds.x, bounds.width, x) else {
        return Ok(false);
    };
    let Some(y) = pointer_coordinate(bounds.y, bounds.height, y) else {
        return Ok(false);
    };
    deliver_pointer(window, handle, POINT { x, y }, None, input)
}

/// Sends explicit pointer input to the top-level window at a point on a selected monitor.
///
/// # Errors
///
/// Returns a Win32 error if the cursor or input stream refuses the operation.
pub fn monitor_pointer(
    monitor: &MonitorId,
    hit: PanelPoint,
    held: Option<WindowId>,
    input: PointerInput,
) -> Result<Option<WindowId>> {
    let _dpi = DpiContext::enter();
    let Some(bounds) = monitor.live_bounds() else {
        return Ok(None);
    };
    let Some(display) = monitor.live_handle() else {
        return Ok(None);
    };
    let Some(x) = pointer_coordinate(bounds.x, bounds.width, hit.u) else {
        return Ok(None);
    };
    let Some(y) = pointer_coordinate(bounds.y, bounds.height, hit.v) else {
        return Ok(None);
    };
    let point = POINT { x, y };
    // SAFETY: these calls only query the current desktop and accept physical pixels.
    let handle = unsafe { GetAncestor(WindowFromPoint(point), GA_ROOT) };
    let Some(window) = WindowId::from_handle(handle) else {
        return Ok(None);
    };
    if window.process_id() == std::process::id()
        || held.is_some_and(|held| held != window)
        || !on_display(display, point)
        || matches!(input, PointerInput::Scroll(..)) && !is_foreground(window)
    {
        return Ok(None);
    }
    deliver_pointer(window, handle, point, Some(display), input).map(|sent| sent.then_some(window))
}

/// Whether the foreground window still belongs to the selected monitor.
#[must_use]
pub fn monitor_focused(monitor: &MonitorId, window: WindowId) -> bool {
    let _dpi = DpiContext::enter();
    let Some(display) = monitor.live_handle() else {
        return false;
    };
    window.live_handle().is_some_and(|handle| {
        // SAFETY: both queries accept the live handle without retaining any storage.
        unsafe {
            GetForegroundWindow() == handle
                && MonitorFromWindow(handle, MONITOR_DEFAULTTONULL) == display
        }
    })
}

fn on_display(display: HMONITOR, point: POINT) -> bool {
    // SAFETY: the point is passed by value, in physical desktop coordinates.
    unsafe { MonitorFromPoint(point, MONITOR_DEFAULTTONULL) == display }
}

fn deliver_pointer(
    window: WindowId,
    handle: HWND,
    point: POINT,
    display: Option<HMONITOR>,
    input: PointerInput,
) -> Result<bool> {
    if !point_targets(point, handle) {
        debug!(?point, "Windows window is covered at the pointer position");
        return Ok(false);
    }
    // SAFETY: these APIs use physical desktop coordinates and caller-owned storage.
    let mut cursor = POINT::default();
    unsafe {
        SetCursorPos(point.x, point.y)?;
        GetCursorPos(&raw mut cursor)?;
    }
    if window.live_handle().is_none()
        || !point_targets(cursor, handle)
        || display.is_some_and(|display| !on_display(display, cursor))
    {
        debug!(
            ?point,
            ?cursor,
            "Windows pointer did not reach the selected window"
        );
        return Ok(false);
    }
    if !allows_mouse_capture(handle)? {
        debug!("another Windows application is holding mouse capture");
        return Ok(false);
    }
    let event = match input {
        PointerInput::Move => return Ok(true),
        PointerInput::Press(button) => button_event(button, true),
        PointerInput::Scroll(axis, delta) => {
            if !is_foreground(window) {
                return Ok(false);
            }
            let flags = match axis {
                ScrollAxis::Vertical => MOUSEEVENTF_WHEEL,
                ScrollAxis::Horizontal => MOUSEEVENTF_HWHEEL,
            };
            mouse_event(flags, delta as u32)
        }
    };
    send(&[event])?;
    Ok(true)
}

/// Releases a button whose press Lunette sent. Release even after occlusion or focus loss.
///
/// # Errors
///
/// Returns an error if Windows refuses the release.
pub fn release_button(button: Button) -> Result<()> {
    send(&[button_event(button, false)])
}

fn button_event(button: Button, pressed: bool) -> INPUT {
    let (down, up, data) = match button {
        Button::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, 0),
        Button::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0),
        Button::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, 0),
        Button::Back => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 1),
        Button::Forward => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, 2),
    };
    mouse_event(if pressed { down } else { up }, data)
}

fn mouse_event(flags: MOUSE_EVENT_FLAGS, data: u32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dwFlags: flags,
                mouseData: data,
                ..MOUSEINPUT::default()
            },
        },
    }
}

/// A keyboard key as a Windows Set 1 scan code, with an optional extended prefix.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ScanCode {
    code: u16,
    extended: bool,
}

impl ScanCode {
    pub fn from_evdev(key: Keycode) -> Option<Self> {
        let (code, extended) = match key.evdev() {
            // The original PC keyboard block uses the same positions in both numbering schemes.
            raw @ (1..=83 | 86..=88) => (raw as u16, false),
            96 => (0x1c, true),  // Keypad Enter.
            97 => (0x1d, true),  // Right Control.
            98 => (0x35, true),  // Keypad Divide.
            100 => (0x38, true), // Right Alt.
            102 => (0x47, true), // Home.
            103 => (0x48, true), // Up.
            104 => (0x49, true), // Page Up.
            105 => (0x4b, true), // Left.
            106 => (0x4d, true), // Right.
            107 => (0x4f, true), // End.
            108 => (0x50, true), // Down.
            109 => (0x51, true), // Page Down.
            110 => (0x52, true), // Insert.
            111 => (0x53, true), // Delete.
            125 => (0x5b, true), // Left Windows.
            126 => (0x5c, true), // Right Windows.
            127 => (0x5d, true), // Menu.
            _ => return None,
        };
        Some(Self { code, extended })
    }

    /// Presses the key while the requested window has Windows foreground focus.
    ///
    /// # Errors
    ///
    /// Returns an error if Windows refuses the press.
    pub fn press(self, window: WindowId) -> Result<bool> {
        if !is_foreground(window) {
            return Ok(false);
        }
        send(&[self.event(true)])?;
        Ok(true)
    }

    /// Releases a key Lunette pressed, even if focus has moved.
    ///
    /// # Errors
    ///
    /// Returns an error if Windows refuses the release.
    pub fn release(self) -> Result<()> {
        send(&[self.event(false)])
    }

    fn event(self, pressed: bool) -> INPUT {
        let mut flags = KEYEVENTF_SCANCODE;
        if self.extended {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        if !pressed {
            flags |= KEYEVENTF_KEYUP;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wScan: self.code,
                    dwFlags: flags,
                    ..KEYBDINPUT::default()
                },
            },
        }
    }
}

/// Resolves a key label using the foreground window's Windows keyboard layout.
/// It preserves the application's dead-key state.
pub fn character(key: Keycode, modifiers: &ModifierState) -> Option<String> {
    let scan = ScanCode::from_evdev(key)?;
    let mut state = [0; 256];
    for (key, modifier) in [
        (VK_SHIFT, KeyModifier::Shift),
        (VK_CONTROL, KeyModifier::Control),
        (VK_MENU, KeyModifier::Alt),
    ] {
        if modifiers.contains(&modifier) {
            state[usize::from(key.0)] = 0x80;
        }
    }
    if modifiers.contains(&KeyModifier::Mod5) {
        for key in [VK_RMENU, VK_MENU, VK_CONTROL] {
            state[usize::from(key.0)] = 0x80;
        }
    }
    if modifiers.contains(&KeyModifier::CapsLock) {
        state[usize::from(VK_CAPITAL.0)] = 1;
    }

    let mut text = [0; 8];
    let extended_scan = u32::from(scan.code) | if scan.extended { 0xe000 } else { 0 };
    // SAFETY: the APIs query the current layout and read/write the supplied buffers only.
    let len = unsafe {
        let thread = GetWindowThreadProcessId(GetForegroundWindow(), None);
        let layout = Some(GetKeyboardLayout(thread));
        let vk = MapVirtualKeyExW(extended_scan, MAPVK_VSC_TO_VK_EX, layout);
        const PRESERVE_KEYBOARD_STATE: u32 = 4;
        ToUnicodeEx(
            vk,
            u32::from(scan.code),
            &state,
            &mut text,
            PRESERVE_KEYBOARD_STATE,
            layout,
        )
    };
    let end = usize::try_from(len.unsigned_abs()).ok()?;
    let text = String::from_utf16(text.get(..end)?).ok()?;
    (!text.is_empty() && text.chars().all(|character| !character.is_control())).then_some(text)
}

/// Types Unicode text into the window while it has foreground focus.
///
/// # Errors
///
/// Returns the Win32 injection error if Windows refuses the input batch.
pub fn type_text(window: WindowId, text: &str) -> Result<bool> {
    let input: Vec<_> = text
        .encode_utf16()
        .flat_map(|unit| {
            [KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP].map(|flags| INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wScan: unit,
                        dwFlags: flags,
                        ..KEYBDINPUT::default()
                    },
                },
            })
        })
        .collect();
    if !is_foreground(window) {
        return Ok(false);
    }
    send(&input)?;
    Ok(true)
}

fn pointer_coordinate(origin: i32, extent: u32, fraction: f64) -> Option<i32> {
    if !(0.0..=1.0).contains(&fraction) {
        return None;
    }
    let offset = (f64::from(extent.checked_sub(1)?) * fraction).round() as i64;
    i32::try_from(i64::from(origin) + offset).ok()
}

fn point_targets(point: POINT, handle: HWND) -> bool {
    // SAFETY: both APIs query the desktop without retaining caller-owned data.
    unsafe { GetAncestor(WindowFromPoint(point), GA_ROOT) == handle }
}

fn allows_mouse_capture(handle: HWND) -> Result<bool> {
    let mut info = GUITHREADINFO {
        cbSize: size_of::<GUITHREADINFO>() as u32,
        ..GUITHREADINFO::default()
    };
    // SAFETY: the structure is correctly sized, and zero identifies the foreground thread.
    unsafe {
        GetGUIThreadInfo(0, &raw mut info)?;
        Ok(info.hwndCapture.0.is_null() || GetAncestor(info.hwndCapture, GA_ROOT) == handle)
    }
}

fn send(input: &[INPUT]) -> Result<()> {
    if input.is_empty() {
        return Ok(());
    }
    let size = size_of::<INPUT>() as i32;
    // SAFETY: the union arms match their tags, and the slice lives throughout the call.
    let sent = unsafe {
        SetLastError(NO_ERROR);
        SendInput(input, size)
    } as usize;
    if sent == input.len() {
        return Ok(());
    }
    let error = Error::from_thread();
    let error = if error.code().is_ok() {
        Error::new(E_FAIL, "Windows did not accept the whole input batch")
    } else {
        error
    };
    if sent > 0
        && sent % 2 == 1
        && let Some(release) = input.get(sent)
    {
        // SAFETY: this is the matching release for a press Windows accepted.
        unsafe { SendInput(std::slice::from_ref(release), size) };
    }
    Err(error)
}
