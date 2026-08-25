//! This file contains sections copied from WayVR's process code and sections
//! adapted for lunette. The source files are `backend/wayvr/process.rs` and
//! `backend/wayvr/mod.rs`. The source revision is
//! `98f800c644719d3f23a20e50bd3237c29a8082cb`. See https://github.com/wayvr-org/wayvr.
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
    thread,
    time::{Duration, Instant},
};

use smithay::reexports::rustix::{
    fs::{OFlags, fcntl_setfl},
    process::{self, Signal},
};
use tracing::{debug, warn};

use crate::protocol::{Argv, Pid, ProcessOutcome, ProcessSignal, SignalNumber, Stream};

/// Limits each output read to one chunk per stream per poll.
///
/// [`crate::state`] polls ten times per second, so the diagnostic output rate is
/// about 80 KB/s per stream. Excess output remains in the pipe until the next
/// poll. The pipe provides backpressure, which slows a chatty child instead of
/// truncating its output or blocking the compositor thread for a frame.
const OUTPUT_CHUNK: usize = 8192;

/// Bounds the wait for a child to honour `SIGTERM` before `SIGKILL` follows.
///
/// The process chooses when to exit, so the only condition to poll is the exit
/// itself. The bound applies once per still-running child during lunette teardown.
const TERMINATE_GRACE: Duration = Duration::from_millis(200);

/// Sets the interval between grace-period checks.
const REAP_POLL: Duration = Duration::from_millis(5);

/// Starts child processes.
///
/// The production implementation forks, while tests substitute a fake. The
/// interface hides that distinction.
pub trait ProcessSpawner: Send {
    /// Starts a process or reports why it could not be started.
    ///
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the program cannot be found or executed. A
    /// mistyped program name is the common case, and the error reports that cause.
    fn spawn(&mut self, plan: &SpawnPlan) -> Result<Box<dyn ChildProcess>, SpawnError>;
}

/// Represents a spawned child.
///
/// Tests substitute this interface to observe exit, output, and signal events
/// without starting a real process.
pub trait ChildProcess: Send {
    fn pid(&self) -> Pid;

    /// Returns the outcome after the child ends and is reaped.
    ///
    /// Returns `None` while the child runs and after the outcome has been reported.
    fn poll(&mut self) -> Option<ProcessOutcome>;

    /// Returns the output available since the last call.
    fn read_output(&mut self) -> Vec<(Stream, Vec<u8>)>;

    /// Signals the child's whole process group.
    ///
    /// Implementations must ignore this after [`ChildProcess::poll`] reports an
    /// outcome. The child PID is the group leader, and reaping it releases the
    /// process-group ID for reuse. A later signal could reach an unrelated group.
    fn signal(&mut self, signal: ProcessSignal);
}

/// What to start and what environment to start it in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnPlan {
    pub argv: Argv,
    /// Values added to the inherited environment, in order.
    pub env: Vec<(OsString, OsString)>,
    pub cwd: Option<PathBuf>,
}

/// Tells a spawned client how to reach lunette.
///
/// The socket is created elsewhere, so this value keeps display discovery out of
/// the process-spawning interface and makes the interface testable.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DisplayEnvironment {
    /// The `WAYLAND_DISPLAY` value, such as `wayland-20`.
    pub wayland_display: OsString,
    /// The `DISPLAY` value, such as `:20`. It is meaningful when xwayland-satellite
    /// runs and harmless otherwise.
    pub x11_display: OsString,
}

/// Spawns processes with the system `fork` and `exec` implementation.
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

        // SAFETY: `pre_exec` runs between `fork` and `exec`, after the child
        // inherits locks held by other parent threads. These rustix calls are
        // single, allocation-free, async-signal-safe system calls.
        unsafe {
            command.pre_exec(|| {
                // The child and its descendants share a process group that lunette
                // can signal as a unit. Signalling only the direct child leaves
                // descendants of a shell wrapper running.
                process::setsid().map_err(io::Error::from)?;

                // Terminates the child if lunette dies before its teardown runs.
                // The signal is tied to the thread that forks the child, which is
                // the compositor thread.
                process::set_parent_process_death_signal(Some(Signal::TERM))
                    .map_err(io::Error::from)?;

                Ok(())
            });
        }

        let child = command.spawn().map_err(|cause| SpawnError {
            program: plan.argv.program().to_owned(),
            cause,
        })?;

        // The compositor thread performs these reads, so a child that writes
        // nothing must not block it.
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
                    // The interface permits this state, although the kernel does
                    // not produce it. Report an unknown exit instead of inventing
                    // a signal number.
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
    /// Reaps a signalled child, escalating to `SIGKILL` after the grace period.
    ///
    /// No other component waits for this child, so omitting the reap leaves a
    /// zombie until lunette exits. `SIGKILL` cannot be caught, which makes the
    /// final blocking wait bounded by the child's kernel exit.
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
            debug!(pid = %self.pid, %error, "the process group was already gone");
        }
        match self.child.wait() {
            Ok(_) => self.liveness = Liveness::Reaped,
            Err(error) => warn!(pid = %self.pid, %error, "could not wait for a killed child"),
        }
    }
}

impl Drop for SystemChild {
    /// Stops the child's process group and waits for the child.
    ///
    /// The group is the correct unit because a wrapper script can otherwise leave
    /// its application running without a window.
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

/// Tracks whether the child's process group can still be addressed.
///
/// Reaping returns the group leader's PID to the kernel for reuse. With the usual
/// `pid_max` of 32768, a busy system can reuse it quickly, and `kill(-pid, …)` can
/// then address an unrelated process group. Every signal is therefore gated on
/// the child not being reaped.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Liveness {
    /// The child has not been reaped, so its PID still identifies its group.
    #[default]
    Running,
    /// The child has been reaped, so its PID may identify an unrelated group.
    Reaped,
}

impl Liveness {
    /// Whether the process group behind this pid is still the child's.
    pub(crate) fn may_signal(self) -> bool {
        matches!(self, Self::Running)
    }
}

/// Why a process could not be started.
#[derive(Debug)]
pub struct SpawnError {
    program: OsString,
    cause: io::Error,
}

impl SpawnError {
    /// Returns the message reported through `ProcessOutcome::SpawnFailed`.
    #[must_use]
    pub fn message(&self) -> String {
        self.to_string()
    }

    /// Constructs an error for a spawn refused before a process starts.
    ///
    /// The registry uses this when it cannot obtain an authentication token. The
    /// resulting outcome matches a program that cannot execute.
    pub(crate) fn refused(program: OsString, cause: io::Error) -> Self {
        Self { program, cause }
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

/// Signals the process and its descendants in the session created by `setsid`.
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

/// Reads the available bytes from a non-blocking pipe.
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
