//! Linux-only: where a host sink's input goes.
//!
//! A sink in the host domain reaches the user's desktop, not a client lunette
//! hosts. The two must not be confused: one goes through the compositor's
//! seat, and the other through `lunette-capture`'s `HidProvider`. [`HostSinks`]
//! is the seam between the Lua surface and the second of those, held by
//! [`Session`] behind a trait object for the same reason the layer pool and
//! the mirrors are: no second type parameter has to thread through every
//! handle.
//!
//! # One cursor and one keyboard focus
//!
//! Every host sink shares one cursor and one keyboard focus, because the host
//! desktop has one of each. This is why the domain is exposed to Lua. A panel
//! library that presents two mirrored monitors as independently focusable
//! describes something the host cannot do.
//!
//! # The two coordinate spaces
//!
//! To the provider, the host desktop is a bounding box: uinput's device spans
//! it in a fixed normalised range, and `zwlr_virtual_pointer_v1` takes the
//! extent on every call. Per-monitor targeting happens above that, in the
//! [`MonitorMapping`] built from each monitor's logical geometry. The two meet
//! at this seam. [`HostPointer::attach`] keeps the box up to date as monitors
//! are added, removed, or moved.
//!
//! [`Session`]: crate::lua::Session

use std::{cell::RefCell, fmt};

use lunette_capture::{
    hid::{
        DesktopLayout, HostInput, KeyModifiers, MonitorMapping, PanelPoint,
        PointerButton as HostButton, ProviderError, VirtualKey, WheelDelta, XkbKeymap,
    },
    monitor::{MonitorKey, Roster, SurfaceTransform},
};
use lunette_compositor::protocol::{KeyModifier, Keycode, ModifierState, PointerButton};
use tracing::{debug, warn};

/// The host desktop, as a sink reaches it.
///
/// Every method takes `&self`, the reference a Lua callback holds.
pub trait HostSinks: fmt::Debug {
    /// Places the host cursor at a hit on a mirrored monitor.
    ///
    /// `hit` is normalised over the monitor's own surface. The conversion from
    /// a pixel coordinate happens above this method, and the mapping to a
    /// desktop position happens below it. Reports whether the monitor is part
    /// of the current host desktop layout.
    fn pointer(&self, monitor: &MonitorKey, hit: PanelPoint) -> bool;

    /// Presses or releases a host pointer button.
    ///
    /// Not per-monitor: the host has one cursor, and a button is pressed
    /// wherever that cursor is.
    fn button(&self, button: HostButton, pressed: bool);

    /// Scrolls the host's wheel.
    fn wheel(&self, delta: WheelDelta);

    /// Presses or releases a key on the host's keyboard.
    ///
    /// Reports whether the key is one the provider declared. A key outside
    /// [`VirtualKey`]'s set is refused, because a uinput device emits nothing
    /// it did not declare at creation and the kernel would drop the key
    /// without reporting.
    ///
    /// The key reaches whatever the host compositor currently focuses; the
    /// focus is not under lunette's control.
    fn key(&self, key: VirtualKey, pressed: bool) -> bool;

    /// Brings the host's held modifiers to a set.
    fn modifiers(&self, modifiers: KeyModifiers) -> bool;

    /// Tells the host which layout its keycodes should be read under.
    ///
    /// Uploaded before the first keystroke, not at startup:
    /// `zwp_virtual_keyboard_v1` treats a key sent before a keymap as a
    /// protocol error and disconnects the provider, so `lunette-capture`'s
    /// chain leaves the virtual keyboard unconfigured until there is a layout
    /// to give it. Reports whether the host now has this layout.
    fn set_keymap(&self, keymap: &XkbKeymap) -> bool;

    /// Sends what accumulated this frame. Called once, at frame end.
    ///
    /// Pointer and button calls accumulate until then; `HidProvider` sends
    /// one motion per frame. Five cursor moves in one frame send one motion.
    fn commit(&self);
}

/// The host desktop of the machine lunette is running on.
///
/// Owns the provider chain and the per-monitor mappings. The mappings are
/// rebuilt from the roster, not updated in place. An incremental update
/// mishandles the bounding-box changes a monitor move causes more often than
/// recomputation does.
pub struct HostPointer {
    input: RefCell<HostInput>,
    /// One mapping per mappable monitor, in the roster's own order.
    monitors: RefCell<Vec<(MonitorKey, MonitorMapping)>>,
    /// The layout most recently uploaded to the host. Keeping it prevents
    /// re-uploading an unchanged keymap on each keystroke: each upload
    /// rewrites a memfd and makes the host compositor recompile.
    keymap: RefCell<Option<XkbKeymap>>,
}

impl HostPointer {
    #[must_use]
    pub const fn new(input: HostInput) -> Self {
        Self {
            input: RefCell::new(input),
            monitors: RefCell::new(Vec::new()),
            keymap: RefCell::new(None),
        }
    }

    /// Rebuilds the desktop layout from the attached monitors.
    ///
    /// Called on every output change. Neither provider needs anything
    /// recreated: uinput's device spans a fixed normalised range, and
    /// `zwlr_virtual_pointer_v1` takes the extent on every call.
    ///
    /// A monitor with a zero logical dimension, one being reconfigured or one
    /// whose mode has not been set, is left out. A pointer cannot be placed
    /// on such a monitor.
    pub fn attach(&self, roster: &Roster) {
        let mut monitors = Vec::with_capacity(roster.monitors().len());
        for monitor in roster.monitors() {
            // Panels apply the captured UV transform before presentation. Hits
            // are already in desktop orientation, including portal frames whose
            // transform is Undefined, so reorienting here would apply it twice.
            match MonitorMapping::new(monitor.geometry(), SurfaceTransform::Normal) {
                Ok(mapping) => monitors.push((monitor.key().clone(), mapping)),
                Err(error) => warn!(
                    monitor = %monitor.key(),
                    %error,
                    "a monitor was left out of the host desktop layout",
                ),
            }
        }

        match DesktopLayout::new(monitors.iter().map(|(_, mapping)| *mapping)) {
            Ok(layout) => {
                debug!(%layout, "the host desktop layout changed");
                self.input.borrow_mut().set_desktop(&layout);
            }
            // No monitors is not a fault. It is the layout of a host whose screens
            // lunette cannot see. The provider keeps whatever extent it has; it
            // is not told the desktop is empty.
            Err(error) => debug!(%error, "no host desktop layout could be built"),
        }

        *self.monitors.borrow_mut() = monitors;
    }
}

impl fmt::Debug for HostPointer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HostPointer")
            .field("monitors", &self.monitors.borrow().len())
            .finish_non_exhaustive()
    }
}

impl HostSinks for HostPointer {
    fn pointer(&self, monitor: &MonitorKey, hit: PanelPoint) -> bool {
        let Some(position) = self
            .monitors
            .borrow()
            .iter()
            .find_map(|(key, mapping)| (key == monitor).then(|| mapping.map(hit)))
        else {
            return false;
        };

        self.input.borrow_mut().provider().mouse_move(position);
        true
    }

    fn button(&self, button: HostButton, pressed: bool) {
        self.input
            .borrow_mut()
            .provider()
            .send_button(button, pressed);
    }

    fn wheel(&self, delta: WheelDelta) {
        self.input.borrow_mut().provider().wheel(delta);
    }

    fn key(&self, key: VirtualKey, pressed: bool) -> bool {
        report("a key could not be sent to the host desktop", || {
            self.input.borrow_mut().provider().send_key(key, pressed)
        })
    }

    fn modifiers(&self, modifiers: KeyModifiers) -> bool {
        report("the host's modifiers could not be set", || {
            self.input.borrow_mut().provider().set_modifiers(modifiers)
        })
    }

    fn set_keymap(&self, keymap: &XkbKeymap) -> bool {
        if self.keymap.borrow().as_ref() == Some(keymap) {
            return true;
        }

        let uploaded = report("the host's layout could not be set", || {
            self.input.borrow_mut().provider().set_keymap(keymap)
        });
        if uploaded {
            *self.keymap.borrow_mut() = Some(keymap.clone());
        }
        uploaded
    }

    fn commit(&self) {
        self.input.borrow_mut().commit();
    }
}

/// Runs a provider call, reporting a failure without propagating it.
///
/// A Lua caller gets a boolean. Driving the host desktop is best-effort: the
/// user may have revoked a permission, or the host session may have gone.
/// A script that raised on every refused keystroke would be unwritable. The
/// log line is where the reason survives.
fn report(context: &str, call: impl FnOnce() -> Result<(), ProviderError>) -> bool {
    match call() {
        Ok(()) => true,
        Err(error) => {
            warn!(%error, "{context}");
            false
        }
    }
}

/// A host desktop lunette does not drive.
///
/// What the entry point installs when host input is switched off, and what a
/// test that is not about it uses. A pointer to a host sink is refused, not
/// silently accepted. A configuration that targets a mirror it cannot drive
/// receives the refusal from the return value.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoHostSinks;

impl HostSinks for NoHostSinks {
    fn pointer(&self, _monitor: &MonitorKey, _hit: PanelPoint) -> bool {
        false
    }

    fn button(&self, _button: HostButton, _pressed: bool) {}

    fn wheel(&self, _delta: WheelDelta) {}

    fn key(&self, _key: VirtualKey, _pressed: bool) -> bool {
        false
    }

    fn modifiers(&self, _modifiers: KeyModifiers) -> bool {
        false
    }

    fn set_keymap(&self, _keymap: &XkbKeymap) -> bool {
        false
    }

    fn commit(&self) {}
}

/// The host's name for a button the Lua surface named.
///
/// The compositor's button enumeration maps to a `BTN_*` code at the seat,
/// and the host's maps to an evdev code at the provider. They carry the same
/// five buttons; this is where that is stated once.
#[must_use]
pub const fn host_button(button: PointerButton) -> HostButton {
    match button {
        PointerButton::Left => HostButton::Left,
        PointerButton::Right => HostButton::Right,
        PointerButton::Middle => HostButton::Middle,
        // `BTN_SIDE` and `BTN_EXTRA`. A host desktop reads these as back and
        // forward. The evdev names describe the switch; the protocol names
        // describe what it does.
        PointerButton::Back => HostButton::Side,
        PointerButton::Forward => HostButton::Extra,
    }
}

/// The host's name for a key the compositor's numbering named.
///
/// Both are evdev codes, so this is a validation, not a translation. A code
/// outside the set the provider declared to the kernel is rejected here.
/// Sending an undeclared code would have the kernel drop it without
/// reporting.
#[must_use]
pub fn host_key(key: Keycode) -> Option<VirtualKey> {
    VirtualKey::from_evdev(u16::try_from(key.evdev()).ok()?)
}

/// The host's modifier mask for the closed set the compositor carries.
///
/// The bits are XKB modifier indices on both sides, so the two enumerations
/// agree by construction. This is where that is stated once, not
/// assumed at each call site.
///
/// A set containing `Mod3` maps to `None`: neither
/// `zwp_virtual_keyboard_v1`'s mask nor uinput's representative-key table has
/// a bit for it. The whole set is refused, because sending the rest would
/// leave the host holding modifiers the caller did not ask for. That is worse
/// than sending nothing and reporting the refusal.
#[must_use]
pub fn host_modifiers(modifiers: &ModifierState) -> Option<KeyModifiers> {
    modifiers.iter().try_fold(
        KeyModifiers::NONE,
        |held, modifier| -> Option<KeyModifiers> {
            Some(held.union(match modifier {
                KeyModifier::Shift => KeyModifiers::SHIFT,
                KeyModifier::CapsLock => KeyModifiers::CAPS_LOCK,
                KeyModifier::Control => KeyModifiers::CTRL,
                KeyModifier::Alt => KeyModifiers::ALT,
                KeyModifier::NumLock => KeyModifiers::NUM_LOCK,
                KeyModifier::Logo => KeyModifiers::SUPER,
                KeyModifier::Mod5 => KeyModifiers::ALT_GR,
                KeyModifier::Mod3 => return None,
            }))
        },
    )
}

#[cfg(test)]
#[expect(clippy::expect_used, reason = "tests report failed expectations")]
mod tests {
    use lunette_capture::{
        hid::{self, DesktopPoint, HidConfig},
        monitor::{
            LogicalGeometry, LogicalPosition, LogicalSize, MonitorName, PixelExtent,
            roster::MonitorReport,
        },
    };

    use super::*;

    #[test]
    fn presented_monitor_hits_map_to_logical_desktop_for_every_output_transform() {
        for transform in SurfaceTransform::ALL {
            let pointer = HostPointer::new(hid::open(&HidConfig::disabled()));
            let mut roster = Roster::new();
            roster.add(MonitorReport {
                name: MonitorName::new(None, Some("Acme".to_owned()), Some("Portrait".to_owned())),
                geometry: LogicalGeometry::new(
                    LogicalPosition::new(40, 80),
                    LogicalSize::new(1080, 1920),
                ),
                pixels: PixelExtent::new(1920, 1080),
                transform: *transform,
            });
            pointer.attach(&roster);
            let mappings = pointer.monitors.borrow();
            let mapping = mappings.first().expect("the output is mappable").1;
            assert_eq!(
                mapping.map(PanelPoint::new(0.25, 0.75)),
                DesktopPoint::new(310.0, 1520.0)
            );
            assert_eq!(
                mapping.map(PanelPoint::new(0.0, 0.0)),
                DesktopPoint::new(40.0, 80.0)
            );
        }
    }
}
