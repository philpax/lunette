//! Desktop protocol state and the Linux Wayland compositor.
//!
//! This crate has no dependency on `lunette-lovr`. Its logic and protocol tests
//! run without a graphics device or XR runtime, and omitting the LÖVR bindings
//! allows those tests to link without `liblovr.so`.

#[cfg(target_os = "linux")]
pub(crate) mod commands;
pub mod config;
#[cfg(target_os = "linux")]
pub(crate) mod drag;
#[cfg(target_os = "linux")]
pub(crate) mod graphics;
#[cfg(target_os = "linux")]
pub mod keymap;
#[cfg(target_os = "linux")]
pub mod listener;
#[cfg(target_os = "linux")]
pub(crate) mod output;
#[cfg(target_os = "linux")]
pub(crate) mod pacing;
mod pixels;
pub mod protocol;
#[cfg(target_os = "linux")]
pub mod satellite;
#[cfg(target_os = "linux")]
pub(crate) mod seat;
#[cfg(target_os = "linux")]
pub mod selection;
#[cfg(target_os = "linux")]
pub mod spawn;
#[cfg(target_os = "linux")]
pub mod surface;
#[cfg(target_os = "linux")]
pub(crate) mod surface_tree;
#[cfg(target_os = "linux")]
pub(crate) mod task_queue;
#[cfg(all(target_os = "linux", any(test, feature = "test-fakes")))]
pub mod test_client;
#[cfg(all(target_os = "linux", any(test, feature = "test-fakes")))]
pub mod testing;
#[cfg(target_os = "linux")]
pub mod thread;
#[cfg(target_os = "linux")]
pub(crate) mod type_text;
#[cfg(target_os = "linux")]
pub(crate) mod wayvr;
#[cfg(target_os = "linux")]
pub(crate) mod window;
