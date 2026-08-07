//! Linux-only: the parts of lunette that are not the entry point.
//!
//! The binary is `main.rs`, and it owns the environment, the subscriber, and the
//! LÖVR boot sequence. Everything the binary orchestrates rather than performs
//! lives here, so that it is reachable from tests and so that its public surface
//! is stated in one place.
//!
//! [`import`] turns what a client committed into something the graphics device
//! holds, and runs on the compositor thread. [`texture`] turns that into a LÖVR
//! `Texture`, and runs on the frame thread. The line between them is the line
//! between creating an image, which touches no queue, and submitting work,
//! which does. [`lua`] is the surface all of it is presented to the user's
//! configuration through, and [`events`] is how the configuration is told that
//! something happened rather than having to look. [`layers`] decides which
//! panels are promoted onto OpenXR composition layers, over the ladder of
//! discrete steps [`scale`] defines. [`mirrors`] is the other half of what Lua
//! can point at: the user's own screens, mirrored through the screencast portal
//! rather than hosted by the compositor, and [`host`] is where a sink pointed at
//! one of them delivers. [`properties`] is the one piece of per-window state
//! Rust keeps on the configuration's behalf, because a soft reload throws the
//! Lua state away and something has to survive it. [`safe_mode`] is the
//! configuration the session falls back to when the user's will not load,
//! embedded rather than installed so that nothing on disk can take it away.
//! [`frame`] is what runs the
//! rest in the order they require, once per frame, and is the only thing that
//! starts the compositor thread.

pub mod events;
pub mod frame;
pub mod host;
pub mod import;
pub mod keymaps;
pub mod layers;
pub mod lua;
pub mod mirrors;
pub mod properties;
pub mod safe_mode;
pub mod scale;
pub mod texture;
