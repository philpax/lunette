use std::fmt;

use lunette_luau::closed_set;

closed_set! {
    /// A pointer button accepted by the input protocol.
    ///
    /// The compositor maps these names to evdev button codes when it sends input.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum PointerButton {
        Left = "left",
        Right = "right",
        Middle = "middle",
        Back = "back",
        Forward = "forward",
    }
}

closed_set! {
    /// The input domain for a sink.
    ///
    /// Window sinks route events through a compositor seat to a hosted client.
    /// Host sinks route events through the host desktop's input provider. Window
    /// sinks have independent pointer and keyboard focus per seat; host sinks share
    /// the host desktop's single pointer and keyboard focus.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum InputDomain {
        Window = "window",
        Host = "host",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ScrollAxis {
    Vertical,
    Horizontal,
}

/// A scroll value that preserves its source unit.
///
/// Continuous values are surface-local pixel distances; discrete values are
/// whole wheel detents. Wayland clients use the distinction to choose kinetic
/// scrolling; the detent count remains available for protocol versions that
/// support it, and the continuous axis value remains available for older
/// clients.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ScrollDelta {
    Continuous(f64),
    Discrete(i32),
}

/// Surface-local units represented by one wheel detent in `wl_pointer.axis`.
///
/// Discrete deltas multiply by this value for clients. Host input divides a
/// continuous distance by it to obtain wheel detents.
pub const SURFACE_UNITS_PER_DETENT: f64 = 10.0;

/// A Linux evdev keycode used by lunette's input protocol.
///
/// XKB keymaps and `wl_keyboard` use keycodes eight higher than evdev. The
/// conversion happens when a keymap or Wayland client consumes this value.
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

closed_set! {
    /// A keyboard modifier accepted by the input protocol.
    ///
    /// `NAMES` and modifier-state arrays preserve this declaration order.
    /// Modifier serialization resolves each name to its XKB mask index.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum KeyModifier {
        Shift = "shift",
        CapsLock = "capsLock",
        Control = "control",
        Alt = "alt",
        NumLock = "numLock",
        Mod3 = "mod3",
        Logo = "logo",
        Mod5 = "mod5",
    }
}

impl KeyModifier {
    /// Whether this modifier is serialized in XKB's locked mask.
    ///
    /// CapsLock and NumLock are locked; every other modifier is depressed.
    #[must_use]
    pub const fn is_lock(self) -> bool {
        matches!(self, Self::CapsLock | Self::NumLock)
    }
}

/// An X11 keysym represented by its raw numeric value.
///
/// The raw value crosses compositor-thread and Lua boundaries because xkbcommon
/// objects are not thread-safe. X11 and xkb define this numeric space, which
/// Wayland keymaps use.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Keysym(u32);

impl Keysym {
    /// The base of XKB's Unicode keysym range.
    ///
    /// A Unicode keysym is `0x0100_0000 | codepoint`.
    const UNICODE_BASE: u32 = 0x0100_0000;

    #[must_use]
    pub const fn from_raw(raw: u32) -> Self {
        Self(raw)
    }

    #[must_use]
    pub const fn raw(self) -> u32 {
        self.0
    }

    /// The canonical Unicode keysym for a character.
    ///
    /// This uses the Unicode encoding. A legacy alias such as Latin-1 or a
    /// keypad keysym does not cover every character, so generated keymaps keep
    /// one stable representation.
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
