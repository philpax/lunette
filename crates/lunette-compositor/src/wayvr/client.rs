//! Adapted from WayVR's `backend/wayvr/client.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The client list, the attribution of a connecting client, the choice of
//! display socket, and the input methods a seat's commands run.
//!
//! lunette's event loop owns the display and the listening socket, and the
//! compositor state owns the clients, so `accept_connection`, `add_client`,
//! and `cleanup_clients` are methods of the state, and `crate::listener`
//! accepts a connection when the loop reports it rather than polling on each
//! tick. The listener writes neither the environment nor `wayvr.disp`.
//! lunette serves several seats, so [`WayVRCompositor`] is one seat's view of
//! the state, and upstream's input methods run against it. `crate::satellite`
//! starts and stops xwayland-satellite, which replaces upstream's spawn in
//! `new` and its `Drop` for the compositor. The compositor clock replaces the
//! wall clock for timestamps. Upstream's `release_all_keys`,
//! `send_pointer_axis_wheel_accumulated`, and `cleanup_handles` are left out,
//! because no lunette command needs them.

use std::{
    ffi::OsStr,
    io,
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
    reexports::wayland_server::{self, protocol::wl_surface::WlSurface},
    utils::{Logical, Point, SerialCounter},
    wayland::socket::ListeningSocketSource,
};
use tracing as log;

use crate::{
    commands::KeymapUploadError,
    listener::ListenError,
    protocol::{KeymapText, Pid, PointerButton, ProcessId},
    spawn,
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

    pub fn send_pointer_axis_wheel_raw(&mut self, delta: super::WheelDelta) {
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

pub(crate) const STARTING_WAYLAND_ADDR_IDX: u32 = 20;

pub(crate) fn create_wayland_listener() -> Result<(super::WaylandEnv, ListeningSocketSource), ListenError>
{
    let mut env = super::WaylandEnv {
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
