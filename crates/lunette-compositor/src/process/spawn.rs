//! Adapted from the spawn and attribution fragments in WayVR
//! (https://github.com/wayvr-org/wayvr), in backend/wayvr/process.rs and
//! backend/wayvr/mod.rs, at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: creates process groups with `setsid`, sets parent-death signalling with
//! `prctl`, and configures non-blocking output pipes with `fcntl`.

use std::{
    error::Error,
    ffi::OsString,
    fmt, io,
    io::Read,
    os::unix::process::{CommandExt, ExitStatusExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use smithay::reexports::rustix::{
    fs::{OFlags, fcntl_setfl},
    process::{self, Signal},
};
use tracing::{debug, warn};

use crate::protocol::{Argv, Pid, ProcessOutcome, ProcessSignal, SignalNumber, Stream};

/// Bounds each non-blocking output read to limit compositor work.
/// Unread output remains in the pipe, so continued child output
/// eventually applies backpressure.
const OUTPUT_CHUNK: usize = 8192;

/// Grace period before escalating from `SIGTERM` to `SIGKILL`.
const TERMINATE_GRACE: Duration = Duration::from_millis(200);

/// Interval between non-blocking waits during the termination grace period.
const REAP_POLL: Duration = Duration::from_millis(5);

/// Abstracts process creation so tests can record spawn plans
/// without starting a real process.
pub trait ProcessSpawner: Send {
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the request cannot be started.
    fn spawn(&mut self, plan: &SpawnPlan) -> Result<Box<dyn ChildProcess>, SpawnError>;
}

/// Abstracts a spawned child so tests can control its lifetime
/// and output without starting a real process.
pub trait ChildProcess: Send {
    fn pid(&self) -> Pid;

    /// Returns one terminal outcome after the child has ended and been reaped.
    /// Returns `None` while the child runs and after the terminal outcome
    /// has been returned.
    fn poll(&mut self) -> Option<ProcessOutcome>;

    /// Returns and clears output accumulated since the previous call.
    fn read_output(&mut self) -> Vec<(Stream, Vec<u8>)>;

    /// Signals the child's process group. Implementations must ignore calls after
    /// [`ChildProcess::poll`] returns an outcome. Reaping releases
    /// the process-group identifier for reuse.
    fn signal(&mut self, signal: ProcessSignal);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnPlan {
    pub argv: Argv,
    /// Applied to the inherited environment in order; later pairs
    /// with the same name override earlier pairs.
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
}

/// Display names passed to spawned clients through their environment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DisplayEnvironment {
    /// Value exported as `WAYLAND_DISPLAY`.
    pub wayland_display: OsString,
    /// Value exported as `DISPLAY`.
    pub x11_display: OsString,
}

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

        // SAFETY: `pre_exec` runs after `fork` and before `exec`,
        // when the child may hold locks copied from other threads.
        // The closure calls no other functions. The rustix syscalls below
        // are async-signal-safe and do not allocate.
        unsafe {
            command.pre_exec(|| {
                // Create the process group containing the child and its descendants,
                // so lunette can signal them as one unit.
                process::setsid().map_err(io::Error::from)?;

                // Request SIGTERM from Linux when the parent process dies
                // before the normal child teardown runs.
                process::set_parent_process_death_signal(Some(Signal::TERM))
                    .map_err(io::Error::from)?;

                Ok(())
            });
        }

        let child = command.spawn().map_err(|cause| SpawnError {
            program: plan.argv.program().to_owned(),
            cause,
        })?;

        // The compositor thread polls these pipes, so a blocking descriptor
        // could stall process polling. Failure is logged; the spawn still succeeds.
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

        Ok(Box::new(SystemChild {
            pid,
            child,
            liveness: Liveness::Running,
        }))
    }
}

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
    liveness: Liveness,
}

impl ChildProcess for SystemChild {
    fn pid(&self) -> Pid {
        self.pid
    }

    fn poll(&mut self) -> Option<ProcessOutcome> {
        if self.liveness == Liveness::Reaped {
            return None;
        }

        match self.child.try_wait() {
            Ok(Some(status)) => Some({
                self.liveness = Liveness::Reaped;
                match (status.code(), status.signal()) {
                    (Some(code), _) => ProcessOutcome::Exited { code },
                    (None, Some(signal)) => ProcessOutcome::Signalled {
                        signal: SignalNumber::new(signal),
                    },
                    // The status can contain neither an exit code nor a signal.
                    // The outcome mapping is total; the fallback counts
                    // as an exit with code -1.
                    (None, None) => ProcessOutcome::Exited { code: -1 },
                }
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
        if !self.liveness.may_signal() {
            debug!(pid = %self.pid, "not signalling a child that has already been reaped");
            return;
        }
        if let Err(error) = signal_group(self.pid, signal) {
            warn!(pid = %self.pid, %error, "could not signal a child's process group");
        }
    }
}

impl SystemChild {
    /// Reaps a stopping child, allowing `TERMINATE_GRACE` for `SIGTERM`
    /// before sending `SIGKILL` to its process group. The final wait
    /// reaps the child after the escalation and does not leave a zombie.
    fn reap(&mut self) {
        let deadline = Instant::now() + TERMINATE_GRACE;
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => {
                    self.liveness = Liveness::Reaped;
                    return;
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(pid = %self.pid, %error, "could not wait for a stopping child");
                    return;
                }
            }
            if Instant::now() >= deadline {
                break;
            }
            thread::sleep(REAP_POLL);
        }

        debug!(pid = %self.pid, "a process group did not stop when asked; killing it");
        if let Err(error) = signal_group(self.pid, ProcessSignal::Kill) {
            // The group may have exited between the grace poll and the kill.
            debug!(pid = %self.pid, %error, "the process group was already gone");
        }
        match self.child.wait() {
            Ok(_) => self.liveness = Liveness::Reaped,
            Err(error) => warn!(pid = %self.pid, %error, "could not wait for a killed child"),
        }
    }
}

impl Drop for SystemChild {
    /// Dropping a running child requests process-group termination, then
    /// attempts to reap the child before the handle is released.
    fn drop(&mut self) {
        if !self.liveness.may_signal() {
            return;
        }

        debug!(pid = %self.pid, "asking a process group to stop");
        if let Err(error) = signal_group(self.pid, ProcessSignal::Terminate) {
            debug!(pid = %self.pid, %error, "the process group was already gone");
        }
        self.reap();
    }
}

/// Tracks whether this handle may use the child's process-group identifier.
/// Reaping releases the identifier for reuse, so a reaped child must
/// not be signalled.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Liveness {
    /// The child has not been reaped, so signalling its group is permitted.
    #[default]
    Running,
    /// The child has been reaped, so signalling its group is forbidden.
    Reaped,
}

impl Liveness {
    pub(crate) fn may_signal(self) -> bool {
        matches!(self, Self::Running)
    }
}

/// Describes why a process request could not be started. Its formatted message
/// names the program and includes the underlying I/O error.
#[derive(Debug)]
pub struct SpawnError {
    program: OsString,
    cause: io::Error,
}

impl SpawnError {
    #[must_use]
    pub fn kind(&self) -> io::ErrorKind {
        self.cause.kind()
    }

    /// Returns the message used by `ProcessOutcome::SpawnFailed`.
    #[must_use]
    pub fn message(&self) -> String {
        self.to_string()
    }

    pub(crate) fn refused(program: OsString, cause: io::Error) -> Self {
        Self { program, cause }
    }

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

/// Sends a signal to the process group identified by `pid`. The process
/// with that identifier receives the signal as a member of the group.
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

/// Reads at most `OUTPUT_CHUNK` bytes from a non-blocking pipe.
/// Returns `None` when no bytes are available, the pipe is closed,
/// or the read fails.
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
