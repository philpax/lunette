//! This module contains process-management sections derived from WayVR's
//! `backend/wayvr/process.rs` and `backend/wayvr/mod.rs`.
//! The source revision is `98f800c644719d3f23a20e50bd3237c29a8082cb`.
//! See https://github.com/wayvr-org/wayvr.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`, and spawns through `setsid` and
//! `prctl`.
//!
//! The process registry tracks spawned and adopted processes. Client attribution
//! checks the connecting PID, then an authentication token in the process environment.
//! A client that matches neither is external.
//!
//! Authentication tokens use operating-system randomness and constant-time comparison.
//! This prevents token guessing and timing attacks from claiming another process.
//! The registry reads environment data as raw bytes because Linux does not require
//! environment values to be UTF-8.
//! Each spawned process starts a new session and process group. The compositor
//! signals the group so wrapper descendants stop with the application. `PR_SET_PDEATHSIG`
//! terminates a spawned process when the compositor process dies.

mod attribution;
mod registry;
mod spawn;
#[cfg(test)]
mod tests;

/// Parses environment blocks for the fake `/proc` implementation.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::registry::find_environment_value;
pub(crate) use crate::process::registry::{ProcessRegistry, Report, SpawnRequest};
/// Enforces the process-group signalling rule in the fake child.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::spawn::Liveness;
pub use crate::process::{
    attribution::{ProcFilesystem, ProcessInspector},
    spawn::{
        ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnError, SpawnPlan, SystemSpawner,
    },
};
