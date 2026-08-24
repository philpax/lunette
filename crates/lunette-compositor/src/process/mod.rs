//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`, and spawns through `setsid` and
//! `prctl`.
//!
//! The process registry tracks spawned and adopted processes. Client attribution
//! checks the connecting pid, then an authentication token in the process environment.
//! A client that matches neither is external.
//!
//! The authentication token uses operating-system randomness and constant-time comparison. This prevents a client from claiming another process through token guessing or timing.
//! Environment data is read as bytes because Linux does not require environment values to be UTF-8.
//! Each spawned process starts a new session and process group. The compositor signals the group so wrapper descendants stop with the application. `PR_SET_PDEATHSIG` terminates a spawned process when the compositor process dies.

mod attribution;
mod registry;
mod spawn;
#[cfg(test)]
mod tests;

/// Used by the fake `/proc` implementation to parse environment blocks.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::registry::find_environment_value;
pub(crate) use crate::process::registry::{ProcessRegistry, Report, SpawnRequest};
/// Used by the fake child to enforce the process-group signalling rule.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::spawn::Liveness;
pub use crate::process::{
    attribution::{ProcFilesystem, ProcessInspector},
    spawn::{
        ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnError, SpawnPlan, SystemSpawner,
    },
};
