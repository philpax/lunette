//! Monitor mirroring and host input injection.
//!
//! This crate wraps `wlx-capture` for reading the user's existing monitors, and
//! `HidProvider` for driving the host's pointer and keyboard. Both are seams
//! onto the machine lunette is running on, as distinct from the Wayland clients
//! lunette hosts itself, which belong to `lunette-compositor`.
//!
//! The wrappers present captured frames and input sinks in the terms the rest
//! of the workspace uses. Policy about which monitors are mirrored, and where,
//! is decided in Lua.
