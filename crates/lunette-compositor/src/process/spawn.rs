//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/process.rs and backend/wayvr/mod.rs (the spawn and attribution fragments at :1232-1349), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: spawns through `setsid` and `prctl`.
//!
//! Starting a child, reading what it writes, and signalling its process group.

use std::{
    error::Error,
    ffi::OsString,
    fmt, io,
    io::Read,
    os::unix::process::{CommandExt, ExitStatusExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
};

use smithay::reexports::rustix::{
    fs::{OFlags, fcntl_setfl},
    process::{self, Signal},
};
use tracing::{debug, warn};

use crate::protocol::{Argv, Pid, ProcessOutcome, ProcessSignal, SignalNumber, Stream};

/// How much of a child's output is taken in one read.
const OUTPUT_CHUNK: usize = 8192;

/// Starts child processes.
///
/// A seam, because subprocesses are exactly what the house rule says to route
/// through one: the production implementation forks, and a test substitutes a
/// fake and asserts on what would have been started. Nothing above this trait
/// knows which it is talking to.
pub trait ProcessSpawner: Send {
    /// Starts a process, or reports why it could not be started.
    ///
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the program cannot be found or executed. A
    /// mistyped program name is the common case, and it is the only report a
    /// caller gets for one.
    fn spawn(&mut self, plan: &SpawnPlan) -> Result<Box<dyn ChildProcess>, SpawnError>;
}

/// A running child.
///
/// Behind the same seam as the spawner, so a test can end a process, feed it
/// output, and observe the events without a real one existing.
pub trait ChildProcess: Send {
    fn pid(&self) -> Pid;

    /// The outcome, once the child has ended and been reaped. `None` while it
    /// is still running.
    fn poll(&mut self) -> Option<ProcessOutcome>;

    /// Takes whatever the child has written since the last call.
    fn read_output(&mut self) -> Vec<(Stream, Vec<u8>)>;

    /// Signals the child's whole process group.
    fn signal(&mut self, signal: ProcessSignal);
}

/// What to start and what environment to start it in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnPlan {
    pub argv: Argv,
    /// Added to the environment the child inherits, in the order given.
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
}

/// What a spawned client is told about how to reach lunette.
///
/// WayVR builds these strings from `WaylandEnv` (`mod.rs:99-108`) and sets them
/// at `mod.rs:1301-1302`. They arrive here as a value because the socket that
/// produces them is created elsewhere, and because a library assembling an
/// environment from its own process's is exactly the coupling that makes it
/// untestable.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DisplayEnvironment {
    /// What `WAYLAND_DISPLAY` is set to, such as `wayland-20`.
    pub wayland_display: OsString,
    /// What `DISPLAY` is set to, such as `:20`. Meaningful only when
    /// xwayland-satellite is running, and harmless when it is not.
    pub x11_display: OsString,
}

/// The real `fork` and `exec`.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemSpawner;

impl ProcessSpawner for SystemSpawner {
    fn spawn(&mut self, plan: &SpawnPlan) -> Result<Box<dyn ChildProcess>, SpawnError> {
        let mut command = Command::new(plan.argv.program());
        command
            .args(plan.argv.arguments())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        for (key, value) in &plan.env {
            command.env(key, value);
        }
        if let Some(cwd) = &plan.cwd {
            command.current_dir(cwd);
        }

        // SAFETY: `pre_exec` runs between `fork` and `exec`, in a child that
        // may hold locks the parent's other threads were holding, so only
        // async-signal-safe calls are permitted. Both of these are single
        // syscalls through rustix and allocate nothing.
        unsafe {
            command.pre_exec(|| {
                // A session of its own, so the child and everything it starts
                // share a process group lunette can signal as a unit. WayVR
                // signals only the direct child, so a shell wrapper's
                // grandchildren outlive it.
                process::setsid().map_err(io::Error::from)?;

                // A backstop for lunette dying without running its own
                // teardown. It fires on the death of the thread that forked,
                // which is the compositor thread, and that thread outliving
                // the process is not a case that exists.
                process::set_parent_process_death_signal(Some(Signal::TERM))
                    .map_err(io::Error::from)?;

                Ok(())
            });
        }

        let child = command.spawn().map_err(|cause| SpawnError {
            program: plan.argv.program().to_owned(),
            cause,
        })?;

        // Non-blocking, because the reads happen on the compositor thread and a
        // child that writes nothing must not stall it.
        for pipe in [
            child.stdout.as_ref().map(|out| out.as_raw()),
            child.stderr.as_ref().map(|err| err.as_raw()),
        ]
        .into_iter()
        .flatten()
        {
            if let Err(error) = fcntl_setfl(pipe, OFlags::NONBLOCK) {
                warn!(%error, "could not make a child's output pipe non-blocking");
            }
        }

        let pid = Pid::new(i32::try_from(child.id()).unwrap_or(0)).ok_or_else(|| SpawnError {
            program: plan.argv.program().to_owned(),
            cause: io::Error::other("the child reported an impossible process id"),
        })?;

        Ok(Box::new(SystemChild { pid, child }))
    }
}

/// Borrows a pipe's descriptor without taking it from the child.
trait AsRawPipe {
    fn as_raw(&self) -> std::os::fd::BorrowedFd<'_>;
}

impl<T: std::os::fd::AsFd> AsRawPipe for T {
    fn as_raw(&self) -> std::os::fd::BorrowedFd<'_> {
        self.as_fd()
    }
}

struct SystemChild {
    pid: Pid,
    child: Child,
}

impl ChildProcess for SystemChild {
    fn pid(&self) -> Pid {
        self.pid
    }

    fn poll(&mut self) -> Option<ProcessOutcome> {
        match self.child.try_wait() {
            Ok(Some(status)) => Some(match (status.code(), status.signal()) {
                (Some(code), _) => ProcessOutcome::Exited { code },
                (None, Some(signal)) => ProcessOutcome::Signalled {
                    signal: SignalNumber::new(signal),
                },
                // `wait` reported neither, which the interface permits and the
                // kernel does not produce. Naming it as an exit of unknown
                // cause beats inventing a signal number.
                (None, None) => ProcessOutcome::Exited { code: -1 },
            }),
            Ok(None) => None,
            Err(error) => {
                warn!(pid = %self.pid, %error, "could not check whether a child had exited");
                None
            }
        }
    }

    fn read_output(&mut self) -> Vec<(Stream, Vec<u8>)> {
        let mut chunks = Vec::new();

        if let Some(stdout) = self.child.stdout.as_mut()
            && let Some(bytes) = read_available(stdout)
        {
            chunks.push((Stream::Stdout, bytes));
        }
        if let Some(stderr) = self.child.stderr.as_mut()
            && let Some(bytes) = read_available(stderr)
        {
            chunks.push((Stream::Stderr, bytes));
        }

        chunks
    }

    fn signal(&mut self, signal: ProcessSignal) {
        if let Err(error) = signal_group(self.pid, signal) {
            warn!(pid = %self.pid, %error, "could not signal a child's process group");
        }
    }
}

impl Drop for SystemChild {
    /// Asks the child's whole group to stop.
    ///
    /// WayVR sends `SIGTERM` to the direct child here (`process.rs:88-97`). A
    /// group is the correct unit: the direct child of a wrapper script is the
    /// script, and killing it leaves the application running with no window.
    fn drop(&mut self) {
        debug!(pid = %self.pid, "asking a process group to stop");
        if let Err(error) = signal_group(self.pid, ProcessSignal::Terminate) {
            debug!(pid = %self.pid, %error, "the process group was already gone");
        }
    }
}

/// Why a process could not be started.
#[derive(Debug)]
pub struct SpawnError {
    program: OsString,
    cause: io::Error,
}

impl SpawnError {
    /// The message reported through `ProcessOutcome::SpawnFailed`.
    #[must_use]
    pub fn message(&self) -> String {
        self.to_string()
    }

    /// Builds an error a fake spawner can report.
    #[cfg(any(test, feature = "test-fakes"))]
    #[must_use]
    pub fn for_test(program: OsString, cause: io::Error) -> Self {
        Self { program, cause }
    }
}

impl fmt::Display for SpawnError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "spawn: could not start {}: {}",
            Path::new(&self.program).display(),
            self.cause
        )
    }
}

impl Error for SpawnError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.cause)
    }
}

/// Signals a process group, which is the process itself and everything it
/// started under the session `setsid` gave it.
pub(crate) fn signal_group(pid: Pid, signal: ProcessSignal) -> io::Result<()> {
    let signal = match signal {
        ProcessSignal::Hangup => Signal::HUP,
        ProcessSignal::Interrupt => Signal::INT,
        ProcessSignal::Terminate => Signal::TERM,
        ProcessSignal::Kill => Signal::KILL,
    };
    let pid = process::Pid::from_raw(pid.get())
        .ok_or_else(|| io::Error::other("a process id of zero addresses the caller's own group"))?;

    process::kill_process_group(pid, signal).map_err(io::Error::from)
}

/// Reads whatever is available on a non-blocking pipe.
fn read_available(pipe: &mut impl Read) -> Option<Vec<u8>> {
    let mut buffer = vec![0_u8; OUTPUT_CHUNK];
    match pipe.read(&mut buffer) {
        Ok(0) => None,
        Ok(read) => {
            buffer.truncate(read);
            Some(buffer)
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => None,
        Err(error) => {
            debug!(%error, "could not read a child's output");
            None
        }
    }
}
