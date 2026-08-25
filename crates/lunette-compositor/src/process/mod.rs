//! Process tracking, attribution, and spawning adapt selected fragments of WayVR's
//! `backend/wayvr/process.rs` and `backend/wayvr/mod.rs`, at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`, creates child process groups with
//! `setsid`, and sets parent-death signalling through `prctl`.

mod attribution;
mod registry;
mod spawn;
#[cfg(test)]
mod tests;

/// Re-exported for the fake `/proc`, which must parse the production NUL-separated
/// environment block with the same byte-preserving behavior.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::registry::find_environment_value;
pub(crate) use crate::process::registry::{ProcessRegistry, Report, SpawnRequest};
/// Re-exported for the fake child, which must not signal a process-group identifier after reaping
/// because the kernel can reuse it for an unrelated group.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::spawn::Liveness;
pub use crate::process::{
    attribution::{ProcFilesystem, ProcessInspector},
    spawn::{
        ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnError, SpawnPlan, SystemSpawner,
    },
};
