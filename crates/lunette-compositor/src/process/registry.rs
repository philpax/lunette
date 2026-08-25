//! This file contains sections derived from WayVR's process registry and attribution code.
//! The source files are `backend/wayvr/process.rs` and `backend/wayvr/mod.rs`.
//! The source revision is `98f800c644719d3f23a20e50bd3237c29a8082cb`.
//! See https://github.com/wayvr-org/wayvr.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Tracks managed and externally connected processes and associates clients with them.

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

/// The environment variable that carries a spawned client's authentication token.
pub(crate) const AUTH_VARIABLE: &str = "LUNETTE_DISPLAY_AUTH";

/// The token length in bytes.
///
/// The token contains 256 bits from the operating system's cryptographic random source.
/// This resists guessing over a local socket.
pub(crate) const TOKEN_BYTES: usize = 32;

/// The processes that lunette started or adopted.
#[derive(Debug)]
pub(crate) struct ProcessRegistry {
    entries: Vec<Entry>,
    /// Allocates identifiers for adopted processes from the top of the 64-bit
    /// identifier space. Managed processes count up from one, so the allocators
    /// cannot collide.
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
    /// Starts and registers a managed process.
    ///
    /// The request supplies the identifier because `lunette.spawn` returns its
    /// handle before the compositor receives the request.
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

    /// Matches a connecting client to its process.
    ///
    /// The registry checks the process ID first. A wrapper or sandbox can change
    /// the connecting process ID, so the authentication token provides a fallback.
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

    /// Collects diagnostic process output and reports processes that have ended.
    ///
    /// Polling avoids one blocked reader thread per child, and diagnostic output
    /// does not require interactive delivery.
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
                        // An adopted process is not lunette's child, so the registry cannot
                        // wait for it or learn its exit status. Zero means that the status is
                        // unknown, not that the process returned zero.
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

/// Events observed while polling the process registry.
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

/// Parameters for starting a managed process.
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
    /// `None` for an adopted process, which does not receive an authentication token.
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
    /// A process started by lunette. The registry can wait for and signal it.
    Managed(Box<dyn ChildProcess>),
    /// A process connected from outside lunette. The registry cannot wait for it
    /// and observes its liveness through `/proc`.
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

/// An authentication token that identifies a managed process to its clients.
///
/// The token contains 256 bits from the operating system's cryptographic random source.
/// Matching compares equal-length tokens in constant time to avoid leaking a partial match.
#[derive(Clone)]
pub(crate) struct AuthToken {
    bytes: [u8; TOKEN_BYTES],
}

impl AuthToken {
    /// Generates a token with the operating system's cryptographic random source.
    ///
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the random source is unavailable.
    /// There is no fallback: a predictable token would let any client claim any process.
    /// The registry refuses the spawn while keeping the session running.
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

    /// Decodes a client-presented token. Invalid input produces an empty token.
    pub(crate) fn from_bytes(presented: &[u8]) -> Vec<u8> {
        decode_hex(presented).unwrap_or_default()
    }

    /// Returns whether a presented token matches this token.
    pub(crate) fn matches(&self, presented: &[u8]) -> bool {
        // The comparison requires equal-length inputs. The length is public because
        // a token with the wrong length cannot match.
        presented.len() == self.bytes.len() && bool::from(self.bytes[..].ct_eq(presented))
    }

    /// Encodes the token for an environment block.
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
    /// Hides the token because debug output can reach logs and issue reports.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
    }
}

/// Builds the command line and environment for a child process.
///
/// Flatpak receives environment variables as `--env=` arguments after `run`, and
/// reads display variables from the launcher's environment. The sandbox does not
/// inherit that environment. `--env` belongs to `flatpak run`, not to `flatpak`.
fn build_plan(request: &SpawnRequest<'_>, token: &AuthToken) -> SpawnPlan {
    let hints = toolkit_hints(&token.encoded());
    let flatpak = is_flatpak(request.argv);

    let (argv, env) = if flatpak {
        let mut arguments = Vec::with_capacity(request.argv.arguments().len() + hints.len());
        let mut rest = request.argv.arguments().iter();

        // Flatpak requires its `run` subcommand before these options.
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

        // Flatpak uses the launcher's display variables to bind displays into the sandbox.
        (
            Argv::new(request.argv.program().to_owned(), arguments),
            display_variables(request.display),
        )
    } else {
        let mut env = display_variables(request.display);
        env.extend(hints);
        (request.argv.clone(), env)
    };

    // User-provided values override lunette's toolkit defaults.
    let mut env = env;
    env.extend(request.env.iter().cloned());

    SpawnPlan {
        argv,
        env,
        cwd: request.cwd.map(Path::to_path_buf),
    }
}

/// Builds the display variables for a child process.
///
/// Empty values are omitted because `WAYLAND_DISPLAY=` selects an empty socket name.
/// Omitting the variable lets the client use the existing session display.
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

/// Builds toolkit hints that prefer Wayland and identify the managed process.
///
/// [`display_variables`] supplies `WAYLAND_DISPLAY` and omits it when no display
/// is configured.
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

/// Reports whether the command line starts with `flatpak run`.
///
/// The check uses the program's file name, so it recognizes both `/usr/bin/flatpak`
/// and a `flatpak` found on `PATH`.
pub(crate) fn is_flatpak(argv: &Argv) -> bool {
    let program = Path::new(argv.program());
    let is_launcher = program
        .file_name()
        .is_some_and(|name| name == OsStr::new("flatpak"));

    is_launcher && argv.arguments().first().is_some_and(|first| first == "run")
}

/// Finds a variable in the NUL-separated block from `/proc/<pid>/environ`.
///
/// The function preserves raw bytes because Linux permits non-UTF-8 environment values.
pub(crate) fn find_environment_value(block: &[u8], key: &[u8]) -> Option<Vec<u8>> {
    block
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
        .find_map(|entry| {
            let separator = entry.iter().position(|byte| *byte == b'=')?;
            (&entry[..separator] == key).then(|| entry[separator + 1..].to_vec())
        })
}

/// Decodes a hexadecimal token, returning `None` for invalid input.
///
/// Invalid input includes odd-length, non-hexadecimal, and empty byte strings.
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
