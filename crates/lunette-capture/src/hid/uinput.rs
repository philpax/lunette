//! Linux-only: creates virtual devices through `/dev/uinput`.
//!
//! The default provider order tries uinput first because it injects below the
//! display server. It works under any Wayland compositor and under X11 without
//! host compositor support.
//!
//! Opening `/dev/uinput` requires write permission, which most distributions do
//! not grant to ordinary users. [`Advice`] describes a udev rule tagged
//! `uaccess` and membership of the `input` group. The `input` group also grants
//! read access to every input device on the machine, which creates a keylogging
//! surface.
//!
//! The provider creates separate keyboard and mouse devices, following WayVR's
//! design. A device declaring both would appear to the host as one peripheral,
//! and a compositor that classifies devices by capability could handle it
//! inconsistently.

use std::{
    ffi::c_int,
    fmt,
    fs::{File, OpenOptions},
    io::{self, Write},
    mem,
    os::fd::{AsRawFd, RawFd},
    path::{Path, PathBuf},
    slice,
};

use tracing::{debug, warn};

use crate::hid::{
    HidProvider,
    evdev::{
        ABS_X, ABS_Y, BitRequest, EV_ABS, EV_KEY, EV_REL, EV_SYN, REL_HWHEEL_HI_RES,
        REL_WHEEL_HI_RES, SYN_REPORT, StructRequest, UI_ABS_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY,
        UI_DEV_SETUP, UI_SET_ABSBIT, UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT,
        WHEEL_HI_RES_PER_DETENT,
    },
    key::{KeyModifiers, PointerButton, VirtualKey, XkbKeymap},
    pointer::{DesktopExtent, DesktopPoint, DesktopVector, PendingPointer, WheelDelta},
    selection::{ProviderError, ProviderKind},
};

/// Configures the uinput device node and the names reported for the created
/// devices.
///
/// The device path is a parameter because this library does not read the
/// environment. [`Self::default`] supplies the path used by the application when
/// no override is configured.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UinputConfig {
    pub device: PathBuf,
    /// Prefix for the names the host reports in `libinput list-devices`. The
    /// provider appends "Keyboard" and "Mouse".
    pub device_prefix: String,
}

impl UinputConfig {
    pub const DEFAULT_DEVICE: &'static str = "/dev/uinput";
}

impl Default for UinputConfig {
    fn default() -> Self {
        Self {
            device: PathBuf::from(Self::DEFAULT_DEVICE),
            device_prefix: "lunette".to_owned(),
        }
    }
}

/// A keyboard and a mouse, injected below the host's display server.
pub struct UinputProvider {
    keyboard: UinputDevice,
    mouse: UinputDevice,
    pending: PendingPointer,
    modifiers: KeyModifiers,
    desktop_origin: DesktopPoint,
    /// `None` until the monitor roster is known. Absent rather than defaulted,
    /// because the extent is a divisor and there is no size the desktop can be
    /// assumed to have.
    desktop_extent: Option<DesktopExtent>,
    /// Whether the "no desktop extent yet" warning has been emitted.
    ///
    /// Once per provider rather than once per frame: the condition resolves as
    /// soon as the monitor roster is known, and a per-frame warning would bury
    /// everything else in the log until it does.
    warned_about_desktop: bool,
}

impl UinputProvider {
    /// Creates the two devices, or reports why it could not.
    ///
    /// # Errors
    ///
    /// [`ProviderError::Io`] when the device node cannot be opened — which is
    /// `ENOENT` if the `uinput` module is not loaded and `EACCES` if the user
    /// lacks write access — or when the kernel refuses part of the setup.
    pub fn open(config: &UinputConfig) -> Result<Self, ProviderError> {
        let keyboard = UinputDevice::create(
            &config.device,
            &format!("{} Keyboard", config.device_prefix),
            KEYBOARD_PRODUCT,
            |device| {
                device.set_bit(UI_SET_EVBIT, "event type", c_int::from(EV_KEY))?;
                for key in VirtualKey::ALL {
                    device.set_bit(UI_SET_KEYBIT, "key", c_int::from(key.evdev_code()))?;
                }
                Ok(Vec::new())
            },
        )?;

        let mouse = UinputDevice::create(
            &config.device,
            &format!("{} Mouse", config.device_prefix),
            MOUSE_PRODUCT,
            |device| {
                device.set_bit(UI_SET_EVBIT, "event type", c_int::from(EV_ABS))?;
                device.set_bit(UI_SET_EVBIT, "event type", c_int::from(EV_REL))?;
                device.set_bit(UI_SET_EVBIT, "event type", c_int::from(EV_KEY))?;
                device.set_bit(UI_SET_ABSBIT, "absolute axis", c_int::from(ABS_X))?;
                device.set_bit(UI_SET_ABSBIT, "absolute axis", c_int::from(ABS_Y))?;
                device.set_bit(
                    UI_SET_RELBIT,
                    "relative axis",
                    c_int::from(REL_WHEEL_HI_RES),
                )?;
                device.set_bit(
                    UI_SET_RELBIT,
                    "relative axis",
                    c_int::from(REL_HWHEEL_HI_RES),
                )?;
                for button in PointerButton::ALL {
                    device.set_bit(UI_SET_KEYBIT, "button", c_int::from(button.evdev_code()))?;
                }
                Ok(vec![absolute_axis(ABS_X), absolute_axis(ABS_Y)])
            },
        )?;

        debug!(
            device = %config.device.display(),
            "created uinput keyboard and mouse devices",
        );

        Ok(Self {
            keyboard,
            mouse,
            pending: PendingPointer::new(),
            modifiers: KeyModifiers::NONE,
            desktop_origin: DesktopPoint::ORIGIN,
            desktop_extent: None,
            warned_about_desktop: false,
        })
    }

    /// Maps a desktop position into the device's fixed normalised range.
    ///
    /// The range spans the whole desktop bounding box rather than one monitor.
    /// Hotplug changes the origin and extent without recreating the device.
    fn normalise(&mut self, position: DesktopPoint) -> Option<(i32, i32)> {
        let Some(extent) = self.desktop_extent else {
            if !self.warned_about_desktop {
                self.warned_about_desktop = true;
                warn!(
                    "a pointer position was sent before the host desktop's extent was known, so it \
                     cannot be placed; the extent arrives with the monitor roster",
                );
            }
            return None;
        };

        let origin = self.desktop_origin;
        let position = position.clamped(origin, extent);
        let scale = |value: f64, origin: f64, span: f64| {
            ((value - origin) * (MOUSE_EXTENT / span)).round() as i32
        };
        Some((
            scale(position.x, origin.x, extent.width()),
            scale(position.y, origin.y, extent.height()),
        ))
    }
}

impl HidProvider for UinputProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Uinput
    }

    fn mouse_move(&mut self, position: DesktopPoint) {
        self.pending.move_to(position);
    }

    fn mouse_move_rel(&mut self, delta: DesktopVector) {
        // The provider clamps relative motion to the desktop bounds and drops it
        // until those bounds are known.
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
            self.send_key(key, down)?;
        }
        self.modifiers = modifiers;
        Ok(())
    }

    fn send_key(&mut self, key: VirtualKey, down: bool) -> Result<(), ProviderError> {
        self.keyboard.emit(&[
            event(EV_KEY, key.evdev_code(), i32::from(down)),
            event(EV_SYN, SYN_REPORT, 0),
        ])
    }

    /// Raw keycodes are interpreted using the host's configured layout. This
    /// provider cannot upload a keymap; only [`crate::hid::wl_virtual`] can.
    fn set_keymap(&mut self, _keymap: &XkbKeymap) -> Result<(), ProviderError> {
        Ok(())
    }

    fn commit(&mut self) -> Result<(), ProviderError> {
        let batch = self.pending.take();

        if let Some(position) = batch.position
            && let Some((x, y)) = self.normalise(position)
        {
            self.mouse.emit(&[
                event(EV_ABS, ABS_X, x),
                event(EV_ABS, ABS_Y, y),
                event(EV_SYN, SYN_REPORT, 0),
            ])?;
        }

        if let Some((button, down)) = batch.button {
            self.mouse.emit(&[
                event(EV_KEY, button.evdev_code(), i32::from(down)),
                event(EV_SYN, SYN_REPORT, 0),
            ])?;
        }

        if let Some(delta) = batch.wheel {
            let steps = |value: f64| (value * WHEEL_HI_RES_PER_DETENT).round() as i32;
            self.mouse.emit(&[
                event(EV_REL, REL_WHEEL_HI_RES, steps(delta.y)),
                event(EV_REL, REL_HWHEEL_HI_RES, steps(delta.x)),
                event(EV_SYN, SYN_REPORT, 0),
            ])?;
        }

        Ok(())
    }
}

/// Provides checks and access guidance when the uinput provider cannot be created.
///
/// The surrounding application chooses how to present the guidance and supplies
/// the login name as a parameter rather than this library reading it from the
/// environment. The guidance includes the security risk of membership in the
/// `input` group.
#[derive(Clone, Copy, Debug)]
pub struct Advice<'a> {
    /// The login name to put in the `usermod` command, if the caller knows it.
    pub user: Option<&'a str>,
}

impl fmt::Display for Advice<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(
            "check that the uinput module is loaded: lsmod | grep uinput. \
             check that the device is writable: ls -l /dev/uinput. ",
        )?;
        match self.user {
            Some(user) => write!(
                f,
                "to grant access, either add a udev rule tagging the device uaccess, or run \
                 sudo usermod -aG input {user} and log out and back in. ",
            )?,
            None => f.write_str(
                "to grant access, either add a udev rule tagging the device uaccess, or add the \
                 account to the input group and log out and back in. ",
            )?,
        }
        f.write_str(
            "note that the input group grants read access to every input device on the machine, \
             which is a keylogging surface; the udev rule does not",
        )
    }
}

/// The kernel's fixed normalised range for the absolute axes.
///
/// The number is arbitrary; what matters is that it never changes. A device
/// using the desktop's logical extent as its range would have to be destroyed
/// and recreated on every hotplug, which would replace the host input device.
const MOUSE_EXTENT: f64 = 32768.0;

/// The `resolution` reported for the absolute axes, in units per millimetre.
///
/// Nonzero because a host that reads zero may classify the device as a touchpad
/// rather than a pointer.
const ABS_RESOLUTION: i32 = 10;

/// `BUS_USB`, which is what a virtual device conventionally claims.
const BUS_USB: u16 = 0x03;

/// The vendor identifier the created devices report.
///
/// Arbitrary, and shared by both devices so that a host rule matching lunette's
/// input matches all of it.
const VENDOR: u16 = 0x1d6b;
const KEYBOARD_PRODUCT: u16 = 0x0001;
const MOUSE_PRODUCT: u16 = 0x0002;

/// A uinput device the kernel has created, destroyed when it is dropped.
///
/// Distinct from [`OpenNode`], which is the descriptor before `UI_DEV_CREATE`
/// has been issued. Only this type has a `Drop`, so a setup that fails partway
/// destroys nothing and reports what actually went wrong: `UI_DEV_DESTROY`
/// against a node with no device behind it fails, and warning about it would
/// bury the real failure under a misleading second line.
struct UinputDevice {
    node: OpenNode,
}

impl UinputDevice {
    /// Opens the device node, applies `declare`, and brings the device up.
    ///
    /// `declare` returns the absolute axes to configure, which have to be set
    /// after their `ABSBIT`s and before `UI_DEV_CREATE`.
    fn create(
        path: &Path,
        name: &str,
        product: u16,
        declare: impl FnOnce(&OpenNode) -> Result<Vec<libc::uinput_abs_setup>, ProviderError>,
    ) -> Result<Self, ProviderError> {
        let node = OpenNode::open(path, name)?;

        for axis in declare(&node)? {
            node.ioctl(UI_ABS_SETUP, "configure an absolute axis", &raw const axis)?;
        }

        let setup = libc::uinput_setup {
            id: libc::input_id {
                bustype: BUS_USB,
                vendor: VENDOR,
                product,
                version: 1,
            },
            name: device_name(name),
            ff_effects_max: 0,
        };
        node.ioctl(UI_DEV_SETUP, "name the device", &raw const setup)?;

        // SAFETY: `UI_DEV_CREATE` takes no argument, and the descriptor is
        // owned by `node` and open for the duration of the call.
        let created = unsafe { libc::ioctl(node.raw_fd(), UI_DEV_CREATE) };
        if created < 0 {
            return Err(node.last_error("create the device"));
        }

        Ok(Self { node })
    }

    /// Writes a complete event group ending with `EV_SYN`.
    ///
    /// `write_all` retries short writes. If an I/O error occurs after a partial
    /// write, the kernel may receive an incomplete group without its final
    /// `EV_SYN`, so the error is returned to the provider.
    fn emit(&mut self, events: &[libc::input_event]) -> Result<(), ProviderError> {
        // SAFETY: `input_event` is a `repr(C)` plain-data structure with no
        // padding invariants and no pointers, so its bytes are a valid slice for
        // the lifetime of the borrow.
        let bytes = unsafe {
            slice::from_raw_parts(events.as_ptr().cast::<u8>(), mem::size_of_val(events))
        };
        self.node
            .file
            .write_all(bytes)
            .map_err(|source| ProviderError::Io {
                operation: "write an event to",
                path: Some(self.node.path.clone()),
                source,
            })
    }
}

impl Drop for UinputDevice {
    fn drop(&mut self) {
        // SAFETY: `UI_DEV_DESTROY` takes no argument, and the descriptor is
        // still open — the `File` is dropped after this.
        let destroyed = unsafe { libc::ioctl(self.node.raw_fd(), UI_DEV_DESTROY) };
        if destroyed < 0 {
            // `Drop` cannot propagate a failed destroy ioctl, so report it before
            // the descriptor closes.
            warn!(
                device = %self.node.name,
                error = %io::Error::last_os_error(),
                "could not destroy the uinput device",
            );
        }
    }
}

/// An open `/dev/uinput` descriptor, before any device exists behind it.
///
/// Deliberately without a `Drop`: closing the descriptor is all that is wanted
/// here, and that is `File`'s own.
struct OpenNode {
    file: File,
    path: PathBuf,
    name: String,
}

impl OpenNode {
    fn open(path: &Path, name: &str) -> Result<Self, ProviderError> {
        let file = OpenOptions::new()
            .write(true)
            .open(path)
            .map_err(|source| ProviderError::Io {
                operation: "open",
                path: Some(path.to_owned()),
                source,
            })?;

        Ok(Self {
            file,
            path: path.to_owned(),
            name: name.to_owned(),
        })
    }

    fn set_bit(
        &self,
        request: BitRequest,
        what: &'static str,
        bit: c_int,
    ) -> Result<(), ProviderError> {
        // SAFETY: `BitRequest` is minted only for the `UI_SET_*BIT` requests,
        // every one of which takes the bit by value as an `int`, and the
        // descriptor is open for the duration of the call.
        let result = unsafe { libc::ioctl(self.raw_fd(), request.code(), bit) };
        if result < 0 {
            return Err(self.last_error(what));
        }
        Ok(())
    }

    fn ioctl<T>(
        &self,
        request: StructRequest<T>,
        what: &'static str,
        argument: *const T,
    ) -> Result<(), ProviderError> {
        // SAFETY: `StructRequest<T>` encodes `size_of::<T>()` in the request
        // number and is the only way to name one of these requests, so the
        // kernel reads exactly the bytes `argument` points at. The pointer is to
        // a live local of the caller's, and the descriptor is open for the
        // duration of the call.
        let result = unsafe { libc::ioctl(self.raw_fd(), request.code(), argument) };
        if result < 0 {
            return Err(self.last_error(what));
        }
        Ok(())
    }

    fn raw_fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }

    fn last_error(&self, what: &'static str) -> ProviderError {
        ProviderError::Io {
            operation: what,
            path: Some(self.path.clone()),
            source: io::Error::last_os_error(),
        }
    }
}

/// Builds an event with a zeroed timestamp.
///
/// The kernel discards the timestamp supplied with a uinput write and stamps
/// the event itself, so filling it in has no observable effect.
const fn event(kind: u16, code: u16, value: i32) -> libc::input_event {
    libc::input_event {
        time: libc::timeval {
            tv_sec: 0,
            tv_usec: 0,
        },
        type_: kind,
        code,
        value,
    }
}

/// One absolute axis over the fixed normalised range.
const fn absolute_axis(code: u16) -> libc::uinput_abs_setup {
    libc::uinput_abs_setup {
        code,
        absinfo: libc::input_absinfo {
            value: 0,
            minimum: 0,
            maximum: MOUSE_EXTENT as i32,
            fuzz: 0,
            flat: 0,
            resolution: ABS_RESOLUTION,
        },
    }
}

/// The device name as the fixed-size NUL-padded field the kernel wants.
///
/// Truncated rather than rejected when it does not fit: the name is a label in
/// `libinput list-devices` and nothing depends on its exact text, so a long
/// prefix is a cosmetic problem rather than grounds for refusing to create the
/// device. The truncation stops one byte short of the field so the NUL survives.
fn device_name(name: &str) -> [libc::c_char; libc::UINPUT_MAX_NAME_SIZE] {
    let mut field = [0; libc::UINPUT_MAX_NAME_SIZE];
    for (slot, byte) in field
        .iter_mut()
        .zip(name.bytes().take(libc::UINPUT_MAX_NAME_SIZE - 1))
    {
        *slot = byte as libc::c_char;
    }
    field
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn rendered(field: &[libc::c_char]) -> String {
        field
            .iter()
            .take_while(|byte| **byte != 0)
            .map(|byte| *byte as u8 as char)
            .collect()
    }

    #[test]
    fn the_default_device_is_the_node_uinput_lives_at() {
        assert_eq!(UinputConfig::default().device, PathBuf::from("/dev/uinput"),);
    }

    #[test]
    fn a_device_name_is_nul_terminated() {
        let field = device_name("lunette Mouse");

        assert_eq!(rendered(&field), "lunette Mouse");
        assert_eq!(field[13], 0);
    }

    #[test]
    fn a_name_too_long_for_the_field_is_truncated_with_its_terminator_intact() {
        let field = device_name(&"x".repeat(200));

        assert_eq!(rendered(&field).len(), libc::UINPUT_MAX_NAME_SIZE - 1);
        assert_eq!(field[libc::UINPUT_MAX_NAME_SIZE - 1], 0);
    }

    #[test]
    fn an_empty_name_is_an_empty_field() {
        assert_eq!(device_name(""), [0; libc::UINPUT_MAX_NAME_SIZE]);
    }

    #[test]
    fn both_absolute_axes_span_the_same_fixed_range() {
        // The range is what makes hotplug free: only the origin and extent
        // change, never the device.
        for axis in [absolute_axis(ABS_X), absolute_axis(ABS_Y)] {
            assert_eq!(axis.absinfo.minimum, 0);
            assert_eq!(axis.absinfo.maximum, 32768);
            assert_eq!(axis.absinfo.resolution, ABS_RESOLUTION);
        }
    }

    #[test]
    fn an_event_is_built_with_the_type_code_and_value_it_was_given() {
        let built = event(EV_ABS, ABS_Y, -3);

        assert_eq!(built.type_, EV_ABS);
        assert_eq!(built.code, ABS_Y);
        assert_eq!(built.value, -3);
    }

    #[test]
    fn the_advice_names_the_user_when_the_caller_knows_it() {
        let advice = Advice {
            user: Some("someone"),
        }
        .to_string();

        assert!(
            advice.contains("sudo usermod -aG input someone"),
            "{advice}"
        );
        assert!(advice.contains("log out and back in"), "{advice}");
        assert!(advice.contains("keylogging surface"), "{advice}");
    }

    #[test]
    fn the_advice_stands_without_a_user_name() {
        let advice = Advice { user: None }.to_string();

        assert!(!advice.contains("usermod -aG input "), "{advice}");
        assert!(advice.contains("lsmod | grep uinput"), "{advice}");
        assert!(advice.contains("keylogging surface"), "{advice}");
    }
}
