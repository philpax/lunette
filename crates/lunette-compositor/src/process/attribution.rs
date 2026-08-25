//! This file contains process-attribution sections derived from WayVR's
//! `backend/wayvr/process.rs` and `backend/wayvr/mod.rs`.
//! The source revision is `98f800c644719d3f23a20e50bd3237c29a8082cb`.
//! See https://github.com/wayvr-org/wayvr.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`.
//!
//! Inspects processes that the compositor did not start.

use std::{fs, io};

use crate::{process::registry::find_environment_value, protocol::Pid};

/// Inspects a process that the compositor did not start.
///
/// The production implementation reads `/proc`. The trait lets tests inspect
/// attribution and liveness without a real process.
pub trait ProcessInspector: Send {
    /// Reads one environment variable as raw bytes.
    ///
    /// # Errors
    ///
    /// Returns the underlying error when the process's environment cannot be
    /// read at all, which usually means it has already exited.
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>>;

    /// Reports whether the process still exists.
    fn is_running(&self, pid: Pid) -> bool;
}

/// Inspects the Linux `/proc` filesystem.
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
