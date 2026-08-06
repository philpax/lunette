//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/client.rs and backend/wayvr/mod.rs (`WaylandEnv` at :95-108), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The listening socket clients connect to, and the X11 bridge beside it.
//!
//! # The socket is bound before the compositor thread starts
//!
//! [`listen`] is called from the entry point, on the main thread, and the
//! source it returns is moved into the compositor thread's closure. That
//! ordering is not incidental: the display name has to exist before the thread
//! does, because the entry point is the only place that may export it.
//!
//! # Why `WAYLAND_DISPLAY` is not exported here
//!
//! [`listen`] returns the name. It does not put it in the environment, and the
//! obvious-looking line that would do so next to the `bind` call is wrong for
//! two reasons.
//!
//! The first is the house rule: environment access belongs to the application
//! entry point, and a library that writes the environment cannot be tested
//! without manipulating it.
//!
//! The second is the one that is invisible from here. In Rust 2024
//! `std::env::set_var` is `unsafe`, and it is unsound once any other thread
//! exists — a concurrent `getenv` anywhere in the process, including inside a
//! C library, reads a pointer the write may free. By the time lunette has a
//! compositor at all, LÖVR and GLFW have booted and spawned threads, because
//! the compositor needs the graphics device they created. So "before any other
//! thread could be reading" is not a condition that can be satisfied at this
//! point in the program, and there is no safe ordering available here.
//!
//! The entry point exports it before any of that happens, and hands the name
//! down. `crates/lunette/src/main.rs` carries the other half of this note.
//!
//! WayVR does not export it either — it writes the display number to
//! `$XDG_RUNTIME_DIR/wayvr.disp` for external tooling (`client.rs:415-421`).
//! Lunette does not write that file: the design gives `lunctl` the job of
//! telling external tooling where lunette is, and a file in a well-known place
//! is a second answer to the same question.

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

/// The first display number lunette tries.
///
/// Twenty, as WayVR uses (`client.rs:413`), so lunette's socket does not
/// collide with the session compositor's `wayland-0` or `wayland-1`.
const FIRST_DISPLAY: u32 = 20;

/// How many display numbers are tried before giving up.
///
/// A machine with twenty-one Wayland compositors already running is not a
/// machine with a free socket a few more attempts would find; it is a machine
/// with something wrong with it, and an error says so.
const DISPLAY_ATTEMPTS: u32 = 21;

/// Binds a listening socket on the first free display number.
///
/// Returns the source to hand to the compositor thread and the name the entry
/// point exports. Called from the main thread, before the compositor thread
/// exists.
///
/// # Errors
///
/// Returns [`ListenError`] when every candidate name is taken, or when the
/// runtime directory cannot be written to at all.
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

/// A bound listening socket, waiting to be watched.
///
/// Owning the source rather than the raw socket means the compositor thread
/// inserts it and nothing else has to know how. It is moved into the thread
/// because `calloop`'s event loop is not `Send` and cannot come the other way.
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

/// Which display lunette is, in the two forms a client needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DisplayName {
    number: u32,
}

impl DisplayName {
    /// The value of `WAYLAND_DISPLAY`, such as `wayland-20`.
    #[must_use]
    pub fn wayland(self) -> OsString {
        OsString::from(format!("wayland-{}", self.number))
    }

    /// The value of `DISPLAY`, such as `:20`.
    ///
    /// The same number as the Wayland socket, as WayVR does (`mod.rs:104-107`).
    /// The two namespaces are unrelated, so reusing the number is a convenience
    /// rather than a requirement; it makes the pair legible in a log line.
    #[must_use]
    pub fn x11(self) -> OsString {
        OsString::from(format!(":{}", self.number))
    }

    /// Both forms, as a spawned client is told them.
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
    /// A display name for a test, which has bound no socket to get one from.
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

/// Why no listening socket could be bound.
#[derive(Debug)]
pub struct ListenError {
    first: u32,
    attempts: u32,
    /// The last bind failure, absent only if no attempt was made.
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

/// Accepts one connection and attributes it.
///
/// Every client goes through this, whether lunette started it or not, and the
/// attribution is what decides which. A client whose stream cannot be inserted
/// is dropped: there is nothing to tell, because there is no protocol object to
/// tell it with.
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

/// Where to find xwayland-satellite.
///
/// The path arrives as a value because resolving it reads `APPDIR`, and reading
/// the environment belongs to the entry point. [`bundled_executable`] is the
/// resolution itself, so the entry point does not have to reimplement WayVR's
/// rule.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XwaylandSatellite {
    pub executable: PathBuf,
}

impl XwaylandSatellite {
    /// The usual name, on `PATH` or under an AppImage's `APPDIR`.
    #[must_use]
    pub fn resolve(appdir: Option<&OsStr>) -> Self {
        Self {
            executable: bundled_executable("xwayland-satellite", appdir),
        }
    }
}

/// Resolves a bundled executable, preferring an AppImage's own copy.
///
/// Ported from `bundled_executable` (`client.rs:472-478`). `APPDIR` is set by
/// the AppImage runtime, and a bundle that ships its own satellite must use
/// that one rather than whatever the host happens to have on `PATH`.
///
/// The value is a parameter rather than a `std::env::var` call, so this is a
/// pure function and the rule it implements is testable.
#[must_use]
pub fn bundled_executable(name: &str, appdir: Option<&OsStr>) -> PathBuf {
    match appdir.filter(|appdir| !appdir.is_empty()) {
        Some(appdir) => Path::new(appdir).join("usr").join("bin").join(name),
        None => PathBuf::from(name),
    }
}

/// The X11 bridge, started once and stopped when lunette stops.
///
/// Best-effort, as WayVR's is (`client.rs:101-108`): a failure to start it is a
/// warning and construction continues, because a session with no X11 support is
/// worth having and a session that refuses to start is not.
#[derive(Default)]
pub(crate) struct Satellite {
    /// Dropping the child asks its process group to stop, which is how the
    /// bridge is reaped. WayVR sends `SIGKILL` and waits (`client.rs:55-65`);
    /// lunette's child handle terminates the group, which also takes the
    /// `Xwayland` process satellite itself started.
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
    /// Starts the bridge, if the caller asked for one.
    ///
    /// Satellite needs `wp_viewporter` from the compositor and refuses to start
    /// without it, along with `wl_compositor`, `wl_output`, and `xdg_shell`. All
    /// four are advertised before this runs.
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
            // The X display number is positional, as satellite takes it.
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
