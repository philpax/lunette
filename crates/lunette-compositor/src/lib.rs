//! Wayland compositor and protocol state for lunette.
//!
//! This crate has no dependency on `lunette-lovr`. Its logic and protocol tests
//! run without a graphics device or XR runtime, and omitting the LÖVR bindings
//! allows those tests to link without `liblovr.so`.

pub mod client;
pub(crate) mod hit_test;
pub mod keymap;
pub(crate) mod output;
pub(crate) mod pacing;
pub mod process;
pub mod protocol;
pub(crate) mod seat;
pub mod selection;
pub mod state;
pub mod surface;
#[cfg(any(test, feature = "test-fakes"))]
pub mod test_client;
#[cfg(any(test, feature = "test-fakes"))]
pub mod testing;
pub mod thread;
pub(crate) mod type_text;
pub mod window;
