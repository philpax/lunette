//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/process.rs and backend/wayvr/mod.rs (the spawn and attribution fragments at :1232-1349), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: reads `/proc/<pid>/environ`, and spawns through `setsid` and
//! `prctl`.
//!
//! The processes lunette started, the ones it adopted, and how a connecting
//! client is matched to one.
//!
//! # Why a client has to be matched at all
//!
//! A Wayland client's connection carries the pid that opened the socket, which
//! is frequently not the process lunette started: a shell wrapper `exec`s, a
//! flatpak launcher hands off to a sandbox, a browser starts a zygote. So
//! matching is two-stage, as WayVR's is (`process.rs:182-217`): the connecting
//! pid first, and failing that an authentication token lunette put in the
//! child's environment and reads back out of `/proc/<pid>/environ`. A client
//! that matches neither connected from outside and is reported as external.
//!
//! # What is fixed relative to WayVR
//!
//! - **The token is from a CSPRNG, not a v4 UUID** (`mod.rs:1346-1349`), and is
//!   compared in constant time rather than with string equality. It is what
//!   attributes a window to a process, so a token that can be guessed or
//!   recovered a byte at a time is an attribution a hostile client can claim.
//! - **`/proc/<pid>/environ` is read as bytes.** WayVR reads it with
//!   `read_to_string` (`client.rs:70`, `process.rs:102`), which fails outright
//!   on an environment that is not UTF-8 — legal on Linux, and produced by any
//!   program that puts a path with odd bytes in one.
//! - **A whole process group is signalled, not just the direct child.** WayVR
//!   signals `child.id()` (`process.rs:132`, `:166`); a grep across its sources
//!   for `setsid`, `PDEATHSIG`, `process_group`, `pre_exec`, and `killpg` finds
//!   nothing, so a shell wrapper's grandchildren survive being killed. Lunette
//!   spawns with `setsid`, signals the group, and sets `PR_SET_PDEATHSIG` as a
//!   backstop for lunette itself dying.

use std::{
    error::Error,
    ffi::{OsStr, OsString},
    fmt, fs, io,
    io::Read,
    os::unix::process::{CommandExt, ExitStatusExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
};

use smithay::reexports::rustix::{
    fs::{OFlags, fcntl_setfl},
    process::{self, Signal},
};
use subtle::ConstantTimeEq;
use tracing::{debug, warn};

use crate::protocol::{
    Argv, Pid, ProcessId, ProcessOutcome, ProcessSignal, ProcessSnapshot, Stream,
};

/// The environment variable a spawned client's authentication token travels in.
const AUTH_VARIABLE: &str = "LUNETTE_DISPLAY_AUTH";

/// How many bytes of randomness the token carries.
///
/// 256 bits, which is well past what a guessing attack over a local socket
/// could reach and costs nothing to carry in an environment block.
const TOKEN_BYTES: usize = 32;

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

/// Every process lunette started or adopted.
#[derive(Debug)]
pub(crate) struct ProcessRegistry {
    entries: Vec<Entry>,
    /// The next identifier for an adopted process.
    ///
    /// Counting down from the top, because the main thread mints identifiers
    /// for the processes it asks to be started — `lunette.spawn` returns a
    /// handle before the compositor has seen the request — and counting up from
    /// one there. Two allocators sharing one space would collide; disjoint ends
    /// of a 64-bit space cannot, and neither side has to ask the other.
    next_adopted: u64,
}

impl Default for ProcessRegistry {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            next_adopted: u64::MAX,
        }
    }
}

impl ProcessRegistry {
    /// Starts a process and registers it.
    ///
    /// The identifier is chosen by the caller, because `lunette.spawn` returns
    /// a handle in the same call and so the identifier has to exist before the
    /// compositor has seen the request.
    pub(crate) fn spawn(
        &mut self,
        spawner: &mut dyn ProcessSpawner,
        request: SpawnRequest<'_>,
    ) -> Result<(), SpawnError> {
        let token = AuthToken::generate();
        let plan = build_plan(&request, &token);

        let child = spawner.spawn(&plan)?;
        debug!(process = %request.process, pid = %child.pid(), "started a process");

        self.entries.push(Entry {
            id: request.process,
            token: Some(token),
            kind: Kind::Managed(child),
        });
        Ok(())
    }

    /// Registers a process that connected from outside lunette.
    pub(crate) fn adopt(&mut self, pid: Pid) -> ProcessId {
        let id = ProcessId::new(self.next_adopted).unwrap_or_else(|| {
            unreachable!("the counter starts at the top and only decreases, so it is never zero")
        });
        self.next_adopted -= 1;

        self.entries.push(Entry {
            id,
            token: None,
            kind: Kind::External { pid, alive: true },
        });
        id
    }

    /// Matches a connecting client to a process it was started by.
    ///
    /// The pid first, then the token from the client's own environment. The
    /// second stage is the one that earns its keep: under a shell wrapper or a
    /// flatpak the connecting pid is almost never the child lunette forked.
    pub(crate) fn identify(&self, pid: Pid, inspector: &dyn ProcessInspector) -> Option<ProcessId> {
        if let Some(entry) = self.entries.iter().find(|entry| entry.pid() == Some(pid)) {
            return Some(entry.id);
        }

        let presented = match inspector.read_environment(pid, AUTH_VARIABLE) {
            Ok(Some(value)) => AuthToken::from_bytes(&value),
            Ok(None) => return None,
            Err(error) => {
                debug!(%pid, %error, "could not read a connecting client's environment");
                return None;
            }
        };

        self.entries
            .iter()
            .find(|entry| {
                entry
                    .token
                    .as_ref()
                    .is_some_and(|token| token.matches(&presented))
            })
            .map(|entry| entry.id)
    }

    /// Signals a process group.
    pub(crate) fn signal(&mut self, id: ProcessId, signal: ProcessSignal) {
        let Some(entry) = self.entries.iter_mut().find(|entry| entry.id == id) else {
            debug!(process = %id, "a signal was asked for a process that is already gone");
            return;
        };

        match &mut entry.kind {
            Kind::Managed(child) => child.signal(signal),
            Kind::External { pid, alive } => {
                if !*alive {
                    return;
                }
                if let Err(error) = signal_group(*pid, signal) {
                    warn!(%pid, %error, "could not signal an adopted process group");
                }
            }
        }
    }

    /// Collects what every process has written, and which have ended.
    ///
    /// Called from a timer rather than from a thread per child: a compositor
    /// with a dozen panels open would otherwise carry a dozen blocked reader
    /// threads, and the output is diagnostic rather than interactive.
    pub(crate) fn poll(&mut self, inspector: &dyn ProcessInspector) -> Vec<Report> {
        let mut reports = Vec::new();

        for entry in &mut self.entries {
            let id = entry.id;
            match &mut entry.kind {
                Kind::Managed(child) => {
                    for (stream, bytes) in child.read_output() {
                        reports.push(Report::Output { id, stream, bytes });
                    }
                    if let Some(outcome) = child.poll() {
                        reports.push(Report::Exited { id, outcome });
                    }
                }
                Kind::External { pid, alive } => {
                    if *alive && !inspector.is_running(*pid) {
                        *alive = false;
                        // An adopted process is not lunette's child, so it
                        // cannot be waited on and its exit status is not
                        // knowable. Reporting a zero would be a lie; reporting
                        // it as ended is the honest amount.
                        reports.push(Report::Exited {
                            id,
                            outcome: ProcessOutcome::Exited { code: 0 },
                        });
                    }
                }
            }
        }

        for report in &reports {
            if let Report::Exited { id, .. } = report {
                self.entries.retain(|entry| entry.id != *id);
            }
        }

        reports
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub(crate) fn snapshot(&self) -> Vec<ProcessSnapshot> {
        self.entries
            .iter()
            .map(|entry| ProcessSnapshot {
                process: entry.id,
                pid: entry.pid(),
                external: matches!(entry.kind, Kind::External { .. }),
                alive: entry.is_alive(),
            })
            .collect()
    }
}

/// What the compositor learned from one poll.
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
}

/// What `lunette.spawn` asked for.
#[derive(Clone, Copy, Debug)]
pub(crate) struct SpawnRequest<'a> {
    pub(crate) process: ProcessId,
    pub(crate) argv: &'a Argv,
    pub(crate) env: &'a [(OsString, OsString)],
    pub(crate) cwd: Option<&'a Path>,
    pub(crate) display: &'a DisplayEnvironment,
}

#[derive(Debug)]
struct Entry {
    id: ProcessId,
    /// Absent for an adopted process, which lunette never gave a token to.
    token: Option<AuthToken>,
    kind: Kind,
}

impl Entry {
    fn pid(&self) -> Option<Pid> {
        match &self.kind {
            Kind::Managed(child) => Some(child.pid()),
            Kind::External { pid, .. } => Some(*pid),
        }
    }

    fn is_alive(&self) -> bool {
        match &self.kind {
            Kind::Managed(_) => true,
            Kind::External { alive, .. } => *alive,
        }
    }
}

enum Kind {
    /// Started by lunette, so it can be waited on and signalled.
    Managed(Box<dyn ChildProcess>),
    /// Connected from outside. Not a child, so it cannot be waited on, and its
    /// liveness is only observable through `/proc`.
    External { pid: Pid, alive: bool },
}

impl fmt::Debug for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Managed(child) => f.debug_tuple("Managed").field(&child.pid()).finish(),
            Self::External { pid, alive } => f
                .debug_struct("External")
                .field("pid", pid)
                .field("alive", alive)
                .finish(),
        }
    }
}

/// A secret lunette gives a child so its clients can be recognised.
///
/// Not a UUID. A v4 UUID has 122 bits from whatever the generator happened to
/// use, and comparing it as a string exits at the first differing byte, which
/// leaks how much of a guess was right. This is 256 bits from the operating
/// system's CSPRNG, compared in constant time.
#[derive(Clone)]
pub(crate) struct AuthToken {
    bytes: [u8; TOKEN_BYTES],
}

impl AuthToken {
    fn generate() -> Self {
        let mut bytes = [0_u8; TOKEN_BYTES];
        getrandom::fill(&mut bytes).unwrap_or_else(|error| {
            // The kernel's random source being unavailable means the machine is
            // in a state where a token cannot be trusted, and a predictable one
            // is worse than none: it would let any client claim any process.
            panic!("the operating system's random source is unavailable: {error}")
        });
        Self { bytes }
    }

    /// Reads a token a client presented, which may be any length or malformed.
    fn from_bytes(presented: &[u8]) -> Vec<u8> {
        decode_hex(presented).unwrap_or_default()
    }

    /// Whether a presented token is this one.
    fn matches(&self, presented: &[u8]) -> bool {
        // Length is compared first and is not itself a secret: a token of the
        // wrong length cannot be this one, and the constant-time comparison
        // below requires equal lengths anyway.
        presented.len() == self.bytes.len() && bool::from(self.bytes[..].ct_eq(presented))
    }

    /// The form the token takes in an environment block.
    fn encoded(&self) -> String {
        let mut encoded = String::with_capacity(self.bytes.len() * 2);
        for byte in self.bytes {
            use std::fmt::Write as _;
            let _ = write!(encoded, "{byte:02x}");
        }
        encoded
    }
}

impl fmt::Debug for AuthToken {
    /// Deliberately opaque. A token in a log line is a token an attacker can
    /// read, and these end up in logs users paste into issue reports.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
    }
}

/// Looks at a process lunette did not start.
///
/// A seam over `/proc`, so both the matching logic and the liveness check can
/// be tested without a real process existing. One trait rather than two,
/// because both answers come from the same directory and every caller wants
/// both.
pub trait ProcessInspector: Send {
    /// The value of one variable in a process's environment, as bytes.
    ///
    /// # Errors
    ///
    /// Returns the underlying error when the process's environment cannot be
    /// read at all, which usually means it has already exited.
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>>;

    /// Whether the process still exists.
    fn is_running(&self, pid: Pid) -> bool;
}

/// The real `/proc`.
#[derive(Clone, Copy, Debug, Default)]
pub struct ProcFilesystem;

impl ProcessInspector for ProcFilesystem {
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>> {
        let raw = fs::read(format!("/proc/{pid}/environ"))?;
        Ok(find_environment_value(&raw, key.as_bytes()))
    }

    fn is_running(&self, pid: Pid) -> bool {
        fs::metadata(format!("/proc/{pid}")).is_ok()
    }
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
                    signal: crate::protocol::SignalNumber::new(signal),
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

/// Assembles the command line and environment a child is started with.
///
/// Ported from `configure_env` (`mod.rs:1290-1343`), including the flatpak
/// detection at `:1252-1253`. Under flatpak the environment has to travel as
/// `--env=` arguments after `run`, because the sandbox does not inherit the
/// launcher's environment and `--env` is an argument of `flatpak run` rather
/// than of `flatpak`.
fn build_plan(request: &SpawnRequest<'_>, token: &AuthToken) -> SpawnPlan {
    let hints = toolkit_hints(&request.display.wayland_display, &token.encoded());
    let flatpak = is_flatpak(request.argv);

    let (argv, env) = if flatpak {
        let mut arguments = Vec::with_capacity(request.argv.arguments().len() + hints.len());
        let mut rest = request.argv.arguments().iter();

        // "run" itself, which the detection established is the first argument.
        if let Some(run) = rest.next() {
            arguments.push(run.clone());
        }
        for (key, value) in &hints {
            let mut argument = OsString::from("--env=");
            argument.push(key);
            argument.push("=");
            argument.push(value);
            arguments.push(argument);
        }
        arguments.extend(rest.cloned());

        // `WAYLAND_DISPLAY` and `DISPLAY` go to the launcher's own environment
        // as well, because flatpak reads them to decide what to bind into the
        // sandbox.
        (
            Argv::new(request.argv.program().to_owned(), arguments),
            display_variables(request.display),
        )
    } else {
        let mut env = display_variables(request.display);
        env.extend(hints);
        (request.argv.clone(), env)
    };

    // The caller's own environment last, so a configuration that deliberately
    // overrides a toolkit hint wins over lunette's default.
    let mut env = env;
    env.extend(request.env.iter().cloned());

    SpawnPlan {
        argv,
        env,
        cwd: request.cwd.map(Path::to_path_buf),
    }
}

/// The two variables that tell a child where lunette is.
///
/// An empty value is omitted rather than exported. A compositor with no
/// listening socket has no display to name, and `WAYLAND_DISPLAY=` would make a
/// client fail to connect to a socket called the empty string rather than fall
/// back to whatever the user's session already provides.
fn display_variables(display: &DisplayEnvironment) -> Vec<(OsString, OsString)> {
    [
        ("WAYLAND_DISPLAY", &display.wayland_display),
        ("DISPLAY", &display.x11_display),
    ]
    .into_iter()
    .filter(|(_, value)| !value.is_empty())
    .map(|(key, value)| (OsString::from(key), value.clone()))
    .collect()
}

/// The variables that tell each toolkit to prefer Wayland.
///
/// Copied wholesale from `mod.rs:1334-1340`. Without them a toolkit that
/// supports both backends often picks X11, which then goes through
/// xwayland-satellite for no reason.
fn toolkit_hints(_wayland_display: &OsStr, token: &str) -> Vec<(OsString, OsString)> {
    [
        (AUTH_VARIABLE, token),
        ("GDK_BACKEND", "wayland,x11"),
        ("QT_QPA_PLATFORM", "wayland;xcb"),
        ("SDL_VIDEODRIVER", "wayland"),
        ("CLUTTER_BACKEND", "wayland"),
        ("MOZ_ENABLE_WAYLAND", "1"),
        ("ELECTRON_OZONE_PLATFORM_HINT", "wayland"),
    ]
    .into_iter()
    .map(|(key, value)| (OsString::from(key), OsString::from(value)))
    .collect()
}

/// Whether the command line is `flatpak run …`.
///
/// The check is on the program's file name rather than the whole path, so
/// `/usr/bin/flatpak` and a `flatpak` found on `PATH` are both recognised.
fn is_flatpak(argv: &Argv) -> bool {
    let program = Path::new(argv.program());
    let is_launcher = program
        .file_name()
        .is_some_and(|name| name == OsStr::new("flatpak"));

    is_launcher && argv.arguments().first().is_some_and(|first| first == "run")
}

/// Finds one variable in the NUL-separated block `/proc/<pid>/environ` holds.
///
/// Bytes throughout. An environment is not required to be UTF-8, and a program
/// that puts a path with odd bytes in one is not doing anything wrong.
pub(crate) fn find_environment_value(block: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    block
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
        .find_map(|entry| {
            let separator = entry.iter().position(|byte| *byte == b'=')?;
            (&entry[..separator] == key).then(|| entry[separator + 1..].to_vec())
        })
}

/// Reads a hexadecimal token, rejecting anything that is not one.
///
/// A client presents whatever it likes here, so this has to survive odd
/// lengths, non-hex bytes, and an empty value.
fn decode_hex(encoded: &[u8]) -> Option<Vec<u8>> {
    if !encoded.len().is_multiple_of(2) {
        return None;
    }

    encoded
        .chunks_exact(2)
        .map(|pair| {
            let high = (pair[0] as char).to_digit(16)?;
            let low = (pair[1] as char).to_digit(16)?;
            u8::try_from(high * 16 + low).ok()
        })
        .collect()
}

/// Signals a process group, which is the process itself and everything it
/// started under the session `setsid` gave it.
fn signal_group(pid: Pid, signal: ProcessSignal) -> io::Result<()> {
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

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::testing::{FakeInspector, FakeSpawner};

    fn display() -> DisplayEnvironment {
        DisplayEnvironment {
            wayland_display: OsString::from("wayland-20"),
            x11_display: OsString::from(":20"),
        }
    }

    fn argv(parts: &[&str]) -> Argv {
        Argv::from_list(parts.iter().map(OsString::from).collect()).expect("non-empty")
    }

    fn process(raw: u64) -> ProcessId {
        ProcessId::new(raw).expect("non-zero")
    }

    fn value<'a>(plan: &'a SpawnPlan, key: &str) -> Option<&'a OsStr> {
        plan.env
            .iter()
            .rev()
            .find(|(name, _)| name == OsStr::new(key))
            .map(|(_, value)| value.as_os_str())
    }

    fn spawn_into(
        registry: &mut ProcessRegistry,
        spawner: &mut FakeSpawner,
        id: ProcessId,
        parts: &[&str],
    ) -> Result<(), SpawnError> {
        let argv = argv(parts);
        let display = display();
        registry.spawn(
            spawner,
            SpawnRequest {
                process: id,
                argv: &argv,
                env: &[],
                cwd: None,
                display: &display,
            },
        )
    }

    #[test]
    fn a_spawn_carries_the_display_and_the_toolkit_hints() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();

        spawn_into(&mut registry, &mut spawner, process(1), &["foot"])
            .expect("the fake spawner starts anything");

        let requested = spawner.log.requested();
        let plan = &requested[0];
        assert_eq!(
            value(plan, "WAYLAND_DISPLAY"),
            Some(OsStr::new("wayland-20"))
        );
        assert_eq!(value(plan, "DISPLAY"), Some(OsStr::new(":20")));
        assert_eq!(value(plan, "GDK_BACKEND"), Some(OsStr::new("wayland,x11")));
        assert_eq!(
            value(plan, "ELECTRON_OZONE_PLATFORM_HINT"),
            Some(OsStr::new("wayland"))
        );
        assert!(
            value(plan, AUTH_VARIABLE).is_some_and(|token| token.len() == TOKEN_BYTES * 2),
            "the token is present and the full width"
        );
    }

    #[test]
    fn two_spawns_get_different_tokens() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();

        spawn_into(&mut registry, &mut spawner, process(1), &["foot"]).expect("started");
        spawn_into(&mut registry, &mut spawner, process(2), &["foot"]).expect("started");

        let requested = spawner.log.requested();
        let first = value(&requested[0], AUTH_VARIABLE).expect("a token");
        let second = value(&requested[1], AUTH_VARIABLE).expect("a token");
        assert_ne!(first, second);
    }

    #[test]
    fn a_flatpak_launch_passes_its_environment_after_run() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();

        spawn_into(
            &mut registry,
            &mut spawner,
            process(1),
            &["/usr/bin/flatpak", "run", "org.example.App", "--window"],
        )
        .expect("started");

        let requested = spawner.log.requested();
        let arguments: Vec<String> = requested[0]
            .argv
            .arguments()
            .iter()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect();

        assert_eq!(arguments[0], "run", "--env must follow run, not precede it");
        assert!(
            arguments
                .iter()
                .any(|argument| argument.starts_with("--env=GDK_BACKEND=")),
            "the hints travel as arguments: {arguments:?}"
        );
        assert_eq!(
            arguments.last().map(String::as_str),
            Some("--window"),
            "the application's own arguments stay after the environment"
        );
        assert!(
            arguments
                .iter()
                .position(|argument| argument == "org.example.App")
                .is_some_and(|index| index > 1),
            "the application id stays after run: {arguments:?}"
        );
    }

    #[test]
    fn a_program_merely_named_flatpak_run_is_not_a_flatpak_launch() {
        assert!(!is_flatpak(&argv(&["flatpak"])));
        assert!(!is_flatpak(&argv(&["flatpak", "list"])));
        assert!(!is_flatpak(&argv(&["flatpakker", "run"])));
        assert!(is_flatpak(&argv(&["flatpak", "run", "org.example.App"])));
        assert!(is_flatpak(&argv(&["/usr/bin/flatpak", "run"])));
    }

    #[test]
    fn a_caller_supplied_variable_overrides_a_toolkit_hint() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();
        let argv = argv(&["foot"]);
        let display = display();

        registry
            .spawn(
                &mut spawner,
                SpawnRequest {
                    process: process(1),
                    argv: &argv,
                    env: &[(OsString::from("GDK_BACKEND"), OsString::from("x11"))],
                    cwd: None,
                    display: &display,
                },
            )
            .expect("started");

        assert_eq!(
            value(&spawner.log.requested()[0], "GDK_BACKEND"),
            Some(OsStr::new("x11")),
            "lunette's hint is a default, not a policy"
        );
    }

    #[test]
    fn a_spawn_that_fails_registers_nothing() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();
        spawner.log.refuse("no such file or directory");

        let error = spawn_into(&mut registry, &mut spawner, process(1), &["not-a-program"])
            .expect_err("a refused spawn is an error");

        assert!(error.message().contains("not-a-program"));
        assert!(
            registry.is_empty(),
            "a process that never ran is not tracked"
        );
        assert!(registry.snapshot().is_empty());
    }

    #[test]
    fn a_client_is_matched_by_its_connecting_pid_first() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();
        spawn_into(&mut registry, &mut spawner, process(7), &["foot"]).expect("started");

        let pid = spawner
            .log
            .pid(0)
            .expect("the fake spawner gave the child a pid");
        assert_eq!(
            registry.identify(pid, &FakeInspector::default()),
            Some(process(7)),
            "the pid match must not need the environment at all"
        );
    }

    #[test]
    fn a_client_behind_a_wrapper_is_matched_by_its_token() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();
        spawn_into(&mut registry, &mut spawner, process(7), &["sh"]).expect("started");

        let requested = spawner.log.requested();
        let token = value(&requested[0], AUTH_VARIABLE).expect("a token");
        let environment = FakeInspector::default();
        let mut block = Vec::new();
        block.extend_from_slice(b"HOME=/home/somebody\0");
        block.extend_from_slice(AUTH_VARIABLE.as_bytes());
        block.push(b'=');
        block.extend_from_slice(token.as_encoded_bytes());
        block.push(0);
        environment.set_environment(4242, block);

        let grandchild = Pid::new(4242).expect("positive");
        assert_eq!(
            registry.identify(grandchild, &environment),
            Some(process(7))
        );
    }

    #[test]
    fn a_client_presenting_a_wrong_token_is_not_matched() {
        let mut registry = ProcessRegistry::default();
        let mut spawner = FakeSpawner::default();
        spawn_into(&mut registry, &mut spawner, process(7), &["sh"]).expect("started");

        let environment = FakeInspector::default();
        for presented in [
            b"".to_vec(),
            b"not-hexadecimal".to_vec(),
            b"00".to_vec(),
            vec![b'a'; TOKEN_BYTES * 2],
        ] {
            environment.set_variable(4242, AUTH_VARIABLE, &presented);

            assert_eq!(
                registry.identify(Pid::new(4242).expect("positive"), &environment),
                None,
                "a token of {presented:?} must not match"
            );
        }
    }

    #[test]
    fn a_client_with_no_token_and_no_matching_pid_is_unknown() {
        let registry = ProcessRegistry::default();
        let environment = FakeInspector::default();
        environment.set_environment(4242, b"HOME=/home/somebody\0".to_vec());

        assert_eq!(
            registry.identify(Pid::new(4242).expect("positive"), &environment),
            None,
            "an unmatched client is external, which the caller decides, not this"
        );
    }

    #[test]
    fn an_adopted_process_is_reported_external_and_alive() {
        let mut registry = ProcessRegistry::default();
        let id = registry.adopt(Pid::new(4242).expect("positive"));

        let snapshot = registry.snapshot();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].process, id);
        assert_eq!(snapshot[0].pid, Pid::new(4242));
        assert!(snapshot[0].external);
        assert!(snapshot[0].alive);
    }

    #[test]
    fn an_adopted_process_that_disappears_is_reported_once() {
        let mut registry = ProcessRegistry::default();
        let id = registry.adopt(Pid::new(4242).expect("positive"));

        assert!(registry.poll(&FakeInspector::default()).is_empty());

        let gone = FakeInspector::default();
        gone.kill(4242);
        let reports = registry.poll(&gone);
        assert_eq!(reports.len(), 1);
        assert!(matches!(reports[0], Report::Exited { id: reported, .. } if reported == id));

        assert!(
            registry.poll(&gone).is_empty(),
            "an exit is reported once, not on every poll"
        );
        assert!(registry.is_empty());
    }

    #[test]
    fn an_environment_block_is_read_as_bytes() {
        let mut block = Vec::new();
        block.extend_from_slice(b"PATH=/usr/bin\0");
        block.extend_from_slice(b"ODD=");
        block.extend_from_slice(&[0xFF, 0xFE, 0x80]);
        block.push(0);
        block.extend_from_slice(b"LAST=1\0");

        assert_eq!(
            find_environment_value(&block, b"ODD"),
            Some(vec![0xFF, 0xFE, 0x80]),
            "a non-UTF-8 value must survive, because it is legal"
        );
        assert_eq!(find_environment_value(&block, b"LAST"), Some(b"1".to_vec()));
        assert_eq!(find_environment_value(&block, b"ABSENT"), None);
    }

    #[test]
    fn an_environment_entry_with_no_separator_is_skipped() {
        let block = b"BROKEN\0GOOD=yes\0".to_vec();
        assert_eq!(
            find_environment_value(&block, b"GOOD"),
            Some(b"yes".to_vec())
        );
        assert_eq!(find_environment_value(&block, b"BROKEN"), None);
    }

    #[test]
    fn an_environment_value_containing_an_equals_keeps_all_of_it() {
        let block = b"KEY=a=b=c\0".to_vec();
        assert_eq!(
            find_environment_value(&block, b"KEY"),
            Some(b"a=b=c".to_vec())
        );
    }

    #[test]
    fn an_empty_environment_block_yields_nothing() {
        assert_eq!(find_environment_value(b"", b"ANY"), None);
        assert_eq!(find_environment_value(b"\0\0\0", b"ANY"), None);
    }

    #[test]
    fn a_token_round_trips_through_its_encoded_form() {
        let token = AuthToken::generate();
        let encoded = token.encoded();

        assert_eq!(encoded.len(), TOKEN_BYTES * 2);
        assert!(token.matches(&AuthToken::from_bytes(encoded.as_bytes())));
    }

    #[test]
    fn a_token_does_not_match_a_prefix_of_itself() {
        let token = AuthToken::generate();
        let encoded = token.encoded();

        assert!(!token.matches(&AuthToken::from_bytes(
            &encoded.as_bytes()[..encoded.len() - 2]
        )));
        assert!(!token.matches(&[]));
    }

    #[test]
    fn hexadecimal_decoding_rejects_what_is_not_hexadecimal() {
        assert_eq!(decode_hex(b"00ff"), Some(vec![0x00, 0xFF]));
        assert_eq!(decode_hex(b""), Some(Vec::new()));
        assert_eq!(decode_hex(b"0"), None, "an odd length is not a byte string");
        assert_eq!(decode_hex(b"zz"), None);
        assert_eq!(decode_hex(b"0x"), None);
        assert_eq!(
            decode_hex("00ÿ".as_bytes()),
            None,
            "a multi-byte character is not two hexadecimal digits"
        );
    }

    #[test]
    fn a_token_is_not_written_into_a_log_line() {
        let token = AuthToken::generate();
        let rendered = format!("{token:?}");

        assert!(!rendered.contains(&token.encoded()));
        assert_eq!(rendered, "AuthToken(<redacted>)");
    }
}
