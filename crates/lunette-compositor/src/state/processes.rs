//! Adapted from WayVR's `backend/wayvr/client.rs` (`WayVRClient`,
//! `accept_connection`, `add_client`, and `cleanup_clients`) at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Attributes connecting clients to processes, and runs the process commands
//! and the timer that polls process output and exits.
//!
//! lunette matches the connecting PID before the token, adopts an unmatched
//! client at once rather than through a task, and records the attributed
//! process on each client, so a window is attributed without reading the
//! client's environment again. A client's output assignment is set before its
//! first dispatch.

use std::{io, os::unix::net::UnixStream, sync::Arc, time::Duration};

use smithay::reexports::{
    calloop::timer::{TimeoutAction, Timer},
    wayland_server::{Client, Resource, protocol::wl_surface::WlSurface},
};
use tracing::{debug, info, warn};

use crate::{
    protocol::{
        Event, OutputId, Pid, ProcessId, ProcessOutcome, ProcessSignal,
        SpawnRequest as SpawnCommand,
    },
    spawn::{self, Report, SpawnRequest},
    state::{CompositorState, compositor::ClientState},
    thread::LoopData,
    wayvr::process::find_by_pid,
};

pub(crate) struct WayVRClient {
    pub client: Client,
    pub process: ProcessId,
}

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

    /// An adopted process stays signalable until a poll observes its `/proc`
    /// entry disappear.
    pub(super) fn signal_process(&mut self, process: ProcessId, signal: ProcessSignal) {
        match self.processes.values_mut().find(|p| p.id() == process) {
            Some(p) => p.kill(signal),
            None => debug!(%process, "a signal was asked for a process that is already gone"),
        }
    }

    /// Inserts a client and attributes it to a process. The connecting PID is
    /// matched first, then the authentication token in the client's
    /// environment, and a client that matches neither is adopted as external.
    ///
    /// Attribution runs before the client's initial `wl_registry` dispatch, so
    /// its first advertisement sees the output assigned to its process.
    ///
    /// # Errors
    ///
    /// Returns the I/O error when the display cannot insert the client.
    pub(crate) fn accept_connection(&mut self, stream: UnixStream) -> io::Result<Client> {
        let client = self
            .display
            .insert_client(stream, Arc::new(ClientState::default()))?;

        let credentials = match client.get_credentials(&self.display) {
            Ok(credentials) => credentials,
            Err(error) => {
                warn!(%error, "could not read a connecting client's credentials");
                return Ok(client);
            }
        };
        let Some(pid) = Pid::new(credentials.pid) else {
            warn!("a client connected with an impossible process id; not attributing it");
            return Ok(client);
        };

        let found = find_by_pid(&self.processes, pid, self.inspector.as_ref())
            .and_then(|handle| self.processes.get(handle));
        let process = if let Some(process) = found {
            debug!(%pid, process = %process.id(), "attributed a client to a known process");
            process.id()
        } else {
            // This is a new process which we didn't meet before.
            let process =
                spawn::add_external_process(&mut self.processes, &mut self.adopted_ids, pid);
            info!(
                %pid,
                %process,
                "a process lunette did not start connected to its socket; adopting it"
            );
            process
        };

        if let Some(state) = client.get_data::<ClientState>() {
            state.assign(self.assignments.get(&process).copied());
        }

        self.cleanup_clients();
        self.add_client(WayVRClient {
            client: client.clone(),
            process,
        });
        self.touch();
        self.watch_processes();
        Ok(client)
    }

    pub(super) fn add_client(&mut self, client: WayVRClient) {
        self.clients.push(client);
    }

    /// The disconnect callback records only a flag, so each new connection
    /// sweeps the clients disconnected since the previous one.
    pub(super) fn cleanup_clients(&mut self) {
        self.clients.retain(|client| {
            let Some(data) = client.client.get_data::<ClientState>() else {
                return false;
            };

            if data.disconnected() {
                return false;
            }

            true
        });
    }

    pub(super) fn process_of(&self, surface: &WlSurface) -> Option<ProcessId> {
        let client = surface.client()?;
        self.clients
            .iter()
            .find(|candidate| candidate.client.id() == client.id())
            .map(|candidate| candidate.process)
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
