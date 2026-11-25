//! Launches Windows applications and publishes the lifetime of launched and selected processes.

use std::{
    collections::BTreeMap,
    io, mem,
    process::{Child, Command},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    thread,
};

use lunette_capture::{
    audio::WindowsAudioTargets,
    windows::{WindowId, WindowsProcess, configure_child, read_child_pipe},
};
use lunette_compositor::protocol::{
    ADOPTED_PROCESS_ID_MIN, Event, Pid, ProcessId, ProcessObservation, ProcessObservationFailure,
    ProcessOutcome, ProcessSnapshot, SpawnRequest, Stream,
};
use tracing::{debug, warn};

#[derive(Debug)]
pub(super) struct WindowsPrograms {
    entries: BTreeMap<ProcessId, Entry>,
    audio_targets: WindowsAudioTargets,
    launcher: Option<Launcher>,
    next_adopted: u64,
    dirty: bool,
    events: Vec<Event>,
}

#[derive(Debug)]
struct Entry {
    process: Option<Arc<WindowsProcess>>,
    child: Option<Child>,
    snapshot: ProcessSnapshot,
}

#[derive(Debug)]
struct Launcher {
    requests: SyncSender<SpawnRequest>,
    completed: Receiver<Launch>,
    active: Arc<AtomicBool>,
}

struct Launch {
    process: ProcessId,
    outcome: io::Result<Child>,
}

impl WindowsPrograms {
    pub(super) fn new(audio_targets: WindowsAudioTargets) -> Self {
        let launcher = match Launcher::start() {
            Ok(launcher) => Some(launcher),
            Err(error) => {
                warn!(%error, "Windows application launcher could not start");
                None
            }
        };
        Self {
            entries: BTreeMap::new(),
            audio_targets,
            launcher,
            next_adopted: ADOPTED_PROCESS_ID_MIN,
            dirty: false,
            events: Vec::new(),
        }
    }

    pub(super) fn spawn(&mut self, request: SpawnRequest) {
        let process = request.process;
        let refusal = if request.xwayland {
            "Xwayland is available only for Linux sessions"
        } else if let Some(launcher) = &self.launcher {
            match launcher.requests.try_send(request) {
                Ok(()) => return,
                Err(TrySendError::Full(_)) => "the Windows application launcher is busy",
                Err(TrySendError::Disconnected(_)) => "the Windows application launcher stopped",
            }
        } else {
            "the Windows application launcher is unavailable"
        };
        self.events.push(spawn_failed(process, refusal));
    }

    pub(super) fn adopt(&mut self, window: WindowId) -> Option<ProcessId> {
        let examined = window.process().ok()?;
        if examined.exit_code().ok()?.is_some() {
            return None;
        }
        if let Some((&id, _)) = self
            .entries
            .iter()
            .find(|(_, entry)| entry.snapshot.instance == Some(examined.instance()))
        {
            return Some(id);
        }
        let next = self
            .next_adopted
            .checked_add(1)
            .filter(|id| *id < (1 << 53))?;
        let id = ProcessId::new(self.next_adopted)?;
        self.next_adopted = next;
        self.register(id, Some(examined), None);
        Some(id)
    }

    fn register(&mut self, id: ProcessId, process: Option<WindowsProcess>, child: Option<Child>) {
        let instance = process.as_ref().map(WindowsProcess::instance);
        let pid = instance.map(|identity| identity.pid()).or_else(|| {
            child
                .as_ref()
                .and_then(|child| i32::try_from(child.id()).ok().and_then(Pid::new))
        });
        let observation = instance.map_or(
            ProcessObservation::Unavailable(ProcessObservationFailure::Other),
            |instance| ProcessObservation::Live {
                instance,
                parent: None,
            },
        );
        let process = process.map(Arc::new);
        if let Some(process) = &process {
            self.audio_targets.register(id, Arc::clone(process));
        }
        let entry = Entry {
            process,
            snapshot: ProcessSnapshot {
                process: id,
                pid,
                instance,
                observation,
                external: child.is_none(),
                alive: true,
            },
            child,
        };
        self.entries.insert(id, entry);
        self.dirty = true;
    }

    pub(super) fn poll(&mut self) {
        let finished: Vec<_> = self
            .launcher
            .as_ref()
            .map_or_else(Vec::new, |launcher| launcher.completed.try_iter().collect());
        for launch in finished {
            match launch.outcome {
                Ok(child) => {
                    let observed = WindowsProcess::from_child(&child)
                        .inspect_err(
                            |error| debug!(%error, "Windows process identity is unavailable"),
                        )
                        .ok();
                    self.register(launch.process, observed, Some(child));
                }
                Err(error) => self
                    .events
                    .push(spawn_failed(launch.process, error.to_string())),
            }
        }

        self.entries.retain(|&id, entry| {
            let mut exit = None;
            if let Some(child) = &mut entry.child {
                match child.try_wait() {
                    Ok(Some(status)) => exit = status.code(),
                    Ok(None) => {}
                    Err(error) => {
                        debug!(%error, process = %id, "Windows child exit could not be queried")
                    }
                }
                let limit = if exit.is_some() { 16 } else { 1 };
                if let Some(stdout) = &mut child.stdout {
                    read_output(&mut self.events, id, Stream::Stdout, stdout, limit);
                }
                if let Some(stderr) = &mut child.stderr {
                    read_output(&mut self.events, id, Stream::Stderr, stderr, limit);
                }
            } else if let Some(process) = &entry.process {
                exit = process.exit_code().ok().flatten();
            }
            if let Some(code) = exit {
                self.audio_targets.remove(id);
                self.events.push(Event::ProcessExited {
                    process: id,
                    outcome: ProcessOutcome::Exited { code },
                });
                self.dirty = true;
                false
            } else {
                true
            }
        });
    }

    pub(super) fn take_snapshot(&mut self) -> Option<Vec<ProcessSnapshot>> {
        mem::take(&mut self.dirty).then(|| {
            self.entries
                .values()
                .map(|entry| entry.snapshot.clone())
                .collect()
        })
    }

    pub(super) fn take_events(&mut self) -> Vec<Event> {
        mem::take(&mut self.events)
    }
}

impl Launcher {
    fn start() -> io::Result<Self> {
        let (requests, pending) = mpsc::sync_channel::<SpawnRequest>(32);
        let (complete, completed) = mpsc::sync_channel(32);
        let active = Arc::new(AtomicBool::new(true));
        let worker_active = Arc::clone(&active);
        thread::Builder::new()
            .name("lunette-win-launcher".into())
            .spawn(move || {
                while let Ok(request) = pending.recv() {
                    if !worker_active.load(Ordering::Acquire) {
                        break;
                    }
                    let mut command = Command::new(request.argv.program());
                    command.args(request.argv.arguments()).envs(request.env);
                    if let Some(directory) = request.cwd {
                        command.current_dir(directory);
                    }
                    configure_child(&mut command);
                    if complete
                        .send(Launch {
                            process: request.process,
                            outcome: command.spawn(),
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            })?;
        Ok(Self {
            requests,
            completed,
            active,
        })
    }
}

impl Drop for Launcher {
    fn drop(&mut self) {
        self.active.store(false, Ordering::Release);
    }
}

fn spawn_failed(process: ProcessId, message: impl Into<String>) -> Event {
    Event::ProcessExited {
        process,
        outcome: ProcessOutcome::SpawnFailed {
            message: message.into(),
        },
    }
}

fn read_output(
    events: &mut Vec<Event>,
    process: ProcessId,
    stream: Stream,
    pipe: &mut (impl io::Read + std::os::windows::io::AsHandle),
    limit: usize,
) {
    let mut bytes = [0; 4096];
    for _ in 0..limit {
        match read_child_pipe(pipe, &mut bytes) {
            Ok(0) => return,
            Ok(read) => events.push(Event::ProcessOutput {
                process,
                stream,
                bytes: bytes[..read].to_vec(),
            }),
            Err(error) => {
                debug!(%error, %process, "Windows child output could not be read");
                return;
            }
        }
    }
}
