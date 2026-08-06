//! The Wayland compositor: a smithay backend vendored from WayVR.
//!
//! This crate owns the Wayland display, the client sockets, the surface tree,
//! and the seat. It hands out surface contents as buffers and accepts input
//! events; it decides nothing about where a window is placed or how it is
//! drawn.
//!
//! This crate must not depend on `lunette-lovr`. The compositor's logic is
//! tested headless, with no graphics device and no XR runtime, and a dependency
//! on the LÖVR bindings would make that impossible — the tests would need a
//! built `liblovr.so` to link against. The separation also keeps the graphics
//! module from becoming a dependency of window management, which is the
//! direction the coupling would otherwise grow.

pub mod protocol;
pub mod thread;
