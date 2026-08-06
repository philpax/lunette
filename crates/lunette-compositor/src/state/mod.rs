//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs and backend/wayvr/mod.rs (the globals and output fragments), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The smithay state and the protocol handlers hung off it.
//!
//! [`CompositorState`] is what WayVR calls `Application` (`comp.rs:68-94`): the
//! one struct every `delegate_*!` macro dispatches into. It owns the delegate
//! state for each global lunette advertises, the surface bookkeeping from
//! [`crate::surface`], and the two ends of the transports in [`crate::thread`]
//! that report outwards.
//!
//! # What is deliberately not here
//!
//! - **The single-pixel-buffer path.** WayVR handles `BufferType::SinglePixel`
//!   at `comp.rs:285-304` and delegates the global at `:693`, but never
//!   constructs `SinglePixelBufferState`, so no client can ever bind it and the
//!   branch is unreachable. Porting dead code carries its bugs forward.
//! - **`wp_fractional_scale_v1`.** WayVR calls `with_fractional_scale` at
//!   `comp.rs:125` and `:145`. Those calls write to surface user data no client
//!   can read, because `FractionalScaleManagerState` is never constructed
//!   there either, and the write is thread-affine besides
//!   (`smithay-0.7.0/src/wayland/fractional_scale/mod.rs:253-263` is a
//!   `get_or_insert`, which records the calling thread). Phase 8 implements
//!   fractional scale properly and owns the question.
//! - **`zwp_relative_pointer`.** A pointer driven by a hand has an absolute
//!   position, and relative motion is what a client that has captured the
//!   pointer wants; nothing asks for it yet.

mod commit;
mod compositor;
mod handlers;
mod input;
mod selection;
#[cfg(test)]
mod tests;

pub use crate::state::compositor::{
    ClientState, CompositorConfig, DEFAULT_OUTPUT, DEFAULT_SEAT, DmabufSupport, RenderNode,
};
pub(crate) use crate::state::compositor::{CompositorState, StateParts};
