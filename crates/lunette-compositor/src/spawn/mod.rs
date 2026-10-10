//! Linux-only: creates child process groups with `setsid`, sets parent-death
//! signalling through `prctl`, and reads `/proc/<pid>`.
//!
//! The parts of process management that do not fit the shape of WayVR's
//! `process.rs`, which lives in [`crate::wayvr::process`]: the spawner and
//! `/proc` seams, process groups, parent-death signalling, output capture, the
//! spawn plan and its authentication token, and the operations on the process
//! table.

mod inspect;
mod plan;
mod system;
mod table;
#[cfg(test)]
mod tests;

/// Re-exported for the fake child, which must not signal a process-group
/// identifier after reaping because the kernel can reuse it for an unrelated
/// group.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::spawn::system::Liveness;
pub(crate) use crate::spawn::{
    inspect::find_environment_value,
    plan::{AUTH_VARIABLE, AuthToken, SpawnRequest},
    system::signal_group,
    table::{AdoptedIds, Report, add_external_process, poll, snapshot, spawn_process},
};
pub use crate::spawn::{
    inspect::{ProcFilesystem, ProcessInspector},
    system::{
        ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnError, SpawnPlan, SystemSpawner,
    },
};
