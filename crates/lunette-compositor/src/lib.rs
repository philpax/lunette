//! Wayland compositor and protocol state for lunette.
//!
//! This crate has no dependency on `lunette-lovr`. Its logic and protocol tests
//! run without a graphics device or XR runtime, and omitting the LÖVR bindings
//! allows those tests to link without `liblovr.so`.

pub(crate) mod commands;
pub mod config;
pub(crate) mod drag;
pub(crate) mod graphics;
pub mod keymap;
pub mod listener;
pub(crate) mod output;
pub(crate) mod pacing;
pub mod protocol;
pub mod satellite;
pub(crate) mod seat;
pub mod selection;
pub mod spawn;
pub mod surface;
pub(crate) mod surface_tree;
pub(crate) mod task_queue;
#[cfg(any(test, feature = "test-fakes"))]
pub mod test_client;
#[cfg(any(test, feature = "test-fakes"))]
pub mod testing;
pub mod thread;
pub(crate) mod type_text;
pub(crate) mod wayvr;
pub(crate) mod window;
