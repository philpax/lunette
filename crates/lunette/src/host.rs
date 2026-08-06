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
        DesktopLayout, HostInput, MonitorMapping, PanelPoint, PointerButton as HostButton,
        SurfaceTransform,
    },
    monitor::{MonitorKey, Roster},
};
use lunette_compositor::protocol::PointerButton;
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
}

impl HostPointer {
    #[must_use]
    pub const fn new(input: HostInput) -> Self {
        Self {
            input: RefCell::new(input),
            monitors: RefCell::new(Vec::new()),
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
            // `SurfaceTransform::Normal` because the roster carries no
            // transform: nothing enumerates the host's `wl_output`s yet, and the
            // transform is reported by the `geometry` event that enumeration
            // would read. A rotated monitor therefore maps as though it were
            // upright until that lands.
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

    fn commit(&self) {
        self.input.borrow_mut().commit();
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
