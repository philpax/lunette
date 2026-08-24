//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`.
//!
//! Inspects processes that the compositor did not start.

use std::{fs, io};

use crate::{process::registry::find_environment_value, protocol::Pid};

/// Inspects a process that the compositor did not start.
///
/// The implementation reads `/proc`. The trait keeps attribution and liveness
/// checks testable without a real process.
pub trait ProcessInspector: Send {
    /// The value of one variable in a process's environment, as bytes.
    ///
    /// # Errors
    ///
    /// Returns the underlying error when the process's environment cannot be
    /// read at all, which usually means it has already exited.
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>>;

    /// Whether the process still exists.
    fn is_running(&self, pid: Pid) -> bool;
}

/// The real `/proc`.
#[derive(Clone, Copy, Debug, Default)]
pub struct ProcFilesystem;

impl ProcessInspector for ProcFilesystem {
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>> {
        let raw = fs::read(format!("/proc/{pid}/environ"))?;
        Ok(find_environment_value(&raw, key.as_bytes()))
    }

    fn is_running(&self, pid: Pid) -> bool {
        fs::metadata(format!("/proc/{pid}")).is_ok()
    }
}
