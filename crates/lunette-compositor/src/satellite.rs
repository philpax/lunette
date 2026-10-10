//! Linux-only: runs xwayland-satellite in its own process group.
//!
//! The optional X11 bridge. WayVR spawns xwayland-satellite in
//! `WayVRCompositor::new` and kills it in the compositor's `Drop`. lunette
//! starts it from the state's constructor behind the process-spawning seam, in
//! a process group that is stopped and reaped when the handle drops, and
//! polls it with the spawned processes.

use std::{
    ffi::{OsStr, OsString},
    fmt, io,
    path::PathBuf,
};

use tracing::{debug, info, warn};

use crate::{
    protocol::Argv,
    spawn::{ChildProcess, ProcessSpawner, SpawnPlan},
    wayvr::{WaylandEnv, client::bundled_executable},
};

/// Where to find xwayland-satellite.
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

/// Owns the optional xwayland-satellite process.
///
/// Startup is best-effort. A missing executable is normal optional absence;
/// other spawn failures warn. Wayland clients remain available in either case.
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
        wayland_env: WaylandEnv,
    ) -> Self {
        let Some(satellite) = satellite else {
            debug!("no xwayland-satellite was configured; x11 clients will not be served");
            return Self::default();
        };

        let plan = SpawnPlan {
            argv: Argv::new(
                satellite.executable.clone(),
                vec![OsString::from(wayland_env.display_num_string())],
            ),
            env: vec![(
                OsString::from("WAYLAND_DISPLAY"),
                OsString::from(wayland_env.wayland_display_num_string()),
            )],
            cwd: None,
        };

        match spawner.spawn(&plan) {
            Ok(child) => {
                info!(x11 = %wayland_env.display_num_string(), "started xwayland-satellite");
                Self { child: Some(child) }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                debug!(
                    executable = %satellite.executable.display(),
                    "optional xwayland-satellite is unavailable; serving wayland clients only"
                );
                Self::default()
            }
            Err(error) => {
                warn!(
                    %error,
                    "could not start xwayland-satellite; check its installation and permissions; serving wayland clients only"
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
    /// The process table does not wait for this child or report its outcome to
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
    use std::{
        io,
        sync::{Arc, Mutex},
    };

    use pretty_assertions::assert_eq;
    use tracing::{
        Event, Level, Metadata, Subscriber,
        span::{Attributes, Id, Record},
    };

    use super::*;
    use crate::{spawn::SpawnError, testing::FakeSpawner};

    #[derive(Clone, Default)]
    struct Events(Arc<Mutex<Vec<Level>>>);

    impl Subscriber for Events {
        fn enabled(&self, _: &Metadata<'_>) -> bool {
            true
        }
        fn new_span(&self, _: &Attributes<'_>) -> Id {
            Id::from_u64(1)
        }
        fn record(&self, _: &Id, _: &Record<'_>) {}
        fn record_follows_from(&self, _: &Id, _: &Id) {}
        fn event(&self, event: &Event<'_>) {
            self.0
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .push(*event.metadata().level());
        }
        fn enter(&self, _: &Id) {}
        fn exit(&self, _: &Id) {}
    }

    struct RefusingSpawner(io::ErrorKind);

    impl ProcessSpawner for RefusingSpawner {
        fn spawn(&mut self, plan: &SpawnPlan) -> Result<Box<dyn ChildProcess>, SpawnError> {
            Err(SpawnError::for_test(
                plan.argv.program().to_owned(),
                io::Error::new(self.0, "spawn refused"),
            ))
        }
    }

    #[test]
    fn a_missing_optional_bridge_is_not_a_warning() {
        assert_bridge_failure_level(io::ErrorKind::NotFound, Level::DEBUG);
    }

    #[test]
    fn genuine_bridge_failures_still_warn() {
        for kind in [
            io::ErrorKind::PermissionDenied,
            io::ErrorKind::InvalidInput,
            io::ErrorKind::Other,
        ] {
            assert_bridge_failure_level(kind, Level::WARN);
        }
    }

    fn assert_bridge_failure_level(kind: io::ErrorKind, level: Level) {
        let events = Events::default();
        let satellite = XwaylandSatellite::resolve(None);
        let bridge = tracing::subscriber::with_default(events.clone(), || {
            Satellite::start(&mut RefusingSpawner(kind), Some(&satellite), display())
        });
        assert!(!bridge.is_running());
        assert_eq!(
            *events.0.lock().unwrap_or_else(|error| error.into_inner()),
            vec![level]
        );
    }

    fn display() -> WaylandEnv {
        WaylandEnv { display_num: 20 }
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
    fn an_unavailable_bridge_does_not_prevent_wayland_startup() {
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
