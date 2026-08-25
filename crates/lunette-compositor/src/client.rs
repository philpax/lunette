//! Linux-only: owns the Wayland listening socket and the optional
//! xwayland-satellite child.
//!
//! The listener setup, display-name formatting, client insertion,
//! xwayland-satellite startup, and bundled executable lookup adapt WayVR's
//! `backend/wayvr/client.rs` and `backend/wayvr/mod.rs` at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb. Lunette adds typed process
//! attribution and injectable process creation around those parts.
//!
//! The application entry point calls [`listen`] before starting the compositor
//! thread, then exports the returned name after saving the host's
//! `WAYLAND_DISPLAY` while the process is single-threaded. This module returns
//! the name but does not access the process environment.
//!
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.

use std::{
    error::Error,
    ffi::{OsStr, OsString},
    fmt,
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    sync::Arc,
};

use smithay::{reexports::wayland_server::BindError, wayland::socket::ListeningSocketSource};
use tracing::{debug, info, warn};

use crate::{
    process::{ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnPlan},
    protocol::Argv,
    state::ClientState,
    thread::LoopData,
};

/// The first display number, matching WayVR's listener setup.
const FIRST_DISPLAY: u32 = 20;

const DISPLAY_ATTEMPTS: u32 = 21;

/// Binds the first available display socket and returns its event source and name.
///
/// The application calls this before starting the compositor thread. It exports
/// the returned name after preserving the host display name.
///
/// # Errors
///
/// Returns [`ListenError`] when every candidate socket cannot be bound.
pub fn listen() -> Result<(WaylandSocket, DisplayName), ListenError> {
    let mut last = None;

    for number in FIRST_DISPLAY..FIRST_DISPLAY + DISPLAY_ATTEMPTS {
        let name = DisplayName { number };
        let socket = name.wayland();
        let socket = socket.to_string_lossy();

        match ListeningSocketSource::with_name(&socket) {
            Ok(source) => {
                info!(%socket, "listening for wayland clients");
                return Ok((WaylandSocket { source }, name));
            }
            Err(error) => {
                debug!(%socket, %error, "that display number is taken; trying the next");
                last = Some(error);
            }
        }
    }

    Err(ListenError {
        first: FIRST_DISPLAY,
        attempts: DISPLAY_ATTEMPTS,
        cause: last,
    })
}

/// A bound listening socket source owned by the compositor thread.
///
/// The source is moved into that thread because calloop's event loop is not
/// `Send`.
pub struct WaylandSocket {
    pub(crate) source: ListeningSocketSource,
}

impl fmt::Debug for WaylandSocket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WaylandSocket")
            .field("name", &self.source.socket_name())
            .finish()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DisplayName {
    number: u32,
}

impl DisplayName {
    /// Returns the Wayland socket name, such as `wayland-20`.
    #[must_use]
    pub fn wayland(self) -> OsString {
        OsString::from(format!("wayland-{}", self.number))
    }

    /// Returns the X11 display name, such as `:20`.
    ///
    /// The number matches the Wayland name, but the two names belong to separate
    /// namespaces.
    #[must_use]
    pub fn x11(self) -> OsString {
        OsString::from(format!(":{}", self.number))
    }

    /// Returns the display names that lunette passes to a spawned client.
    #[must_use]
    pub fn environment(self) -> DisplayEnvironment {
        DisplayEnvironment {
            wayland_display: self.wayland(),
            x11_display: self.x11(),
        }
    }
}

#[cfg(any(test, feature = "test-fakes"))]
impl DisplayName {
    /// Constructs a deterministic display name without binding a socket.
    #[must_use]
    pub fn for_test(number: u32) -> Self {
        Self { number }
    }
}

impl fmt::Display for DisplayName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "wayland-{}", self.number)
    }
}

#[derive(Debug)]
pub struct ListenError {
    first: u32,
    attempts: u32,
    /// The final bind failure, which preserves the underlying cause for error chaining.
    cause: Option<BindError>,
}

impl fmt::Display for ListenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "compositor: could not bind a wayland socket; wayland-{} through wayland-{} are all \
             taken",
            self.first,
            self.first + self.attempts - 1
        )
    }
}

impl Error for ListenError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        self.cause
            .as_ref()
            .map(|cause| cause as &(dyn Error + 'static))
    }
}

/// Inserts an accepted client and attributes it to a managed or external process.
///
/// Attribution runs before the client's initial `wl_registry` dispatch. If
/// insertion fails, the stream is dropped because no protocol object exists for
/// an error response.
pub(crate) fn accept(data: &mut LoopData, stream: UnixStream) {
    let client = data
        .display
        .handle()
        .insert_client(stream, Arc::new(ClientState::default()));

    match client {
        Ok(client) => data.state.attach_client(&client),
        Err(error) => warn!(%error, "could not accept a client connection"),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XwaylandSatellite {
    pub executable: PathBuf,
}

impl XwaylandSatellite {
    /// Resolves the usual executable name from the optional AppImage root.
    #[must_use]
    pub fn resolve(appdir: Option<&OsStr>) -> Self {
        Self {
            executable: bundled_executable("xwayland-satellite", appdir),
        }
    }
}

/// Resolves an executable from an AppImage root or falls back to `PATH`.
///
/// This helper adapts WayVR's `bundled_executable`. The entry point supplies
/// `APPDIR` so this module does not read the process environment and the lookup
/// remains directly testable.
#[must_use]
pub fn bundled_executable(name: &str, appdir: Option<&OsStr>) -> PathBuf {
    match appdir.filter(|appdir| !appdir.is_empty()) {
        Some(appdir) => Path::new(appdir).join("usr").join("bin").join(name),
        None => PathBuf::from(name),
    }
}

/// Owns the optional xwayland-satellite process.
///
/// Startup is best-effort, as in WayVR's satellite setup. A spawn failure logs a
/// warning and leaves Wayland clients available without X11 support.
#[derive(Default)]
pub(crate) struct Satellite {
    /// The child handle terminates and reaps the process group on drop, including
    /// any `Xwayland` process the bridge started.
    child: Option<Box<dyn ChildProcess>>,
}

impl fmt::Debug for Satellite {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Satellite")
            .field("running", &self.child.is_some())
            .finish()
    }
}

impl Satellite {
    /// Starts the bridge when configured.
    ///
    /// The compositor advertises `wl_compositor`, `wl_output`, `xdg_shell`, and
    /// `wp_viewporter` before this call. The bridge receives the X11 display as
    /// its positional argument and lunette's Wayland name in its environment.
    pub(crate) fn start(
        spawner: &mut dyn ProcessSpawner,
        satellite: Option<&XwaylandSatellite>,
        name: DisplayName,
    ) -> Self {
        let Some(satellite) = satellite else {
            debug!("no xwayland-satellite was configured; x11 clients will not be served");
            return Self::default();
        };

        let plan = SpawnPlan {
            argv: Argv::new(satellite.executable.clone(), vec![name.x11()]),
            env: vec![(OsString::from("WAYLAND_DISPLAY"), name.wayland())],
            cwd: None,
        };

        match spawner.spawn(&plan) {
            Ok(child) => {
                info!(x11 = %name.x11().to_string_lossy(), "started xwayland-satellite");
                Self { child: Some(child) }
            }
            Err(error) => {
                warn!(
                    %error,
                    "could not start xwayland-satellite; x11 applications will not work"
                );
                Self::default()
            }
        }
    }

    pub(crate) fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// Polls the unregistered bridge and drops its handle after it exits.
    ///
    /// The process registry does not wait for this child or report its outcome to
    /// Lua. Polling here reaps it and removes the handle so its exit is logged
    /// once.
    pub(crate) fn poll(&mut self) {
        let Some(child) = self.child.as_mut() else {
            return;
        };
        if let Some(outcome) = child.poll() {
            warn!(
                ?outcome,
                "xwayland-satellite stopped; x11 applications will not work"
            );
            self.child = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::testing::FakeSpawner;

    fn display() -> DisplayName {
        DisplayName { number: 20 }
    }

    #[test]
    fn a_display_name_has_both_forms() {
        let name = display();

        assert_eq!(name.wayland(), OsStr::new("wayland-20"));
        assert_eq!(name.x11(), OsStr::new(":20"));
        assert_eq!(name.environment().wayland_display, name.wayland());
        assert_eq!(name.environment().x11_display, name.x11());
    }

    #[test]
    fn an_executable_is_taken_from_the_bundle_when_there_is_one() {
        assert_eq!(
            bundled_executable("xwayland-satellite", Some(OsStr::new("/tmp/appimage"))),
            PathBuf::from("/tmp/appimage/usr/bin/xwayland-satellite")
        );
    }

    #[test]
    fn an_executable_falls_back_to_the_path_without_a_bundle() {
        assert_eq!(
            bundled_executable("xwayland-satellite", None),
            PathBuf::from("xwayland-satellite")
        );
        assert_eq!(
            bundled_executable("xwayland-satellite", Some(OsStr::new(""))),
            PathBuf::from("xwayland-satellite"),
            "an empty APPDIR is not a bundle, and joining it would produce /usr/bin"
        );
    }

    #[test]
    fn the_bridge_is_started_with_the_display_on_both_sides() {
        let mut spawner = FakeSpawner::default();
        let satellite = XwaylandSatellite {
            executable: PathBuf::from("xwayland-satellite"),
        };

        let bridge = Satellite::start(&mut spawner, Some(&satellite), display());

        let requested = spawner.log.requested();
        assert_eq!(requested.len(), 1, "the bridge is started exactly once");
        assert_eq!(
            requested[0].argv.program(),
            OsStr::new("xwayland-satellite")
        );
        assert_eq!(
            requested[0].argv.arguments(),
            [OsString::from(":20")],
            "the X display number is positional"
        );
        assert_eq!(
            requested[0].env,
            [(
                OsString::from("WAYLAND_DISPLAY"),
                OsString::from("wayland-20")
            )],
            "the bridge is itself a wayland client of lunette"
        );
        assert!(bridge.child.is_some());
    }

    #[test]
    fn nothing_is_started_when_no_bridge_is_configured() {
        let mut spawner = FakeSpawner::default();

        let bridge = Satellite::start(&mut spawner, None, display());

        assert!(spawner.log.requested().is_empty());
        assert!(bridge.child.is_none());
    }

    #[test]
    fn a_bridge_that_will_not_start_is_a_warning_rather_than_a_failure() {
        let mut spawner = FakeSpawner::default();
        spawner.log.refuse("no such file or directory");
        let satellite = XwaylandSatellite {
            executable: PathBuf::from("xwayland-satellite"),
        };

        let bridge = Satellite::start(&mut spawner, Some(&satellite), display());

        assert!(
            bridge.child.is_none(),
            "the compositor carries on without an x11 bridge"
        );
    }
}
