//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/process.rs and backend/wayvr/mod.rs (the spawn and attribution fragments at :1232-1349), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`, and spawns through `setsid` and
//! `prctl`.
//!
//! The processes lunette started, the ones it adopted, and how a connecting
//! client is matched to one.
//!
//! # Why a client has to be matched at all
//!
//! A Wayland client's connection carries the pid that opened the socket, which
//! is frequently not the process lunette started: a shell wrapper `exec`s, a
//! flatpak launcher hands off to a sandbox, a browser starts a zygote. So
//! matching is two-stage, as WayVR's is (`process.rs:182-217`): the connecting
//! pid first, and failing that an authentication token lunette put in the
//! child's environment and reads back out of `/proc/<pid>/environ`. A client
//! that matches neither connected from outside and is reported as external.
//!
//! # What is fixed relative to WayVR
//!
//! - **The token is from a CSPRNG, not a v4 UUID** (`mod.rs:1346-1349`), and is
//!   compared in constant time rather than with string equality. It is what
//!   attributes a window to a process, so a token that can be guessed or
//!   recovered a byte at a time is an attribution a hostile client can claim.
//! - **`/proc/<pid>/environ` is read as bytes.** WayVR reads it with
//!   `read_to_string` (`client.rs:70`, `process.rs:102`), which fails outright
//!   on an environment that is not UTF-8 — legal on Linux, and produced by any
//!   program that puts a path with odd bytes in one.
//! - **A whole process group is signalled, not just the direct child.** WayVR
//!   signals `child.id()` (`process.rs:132`, `:166`); a grep across its sources
//!   for `setsid`, `PDEATHSIG`, `process_group`, `pre_exec`, and `killpg` finds
//!   nothing, so a shell wrapper's grandchildren survive being killed. Lunette
//!   spawns with `setsid`, signals the group, and sets `PR_SET_PDEATHSIG` as a
//!   backstop for lunette itself dying.

mod attribution;
mod registry;
mod spawn;
#[cfg(test)]
mod tests;

/// Reached only by the fake `/proc` in [`crate::testing`], which has to parse
/// an environment block the same way the real one does or the two would answer
/// differently.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::registry::find_environment_value;
pub(crate) use crate::process::registry::{ProcessRegistry, Report, SpawnRequest};
/// Reached by the fake child in [`crate::testing`], which enforces the same
/// signalling rule as the real one so a test can assert it without forking.
#[cfg(any(test, feature = "test-fakes"))]
pub(crate) use crate::process::spawn::Liveness;
pub use crate::process::{
    attribution::{ProcFilesystem, ProcessInspector},
    spawn::{
        ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnError, SpawnPlan, SystemSpawner,
    },
};
