//! Enumerates and captures host desktop surfaces.
//!
//! On Linux, it enumerates host outputs over Wayland, captures monitor frames
//! through xdg-desktop-portal and PipeWire, provides host-input providers for
//! uinput and the wlroots virtual-input protocols, and connects to the host
//! clipboard over the data-control protocols.
//!
//! This crate separates the host desktop from the Wayland clients hosted by
//! `lunette-compositor`. It exposes monitor descriptions and capture streams for
//! the host outputs, the input-provider seam for the host pointer and keyboard,
//! and the host clipboard client that implements the compositor's
//! `HostSelectionSource` seam.
//!
//! Capture workers own the platform's capture resources and hand off owned frame data.
//! LÖVR and Vulkan resources belong to the host's frame thread.

#[macro_use]
mod variants;

pub mod audio;
#[cfg(target_os = "linux")]
pub mod clipboard;
pub mod hid;
pub mod mirror;
pub mod monitor;
pub mod portal;
mod transform;
pub use transform::FrameTransform;
#[cfg(target_os = "linux")]
pub mod stream;
#[cfg(target_os = "linux")]
pub mod tokens;
#[cfg(windows)]
pub mod windows;
