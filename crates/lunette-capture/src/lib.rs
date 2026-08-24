//! Linux-only: drives xdg-desktop-portal over D-Bus, PipeWire, and `/dev/uinput`.
//!
//! Monitor mirroring and host input injection.
//!
//! This crate wraps `wlx-capture` for reading existing monitors, and
//! `HidProvider` for driving the host's pointer and keyboard. Both are seams
//! onto the machine lunette is running on, as distinct from the Wayland clients
//! lunette hosts itself, which belong to `lunette-compositor`.
//!
//! The wrappers present captured frames and input sinks in the terms the rest
//! of the workspace uses. Policy about which monitors are mirrored, and where,
//! is decided in Lua.
//!
//! This crate must not depend on a graphics API, and in particular not on
//! `ash`. Captured frames are forwarded to the main thread as plain buffer and
//! dmabuf descriptions, and the import path in `lunette` turns them into
//! textures. That leaves one import path and one GPU queue for the whole
//! process, rather than a second queue on the capture thread as WayVR needs,
//! and it keeps this crate testable without a graphics device — the same
//! constraint `lunette-compositor` carries, for the same reason.

#[macro_use]
mod variants;

pub mod hid;
pub mod mirror;
pub mod monitor;
pub mod portal;
pub mod stream;
pub mod tokens;
