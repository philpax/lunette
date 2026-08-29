//! Linux-only: the pool of OpenXR composition layers that panels are promoted
//! onto.
//!
//! lunette's renderer resamples a panel drawn on an in-scene quad.
//! The runtime resamples it a second time.
//! A panel on a composition layer is composited once, at its native resolution.
//! That is the whole of the sharpness difference. Layers are scarce.
//! The pool allocates a layer to a panel when Lua's claim on it is granted.
//!
//! # Reason for the pool
//!
//! `lovrLayerCreate` allocates an OpenXR swapchain with images, memory, and
//! runtime state, synchronously on the calling thread, ending in
//! `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop with
//! no exit condition. A panel manager promoting and demoting panels as the
//! user looks around would allocate one every few frames if Lua created layers
//! directly. Rust owns the layers, reuses them via a free list keyed by
//! [`LayerKey`], and creates at most [`LayerPool::CREATIONS_PER_FRAME`] per
//! frame boundary.
//!
//! # The division with Lua
//!
//! Lua supplies a scalar [`Priority`] per claim. Rust assigns the top N
//! deterministically. Ranking is application knowledge: focus, gaze,
//! distance, a rule putting video above a terminal. lunette never invents
//! it. The division is a recorded decision.

mod backend;
mod blit;
mod key;
mod lovr;
mod pool;
#[cfg(test)]
mod tests;

pub use self::{
    backend::{LayerBackend, SessionId, SessionPresence},
    blit::{BlitLedger, Blitted, Decision, LayerBlitter, LayerTexture, StaleLayerTexture, decide},
    key::{LayerKey, LayerProperties, LayerSize},
    lovr::{LovrBlits, LovrLayer, LovrLayers},
    pool::{ClaimId, ClaimState, LayerBudget, LayerPool, PoolOutcome, Priority},
};
