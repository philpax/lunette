//! Adapted from the `configure_env` and `generate_auth_key` fragments of WayVR's
//! `backend/wayvr/mod.rs` at commit 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The command line and environment of a spawned child, and the token that
//! attributes its clients.
//!
//! The variable list and the Flatpak `--env=` insertion after `run` are
//! upstream's. lunette builds a plan rather than configuring a `Command`, so
//! the spawner seam can record it; omits an empty display variable; applies
//! the caller's variables last; names the token variable
//! `LUNETTE_DISPLAY_AUTH`; and draws a 256-bit token from the operating
//! system's random source, compared in constant time, where upstream uses a
//! UUID.

use std::{
    ffi::{OsStr, OsString},
    fmt, io,
    path::Path,
};

use subtle::ConstantTimeEq;

use crate::{
    protocol::{Argv, ProcessId},
    spawn::system::{DisplayEnvironment, SpawnError, SpawnPlan},
};

/// The environment variable carrying a spawned client's authentication token.
pub(crate) const AUTH_VARIABLE: &str = "LUNETTE_DISPLAY_AUTH";

/// The token width in bytes. The operating system draws the 256 bits
/// from its cryptographically secure random number generator (CSPRNG).
pub(crate) const TOKEN_BYTES: usize = 32;

#[derive(Clone, Copy, Debug)]
pub(crate) struct SpawnRequest<'a> {
    pub(crate) process: ProcessId,
    pub(crate) argv: &'a Argv,
    pub(crate) env: &'a [(OsString, OsString)],
    pub(crate) cwd: Option<&'a Path>,
    pub(crate) display: &'a DisplayEnvironment,
}

/// A per-spawn authentication token. It attributes clients after wrappers,
/// re-execing launchers, or Flatpak change the connecting PID.
/// The operating system draws the token's 256 bits from its CSPRNG,
/// and comparisons take constant time.
#[derive(Clone)]
pub(crate) struct AuthToken {
    bytes: [u8; TOKEN_BYTES],
}

impl AuthToken {
    /// Draws a token from the operating system's CSPRNG.
    ///
    /// # Errors
    ///
    /// Returns [`SpawnError`] when the random source is unavailable.
    /// The spawn is refused; a predictable fallback token is not used.
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

    /// Decodes the token presented by a client. Malformed input becomes
    /// an empty token, which cannot match a fixed-width authentication token.
    pub(crate) fn from_bytes(presented: &[u8]) -> Vec<u8> {
        decode_hex(presented).unwrap_or_default()
    }

    /// Compares a presented token with this token without exposing byte prefixes.
    pub(crate) fn matches(&self, presented: &[u8]) -> bool {
        // The constant-time comparison requires equal-length slices; token length
        // is not secret because every valid token has the same width.
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
    /// Hides the token from debug output. Logs can expose their contents.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AuthToken(<redacted>)")
    }
}

/// Builds the command line and environment for a spawned child. Flatpak
/// receives toolkit variables as `--env=` arguments after `run`. Display
/// variables also go to the launcher's environment so it can bind
/// the corresponding sandbox APIs.
pub(crate) fn build_plan(request: &SpawnRequest<'_>, token: &AuthToken) -> SpawnPlan {
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

    // Request values are applied last
    // and override lunette's default toolkit hints.
    let mut env = env;
    env.extend(request.env.iter().cloned());

    SpawnPlan {
        argv,
        env,
        cwd: request.cwd.map(Path::to_path_buf),
    }
}

/// Returns non-empty display variables for a spawned child. An empty
/// `WAYLAND_DISPLAY` or `DISPLAY` is omitted, so the child inherits
/// any existing value and does not try to use an empty socket or display name.
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

/// Returns the authentication token and toolkit defaults that select
/// Wayland backends first. Display variables are added separately,
/// so empty values can be omitted without overriding the inherited environment.
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

/// Decodes an even-length hexadecimal byte string. Odd lengths and non-hex
/// bytes are rejected without panicking. Empty input decodes
/// to an empty byte string.
pub(crate) fn decode_hex(encoded: &[u8]) -> Option<Vec<u8>> {
    if !encoded.len().is_multiple_of(2) {
        return None;
    }

    let (pairs, _) = encoded.as_chunks::<2>();
    pairs
        .iter()
        .map(|&[hi, lo]| {
            let high = (hi as char).to_digit(16)?;
            let low = (lo as char).to_digit(16)?;
            u8::try_from(high * 16 + low).ok()
        })
        .collect()
}
