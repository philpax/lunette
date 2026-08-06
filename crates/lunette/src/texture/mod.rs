//! Linux-only: wrapping what the compositor imported as a LÖVR texture.
//!
//! The frame thread owns everything here. The compositor thread creates images
//! and repacks pixels; this module turns either into a `Texture` LÖVR can
//! sample, records the barriers around reading it, and destroys it afterwards.
//!
//! The four parts are separate because three of them need no graphics device.
//! `generation` is two counters, `ledger` is the bookkeeping over an
//! arbitrary texture, `barrier` is the choice of arguments an import barrier
//! is recorded with, and `lovr` is the only part that calls LÖVR.

mod barrier;
mod generation;
mod ledger;
mod lovr;

pub use self::{
    barrier::{BarrierPolicy, ForeignLayout, QueueFamilyMode},
    generation::{FrameGeneration, SurfaceCommit},
    ledger::{
        CopyableTexture, Released, TextureDescription, TextureLedger, TextureRef,
        TextureUnavailable, describe, destroy_due_images,
    },
    lovr::{LovrTexture, TextureError},
};
