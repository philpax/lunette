//! Linux-only: where a host sink's input goes.
//!
//! A sink in the host domain reaches the user's own desktop rather than a
//! client lunette hosts, and the two must not be confused: one goes through the
//! compositor's seat and the other through `lunette-capture`'s `HidProvider`.
//! [`HostSinks`] is the seam between the Lua surface and the second of those,
//! held by [`Session`] behind a trait object for the same reason the layer pool
//! and the mirrors are — so that no second type parameter has to thread through
//! every handle.
//!
//! # One cursor, however many hands
//!
//! Every host sink shares one cursor and one keyboard focus, because the host
//! desktop has one of each. That is the whole reason the domain is exposed to
//! Lua rather than hidden: a panel library that presented two mirrored monitors
//! as independently focusable would be describing something the host cannot do.
//!
//! # The two coordinate spaces
//!
//! A provider knows the host desktop only as a bounding box: uinput's device
//! spans it in a fixed normalised range, and `zwlr_virtual_pointer_v1` takes the
//! extent on every call. Per-monitor targeting is upstream of that, in the
//! [`MonitorMapping`] built from each monitor's logical geometry. This is the
//! seam where the two meet, and [`HostPointer::attach`] is what keeps the box up
//! to date as monitors are added, removed, or moved.
//!
//! [`Session`]: crate::lua::Session

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
/// Every method takes `&self` because that is what a Lua callback holds.
pub trait HostSinks: fmt::Debug {
    /// Places the host cursor at a hit on a mirrored monitor.
    ///
    /// `hit` is normalised over the monitor's own surface, so the conversion
    /// from a pixel coordinate happens above this and the mapping to a desktop
    /// position happens below it. Reports whether the monitor is one the host
    /// desktop knows about.
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
    /// Reports whether the key was one the provider declared. A key outside
    /// [`VirtualKey`]'s set is refused rather than sent, because a uinput device
    /// emits nothing it did not declare at creation and the kernel would drop it
    /// without saying so.
    ///
    /// This is the last link of `lunette-v1.AC3.3`: what the key reaches is
    /// whatever the *host* compositor currently focuses, and lunette does not
    /// choose what that is.
    fn key(&self, key: VirtualKey, pressed: bool) -> bool;

    /// Brings the host's held modifiers to a set.
    fn modifiers(&self, modifiers: KeyModifiers) -> bool;

    /// Tells the host which layout its keycodes should be read under.
    ///
    /// Uploaded before the first keystroke, not at startup:
    /// `zwp_virtual_keyboard_v1` treats a key sent before a keymap as a protocol
    /// error and disconnects the provider, so `lunette-capture`'s chain leaves
    /// the virtual keyboard unconfigured until there is a layout to give it.
    /// Reports whether the host now has this layout.
    fn set_keymap(&self, keymap: &XkbKeymap) -> bool;

    /// Sends what accumulated this frame. Called once, at frame end.
    ///
    /// Pointer and button calls only accumulate, which is the division
    /// `HidProvider` is written around: a frame that moved the cursor five times
    /// sends one motion.
    fn commit(&self);
}

/// The host desktop of the machine lunette is running on.
///
/// Owns the provider chain and the per-monitor mappings. The mappings are
/// rebuilt from the roster rather than updated in place, because a monitor
/// moving changes the bounding box in ways an incremental update gets wrong far
/// more easily than recomputing does.
pub struct HostPointer {
    input: RefCell<HostInput>,
    /// One mapping per mappable monitor, in the roster's own order.
    monitors: RefCell<Vec<(MonitorKey, MonitorMapping)>>,
    /// The layout the host was last told about, so an unchanged one is not
    /// re-uploaded. A keymap upload rewrites a memfd and makes the host
    /// compositor recompile, which is not something to do per keystroke.
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
    /// Called on every output change. Neither provider needs anything recreated
    /// for it: uinput's device spans a fixed normalised range, and
    /// `zwlr_virtual_pointer_v1` takes the extent on every call.
    ///
    /// A monitor with a zero logical dimension — one being reconfigured, or one
    /// whose mode has not been set — is left out rather than mapped, because it
    /// is not a monitor a pointer can be placed on.
    pub fn attach(&self, roster: &Roster) {
        let mut monitors = Vec::with_capacity(roster.monitors().len());
        for monitor in roster.monitors() {
            // The transform the host reported through `wl_output.geometry`, not
            // an assumed `Normal`. A portrait-mounted monitor reports a rotated
            // transform and a logical size with the axes already swapped; using
            // the size without the transform puts every hit in the wrong corner.
            match MonitorMapping::new(monitor.geometry(), monitor.transform()) {
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
            // No monitors is not a fault. It is what a machine whose screens
            // lunette cannot see looks like, and the provider keeps whatever
            // extent it had rather than being told the desktop is empty.
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

/// Runs a provider call, reporting a failure rather than propagating it.
///
/// A Lua caller gets a boolean: driving the host desktop is best-effort — the
/// user may have revoked a permission, or the host session may have gone — and
/// a script that raised on every refused keystroke would be unwritable. The log
/// line is where the reason survives.
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
/// test that is not about it uses. A pointer to a host sink is refused rather
/// than silently accepted, so a configuration pointing at a mirror it cannot
/// drive is told so by the return value.
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
/// Two enumerations rather than one, because they are two vocabularies: the
/// compositor's maps to a `BTN_*` code at the seat, and the host's maps to an
/// evdev code at the provider. They happen to carry the same five buttons, and
/// this is where that is stated once rather than assumed.
#[must_use]
pub const fn host_button(button: PointerButton) -> HostButton {
    match button {
        PointerButton::Left => HostButton::Left,
        PointerButton::Right => HostButton::Right,
        PointerButton::Middle => HostButton::Middle,
        // `BTN_SIDE` and `BTN_EXTRA`, which a host desktop reads as back and
        // forward. The evdev names describe the switch and the protocol names
        // describe what it does, and this is where the two are tied together.
        PointerButton::Back => HostButton::Side,
        PointerButton::Forward => HostButton::Extra,
    }
}

/// The host's name for a key the compositor's numbering named.
///
/// Both are evdev codes, so this is a validation rather than a translation: it
/// is where a code outside the set the provider declared to the kernel is
/// rejected, instead of being sent and dropped without a word.
#[must_use]
pub fn host_key(key: Keycode) -> Option<VirtualKey> {
    VirtualKey::from_evdev(u16::try_from(key.evdev()).ok()?)
}

/// The host's modifier mask for the closed set the compositor carries.
///
/// The bits are XKB modifier indices on both sides, so the two enumerations
/// agree by construction; this is where that is stated once rather than assumed
/// at each call site.
///
/// `None` for a set containing `Mod3`, which neither
/// `zwp_virtual_keyboard_v1`'s mask nor uinput's representative-key table has a
/// bit for. Refusing the whole set is the honest answer: sending the rest would
/// leave the host holding modifiers the caller did not ask for, which is worse
/// than sending nothing and saying so.
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
