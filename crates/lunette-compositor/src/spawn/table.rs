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
//! table, so they can be tested without a compositor. lunette's accessors on
//! upstream's `Process` are here too.

use std::{error::Error, fmt, io};

use slotmap::DenseSlotMap;
use tracing::debug;

use crate::{
    protocol::{
        ADOPTED_PROCESS_ID_MIN, PROCESS_ID_MAX, Pid, ProcessId, ProcessObservation, ProcessOutcome,
        ProcessSnapshot, Stream,
    },
    spawn::{
        inspect::{ProcessInspector, ProcessRecord},
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
    inspector: &dyn ProcessInspector,
    request: SpawnRequest<'_>,
) -> Result<ProcessHandle, SpawnError> {
    if request.process.get() >= ADOPTED_PROCESS_ID_MIN {
        return Err(SpawnError::refused(
            request.argv.program().to_owned(),
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "process identifier is outside the managed range",
            ),
        ));
    }
    let auth_key = AuthToken::generate(request.argv.program())?;
    let plan = build_plan(&request, &auth_key);

    let child = spawner.spawn(&plan)?;
    debug!(process = %request.process, pid = %child.pid(), "started a process");

    let record = ProcessRecord::capture(child.pid(), inspector);
    Ok(processes.insert(Process::Managed(WayVRProcess {
        record,
        auth_key,
        child,
        id: request.process,
    })))
}

/// Registers a process that connects from outside lunette. Identity is captured
/// at registration; lunette does not own or reap it.
pub(crate) fn add_external_process(
    processes: &mut DenseSlotMap<ProcessHandle, Process>,
    ids: &mut AdoptedIds,
    pid: Pid,
    inspector: &dyn ProcessInspector,
) -> Result<ProcessId, AdoptedIdsExhausted> {
    let id = ids.next()?;
    let record = ProcessRecord::capture(pid, inspector);
    processes.insert(Process::External(ExternalProcess { pid, id, record }));
    Ok(id)
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
        let pid = process.pid();
        if process.record_mut().refresh(pid, inspector) {
            reports.push(Report::ObservationChanged {
                id: process.id(),
                observation: process.record().observation,
            });
        }
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
                if p.record.observation == ProcessObservation::Ended {
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

/// Handle liveness follows ownership, not inspectability. Managed entries leave
/// when reaped; adopted entries leave when their captured instance ends.
pub(crate) fn snapshot(processes: &DenseSlotMap<ProcessHandle, Process>) -> Vec<ProcessSnapshot> {
    processes
        .values()
        .map(|process| ProcessSnapshot {
            process: process.id(),
            pid: Some(process.pid()),
            instance: process.record().instance,
            observation: process.record().observation,
            external: matches!(process, Process::External(_)),
            alive: true,
        })
        .collect()
}

#[derive(Debug)]
pub(crate) enum Report {
    ObservationChanged {
        id: ProcessId,
        observation: ProcessObservation,
    },
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

/// Allocates adopted-process identifiers downwards within the exact Luau integer range.
/// Managed identifiers stay below the adopted range, so neither allocator can overlap the other.
#[derive(Debug)]
pub(crate) struct AdoptedIds {
    next: u64,
}

impl Default for AdoptedIds {
    fn default() -> Self {
        Self {
            next: PROCESS_ID_MAX,
        }
    }
}

impl AdoptedIds {
    fn next(&mut self) -> Result<ProcessId, AdoptedIdsExhausted> {
        if !(ADOPTED_PROCESS_ID_MIN..=PROCESS_ID_MAX).contains(&self.next) {
            return Err(AdoptedIdsExhausted);
        }
        let id = ProcessId::new(self.next).ok_or(AdoptedIdsExhausted)?;
        self.next -= 1;
        Ok(id)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AdoptedIdsExhausted;

impl fmt::Display for AdoptedIdsExhausted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("compositor: the adopted process identifier space is exhausted")
    }
}

impl Error for AdoptedIdsExhausted {}

impl Process {
    pub(crate) fn record(&self) -> &ProcessRecord {
        match self {
            Self::Managed(p) => &p.record,
            Self::External(p) => &p.record,
        }
    }

    fn record_mut(&mut self) -> &mut ProcessRecord {
        match self {
            Self::Managed(p) => &mut p.record,
            Self::External(p) => &mut p.record,
        }
    }

    /// The identifier Lua sees for the process.
    pub(crate) fn id(&self) -> ProcessId {
        match self {
            Self::Managed(p) => p.id,
            Self::External(p) => p.id,
        }
    }

    /// The pid of a managed child or an adopted process.
    pub(crate) fn pid(&self) -> Pid {
        match self {
            Self::Managed(p) => p.child.pid(),
            Self::External(p) => p.pid,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::FakeInspector;

    #[test]
    fn adopted_ids_start_at_the_largest_exact_lua_integer() {
        let mut ids = AdoptedIds::default();
        let first = ids.next().expect("first adopted id");
        let second = ids.next().expect("second adopted id");
        assert_eq!(first.get(), (1_u64 << 53) - 1);
        assert_eq!(second.get(), (1_u64 << 53) - 2);
    }

    #[test]
    fn adopted_ids_reach_their_lower_bound_without_overlapping_managed_ids() {
        let mut ids = AdoptedIds {
            next: (1_u64 << 52) + 1,
        };
        assert_eq!(
            ids.next().expect("penultimate adopted id").get(),
            (1_u64 << 52) + 1
        );
        assert_eq!(ids.next().expect("last adopted id").get(), 1_u64 << 52);
        for _ in 0..2 {
            assert_eq!(
                ids.next(),
                Err(AdoptedIdsExhausted),
                "exhaustion must not allocate a managed id"
            );
            assert_eq!(ids.next, (1_u64 << 52) - 1);
        }
    }

    #[test]
    fn adopted_exhaustion_and_invalid_counters_never_register_a_process() {
        for invalid in [0, (1_u64 << 52) - 1, 1_u64 << 53, u64::MAX] {
            let mut processes = DenseSlotMap::with_key();
            let mut ids = AdoptedIds { next: invalid };
            for _ in 0..2 {
                assert_eq!(
                    add_external_process(
                        &mut processes,
                        &mut ids,
                        Pid::new(4242).expect("positive pid"),
                        &FakeInspector::default(),
                    ),
                    Err(AdoptedIdsExhausted)
                );
                assert!(snapshot(&processes).is_empty());
                assert_eq!(ids.next, invalid);
            }
        }
    }

    #[test]
    fn the_table_only_registers_exact_numeric_ids() {
        let mut processes = DenseSlotMap::with_key();
        let id = add_external_process(
            &mut processes,
            &mut AdoptedIds::default(),
            Pid::new(4242).expect("positive pid"),
            &FakeInspector::default(),
        )
        .expect("adopted identifier available");
        assert_eq!(id.get(), (1_u64 << 53) - 1);
        assert_eq!(snapshot(&processes)[0].process, id);
    }
}
