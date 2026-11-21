//! Windows-only: discovers host surfaces and captures them with Windows Graphics Capture.

mod capture;
mod desktop;
mod input;
mod stream;
#[cfg(test)]
mod tests;

pub use self::{
    capture::{Capture, CaptureTarget},
    desktop::{Bounds, Monitor, MonitorId, Window, WindowId, monitors, windows},
    input::{Button, click, close, focus, type_text},
    stream::{CaptureStream, CaptureUpdate},
};
