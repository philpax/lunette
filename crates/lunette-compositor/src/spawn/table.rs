//! Linux-only: adopted-process liveness depends on the production inspector
//! reading `/proc`.
//!
//! The operations on the process table: starting a managed process, adopting
//! an external one, polling both, and reporting them to the snapshot.
//!
//! The table is upstream's `DenseSlotMap<ProcessHandle, Process>`. Upstream
//! starts and adopts processes in `spawn_process` and
//! `add_external_process` of `backend/wayvr/mod.rs` and polls them in
//! `tick_events`; lunette keeps those operations here as functions of the
//! table, so they can be tested without a compositor.

use slotmap::DenseSlotMap;
use tracing::debug;

use crate::{
    protocol::{Pid, ProcessId, ProcessOutcome, ProcessSnapshot, Stream},
    spawn::{
        inspect::ProcessInspector,
        plan::{AuthToken, SpawnRequest, build_plan},
        system::{ProcessSpawner, SpawnError},
    },
    wayvr::process::{ExternalProcess, Process, ProcessHandle, WayVRProcess},
};

/// Starts a process and registers it under an identifier allocated by the
/// main thread before the request is sent. A failed spawn is not registered.
pub(crate) fn spawn_process(
    processes: &mut DenseSlotMap<ProcessHandle, Process>,
    spawner: &mut dyn ProcessSpawner,
    request: SpawnRequest<'_>,
) -> Result<ProcessHandle, SpawnError> {
    let auth_key = AuthToken::generate(request.argv.program())?;
    let plan = build_plan(&request, &auth_key);

    let child = spawner.spawn(&plan)?;
    debug!(process = %request.process, pid = %child.pid(), "started a process");

    Ok(processes.insert(Process::Managed(WayVRProcess {
        auth_key,
        child,
        id: request.process,
    })))
}

/// Registers a process that connects from outside lunette. The PID identifies
/// it, and lunette does not own or reap it.
pub(crate) fn add_external_process(
    processes: &mut DenseSlotMap<ProcessHandle, Process>,
    ids: &mut AdoptedIds,
    pid: Pid,
) -> ProcessId {
    let id = ids.next();
    processes.insert(Process::External(ExternalProcess { pid, id }));
    id
}

/// Collects managed output and removes processes that have ended, without
/// blocking the compositor thread. The compositor calls this from a timer, so
/// no reader thread exists per child.
pub(crate) fn poll(
    processes: &mut DenseSlotMap<ProcessHandle, Process>,
    inspector: &dyn ProcessInspector,
) -> Vec<Report> {
    let mut reports = Vec::new();
    let mut to_remove = Vec::new();

    for (handle, process) in processes.iter_mut() {
        match process {
            Process::Managed(p) => {
                for (stream, bytes) in p.child.read_output() {
                    reports.push(Report::Output {
                        id: p.id,
                        stream,
                        bytes,
                    });
                }
                if let Some(outcome) = p.child.poll() {
                    reports.push(Report::Exited { id: p.id, outcome });
                    to_remove.push(handle);
                }
            }
            Process::External(p) => {
                if !p.is_running(inspector) {
                    // `/proc` reports the disappearance but not the exit
                    // status, so this is not reported as an exit.
                    reports.push(Report::Vanished { id: p.id });
                    to_remove.push(handle);
                }
            }
        }
    }

    for handle in to_remove {
        processes.remove(handle);
    }

    reports
}

/// Every tracked process is running: a managed one leaves the table when it is
/// reaped, and an adopted one when its `/proc` entry disappears.
pub(crate) fn snapshot(processes: &DenseSlotMap<ProcessHandle, Process>) -> Vec<ProcessSnapshot> {
    processes
        .values()
        .map(|process| ProcessSnapshot {
            process: process.id(),
            pid: Some(process.pid()),
            external: matches!(process, Process::External(_)),
            alive: true,
        })
        .collect()
}

#[derive(Debug)]
pub(crate) enum Report {
    Output {
        id: ProcessId,
        stream: Stream,
        bytes: Vec<u8>,
    },
    Exited {
        id: ProcessId,
        outcome: ProcessOutcome,
    },
    /// An adopted process is gone. Its exit status is unknowable.
    Vanished { id: ProcessId },
}

/// Allocates adopted-process identifiers from the top of the non-zero `u64`
/// range. The main thread allocates spawned-process identifiers from the
/// bottom before sending the request, so the two allocators use disjoint ends.
#[derive(Debug)]
pub(crate) struct AdoptedIds {
    next: u64,
}

impl Default for AdoptedIds {
    fn default() -> Self {
        Self { next: u64::MAX }
    }
}

impl AdoptedIds {
    fn next(&mut self) -> ProcessId {
        let id = ProcessId::new(self.next).unwrap_or_else(|| {
            unreachable!("the counter starts at the top and only decreases, so it is never zero")
        });
        self.next -= 1;
        id
    }
}
