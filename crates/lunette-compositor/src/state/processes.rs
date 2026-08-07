//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/client.rs (`accept_connection` and `cleanup_clients`) and backend/wayvr/mod.rs (the spawn fragment), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The processes lunette starts, and which client belongs to which.
//!
//! Two halves of one question. Spawning is a `ProcessSpawner` call and a timer
//! that reaps; attribution is the credentials of a connecting client matched
//! against the processes that are still unclaimed. They live together because
//! neither is useful without the other: a spawn nobody can attribute a client
//! to is a process lunette has lost track of, and an attribution with nothing
//! to attribute to is an adopted client.
//!
//! Split out of `compositor.rs` as a self-contained concern, and the header
//! travels with it: `attach_client` and `prune_clients` are the halves of
//! WayVR's `accept_connection` and `cleanup_clients` that did not go to
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

/// How often spawned processes are checked for output and for having exited.
///
/// A tenth of a second. Output from a spawned application is diagnostic, so the
/// latency does not matter; the interval is short enough that a process that
/// exits is reported within a frame or two of it happening.
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(100);

impl CompositorState {
    /// Starts a process and attributes the clients it connects with.
    ///
    /// A spawn that fails is reported as an exit that never happened, because
    /// that is the one report a caller of `lunette.spawn` gets for a mistyped
    /// program name and there is nothing else to hang it on.
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

    /// Records which output a spawned process's clients will be shown.
    ///
    /// An output that does not exist is refused rather than recorded: a client
    /// assigned one would see no monitor at all, which is a harder failure to
    /// diagnose than a warning naming the output. Falling back to the default
    /// is what an absent assignment already means.
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

    /// Attributes a newly connected client to a process.
    ///
    /// The connecting pid first, then the token in the client's own
    /// environment, and failing both the client is adopted as external — which
    /// is the case a process started outside lunette with `WAYLAND_DISPLAY`
    /// pointing at its socket falls into.
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

        // Before any request from this client has been dispatched, because
        // `insert_client` does not dispatch: the client's `wl_registry` has not
        // been read yet, so the first advertisement sees the assignment.
        if let Some(state) = client.get_data::<ClientState>() {
            state.assign(self.assignments.get(&process).copied());
        }

        self.prune_clients();
        self.clients.insert(client.id(), process);
        self.touch();
        self.watch_processes();
    }

    /// Forgets clients that have gone away.
    ///
    /// There is no per-client destruction hook to hang this on:
    /// `ClientData::disconnected` is called on an `Arc` that knows nothing
    /// about the compositor, and `CompositorHandler` only reports surfaces. So
    /// the map is swept when a new client arrives, which bounds it at the
    /// number of clients that have connected since the last connection rather
    /// than at the number that have ever connected.
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

    /// The process a client was attributed to.
    pub(super) fn process_of(&self, surface: &WlSurface) -> Option<ProcessId> {
        let client = surface.client()?;
        self.clients.get(&client.id()).copied()
    }

    /// Starts the poll timer if it is not already running.
    ///
    /// One timer for every process rather than a source per pipe and a reaper
    /// besides: a child's output is diagnostic, so a fraction of a second of
    /// latency costs nothing, and a source registered per child would have to
    /// be unregistered from inside its own callback.
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

    /// Collects output and exits, and decides whether to keep watching.
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
            // Nothing left to reap. The timer is dropped rather than left to
            // wake an otherwise idle compositor ten times a second.
            self.process_poll = None;
            return TimeoutAction::Drop;
        }

        TimeoutAction::ToDuration(PROCESS_POLL_INTERVAL)
    }
}
