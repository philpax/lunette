//! Linux-only: the pool of OpenXR composition layers panels are promoted onto.
//!
//! A panel drawn on an in-scene quad is resampled by lunette's own renderer
//! before the runtime resamples it again. A panel on a composition layer is
//! handed to the runtime at its native resolution and composited once, which is
//! the whole of the sharpness difference. Layers are scarce, so the question
//! this module answers is which panels hold one.
//!
//! # Why the pool exists at all
//!
//! `lovrLayerCreate` allocates an OpenXR swapchain with images, memory, and
//! runtime state, synchronously on the calling thread, ending in
//! `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop that
//! has no escape. A panel manager promoting and demoting panels as the user
//! looks around would allocate one every few frames if Lua created them
//! directly. So Rust owns them, recycles them through a free list keyed by
//! [`LayerKey`], and creates at most [`LayerPool::CREATIONS_PER_FRAME`] a
//! boundary.
//!
//! # The division with Lua
//!
//! Lua supplies a scalar [`Priority`] per claim and Rust assigns the top N
//! deterministically. Ranking is application knowledge — focus, gaze, distance,
//! a rule putting video above a terminal — and lunette never invents it. This
//! is a recorded decision, revisited once during design; the first proposal put
//! the pool itself in Lua, and layer churn is what ruled it out.

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
