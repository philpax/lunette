//! Adapted from the `get_process_env_value` fragment in WayVR's
//! `backend/wayvr/process.rs`
//! (https://github.com/wayvr-org/wayvr), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ` and checks `/proc/<pid>` metadata.

use std::{fs, io};

use crate::{process::registry::find_environment_value, protocol::Pid};

/// Provides process observations for client attribution and adopted-process liveness.
///
/// A process can be identified by PID, or by an authentication-token variable
/// when a wrapper or sandbox launcher presents a different PID. Implementations
/// do not own or wait for processes. Environment values remain
/// raw bytes because process environments are not required to be UTF-8. An
/// in-memory implementation lets tests avoid the host's `/proc`.
pub trait ProcessInspector: Send {
    /// Returns `None` when `key` is absent and preserves the value's bytes.
    ///
    /// # Errors
    ///
    /// Returns an I/O error when the process environment cannot be read,
    /// including when the process exits before the read.
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>>;

    /// Returns a point-in-time liveness observation for `pid`.
    ///
    /// A false result does not distinguish an exited process from an unavailable
    /// process record, and it does not reserve the PID or establish ownership.
    fn is_running(&self, pid: Pid) -> bool;
}

/// Uses the host's Linux `/proc` filesystem for process inspection.
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
