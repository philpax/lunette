//! Adapted from WayVR's `backend/wayvr/process.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`.
//!
//! The processes lunette started or adopted, and the attribution of a
//! connecting client to one of them.
//!
//! lunette keeps the identifier Lua sees beside each slotmap handle. A managed
//! process holds its child behind the `ChildProcess` seam, which signals the
//! whole process group, never signals a child after reaping it, and terminates
//! and reaps the group when dropped, so `WayVRProcess` needs no `Drop` of its
//! own. An adopted process is signalled as a group too. The authentication
//! token is compared in constant time, and the environment is read as bytes,
//! because an environment is not required to be UTF-8. The application
//! metadata, names, and IPC packet conversions are left out, because lunette
//! has no IPC clients.

use std::io;

use slotmap::{DenseSlotMap, new_key_type};
use tracing as log;

use crate::{
    protocol::{Pid, ProcessId, ProcessSignal},
    spawn::{
        AUTH_VARIABLE, AuthToken, ChildProcess, ProcessInspector, find_environment_value,
        signal_group,
    },
};

#[derive(Debug)]
#[allow(dead_code)]
pub struct WayVRProcess {
    pub auth_key: AuthToken,
    pub child: Box<dyn ChildProcess>,
    pub id: ProcessId,
}

#[derive(Debug)]
pub struct ExternalProcess {
    pub pid: Pid,
    pub id: ProcessId,
}

#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum Process {
    Managed(WayVRProcess),     // Process spawned by WayVR
    External(ExternalProcess), // External process not directly controlled by us
}

impl Process {
    pub fn kill(&mut self, signal: ProcessSignal) {
        match self {
            Self::Managed(p) => p.kill(signal),
            Self::External(p) => p.kill(signal),
        }
    }
}

pub fn get_process_env_value(pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>> {
    let path = format!("/proc/{pid}/environ");
    let env_data = std::fs::read(path)?;
    Ok(find_environment_value(&env_data, key.as_bytes()))
}

impl WayVRProcess {
    fn kill(&mut self, signal: ProcessSignal) {
        self.child.signal(signal);
    }
}

impl ExternalProcess {
    pub fn is_running(&self, inspector: &dyn ProcessInspector) -> bool {
        inspector.is_running(self.pid)
    }

    fn kill(&mut self, signal: ProcessSignal) {
        if let Err(error) = signal_group(self.pid, signal) {
            log::warn!(pid = %self.pid, %error, "could not signal an adopted process group");
        }
    }
}

new_key_type! {
    pub struct ProcessHandle;
}

pub fn find_by_pid(
    processes: &DenseSlotMap<ProcessHandle, Process>,
    pid: Pid,
    inspector: &dyn ProcessInspector,
) -> Option<ProcessHandle> {
    log::debug!("Finding process with PID {pid}");

    for (handle, process) in processes {
        match &process {
            Process::Managed(wayvr_process) => {
                if wayvr_process.child.pid() == pid {
                    return Some(handle);
                }
            }
            Process::External(external_process) => {
                if external_process.pid == pid {
                    return Some(handle);
                }
            }
        }
    }

    log::debug!("Finding by PID failed, trying {AUTH_VARIABLE}...");

    match inspector.read_environment(pid, AUTH_VARIABLE) {
        Ok(Some(value)) => {
            let presented = AuthToken::from_bytes(&value);
            for (handle, process) in processes {
                if let Process::Managed(wayvr_process) = &process
                    && wayvr_process.auth_key.matches(&presented)
                {
                    return Some(handle);
                }
            }
        }
        Ok(None) => {}
        // An unreadable environment cannot authenticate the client.
        Err(error) => log::debug!(%pid, %error, "could not read a connecting client's environment"),
    }

    log::debug!("Process find with PID {pid} failed");
    None
}
