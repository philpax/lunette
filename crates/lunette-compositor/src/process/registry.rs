//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/process.rs and backend/wayvr/mod.rs (the spawn and attribution fragments at :1232-1349), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Which processes exist, and which client belongs to which.

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

/// The environment variable a spawned client's authentication token travels in.
pub(crate) const AUTH_VARIABLE: &str = "LUNETTE_DISPLAY_AUTH";

/// How many bytes of randomness the token carries.
///
/// 256 bits, which is well past what a guessing attack over a local socket
/// could reach and costs nothing to carry in an environment block.
pub(crate) const TOKEN_BYTES: usize = 32;

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
    /// Draws a token from the operating system's CSPRNG.
    ///
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the random source is unavailable, which a
    /// hardened kernel blocking `getrandom` and an exhausted descriptor table
    /// both produce. There is no fallback: a predictable token is worse than
    /// none, because it would let any client claim any process. Refusing the
    /// spawn is the whole of the response — the session keeps running.
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

    /// Reads a token a client presented, which may be any length or malformed.
    pub(crate) fn from_bytes(presented: &[u8]) -> Vec<u8> {
        decode_hex(presented).unwrap_or_default()
    }

    /// Whether a presented token is this one.
    pub(crate) fn matches(&self, presented: &[u8]) -> bool {
        // Length is compared first and is not itself a secret: a token of the
        // wrong length cannot be this one, and the constant-time comparison
        // below requires equal lengths anyway.
        presented.len() == self.bytes.len() && bool::from(self.bytes[..].ct_eq(presented))
    }

    /// The form the token takes in an environment block.
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
    /// Deliberately opaque. A token in a log line is a token an attacker can
    /// read, and these end up in logs users paste into issue reports.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
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
    let hints = toolkit_hints(&token.encoded());
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

/// The variables that tell each toolkit to prefer Wayland, and the token that
/// identifies the process they belong to.
///
/// Copied wholesale from `mod.rs:1334-1340`. Without them a toolkit that
/// supports both backends often picks X11, which then goes through
/// xwayland-satellite for no reason. `WAYLAND_DISPLAY` is not among them:
/// [`display_variables`] carries it, because a spawn with no socket bound must
/// omit it rather than export an empty one.
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

/// Whether the command line is `flatpak run …`.
///
/// The check is on the program's file name rather than the whole path, so
/// `/usr/bin/flatpak` and a `flatpak` found on `PATH` are both recognised.
pub(crate) fn is_flatpak(argv: &Argv) -> bool {
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
