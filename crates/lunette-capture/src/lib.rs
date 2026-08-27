//! Linux-only: enumerates host outputs over Wayland, captures monitor frames
//! through xdg-desktop-portal and PipeWire, and provides host-input providers for
//! uinput and the wlroots virtual-input protocols.
//!
//! This crate separates the host desktop from the Wayland clients hosted by
//! `lunette-compositor`. It exposes monitor descriptions and capture streams for
//! the host outputs, and the input-provider seam for the host pointer and
//! keyboard.
//!
//! This crate must not depend on a graphics API, including `ash`. Capture
//! threads forward owned buffer and dmabuf descriptions to the main thread,
//! where `lunette` imports them through the same path as client buffers. GPU
//! import stays in `lunette`, so there is one import path and the tests run
//! without a graphics device.

#[macro_use]
mod variants;

pub mod hid;
pub mod mirror;
pub mod monitor;
pub mod portal;
pub mod stream;
pub mod tokens;
