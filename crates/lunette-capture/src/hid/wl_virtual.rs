//! Linux-only: speaks `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1`
//! to the host compositor over a Wayland socket.
//!
//! The zero-setup provider, and the second the chain tries. It needs no
//! permission and no kernel module, and its coordinate handling is better than
//! uinput's: `motion_absolute` takes the extent on every call
//! (`wl_virtual.rs:50-56` in WayVR), so nothing has to be recreated when the
//! monitor layout changes.
//!
//! What it costs is portability. Both protocols are wlroots extensions,
//! implemented by sway, Hyprland, wayfire, labwc, dwl, river, and niri. **KWin
//! and mutter implement neither and have no plans to**, which is why uinput is
//! tried first rather than this.
//!
//! # Thread affinity
//!
//! The provider owns a `wayland_client::EventQueue`, and its `commit` is a
//! roundtrip on it. Nothing here may move between threads: a roundtrip from a
//! second thread would interleave with the first thread's dispatch and read
//! events belonging to it. WayVR declares `HidProvider: Sync + Send`
//! (`provider/mod.rs:8`) and is thread-affine anyway; lunette's trait carries no
//! such bound, so the type does not have to lie about it.
//!
//! # Disconnection is ordinary
//!
//! WayVR panics when the host compositor goes away — `.unwrap()` on flush at
//! `wl_virtual.rs:146` and `:176`, and on roundtrip at `:199` and `:204`. A host
//! session ending is a normal event, and it must not abort the process. Every
//! one of those returns [`ProviderError::Disconnected`] here, which
//! [`crate::hid::HostInput`] turns into a degradation to the dummy provider with
//! a logged reason.

use std::{
    ffi::CString,
    fs::File,
    io::{self, Write},
    ops::RangeInclusive,
    os::{
        fd::{AsFd, FromRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::PathBuf,
};

use tracing::debug;
use wayland_client::{
    Connection, Dispatch, EventQueue, Proxy, QueueHandle, delegate_noop,
    globals::{GlobalList, GlobalListContents, registry_queue_init},
    protocol::{
        wl_pointer::{Axis, AxisSource, ButtonState},
        wl_registry::WlRegistry,
        wl_seat::WlSeat,
    },
};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1,
    zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
};

use crate::hid::{
    HidProvider,
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    pointer::{DesktopExtent, DesktopPoint, DesktopVector, PendingPointer, WheelDelta},
    selection::{ProviderError, ProviderKind},
};

/// Where the host compositor's Wayland socket is, and what layout to upload.
///
/// The socket is a path rather than something read from `WAYLAND_DISPLAY` here,
/// because this is a library. The entry point joins `XDG_RUNTIME_DIR` and
/// `WAYLAND_DISPLAY` — or takes an absolute `WAYLAND_DISPLAY` as-is, which the
/// protocol permits — and passes the result in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WlVirtualConfig {
    pub socket: PathBuf,
    /// The layout to upload to the virtual keyboard.
    ///
    /// Required rather than optional. `zwp_virtual_keyboard_v1` treats a `key`
    /// request before a `keymap` request as a protocol error, which disconnects
    /// the client rather than failing the request, so a provider with no keymap
    /// is one that will be killed by the first keystroke.
    pub keymap: XkbKeymap,
}

/// A virtual pointer and keyboard on the host compositor's seat.
pub struct WlVirtualProvider {
    connection: Connection,
    queue: EventQueue<Registry>,
    registry: Registry,
    pointer: ZwlrVirtualPointerV1,
    keyboard: ZwpVirtualKeyboardV1,
    /// The memfd the keymap was written to.
    ///
    /// Held for the compositor's benefit: it maps the descriptor lazily, and a
    /// closed one gives it nothing to map.
    keymap: Option<File>,
    pending: PendingPointer,
    modifiers: KeyModifiers,
    desktop_origin: DesktopPoint,
    desktop_extent: Option<DesktopExtent>,
    /// Accumulated fractional detents, so a slow scroll eventually steps.
    wheel_residue: WheelDelta,
    /// The timestamp of the last request, in the protocol's milliseconds.
    ///
    /// Monotonic and lunette's own rather than the wall clock: WayVR stamps
    /// every request with `SystemTime::now()` (`wl_virtual.rs:253-258`), so a
    /// clock step backwards produces timestamps a compositor may reorder or
    /// discard.
    clock: u32,
}

impl WlVirtualProvider {
    /// Connects to the host compositor and binds the two virtual devices.
    ///
    /// # Errors
    ///
    /// [`ProviderError::Io`] when the socket cannot be reached,
    /// [`ProviderError::MissingInterface`] when the compositor is not one of the
    /// wlroots family, and [`ProviderError::Disconnected`] when the connection
    /// ends during setup.
    pub fn open(config: &WlVirtualConfig) -> Result<Self, ProviderError> {
        let stream = UnixStream::connect(&config.socket).map_err(|source| ProviderError::Io {
            operation: "connect to the host compositor at",
            path: Some(config.socket.clone()),
            source,
        })?;
        let connection =
            Connection::from_socket(stream).map_err(|error| ProviderError::Disconnected {
                detail: error.to_string(),
            })?;

        let (globals, queue) = registry_queue_init::<Registry>(&connection).map_err(|error| {
            ProviderError::Disconnected {
                detail: error.to_string(),
            }
        })?;
        let handle = queue.handle();

        // The virtual pointer takes an optional seat, and the virtual keyboard
        // requires one, so a compositor with no seat at these versions cannot
        // host either device.
        let seat: WlSeat = bind(&globals, &handle, "wl_seat", 4..=9)?;
        let pointer_manager: ZwlrVirtualPointerManagerV1 =
            bind(&globals, &handle, "zwlr_virtual_pointer_manager_v1", 1..=2)?;
        let keyboard_manager: ZwpVirtualKeyboardManagerV1 =
            bind(&globals, &handle, "zwp_virtual_keyboard_manager_v1", 1..=1)?;

        let pointer = pointer_manager.create_virtual_pointer(Some(&seat), &handle, ());
        let keyboard = keyboard_manager.create_virtual_keyboard(&seat, &handle, ());

        let mut provider = Self {
            connection,
            queue,
            registry: Registry,
            pointer,
            keyboard,
            keymap: None,
            pending: PendingPointer::new(),
            modifiers: KeyModifiers::NONE,
            desktop_origin: DesktopPoint::ORIGIN,
            desktop_extent: None,
            wheel_residue: WheelDelta::new(0.0, 0.0),
            clock: 0,
        };
        provider.set_keymap(&config.keymap)?;

        debug!(
            socket = %config.socket.display(),
            "bound a virtual pointer and keyboard on the host compositor",
        );

        Ok(provider)
    }

    /// The next request timestamp, in the protocol's milliseconds.
    ///
    /// The protocol only requires that timestamps do not go backwards, so a
    /// counter satisfies it and cannot be stepped by the system clock.
    fn now(&mut self) -> u32 {
        self.clock = self.clock.wrapping_add(1);
        self.clock
    }

    fn flush(&self) -> Result<(), ProviderError> {
        self.connection
            .flush()
            .map_err(|error| ProviderError::Disconnected {
                detail: error.to_string(),
            })
    }

    fn roundtrip(&mut self) -> Result<(), ProviderError> {
        self.queue
            .roundtrip(&mut self.registry)
            .map(|_| ())
            .map_err(|error| ProviderError::Disconnected {
                detail: error.to_string(),
            })
    }

    /// Sends the modifier mask the compositor should believe is held.
    fn send_modifier_state(&mut self) {
        self.keyboard
            .modifiers(self.modifiers.depressed(), 0, self.modifiers.locked(), 0);
    }
}

impl HidProvider for WlVirtualProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::WlVirtual
    }

    fn mouse_move(&mut self, position: DesktopPoint) {
        self.pending.move_to(position);
    }

    fn mouse_move_rel(&mut self, delta: DesktopVector) {
        let Some(extent) = self.desktop_extent else {
            return;
        };
        self.pending.move_by(delta, self.desktop_origin, extent);
    }

    fn send_button(&mut self, button: PointerButton, down: bool) {
        self.pending.press(button, down);
    }

    fn wheel(&mut self, delta: WheelDelta) {
        self.pending.scroll(delta);
    }

    fn set_desktop_extent(&mut self, extent: DesktopExtent) {
        self.desktop_extent = Some(extent);
    }

    fn set_desktop_origin(&mut self, origin: DesktopPoint) {
        self.desktop_origin = origin;
    }

    fn set_modifiers(&mut self, modifiers: KeyModifiers) -> Result<(), ProviderError> {
        for (key, down) in self.modifiers.changes(modifiers) {
            let time = self.now();
            self.keyboard
                .key(time, u32::from(key.evdev_code()), u32::from(down));
        }
        self.modifiers = modifiers;
        self.send_modifier_state();
        self.flush()
    }

    fn send_key(&mut self, key: VirtualKey, down: bool) -> Result<(), ProviderError> {
        let time = self.now();
        self.keyboard
            .key(time, u32::from(key.evdev_code()), u32::from(down));
        self.flush()
    }

    /// Uploads a layout through a memfd.
    ///
    /// The compositor interprets the keycodes lunette sends under this layout,
    /// which is the one capability uinput does not have: there, the host applies
    /// whatever it is already configured with.
    fn set_keymap(&mut self, keymap: &XkbKeymap) -> Result<(), ProviderError> {
        let bytes = keymap.as_bytes_with_nul();
        let size = u32::try_from(bytes.len()).map_err(|_| ProviderError::Io {
            operation: "upload a keymap larger than four gigabytes",
            path: None,
            source: io::Error::from(io::ErrorKind::InvalidInput),
        })?;
        let file = memfd("lunette-keymap", &bytes)?;
        self.keyboard
            .keymap(KEYMAP_FORMAT_XKB_V1, file.as_fd(), size);
        self.roundtrip()?;
        self.keymap = Some(file);
        Ok(())
    }

    fn commit(&mut self) -> Result<(), ProviderError> {
        let batch = self.pending.take();

        if let Some(position) = batch.position
            && let Some(extent) = self.desktop_extent
        {
            let position = position.clamped(self.desktop_origin, extent);
            let time = self.now();
            self.pointer.motion_absolute(
                time,
                offset(position.x, self.desktop_origin.x),
                offset(position.y, self.desktop_origin.y),
                extent.width().round() as u32,
                extent.height().round() as u32,
            );
            self.pointer.frame();
        }

        if let Some((button, down)) = batch.button {
            let time = self.now();
            self.pointer.button(
                time,
                u32::from(button.evdev_code()),
                if down {
                    ButtonState::Pressed
                } else {
                    ButtonState::Released
                },
            );
            self.pointer.frame();
        }

        if let Some(delta) = batch.wheel {
            self.pointer.axis_source(AxisSource::Wheel);
            // The protocol's vertical axis grows downwards while a wheel's
            // delta is reported growing upwards, so the sign flips here and
            // nowhere else.
            let vertical = -delta.y;
            if vertical != 0.0 {
                let steps = detents(&mut self.wheel_residue.y, vertical);
                let time = self.now();
                self.pointer
                    .axis_discrete(time, Axis::VerticalScroll, vertical, steps);
            }
            if delta.x != 0.0 {
                let steps = detents(&mut self.wheel_residue.x, delta.x);
                let time = self.now();
                self.pointer
                    .axis_discrete(time, Axis::HorizontalScroll, delta.x, steps);
            }
            self.pointer.frame();
        }

        self.roundtrip()
    }
}

/// The `wl_keyboard.keymap_format` value for XKB's version 1 text format.
///
/// Written out rather than taken from `wayland-server`'s enum, which is the only
/// place the wayland crates define it and which this crate has no other reason
/// to depend on. WayVR reaches through smithay for it (`wl_virtual.rs:10`).
const KEYMAP_FORMAT_XKB_V1: u32 = 1;

/// How many logical scroll units make one detent.
///
/// `axis_discrete` reports whole detents alongside the continuous value, and a
/// host that only reads the discrete count scrolls nothing until one accrues.
const UNITS_PER_DETENT: f64 = 10.0;

/// The dispatch target. It handles nothing: neither virtual device sends events,
/// and the registry's are not interesting once the globals have been bound.
struct Registry;

impl Dispatch<WlRegistry, GlobalListContents> for Registry {
    fn event(
        _state: &mut Self,
        _proxy: &WlRegistry,
        _event: <WlRegistry as Proxy>::Event,
        _data: &GlobalListContents,
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
    }
}

delegate_noop!(Registry: ignore WlSeat);
delegate_noop!(Registry: ignore ZwlrVirtualPointerV1);
delegate_noop!(Registry: ignore ZwlrVirtualPointerManagerV1);
delegate_noop!(Registry: ignore ZwpVirtualKeyboardV1);
delegate_noop!(Registry: ignore ZwpVirtualKeyboardManagerV1);

/// Binds one global, naming it in the error rather than leaving the caller to
/// guess which of the three was missing.
fn bind<I>(
    globals: &GlobalList,
    handle: &QueueHandle<Registry>,
    interface: &'static str,
    versions: RangeInclusive<u32>,
) -> Result<I, ProviderError>
where
    I: Proxy + 'static,
    Registry: Dispatch<I, ()>,
{
    globals
        .bind(handle, versions, ())
        .map_err(|error| ProviderError::MissingInterface {
            interface,
            detail: error.to_string(),
        })
}

/// An anonymous file holding `bytes`, for handing to the compositor.
///
/// A memfd rather than a file under `XDG_RUNTIME_DIR`, so nothing has to be
/// unlinked and nothing is left behind if lunette dies between creating it and
/// sending it.
fn memfd(name: &str, bytes: &[u8]) -> Result<File, ProviderError> {
    let name = CString::new(name).map_err(|_| ProviderError::Io {
        operation: "name an anonymous file",
        path: None,
        source: io::Error::from(io::ErrorKind::InvalidInput),
    })?;

    // SAFETY: `name` is a live NUL-terminated string for the duration of the
    // call, and `MFD_CLOEXEC` is the only flag passed.
    let raw = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    if raw < 0 {
        return Err(ProviderError::Io {
            operation: "create an anonymous file for the keymap",
            path: None,
            source: io::Error::last_os_error(),
        });
    }

    // SAFETY: `memfd_create` returned a fresh descriptor that nothing else owns,
    // so taking ownership of it here cannot alias another owner.
    let mut file = File::from(unsafe { OwnedFd::from_raw_fd(raw) });
    file.write_all(bytes).map_err(|source| ProviderError::Io {
        operation: "write the keymap to an anonymous file",
        path: None,
        source,
    })?;
    Ok(file)
}

/// A coordinate relative to the desktop's origin, as the protocol's unsigned
/// value.
///
/// Saturating at zero rather than wrapping: the caller has already clamped to
/// the desktop, so a negative here would be a rounding artefact at the origin,
/// and a wrap would put the cursor at four billion.
fn offset(value: f64, origin: f64) -> u32 {
    let relative = value - origin;
    if relative <= 0.0 {
        0
    } else {
        relative.round() as u32
    }
}

/// How many whole detents `delta` completes, carrying the remainder forward.
///
/// Without the carry, a trackpad-style stream of small deltas reports zero
/// detents forever and a host that reads only the discrete count never scrolls.
fn detents(residue: &mut f64, delta: f64) -> i32 {
    *residue += delta;
    let steps = (*residue / UNITS_PER_DETENT).trunc();
    if steps != 0.0 {
        *residue -= steps * UNITS_PER_DETENT;
    }
    steps as i32
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn a_coordinate_at_the_desktop_origin_is_zero() {
        assert_eq!(offset(-1920.0, -1920.0), 0);
    }

    #[test]
    fn a_coordinate_left_of_the_origin_saturates_rather_than_wrapping() {
        // A wrap would put the cursor four billion pixels away rather than one.
        assert_eq!(offset(-1921.0, -1920.0), 0);
    }

    #[test]
    fn a_coordinate_is_offset_by_the_origin_rather_than_taken_raw() {
        assert_eq!(offset(0.0, -1920.0), 1920);
        assert_eq!(offset(100.4, 0.0), 100);
    }

    #[test]
    fn a_scroll_shorter_than_a_detent_reports_no_step_yet() {
        let mut residue = 0.0;

        assert_eq!(detents(&mut residue, 4.0), 0);
        assert_eq!(residue, 4.0);
    }

    #[test]
    fn successive_short_scrolls_accumulate_into_a_step() {
        let mut residue = 0.0;
        let _ = detents(&mut residue, 6.0);

        assert_eq!(detents(&mut residue, 6.0), 1);
        assert_eq!(residue, 2.0);
    }

    #[test]
    fn a_scroll_of_several_detents_reports_all_of_them_at_once() {
        let mut residue = 0.0;

        assert_eq!(detents(&mut residue, 25.0), 2);
        assert_eq!(residue, 5.0);
    }

    #[test]
    fn scrolling_back_the_way_it_came_returns_the_residue_to_where_it_started() {
        let mut residue = 0.0;
        let _ = detents(&mut residue, 7.0);
        let _ = detents(&mut residue, -7.0);

        assert_eq!(residue, 0.0);
    }

    #[test]
    fn a_negative_scroll_steps_negatively() {
        let mut residue = 0.0;

        assert_eq!(detents(&mut residue, -25.0), -2);
        assert_eq!(residue, -5.0);
    }
}
