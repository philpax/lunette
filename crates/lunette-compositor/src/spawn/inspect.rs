//! Linux-only: reads `/proc/<pid>/environ` and checks `/proc/<pid>` metadata.
//!
//! The `/proc` seam behind client attribution and adopted-process liveness.

use std::{fs, io};

use crate::{protocol::Pid, wayvr::process::get_process_env_value};

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
        get_process_env_value(pid, key)
    }

    fn is_running(&self, pid: Pid) -> bool {
        fs::metadata(format!("/proc/{pid}")).is_ok()
    }
}

/// Finds a variable in a NUL-separated environment block, as
/// `/proc/<pid>/environ` presents it. It skips entries without `=`, and keeps
/// non-UTF-8 values and everything after the first `=` in the matching entry.
pub(crate) fn find_environment_value(env_data: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    env_data
        .split(|byte| *byte == 0)
        .filter(|line| !line.is_empty())
        .find_map(|line| {
            let separator = line.iter().position(|byte| *byte == b'=')?;
            (&line[..separator] == key).then(|| line[separator + 1..].to_vec())
        })
}
