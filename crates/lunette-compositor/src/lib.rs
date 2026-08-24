//! The Wayland compositor backend.
//!
//! This crate owns the Wayland display, client sockets, surface tree, and seats.
//! It exposes surface contents as buffers and accepts input events. Window placement and drawing remain outside this crate.
//!
//! This crate does not depend on `lunette-lovr`. Headless tests run without a graphics device or an XR runtime. The separation also keeps graphics code out of window management.

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
