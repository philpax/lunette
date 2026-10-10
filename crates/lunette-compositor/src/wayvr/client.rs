//! Adapted from WayVR's `backend/wayvr/client.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a, with `WaylandEnv` from
//! `backend/wayvr/mod.rs`.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Linux-only: owns the Wayland listening socket and the optional
//! xwayland-satellite child.
//!
//! The listener, the client list, the attribution of a connecting client, the
//! satellite, and the input methods a seat's commands run.
//!
//! lunette's event loop owns the display and the listening socket, and the
//! compositor state owns the clients, so `accept_connection`, `add_client`,
//! and `cleanup_clients` are methods of the state, and a connection is
//! accepted when the loop reports it rather than polled on each tick.
//! [`listen`] returns the display name and writes neither the environment nor
//! `wayvr.disp`; the application entry point exports the name. lunette serves
//! several seats, so [`WayVRCompositor`] is one seat's view of the state, and
//! upstream's input methods run against it. The satellite runs behind the
//! process-spawning seam, in a process group that is stopped and reaped when
//! it drops, which replaces upstream's `Drop` for the compositor. The
//! compositor clock replaces the wall clock for timestamps. Upstream's
//! `release_all_keys`, `send_pointer_axis_wheel_accumulated`, and
//! `cleanup_handles` are left out, because no lunette command needs them.

use std::{
    error::Error,
    ffi::{OsStr, OsString},
    fmt, io,
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::Arc,
};

use glam::{DVec2, Vec2};
use smithay::{
    backend::input::{Axis, AxisSource, ButtonState, Keycode},
    input::{
        keyboard::KeyboardHandle,
        pointer::{AxisFrame, ButtonEvent, MotionEvent, PointerHandle, RelativeMotionEvent},
    },
    reexports::wayland_server::{self, BindError, protocol::wl_surface::WlSurface},
    utils::{Logical, Point, SerialCounter},
    wayland::socket::ListeningSocketSource,
};
use tracing as log;

use crate::{
    commands::KeymapUploadError,
    protocol::{Argv, KeymapText, Pid, PointerButton, ProcessId},
    spawn::{self, ChildProcess, DisplayEnvironment, ProcessSpawner, SpawnPlan},
    thread::LoopData,
    wayvr::process::find_by_pid,
};

use super::comp::{self, ClientState};

pub(crate) struct WayVRClient {
    pub client: wayland_server::Client,
    pub process: ProcessId,
}

/// One seat's view of the compositor state, which the input methods run
/// against.
///
/// Upstream's `WayVRCompositor` owns the state and serves one seat. lunette
/// serves several, so this borrows the state and holds the handles of the
/// seat a command names.
pub(crate) struct WayVRCompositor<'a> {
    pub state: &'a mut comp::Application,
    pub seat_keyboard: KeyboardHandle<comp::Application>,
    pub seat_pointer: PointerHandle<comp::Application>,
    pub serial_counter: &'static SerialCounter,
    /// The compositor clock when the view was taken, as a wrapping Wayland
    /// millisecond timestamp.
    pub millis: u32,
    /// The compositor clock when the view was taken, in microseconds.
    pub micros: u64,
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
            log::debug!("no xwayland-satellite was configured; x11 clients will not be served");
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
                log::info!(x11 = %wayland_env.display_num_string(), "started xwayland-satellite");
                Self { child: Some(child) }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                log::debug!(
                    executable = %satellite.executable.display(),
                    "optional xwayland-satellite is unavailable; serving wayland clients only"
                );
                Self::default()
            }
            Err(error) => {
                log::warn!(
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
            log::warn!(
                ?outcome,
                "xwayland-satellite stopped; x11 applications will not work"
            );
            self.child = None;
        }
    }
}

/// Inserts an accepted client and attributes it to a managed or external process.
///
/// Attribution runs before the client's initial `wl_registry` dispatch. If
/// insertion fails, the stream is dropped because no protocol object exists for
/// an error response.
pub(crate) fn accept(data: &mut LoopData, stream: UnixStream) {
    if let Err(e) = data.state.accept_connection(stream) {
        log::error!("Failed to accept connection: {e}");
    }
}

impl comp::Application {
    pub fn add_client(&mut self, client: WayVRClient) {
        self.clients.push(client);
    }

    /// The disconnect callback records only a flag, so each new connection
    /// sweeps the clients disconnected since the previous one.
    pub fn cleanup_clients(&mut self) {
        self.clients.retain(|client| {
            let Some(data) = client.client.get_data::<ClientState>() else {
                return false;
            };

            if *data.disconnected.lock().unwrap() {
                return false;
            }

            true
        });
    }

    /// Inserts a client and attributes it to a process. The connecting PID is
    /// matched first, then the authentication token in the client's
    /// environment, and a client that matches neither is adopted as external.
    ///
    /// Attribution runs before the client's initial `wl_registry` dispatch, so
    /// its first advertisement sees the output assigned to its process.
    ///
    /// # Errors
    ///
    /// Returns the I/O error when the display cannot insert the client.
    pub(crate) fn accept_connection(
        &mut self,
        stream: UnixStream,
    ) -> io::Result<wayland_server::Client> {
        let client = self
            .display_handle
            .insert_client(stream, Arc::new(comp::ClientState::default()))?;

        let credentials = match client.get_credentials(&self.display_handle) {
            Ok(credentials) => credentials,
            Err(error) => {
                log::warn!(%error, "could not read a connecting client's credentials");
                return Ok(client);
            }
        };
        let Some(pid) = Pid::new(credentials.pid) else {
            log::warn!("a client connected with an impossible process id; not attributing it");
            return Ok(client);
        };

        // Find suitable auth key from the process list
        let found = find_by_pid(&self.processes, pid, self.inspector.as_ref())
            .and_then(|handle| self.processes.get(handle));
        let process = if let Some(process) = found {
            log::debug!(%pid, process = %process.id(), "attributed a client to a known process");
            process.id()
        } else {
            // This is a new process which we didn't meet before.
            // Treat external processes exclusively (spawned by the user or external program)
            let process =
                spawn::add_external_process(&mut self.processes, &mut self.adopted_ids, pid);
            log::info!(
                %pid,
                %process,
                "a process lunette did not start connected to its socket; adopting it"
            );
            process
        };

        if let Some(state) = client.get_data::<ClientState>() {
            state.assign(self.assignments.get(&process).copied());
        }

        self.cleanup_clients();
        self.add_client(WayVRClient {
            client: client.clone(),
            process,
        });
        self.touch();
        self.watch_processes();
        Ok(client)
    }
}

#[expect(
    clippy::needless_borrow,
    reason = "upstream owns the state where lunette borrows it; keeping `&mut self.state` keeps upstream's text"
)]
impl WayVRCompositor<'_> {
    pub fn send_key(&mut self, virtual_key: u32, down: bool) {
        let state = if down {
            smithay::backend::input::KeyState::Pressed
        } else {
            smithay::backend::input::KeyState::Released
        };

        self.seat_keyboard.input::<(), _>(
            &mut self.state,
            Keycode::new(virtual_key),
            state,
            self.serial_counter.next_serial(),
            self.millis,
            |_, _, _| smithay::input::keyboard::FilterResult::Forward,
        );
    }

    pub fn set_keymap(&mut self, keymap: &KeymapText) -> Result<(), KeymapUploadError> {
        // Smithay only accepts keymaps in a string form due to thread safety concerns
        self.seat_keyboard
            .set_keymap_from_string(
                &mut self.state,
                keymap.as_str().to_owned(),
            )
            .map_err(|error| KeymapUploadError::Refused {
                message: error.to_string(),
            })
    }

    pub fn send_mouse_move(
        &mut self,
        focus: Option<(WlSurface, Vec2)>,
        global_pos: DVec2,
        delta: DVec2,
        delta_unaccel: DVec2,
    ) {
        let location: Point<f64, Logical> = (global_pos.x, global_pos.y).into();
        let delta: Point<f64, Logical> = (delta.x, delta.y).into();
        let delta_unaccel: Point<f64, Logical> = (delta_unaccel.x, delta_unaccel.y).into();

        let focus = focus.map(|(surface, origin)| {
            let focus_location: Point<f64, Logical> = (origin.x as f64, origin.y as f64).into();

            (surface, focus_location)
        });

        self.seat_pointer.motion(
            &mut self.state,
            focus.clone(),
            &MotionEvent {
                location,
                serial: self.serial_counter.next_serial(),
                time: self.millis,
            },
        );
        self.seat_pointer.relative_motion(
            &mut self.state,
            focus,
            &RelativeMotionEvent {
                delta,
                delta_unaccel,
                utime: self.micros,
            },
        );

        self.seat_pointer.frame(&mut self.state);
    }

    pub fn send_pointer_button(&mut self, index: PointerButton, pressed: bool) {
        let state = if pressed {
            ButtonState::Pressed
        } else {
            ButtonState::Released
        };

        let serial = self.serial_counter.next_serial();
        let time = self.millis;
        let button = match index {
            PointerButton::Left => 0x110,
            PointerButton::Middle => 0x112,
            PointerButton::Right => 0x111,
            PointerButton::Back => 0x113,
            PointerButton::Forward => 0x114,
        };

        self.seat_pointer.button(
            &mut self.state,
            &ButtonEvent {
                serial,
                time,
                button,
                state,
            },
        );

        self.seat_pointer.frame(&mut self.state);
    }

    pub fn send_pointer_axis_wheel_raw(&mut self, delta: WheelDelta) {
        // 15 logical axis units for one wheel detent of 120 v120 units
        const AXIS_VALUE_PER_DETENT: f64 = 15.0;

        let time = self.millis;

        let v120_x = delta.x;
        let v120_y = delta.y;

        if v120_x == 0 && v120_y == 0 {
            return;
        }

        let mut frame = AxisFrame::new(time).source(AxisSource::Wheel);

        if v120_x != 0 {
            frame = frame
                .value(
                    Axis::Horizontal,
                    f64::from(v120_x) / 120.0 * AXIS_VALUE_PER_DETENT,
                )
                .v120(Axis::Horizontal, v120_x);
        }

        if v120_y != 0 {
            frame = frame
                .value(
                    Axis::Vertical,
                    f64::from(v120_y) / 120.0 * AXIS_VALUE_PER_DETENT,
                )
                .v120(Axis::Vertical, v120_y);
        }

        self.seat_pointer.axis(&mut self.state, frame);
        self.seat_pointer.frame(&mut self.state);
    }
}

const STARTING_WAYLAND_ADDR_IDX: u32 = 20;

fn create_wayland_listener() -> Result<(WaylandEnv, ListeningSocketSource), ListenError> {
    let mut env = WaylandEnv {
        display_num: STARTING_WAYLAND_ADDR_IDX,
    };

    let listener = loop {
        let display_str = env.wayland_display_num_string();
        log::debug!("Trying to open socket \"{display_str}\"");
        match ListeningSocketSource::with_name(display_str.as_str()) {
            Ok(listener) => {
                log::debug!("Listening to {display_str}");
                break listener;
            }
            Err(e) => {
                log::debug!(
                    "Failed to open socket \"{display_str}\" (reason: {e}), trying next..."
                );

                env.display_num += 1;
                if env.display_num > STARTING_WAYLAND_ADDR_IDX + 20 {
                    // Highly unlikely for the user to have 20 Wayland displays enabled at once. Return error instead.
                    return Err(ListenError { cause: e });
                }
            }
        }
    };

    Ok((env, listener))
}

/// Runs executable from APPDIR, falling back to PATH
///
/// The entry point supplies `APPDIR`, so this module does not read the process
/// environment. An empty `APPDIR` is not a bundle.
#[must_use]
pub fn bundled_executable(name: impl AsRef<std::path::Path>, appdir: Option<&OsStr>) -> PathBuf {
    match appdir.filter(|appdir| !appdir.is_empty()) {
        Some(appdir) => PathBuf::from(appdir).join("usr").join("bin").join(name),
        None => PathBuf::from(name.as_ref()),
    }
}

/// A wheel movement on each axis, in `wl_pointer.axis_value120` units, where
/// one detent is 120.
///
/// Upstream's `hid::WheelDelta` carries the same values as `f32`.
pub(crate) struct WheelDelta {
    pub x: i32,
    pub y: i32,
}

/// The display a bound socket serves, as a number shared by the Wayland and
/// X11 names.
///
/// The number matches between the two names, but they belong to separate
/// namespaces.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct WaylandEnv {
    pub(crate) display_num: u32,
}

impl WaylandEnv {
    pub fn wayland_display_num_string(&self) -> String {
        // e.g. "wayland-20"
        format!("wayland-{}", self.display_num)
    }
    pub fn display_num_string(&self) -> String {
        // e.g. ":20"
        format!(":{}", self.display_num)
    }

    /// Returns the display names that lunette passes to a spawned client.
    #[must_use]
    pub fn environment(self) -> DisplayEnvironment {
        DisplayEnvironment {
            wayland_display: OsString::from(self.wayland_display_num_string()),
            x11_display: OsString::from(self.display_num_string()),
        }
    }
}

#[cfg(any(test, feature = "test-fakes"))]
impl WaylandEnv {
    /// Constructs a deterministic display name without binding a socket.
    #[must_use]
    pub fn for_test(display_num: u32) -> Self {
        Self { display_num }
    }
}

/// Binds the first available display socket and returns its event source and name.
///
/// The application calls this before starting the compositor thread. It exports
/// the returned name after preserving the host display name.
///
/// # Errors
///
/// Returns [`ListenError`] when every candidate socket cannot be bound.
pub fn listen() -> Result<(WaylandSocket, WaylandEnv), ListenError> {
    let (wayland_env, listener) = create_wayland_listener()?;
    Ok((WaylandSocket { source: listener }, wayland_env))
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

/// Every candidate display socket was taken.
#[derive(Debug)]
pub struct ListenError {
    /// The final bind failure, which preserves the underlying cause for error chaining.
    cause: BindError,
}

impl fmt::Display for ListenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "compositor: could not bind a wayland socket; wayland-{} through wayland-{} are all \
             taken",
            STARTING_WAYLAND_ADDR_IDX,
            STARTING_WAYLAND_ADDR_IDX + 20
        )
    }
}

impl Error for ListenError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.cause)
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
    fn a_display_name_has_both_forms() {
        let name = display();

        assert_eq!(name.wayland_display_num_string(), "wayland-20");
        assert_eq!(name.display_num_string(), ":20");
        assert_eq!(name.environment().wayland_display, OsStr::new("wayland-20"));
        assert_eq!(name.environment().x11_display, OsStr::new(":20"));
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
