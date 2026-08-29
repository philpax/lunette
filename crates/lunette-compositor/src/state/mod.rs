//! Adapted from the globals and output fragments in WayVR's
//! `backend/wayvr/comp.rs` and `backend/wayvr/mod.rs`
//! (https://github.com/wayvr-org/wayvr), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The protocol delegate implementations in `handlers.rs` dispatch requests to
//! [`CompositorState`]. It owns the state for each global lunette advertises, the
//! surface bookkeeping from [`crate::surface`], and the compositor-thread
//! endpoints of the event and snapshot transports in [`crate::thread`].
//!
//! # Deliberately omitted
//!
//! - **`wp_single_pixel_buffer_manager_v1`.** Lunette does not advertise this
//!   global, so clients cannot bind it.
//! - **`zwp_relative_pointer_manager_v1`.** Lunette reports absolute pointer
//!   positions and does not advertise relative pointer events.

mod commit;
mod compositor;
mod graphics;
mod handlers;
mod input;
mod outputs;
mod pacing;
mod processes;
mod selection;
#[cfg(test)]
mod tests;

pub use crate::state::compositor::{
    ClientState, CompositorConfig, DEFAULT_OUTPUT, DEFAULT_SEAT, DmabufSupport, RenderNode,
};
pub(crate) use crate::state::compositor::{CompositorState, StateParts};
