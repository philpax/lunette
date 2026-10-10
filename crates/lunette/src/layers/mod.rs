//! Linux-only: the pool of backend-owned composition layers that panels are
//! promoted onto.
//!
//! A panel on a composition layer is resampled once instead of twice, so it is sharper. Creating
//! a layer is expensive and synchronous, so the pool reuses layers through a free list. Lua
//! supplies each claim's [`Priority`], and Rust assigns the top claims deterministically.

mod backend;
mod blit;
mod key;
mod lovr;
mod pool;
#[cfg(test)]
mod tests;

pub use self::{
    backend::{LayerBackend, SessionId, SessionPresence},
    blit::{BlitLedger, Blitted, LayerBlitter},
    key::LayerSize,
    lovr::{LovrBlits, LovrLayer, LovrLayers},
    pool::{ClaimId, ClaimState, LayerBudget, LayerPool, Priority},
};
