//! What an input event carries, in the domain's own terms.
//!
//! Every one of these is a closed set or a validated newtype rather than the
//! integer the protocol carries. A keycode that is not in the evdev range, a
//! scroll distance that is not finite, and a modifier name nothing recognises
//! are all refused here rather than sent onwards and diagnosed as the
//! compositor misbehaving.

use std::fmt;

/// A pointer button.
///
/// The five a mouse actually has, rather than the whole evdev range. Mapping to
/// a `BTN_*` code belongs with the seat, which is the only place that speaks
/// the protocol's numbering.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PointerButton {
    Left,
    Right,
    Middle,
    Back,
    Forward,
}

/// Which pipeline a sink's input travels down.
///
/// A sink is somewhere pixel-space input can be delivered, and there are two
/// kinds of somewhere. A window sink reaches a client this compositor hosts,
/// through its seat. A host sink reaches the user's own desktop, through the
/// `HidProvider` in `lunette-capture`, and nothing in this crate ever sees one:
/// the domain is defined here because it is the closed set both halves name, and
/// because a caller routing input has to be able to ask which it is holding.
///
/// A type rather than a flag, so routing is an exhaustive match and a domain
/// added later cannot be silently unhandled.
///
/// This is new work. WayVR has one global binary `InputFocus { PhysicalScreen,
/// WayVR }` (`subsystem/input.rs:10`), toggled for the whole session, which
/// cannot express two hands pointing at two kinds of surface at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum InputDomain {
    /// A surface this compositor hosts.
    ///
    /// Each window is independently addressable: two seats pointing at two
    /// windows produce two cursors and two focuses.
    Window,
    /// The host desktop, behind a mirrored monitor.
    ///
    /// Every host sink shares one cursor and one keyboard focus, because the
    /// host has one of each. Two seats pointing at two mirrored monitors cannot
    /// produce two cursors, and `docs/host-desktop.md` records why that
    /// difference is exposed rather than hidden.
    Host,
}

impl InputDomain {
    /// The name Lua reads on `sink.domain`.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Window => "window",
            Self::Host => "host",
        }
    }
}

impl fmt::Display for InputDomain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ScrollAxis {
    Vertical,
    Horizontal,
}

/// How far a scroll went.
///
/// Both forms exist in the protocol and clients treat them differently: a
/// notched wheel sends discrete steps, a touchpad sends a continuous distance.
/// Collapsing them loses the distinction that decides whether a client
/// kinetically scrolls.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ScrollDelta {
    /// A distance in surface-local pixels.
    Continuous(f64),
    /// A count of wheel notches.
    Discrete(i32),
}

/// How many surface-local units `wl_pointer.axis` carries per wheel detent.
///
/// The convention every toolkit reads a continuous scroll under, and the one
/// number both directions of the conversion depend on: the compositor
/// multiplies a discrete count by it on the way to a client, and the host
/// pointer divides a continuous distance by it on the way to a wheel provider.
/// Two copies that drifted apart would make one direction stop inverting the
/// other, so there is one.
pub const SURFACE_UNITS_PER_DETENT: f64 = 10.0;

/// A key, in the Linux evdev numbering that `wl_keyboard` uses.
///
/// xkb numbers the same keys eight higher. Nothing here performs that
/// adjustment; it belongs where the keymap is consulted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Keycode(u32);

impl Keycode {
    #[must_use]
    pub const fn from_evdev(code: u32) -> Self {
        Self(code)
    }

    #[must_use]
    pub const fn evdev(self) -> u32 {
        self.0
    }
}

/// A keyboard modifier that a seat can hold down.
///
/// The order is the XKB modifier index order — shift, lock, control, then
/// `Mod1` through `Mod5` — because that is the order the masks on the wire are
/// numbered in, and a reader comparing this against a keymap's modifier list
/// should not have to reorder it in their head.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum KeyModifier {
    Shift,
    CapsLock,
    Control,
    Alt,
    NumLock,
    Mod3,
    Logo,
    Mod5,
}

impl KeyModifier {
    /// Every modifier a keymap can name.
    pub const ALL: &'static [Self] = &[
        Self::Shift,
        Self::CapsLock,
        Self::Control,
        Self::Alt,
        Self::NumLock,
        Self::Mod3,
        Self::Logo,
        Self::Mod5,
    ];

    /// The name Lua spells this modifier with, and the name it reads back.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Shift => "shift",
            Self::CapsLock => "capsLock",
            Self::Control => "control",
            Self::Alt => "alt",
            Self::NumLock => "numLock",
            Self::Mod3 => "mod3",
            Self::Logo => "logo",
            Self::Mod5 => "mod5",
        }
    }

    /// The modifier a Lua name refers to, rejecting anything else.
    ///
    /// `None` rather than a default: `'shft'` is a typo, and a modifier that
    /// silently does nothing is harder to find than an error.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|modifier| modifier.as_str() == name)
    }

    /// A modifier that only latches rather than tracking the key.
    ///
    /// A lock is reported to a client in the locked mask and never in the
    /// depressed one, and the distinction is what stops a lock toggling itself
    /// off on the next update.
    #[must_use]
    pub const fn is_lock(self) -> bool {
        matches!(self, Self::CapsLock | Self::NumLock)
    }
}

impl fmt::Display for KeyModifier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An X11 keysym: what a keycode means once a layout and modifiers are applied.
///
/// A newtype over the raw number rather than `xkbcommon`'s own `Keysym`,
/// because a keysym travels between threads and through Lua, and neither end
/// should have to name a type from a library that is not thread-safe. The
/// numbering is X11's, which is also Wayland's and xkb's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Keysym(u32);

impl Keysym {
    /// The keysym Unicode codepoints map onto, which is the range
    /// `0x0100_0000 | codepoint`.
    const UNICODE_BASE: u32 = 0x0100_0000;

    #[must_use]
    pub const fn from_raw(raw: u32) -> Self {
        Self(raw)
    }

    #[must_use]
    pub const fn raw(self) -> u32 {
        self.0
    }

    /// The keysym for a character, in the Unicode range every character has.
    ///
    /// Deliberately not the legacy Latin-1 or keypad keysyms a layout would
    /// name the same character by. Those are what a *reverse lookup* answers
    /// with; this is the canonical name a synthesised keymap binds, and one
    /// canonical form is what makes two requests for the same character
    /// deduplicate.
    #[must_use]
    pub const fn from_char(character: char) -> Self {
        Self(Self::UNICODE_BASE | character as u32)
    }
}

impl fmt::Display for Keysym {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "keysym {:#010x}", self.0)
    }
}
