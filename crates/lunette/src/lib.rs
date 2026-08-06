//! Linux-only: the parts of lunette that are not the entry point.
//!
//! The binary is `main.rs`, and it owns the environment, the subscriber, and the
//! LÖVR boot sequence. Everything the binary orchestrates rather than performs
//! lives here, so that it is reachable from tests and so that its public surface
//! is stated in one place.
//!
//! Five modules today. [`import`] turns what a client committed into something
//! the graphics device holds, and runs on the compositor thread. [`texture`]
//! turns that into a LÖVR `Texture`, and runs on the frame thread. The line
//! between them is the line between creating an image, which touches no queue,
//! and submitting work, which does. [`lua`] is the surface all of it is
//! presented to the user's configuration through, and [`events`] is how the
//! configuration is told that something happened rather than having to look.
//! [`frame`] is what runs the other four in the order they require, once per
//! frame, and is the only thing that starts the compositor thread.

pub mod events;
pub mod frame;
pub mod import;
pub mod lua;
pub mod texture;
