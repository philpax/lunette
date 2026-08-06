//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/process.rs and backend/wayvr/mod.rs (the spawn and attribution fragments at :1232-1349), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`.
//!
//! How lunette looks at a process it did not start.

use std::{fs, io};

use crate::{process::registry::find_environment_value, protocol::Pid};

/// Looks at a process lunette did not start.
///
/// A seam over `/proc`, so both the matching logic and the liveness check can
/// be tested without a real process existing. One trait rather than two,
/// because both answers come from the same directory and every caller wants
/// both.
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
