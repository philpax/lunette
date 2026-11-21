//! Wraps desktop surfaces as LÖVR textures.
//!
//! The frame thread owns everything in this module. The compositor thread creates images
//! and repacks pixels; this module turns either into a `Texture` LÖVR can
//! sample, records the barriers around reading it, and destroys it afterwards.
//!
//! The five parts are separate because four of them need no graphics device.
//! `generation` is two counters, `ledger` is the bookkeeping over an
//! arbitrary texture, `monitor` is the same for a mirrored monitor's texture,
//! `barrier` is the choice of arguments an import barrier is recorded with.
//! No part other than `lovr` calls LÖVR.

mod barrier;
mod generation;
mod ledger;
mod lovr;
mod monitor;

pub use self::{
    barrier::{BarrierPolicy, ForeignLayout, QueueFamilyMode},
    generation::{FrameGeneration, SurfaceCommit},
    ledger::{
        CopyableTexture, Released, TextureDescription, TextureLedger, TextureRef,
        TextureUnavailable, describe, describe_pixels,
    },
    lovr::{LovrTexture, TextureError},
    monitor::MonitorTextures,
};

#[cfg(target_os = "linux")]
pub use ledger::destroy_due_images;

/// Whether a format's fourth component carries alpha or padding.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Alpha {
    /// The fourth component is alpha, and a consumer samples it.
    Present,
    /// The fourth component is undefined padding, and a consumer forces it to
    /// one. Sampling it renders the surface with arbitrary transparency.
    Opaque,
}
