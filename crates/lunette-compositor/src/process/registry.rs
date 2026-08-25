//! Adapted from the spawn and attribution fragments in WayVR
//! (https://github.com/wayvr-org/wayvr), in `backend/wayvr/process.rs` and
//! `backend/wayvr/mod.rs`, at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: process attribution and adopted-process liveness depend on the
//! production inspector reading `/proc`.

use std::{
    ffi::{OsStr, OsString},
    fmt, io,
    path::Path,
};

use subtle::ConstantTimeEq;
use tracing::{debug, warn};

use crate::{
    process::{
        attribution::ProcessInspector,
        spawn::{
            ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnError, SpawnPlan, signal_group,
        },
    },
    protocol::{Argv, Pid, ProcessId, ProcessOutcome, ProcessSignal, ProcessSnapshot, Stream},
};

/// The environment variable carrying a spawned client's authentication token.
pub(crate) const AUTH_VARIABLE: &str = "LUNETTE_DISPLAY_AUTH";

/// The token width in bytes. Tokens contain 256 bits from the operating
/// system's cryptographically secure random number generator.
pub(crate) const TOKEN_BYTES: usize = 32;

#[derive(Debug)]
pub(crate) struct ProcessRegistry {
    entries: Vec<Entry>,
    /// Allocates adopted-process identifiers from the top of the non-zero `u64`
    /// range. The main thread allocates spawned-process identifiers from the
    /// bottom before sending the request, so the two allocators use disjoint ends.
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
    /// Starts a process and registers it under the identifier allocated by the
    /// main thread before it sent the request. A failed spawn is not registered.
    pub(crate) fn spawn(
        &mut self,
        spawner: &mut dyn ProcessSpawner,
        request: SpawnRequest<'_>,
    ) -> Result<(), SpawnError> {
        let token = AuthToken::generate(request.argv.program())?;
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

    /// Registers a process that connected from outside lunette. The process is
    /// identified by its PID, but lunette does not own or reap it.
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

    /// Matches a connecting client to a process started by lunette. It checks
    /// the connecting PID first, then the authentication token in that process's
    /// environment for wrappers, re-execing launchers, and Flatpak applications.
    pub(crate) fn identify(&self, pid: Pid, inspector: &dyn ProcessInspector) -> Option<ProcessId> {
        if let Some(entry) = self.entries.iter().find(|entry| entry.pid() == Some(pid)) {
            return Some(entry.id);
        }

        let presented = match inspector.read_environment(pid, AUTH_VARIABLE) {
            Ok(Some(value)) => AuthToken::from_bytes(&value),
            Ok(None) => return None,
            Err(error) => {
                // An unreadable environment cannot authenticate the client.
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

    /// Signals a managed or adopted process group. An adopted process remains
    /// signalable until a liveness poll observes its `/proc` entry disappear.
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

    /// Polls managed output and liveness without blocking the compositor thread.
    /// The compositor invokes this from a timer rather than dedicating a reader
    /// thread to each child. `ProcessInspector` keeps `/proc` observation behind
    /// a deterministic seam for tests.
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
                        // `/proc` reports disappearance, but not the adopted
                        // process's exit status. The protocol has no unknown
                        // status, so use the neutral exit code for this report.
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
    /// Present only for processes started by lunette. Adopted processes have no
    /// token because lunette did not create their environment.
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
    /// Started by lunette, so it can be reaped and its process group signalled.
    Managed(Box<dyn ChildProcess>),
    /// Connected from outside. Lunette cannot reap it or obtain its exit status;
    /// liveness is sampled through `/proc`.
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

/// A per-spawn authentication token used to attribute clients after wrappers,
/// re-execing launchers, or Flatpak change the connecting PID. The token contains
/// 256 bits from the operating system's CSPRNG and comparisons are constant-time.
#[derive(Clone)]
pub(crate) struct AuthToken {
    bytes: [u8; TOKEN_BYTES],
}

impl AuthToken {
    /// Draws a token from the operating system's CSPRNG.
    ///
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the random source is unavailable. The spawn
    /// is refused instead of using a predictable fallback token.
    pub(crate) fn generate(program: &OsStr) -> Result<Self, SpawnError> {
        let mut bytes = [0_u8; TOKEN_BYTES];
        getrandom::fill(&mut bytes).map_err(|error| {
            SpawnError::refused(
                program.to_owned(),
                io::Error::other(format!(
                    "the operating system's random source is unavailable: {error}"
                )),
            )
        })?;
        Ok(Self { bytes })
    }

    /// Decodes the token presented by a client. Malformed input becomes an empty
    /// token, which cannot match a fixed-width authentication token.
    pub(crate) fn from_bytes(presented: &[u8]) -> Vec<u8> {
        decode_hex(presented).unwrap_or_default()
    }

    /// Compares a presented token with this token without exposing byte prefixes.
    pub(crate) fn matches(&self, presented: &[u8]) -> bool {
        // The constant-time comparison requires equal-length slices, and token
        // length is not secret because every valid token has the same width.
        presented.len() == self.bytes.len() && bool::from(self.bytes[..].ct_eq(presented))
    }

    /// Encodes the token as lowercase hexadecimal for an environment value.
    pub(crate) fn encoded(&self) -> String {
        let mut encoded = String::with_capacity(self.bytes.len() * 2);
        for byte in self.bytes {
            use std::fmt::Write as _;
            let _ = write!(encoded, "{byte:02x}");
        }
        encoded
    }
}

impl fmt::Debug for AuthToken {
    /// Hides the token from debug output because logs can expose their contents.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
    }
}

/// Builds the command line and environment for a spawned child. Flatpak receives
/// toolkit variables as `--env=` arguments after `run`; display variables also go
/// to the launcher's environment so it can bind the corresponding sandbox APIs.
fn build_plan(request: &SpawnRequest<'_>, token: &AuthToken) -> SpawnPlan {
    let hints = toolkit_hints(&token.encoded());
    let flatpak = is_flatpak(request.argv);

    let (argv, env) = if flatpak {
        let mut arguments = Vec::with_capacity(request.argv.arguments().len() + hints.len());
        let mut rest = request.argv.arguments().iter();

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

        (
            Argv::new(request.argv.program().to_owned(), arguments),
            display_variables(request.display),
        )
    } else {
        let mut env = display_variables(request.display);
        env.extend(hints);
        (request.argv.clone(), env)
    };

    // Apply request values last so they override lunette's default toolkit hints.
    let mut env = env;
    env.extend(request.env.iter().cloned());

    SpawnPlan {
        argv,
        env,
        cwd: request.cwd.map(Path::to_path_buf),
    }
}

/// Returns non-empty display variables for a spawned child. An empty
/// `WAYLAND_DISPLAY` or `DISPLAY` is omitted so the child inherits any existing
/// value instead of trying to use an empty socket or display name.
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

/// Returns the authentication token and toolkit defaults that prefer Wayland.
/// Display variables are added separately so empty values can be omitted without
/// overriding the inherited environment.
fn toolkit_hints(token: &str) -> Vec<(OsString, OsString)> {
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

/// Returns whether the program's file name is `flatpak` and its first argument
/// is `run`, regardless of whether the program path is absolute.
pub(crate) fn is_flatpak(argv: &Argv) -> bool {
    let program = Path::new(argv.program());
    let is_launcher = program
        .file_name()
        .is_some_and(|name| name == OsStr::new("flatpak"));

    is_launcher && argv.arguments().first().is_some_and(|first| first == "run")
}

/// Finds a variable in the NUL-separated byte block read from
/// `/proc/<pid>/environ`. It skips entries without `=`, and preserves non-UTF-8
/// values and everything after the first `=` in the matching entry.
pub(crate) fn find_environment_value(block: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    block
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
        .find_map(|entry| {
            let separator = entry.iter().position(|byte| *byte == b'=')?;
            (&entry[..separator] == key).then(|| entry[separator + 1..].to_vec())
        })
}

/// Decodes an even-length hexadecimal byte string. Odd lengths and non-hex bytes
/// are rejected without panicking; empty input decodes to an empty byte string.
pub(crate) fn decode_hex(encoded: &[u8]) -> Option<Vec<u8>> {
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
