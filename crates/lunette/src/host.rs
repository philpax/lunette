//! Linux-only: where a host sink's input goes.
//!
//! A host sink reaches the user's desktop through `lunette-capture`'s `HidProvider`, not a
//! hosted client. Every host sink shares one cursor and one keyboard focus, because the host
//! desktop has one of each.

use std::{cell::RefCell, fmt};

use lunette_capture::{
    hid::{
        DesktopLayout, HostInput, KeyModifiers, MonitorMapping, PanelPoint,
        PointerButton as HostButton, ProviderError, VirtualKey, WheelDelta, XkbKeymap,
    },
    monitor::{MonitorKey, Roster},
};
use lunette_compositor::protocol::{KeyModifier, Keycode, ModifierState, PointerButton};
use tracing::{debug, warn};

/// The host desktop, as a sink reaches it.
///
/// Every method takes `&self`, the reference a Lua callback holds.
pub trait HostSinks: fmt::Debug {
    /// Places the host cursor at a hit on a mirrored monitor.
    ///
    /// `hit` is normalised over the monitor's surface. Reports whether the
    /// monitor is part of the current host desktop layout.
    fn pointer(&self, monitor: &MonitorKey, hit: PanelPoint) -> bool;

    /// Presses or releases a host pointer button.
    ///
    /// Not per-monitor, because the host has one cursor.
    fn button(&self, button: HostButton, pressed: bool);

    /// Scrolls the host's wheel.
    fn wheel(&self, delta: WheelDelta);

    /// Presses or releases a key on the host's keyboard.
    ///
    /// Reports whether the key is one the provider declared, because the kernel
    /// silently drops a key a uinput device did not declare. The key reaches
    /// whatever the host compositor focuses.
    fn key(&self, key: VirtualKey, pressed: bool) -> bool;

    /// Brings the host's held modifiers to a set.
    fn modifiers(&self, modifiers: KeyModifiers) -> bool;

    /// Tells the host which layout its keycodes should be read under.
    ///
    /// `zwp_virtual_keyboard_v1` disconnects a provider that sends a key before
    /// a keymap, so this must precede the first keystroke. Reports whether the
    /// host now has this layout.
    fn set_keymap(&self, keymap: &XkbKeymap) -> bool;

    /// Sends what accumulated this frame. Called once, at frame end.
    ///
    /// `HidProvider` sends one motion per frame however many moves accumulated.
    fn commit(&self);
}

/// The host desktop of the machine lunette is running on.
///
/// The mappings are rebuilt from the roster, because an incremental update is
/// easier to get wrong when a monitor move changes the bounding box.
pub struct HostPointer {
    input: RefCell<HostInput>,
    /// One mapping per mappable monitor, in the roster's own order.
    monitors: RefCell<Vec<(MonitorKey, MonitorMapping)>>,
    /// The layout most recently uploaded, kept because each upload makes the
    /// host compositor recompile.
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
    /// Called on every output change. A monitor with a zero logical dimension
    /// is left out.
    pub fn attach(&self, roster: &Roster) {
        let mut monitors = Vec::with_capacity(roster.monitors().len());
        for monitor in roster.monitors() {
            match MonitorMapping::new(monitor.geometry()) {
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
            // Not a fault: lunette may not see the host's screens. The provider
            // keeps its previous extent.
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
/// Driving the host desktop is best-effort, so a Lua caller gets a boolean and
/// the reason goes to the log.
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
/// Installed when host input is switched off. Every call reports a refusal
/// rather than silently succeeding.
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
/// The two enumerations carry the same five buttons.
#[must_use]
pub const fn host_button(button: PointerButton) -> HostButton {
    match button {
        PointerButton::Left => HostButton::Left,
        PointerButton::Right => HostButton::Right,
        PointerButton::Middle => HostButton::Middle,
        // A host desktop reads `BTN_SIDE` and `BTN_EXTRA` as back and forward.
        PointerButton::Back => HostButton::Side,
        PointerButton::Forward => HostButton::Extra,
    }
}

/// The host's name for a key the compositor's numbering named.
///
/// Both are evdev codes, so this only rejects a code the provider did not
/// declare, which the kernel would drop silently.
#[must_use]
pub fn host_key(key: Keycode) -> Option<VirtualKey> {
    VirtualKey::from_evdev(u16::try_from(key.evdev()).ok()?)
}

/// The host's modifier mask for the closed set the compositor carries.
///
/// A set containing `Mod3` maps to `None`, because neither host path has a bit
/// for it. The whole set is refused, because sending the rest would leave the
/// host holding a set the caller did not ask for.
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
