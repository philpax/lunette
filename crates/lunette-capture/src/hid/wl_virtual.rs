//! Linux-only: implements the `zwlr_virtual_pointer_v1` and
//! `zwp_virtual_keyboard_v1` protocols against the host compositor over a
//! Wayland socket.
//!
//! This provider needs no device permission or kernel module. Its absolute pointer
//! requests include the desktop extent, so a monitor-layout change does not
//! require recreating the device.
//!
//! Both protocols are wlroots extensions. KWin and mutter do not implement them,
//! so uinput remains the portable provider.
//!
//! # Thread affinity
//!
//! [`WlVirtualProvider`] owns a `wayland_client::EventQueue`, and `commit`
//! performs a roundtrip on it. The provider must stay on one thread: dispatching
//! its queue from another thread could interleave event handling.
//!
//! # Disconnection
//!
//! Flush and roundtrip failures become [`ProviderError::Disconnected`].
//! [`crate::hid::HostInput`] replaces a disconnected provider with the dummy and
//! logs the reason. It does not abort the process.

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
    pointer::{DesktopExtent, DesktopPoint, PendingPointer, WheelDelta},
    selection::{ProviderError, ProviderKind},
};

/// The host compositor's Wayland socket and keyboard layout.
///
/// The application resolves the socket from its environment and passes the
/// resulting path to this library.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WlVirtualConfig {
    pub socket: PathBuf,
    /// The layout uploaded to the virtual keyboard.
    ///
    /// The protocol disconnects a client that sends a `key` request before a
    /// `keymap` request, so the provider always requires a layout.
    pub keymap: XkbKeymap,
}

pub struct WlVirtualProvider {
    connection: Connection,
    queue: EventQueue<Registry>,
    registry: Registry,
    pointer: ZwlrVirtualPointerV1,
    keyboard: ZwpVirtualKeyboardV1,
    /// The memfd the keymap was written to.
    ///
    /// Held open because the compositor maps the descriptor lazily; a closed
    /// one gives it nothing to map.
    keymap: Option<File>,
    pending: PendingPointer,
    modifiers: KeyModifiers,
    desktop_origin: DesktopPoint,
    desktop_extent: Option<DesktopExtent>,
    /// Accumulated fractional detents, so a slow scroll eventually steps.
    wheel_residue: WheelDelta,
    /// The timestamp of the last request, in the protocol's milliseconds.
    ///
    /// The counter avoids clock adjustments that could make the compositor
    /// reorder or discard requests.
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

        // The virtual keyboard requires a seat, so a compositor without a
        // sufficiently recent `wl_seat` cannot host either device.
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
                self.pointer.axis_discrete(
                    time,
                    Axis::VerticalScroll,
                    vertical * AXIS_UNITS_PER_DETENT,
                    steps,
                );
            }
            if delta.x != 0.0 {
                let steps = detents(&mut self.wheel_residue.x, delta.x);
                let time = self.now();
                self.pointer.axis_discrete(
                    time,
                    Axis::HorizontalScroll,
                    delta.x * AXIS_UNITS_PER_DETENT,
                    steps,
                );
            }
            self.pointer.frame();
        }

        self.roundtrip()
    }
}

/// The `wl_keyboard.keymap_format` value for XKB's version 1 text format.
///
/// The wayland crates expose this value only through `wayland-server`, which this
/// crate does not otherwise need to depend on.
const KEYMAP_FORMAT_XKB_V1: u32 = 1;

/// How many `wl_pointer.axis` units one wheel detent is.
///
/// The continuous value is in surface-local coordinates, and ten per detent is
/// what libinput reports and what every wlroots compositor therefore expects.
/// [`WheelDelta`] counts detents, so the conversion is explicit here and not
/// implied by the caller's argument.
const AXIS_UNITS_PER_DETENT: f64 = 10.0;

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

/// Creates an anonymous file for the compositor to map.
///
/// A memfd needs no unlinking and leaves no file behind if lunette exits before
/// it sends the descriptor.
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

/// Converts a clamped coordinate to the protocol's unsigned offset.
///
/// Saturating at zero prevents a rounding artefact at the origin from wrapping
/// the cursor to a position near four billion.
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
/// `delta` is in detents, as [`WheelDelta`] is. `axis_discrete` reports whole
/// detents alongside the continuous value. Without the carry, a
/// trackpad-style stream of fractional deltas reports zero detents, so a host
/// that reads only the discrete count never scrolls.
fn detents(residue: &mut f64, delta: f64) -> i32 {
    *residue += delta;
    let steps = residue.trunc();
    *residue -= steps;
    steps as i32
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn a_coordinate_is_offset_by_the_origin_and_saturates_left_of_it() {
        assert_eq!(offset(-1920.0, -1920.0), 0);
        assert_eq!(offset(-1921.0, -1920.0), 0, "left of the origin");
        assert_eq!(offset(0.0, -1920.0), 1920);
        assert_eq!(offset(100.4, 0.0), 100);
    }

    #[test]
    fn scrolls_carry_their_residue_until_it_makes_a_whole_detent() {
        let mut residue = 0.0;

        assert_eq!(detents(&mut residue, 0.4), 0, "shorter than a detent");
        assert_eq!(residue, 0.4);
        assert_eq!(detents(&mut residue, 0.8), 1, "accumulated into a step");
        assert!((residue - 0.2).abs() < f64::EPSILON * 8.0, "{residue}");

        let mut residue = 0.0;
        assert_eq!(detents(&mut residue, 2.5), 2, "several detents at once");
        assert_eq!(residue, 0.5);
    }

    #[test]
    fn a_negative_scroll_steps_negatively_and_cancels_a_positive_residue() {
        let mut residue = 0.0;

        assert_eq!(detents(&mut residue, -2.5), -2);
        assert_eq!(residue, -0.5);

        let mut residue = 0.0;
        let _ = detents(&mut residue, 0.7);
        let _ = detents(&mut residue, -0.7);
        assert_eq!(residue, 0.0);
    }
}
