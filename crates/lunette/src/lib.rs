//! Linux-only: the parts of lunette that are not the entry point.
//!
//! The binary is `main.rs`, and it owns the environment, the subscriber, and the
//! LÖVR boot sequence. Everything the binary orchestrates rather than performs
//! lives here, so that it is reachable from tests and so that its public surface
//! is stated in one place.
//!
//! One module today. [`import`] turns what a client committed into something
//! the graphics device holds, and runs on the compositor thread.

pub mod import;
