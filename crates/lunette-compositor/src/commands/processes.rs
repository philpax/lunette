//! Runs the process commands and the timer that polls process output and
//! exits.
//!
//! Connecting clients are attributed to processes by `accept_connection` in
//! `src/wayvr/client.rs`.

use std::time::Duration;

use smithay::reexports::{
    calloop::timer::{TimeoutAction, Timer},
    wayland_server::{Resource, protocol::wl_surface::WlSurface},
};
use tracing::{debug, warn};

use crate::{
    protocol::{
        Event, OutputId, ProcessId, ProcessOutcome, ProcessSignal, SpawnRequest as SpawnCommand,
    },
    spawn::{self, Report, SpawnRequest},
    thread::LoopData,
    wayvr::comp::Application,
};

/// The shared poll checks process output, exits, and the satellite every 100
/// milliseconds. Child output is diagnostic, so polling stays off the frame path.
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(100);

impl Application {
    /// A failed spawn is reported as `ProcessExited` with a spawn-failure
    /// outcome, so the request has a terminal result.
    pub(crate) fn spawn_process(&mut self, request: &SpawnCommand) {
        let plan = SpawnRequest {
            process: request.process,
            argv: &request.argv,
            env: &request.env,
            cwd: request.cwd.as_deref(),
            display: &self.environment,
        };

        if request.xwayland {
            debug!(
                process = %request.process,
                "an X11 client still reaches lunette through xwayland-satellite's own socket"
            );
        }

        match spawn::spawn_process(&mut self.processes, self.spawner.as_mut(), plan) {
            Ok(_) => {
                self.assign_output(request.process, request.output);
                self.touch();
                self.watch_processes();
            }
            Err(error) => {
                warn!(%error, "could not start a process");
                self.report(Event::ProcessExited {
                    process: request.process,
                    outcome: ProcessOutcome::SpawnFailed {
                        message: error.message(),
                    },
                });
            }
        }
    }

    /// An absent or unknown output leaves the process unassigned, so its clients
    /// see the default output.
    pub(crate) fn assign_output(&mut self, process: ProcessId, output: Option<OutputId>) {
        let Some(output) = output else {
            return;
        };
        if self.outputs.get(output).is_none() {
            warn!(
                %process,
                %output,
                "a spawn named an output that does not exist; showing the default output instead"
            );
            return;
        }
        self.assignments.insert(process, output);
    }

    /// An adopted process stays signalable until a poll observes its `/proc`
    /// entry disappear.
    pub(crate) fn signal_process(&mut self, process: ProcessId, signal: ProcessSignal) {
        match self.processes.values_mut().find(|p| p.id() == process) {
            Some(p) => p.kill(signal),
            None => debug!(%process, "a signal was asked for a process that is already gone"),
        }
    }

    pub(crate) fn process_of(&self, surface: &WlSurface) -> Option<ProcessId> {
        let client = surface.client()?;
        self.clients
            .iter()
            .find(|candidate| candidate.client.id() == client.id())
            .map(|candidate| candidate.process)
    }

    /// One timer polls all process entries and the satellite. Keeping the
    /// registration token in `process_poll` keeps the source alive and prevents
    /// duplicate timers.
    pub(crate) fn watch_processes(&mut self) {
        if self.process_poll.is_some() {
            return;
        }

        let inserted = self.loop_handle.insert_source(
            Timer::from_duration(PROCESS_POLL_INTERVAL),
            |_now, _metadata, data: &mut LoopData| data.state.poll_processes(),
        );

        match inserted {
            Ok(token) => self.process_poll = Some(token),
            Err(error) => warn!(
                error = %error.error,
                "could not watch spawned processes; their output and exits will not be reported"
            ),
        }
    }

    pub(crate) fn poll_processes(&mut self) -> TimeoutAction {
        self.satellite.poll();

        for report in spawn::poll(&mut self.processes, self.inspector.as_ref()) {
            match report {
                Report::Output { id, stream, bytes } => self.report(Event::ProcessOutput {
                    process: id,
                    stream,
                    bytes,
                }),
                Report::Exited { id, outcome } => {
                    self.assignments.remove(&id);
                    self.touch();
                    self.report(Event::ProcessExited {
                        process: id,
                        outcome,
                    });
                }
                // Lua never holds an adopted process's handle, and its status is unknowable.
                Report::Vanished { id } => {
                    debug!(process = %id, "an adopted process is gone");
                    self.assignments.remove(&id);
                    self.touch();
                }
            }
        }

        if self.processes.is_empty() && !self.satellite.is_running() {
            // Drop the token to remove the idle source; later work can install a new timer.
            self.process_poll = None;
            return TimeoutAction::Drop;
        }

        TimeoutAction::ToDuration(PROCESS_POLL_INTERVAL)
    }
}
