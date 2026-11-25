//! Windows-only: discovers host surfaces and captures them with Windows Graphics Capture.

mod capture;
mod desktop;
mod input;
mod process;
mod stream;
#[cfg(all(test, feature = "test-windows-capture"))]
mod tests;

pub use self::{
    capture::{Capture, CaptureTarget},
    desktop::{
        Bounds, Monitor, MonitorId, Window, WindowId, app_id, monitors, resize_window, window,
        window_title, windows,
    },
    input::{
        Button, PointerInput, ScanCode, character, close, focus, is_foreground, monitor_focused,
        monitor_pointer, pointer, release_button, type_text,
    },
    process::{WindowsProcess, configure_child, read_child_pipe},
    stream::{CaptureStream, CaptureUpdate},
};
