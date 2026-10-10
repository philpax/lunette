//! lunette's own compositor-thread work: outputs, frame pacing, processes,
//! the host clipboard bridge, and the graphics device handover.
//!
//! The protocol handlers that dispatch to [`crate::wayvr::comp::Application`]
//! are in `src/wayvr/comp.rs`.

mod graphics;
mod outputs;
mod pacing;
mod processes;
mod selection;
#[cfg(test)]
mod tests;

pub(crate) use crate::state::outputs::logical_size;
pub use crate::{
    config::{CompositorConfig, DEFAULT_OUTPUT, DEFAULT_SEAT, DmabufSupport, RenderNode},
    wayvr::comp::ClientState,
};
