//! Adapted from the globals and output fragments in WayVR (https://github.com/wayvr-org/wayvr),
//! backend/wayvr/comp.rs and backend/wayvr/mod.rs, at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! This module owns the compositor state and the protocol handlers routed into
//! it. [`CompositorState`] is what WayVR calls `Application`: the one struct
//! every `delegate_*!` macro dispatches into. It owns the delegate state for
//! each global lunette advertises, the surface bookkeeping from
//! [`crate::surface`], and the two ends of the transports in [`crate::thread`]
//! that report outwards.
//!
//! Two WayVR behaviours are deliberately absent:
//!
//! - The single-pixel-buffer path. WayVR handles `BufferType::SinglePixel` but
//!   never constructs `SinglePixelBufferState`, so no client can ever bind the
//!   global and the branch is unreachable. Porting dead code carries its bugs
//!   forward.
//! - `zwp_relative_pointer`. A pointer driven by a hand has an absolute
//!   position, and relative motion serves clients that capture the pointer;
//!   nothing asks for it yet.

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
