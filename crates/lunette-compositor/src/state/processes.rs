//! Adapted from WayVR's `backend/wayvr/client.rs` (`accept_connection` and
//! `cleanup_clients`) and the spawn fragment in `backend/wayvr/mod.rs`
//! (https://github.com/wayvr-org/wayvr), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! `attach_client` and `prune_clients` adapt the client-attribution portions of
//! WayVR's `accept_connection` and `cleanup_clients` that remain outside
//! [`crate::client`].

use std::time::Duration;

use smithay::reexports::{
    calloop::timer::{TimeoutAction, Timer},
    wayland_server::{Client, Resource, protocol::wl_surface::WlSurface},
};
use tracing::{debug, info, warn};

use crate::{
    process::{Report, SpawnRequest},
    protocol::{
        Event, OutputId, Pid, ProcessId, ProcessOutcome, ProcessSignal,
        SpawnRequest as SpawnCommand,
    },
    state::{CompositorState, compositor::ClientState},
    thread::LoopData,
};

/// The shared poll checks process output, exits, and the satellite every 100
/// milliseconds. Child output is diagnostic, so polling stays off the frame path.
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(100);

impl CompositorState {
    /// A failed spawn is reported as `ProcessExited` with a spawn-failure
    /// outcome, so the request has a terminal result.
    pub(super) fn spawn_process(&mut self, request: &SpawnCommand) {
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

        match self.processes.spawn(self.spawner.as_mut(), plan) {
            Ok(()) => {
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
    pub(super) fn assign_output(&mut self, process: ProcessId, output: Option<OutputId>) {
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

    pub(super) fn signal_process(&mut self, process: ProcessId, signal: ProcessSignal) {
        self.processes.signal(process, signal);
    }

    /// Matches the connecting PID first, then the authentication token in the
    /// client's environment. A valid but unmatched client is adopted as external.
    pub(crate) fn attach_client(&mut self, client: &Client) {
        let process = match client.get_credentials(&self.display) {
            Ok(credentials) => match Pid::new(credentials.pid) {
                Some(pid) => self.attribute(pid),
                None => {
                    warn!("a client connected with an impossible process id; not attributing it");
                    return;
                }
            },
            Err(error) => {
                warn!(%error, "could not read a connecting client's credentials");
                return;
            }
        };

        // Assign before dispatch: `insert_client` has not dispatched the client's
        // `wl_registry` request, so the first advertisement sees this value.
        if let Some(state) = client.get_data::<ClientState>() {
            state.assign(self.assignments.get(&process).copied());
        }

        self.prune_clients();
        self.clients.insert(client.id(), process);
        self.touch();
        self.watch_processes();
    }

    /// The disconnect callback records only a flag, so the next connection sweeps
    /// disconnected clients. Between connections, the map contains connected
    /// clients plus entries for clients disconnected since the previous sweep.
    pub(super) fn prune_clients(&mut self) {
        let backend = self.display.backend_handle();
        self.clients.retain(|client, _| {
            backend
                .get_client_data(client.clone())
                .ok()
                .and_then(|data| data.downcast_arc::<ClientState>().ok())
                .is_some_and(|data| !data.disconnected())
        });
    }

    pub(super) fn attribute(&mut self, pid: Pid) -> ProcessId {
        if let Some(process) = self.processes.identify(pid, self.inspector.as_ref()) {
            debug!(%pid, %process, "attributed a client to a process lunette started");
            return process;
        }

        let process = self.processes.adopt(pid);
        info!(
            %pid,
            %process,
            "a process lunette did not start connected to its socket; adopting it"
        );
        process
    }

    pub(super) fn process_of(&self, surface: &WlSurface) -> Option<ProcessId> {
        let client = surface.client()?;
        self.clients.get(&client.id()).copied()
    }

    /// One timer polls all process entries and the satellite. Keeping the
    /// registration token in `process_poll` keeps the source alive and prevents
    /// duplicate timers.
    pub(super) fn watch_processes(&mut self) {
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

    pub(super) fn poll_processes(&mut self) -> TimeoutAction {
        self.satellite.poll();

        for report in self.processes.poll(self.inspector.as_ref()) {
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
