//! Windows-only: routes explicit input to a visible native window.

use std::mem::size_of;

use ::windows::{
    Win32::{
        Foundation::{E_FAIL, HWND, LPARAM, NO_ERROR, POINT, SetLastError, WPARAM},
        UI::{
            Input::KeyboardAndMouse::{
                INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP,
                KEYEVENTF_UNICODE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
                MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTDOWN,
                MOUSEEVENTF_RIGHTUP, MOUSEINPUT, SendInput,
            },
            WindowsAndMessaging::{
                GA_ROOT, GetAncestor, GetForegroundWindow, PostMessageW, SetCursorPos,
                SetForegroundWindow, WM_CLOSE, WindowFromPoint,
            },
        },
    },
    core::{Error, Result},
};

use crate::windows::desktop::{DpiContext, WindowId, window_bounds};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Left,
    Middle,
    Right,
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

/// Clicks a normalized point if the window is the topmost target at that point.
///
/// # Errors
///
/// Returns the Win32 delivery error if cursor movement or injection fails.
pub fn click(window: WindowId, x: f64, y: f64, button: Button) -> Result<bool> {
    let _dpi = DpiContext::enter();
    let Some(handle) = window.live_handle() else {
        return Ok(false);
    };
    let Some(bounds) = window_bounds(handle) else {
        return Ok(false);
    };
    let Some(x) = pointer_coordinate(bounds.x, bounds.width, x) else {
        return Ok(false);
    };
    let Some(y) = pointer_coordinate(bounds.y, bounds.height, y) else {
        return Ok(false);
    };
    let point = POINT { x, y };
    if !point_targets(point, handle) {
        return Ok(false);
    }
    // SAFETY: coordinates are physical desktop pixels and fall within the window.
    unsafe { SetCursorPos(x, y)? };
    if window.live_handle().is_none() || !point_targets(point, handle) {
        return Ok(false);
    }
    let (down, up) = match button {
        Button::Left => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        Button::Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
        Button::Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
    };
    let button_input = |flags| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dwFlags: flags,
                ..MOUSEINPUT::default()
            },
        },
    };
    send_pairs(&[button_input(down), button_input(up)])?;
    Ok(true)
}

/// Types Unicode text into the window while it has foreground focus.
///
/// # Errors
///
/// Returns the Win32 injection error if Windows refuses the input batch.
pub fn type_text(window: WindowId, text: &str) -> Result<bool> {
    let Some(handle) = window.live_handle() else {
        return Ok(false);
    };
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
    // SAFETY: GetForegroundWindow does not access caller-provided memory.
    if window.live_handle().is_none() || unsafe { GetForegroundWindow() } != handle {
        return Ok(false);
    }
    send_pairs(&input)?;
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

fn send_pairs(input: &[INPUT]) -> Result<()> {
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
    if sent % 2 == 1
        && let Some(release) = input.get(sent)
    {
        // SAFETY: this is the matching release for a press Windows accepted.
        unsafe { SendInput(std::slice::from_ref(release), size) };
    }
    Err(error)
}
