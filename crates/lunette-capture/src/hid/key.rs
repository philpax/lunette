//! Linux-only: the key and button codes are Linux's `input-event-codes.h`.
//!
//! The keys and buttons lunette can send to the host's keyboard and pointer
//! are closed sets. The kernel and the Wayland protocols carry the same codes
//! as integers.
//!
//! Every value here is an evdev code, the vocabulary both providers use.
//! uinput accepts evdev codes directly, and `zwp_virtual_keyboard_v1`'s
//! `key` request is documented as taking an evdev code as well. WayVR's
//! `VirtualKey` is numbered in X11 keycodes and subtracts eight at every call
//! site. No third consumer uses the X11 numbering, so the offset is not
//! reproduced here.
//!
//! Nothing in this file does I/O, so all of it is exercised directly.

use std::fmt;

variants! {
    /// One key on a keyboard, named by its Linux evdev code.
    ///
    /// The type is a closed set, not a `u16`, so a caller cannot invent a code
    /// the provider never declared to the kernel. A uinput device only emits
    /// the keys it set a `KEYBIT` for at creation, and the kernel silently
    /// drops a key outside [`VirtualKey::ALL`] without reporting an error.
    ///
    /// The set is the ordinary PC keyboard, including the keys a Japanese or
    /// Korean layout adds, plus the media and browser keys a modern keyboard
    /// carries. Keys outside it, a vendor's macro row or a laptop's
    /// fingerprint key, are not representable. [`Self::from_evdev`] returns
    /// [`Option`] because no variant exists for such a key.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    #[repr(u16)]
    pub enum VirtualKey {
        Escape = 1,
        Digit1 = 2,
        Digit2 = 3,
        Digit3 = 4,
        Digit4 = 5,
        Digit5 = 6,
        Digit6 = 7,
        Digit7 = 8,
        Digit8 = 9,
        Digit9 = 10,
        Digit0 = 11,
        Minus = 12,
        Equal = 13,
        Backspace = 14,
        Tab = 15,
        Q = 16,
        W = 17,
        E = 18,
        R = 19,
        T = 20,
        Y = 21,
        U = 22,
        I = 23,
        O = 24,
        P = 25,
        LeftBrace = 26,
        RightBrace = 27,
        Enter = 28,
        LeftCtrl = 29,
        A = 30,
        S = 31,
        D = 32,
        F = 33,
        G = 34,
        H = 35,
        J = 36,
        K = 37,
        L = 38,
        Semicolon = 39,
        Apostrophe = 40,
        Grave = 41,
        LeftShift = 42,
        Backslash = 43,
        Z = 44,
        X = 45,
        C = 46,
        V = 47,
        B = 48,
        N = 49,
        M = 50,
        Comma = 51,
        Dot = 52,
        Slash = 53,
        RightShift = 54,
        KeypadAsterisk = 55,
        LeftAlt = 56,
        Space = 57,
        CapsLock = 58,
        F1 = 59,
        F2 = 60,
        F3 = 61,
        F4 = 62,
        F5 = 63,
        F6 = 64,
        F7 = 65,
        F8 = 66,
        F9 = 67,
        F10 = 68,
        NumLock = 69,
        ScrollLock = 70,
        Keypad7 = 71,
        Keypad8 = 72,
        Keypad9 = 73,
        KeypadMinus = 74,
        Keypad4 = 75,
        Keypad5 = 76,
        Keypad6 = 77,
        KeypadPlus = 78,
        Keypad1 = 79,
        Keypad2 = 80,
        Keypad3 = 81,
        Keypad0 = 82,
        KeypadDot = 83,
        ZenkakuHankaku = 85,
        /// The extra key many non-US layouts place between left shift and `Z`.
        IntlBackslash = 86,
        F11 = 87,
        F12 = 88,
        /// `KEY_RO`, the Japanese layout's backslash-underscore key.
        IntlRo = 89,
        Katakana = 90,
        Hiragana = 91,
        Henkan = 92,
        KatakanaHiragana = 93,
        Muhenkan = 94,
        KeypadJpComma = 95,
        KeypadEnter = 96,
        RightCtrl = 97,
        KeypadSlash = 98,
        SysRq = 99,
        RightAlt = 100,
        Home = 102,
        Up = 103,
        PageUp = 104,
        Left = 105,
        Right = 106,
        End = 107,
        Down = 108,
        PageDown = 109,
        Insert = 110,
        Delete = 111,
        Mute = 113,
        VolumeDown = 114,
        VolumeUp = 115,
        Power = 116,
        KeypadEqual = 117,
        Pause = 119,
        KeypadComma = 121,
        Hangeul = 122,
        Hanja = 123,
        /// `KEY_YEN`, the Japanese layout's yen-pipe key.
        IntlYen = 124,
        LeftMeta = 125,
        RightMeta = 126,
        Compose = 127,
        Stop = 128,
        Again = 129,
        Undo = 131,
        Copy = 133,
        Paste = 135,
        Find = 136,
        Cut = 137,
        Help = 138,
        Menu = 139,
        Calculator = 140,
        Sleep = 142,
        Mail = 155,
        Bookmarks = 156,
        Computer = 157,
        Back = 158,
        Forward = 159,
        NextSong = 163,
        PlayPause = 164,
        PreviousSong = 165,
        StopCd = 166,
        Record = 167,
        Rewind = 168,
        HomePage = 172,
        Refresh = 173,
        ScrollUp = 177,
        ScrollDown = 178,
        F13 = 183,
        F14 = 184,
        F15 = 185,
        F16 = 186,
        F17 = 187,
        F18 = 188,
        F19 = 189,
        F20 = 190,
        F21 = 191,
        F22 = 192,
        F23 = 193,
        F24 = 194,
        Search = 217,
        BrightnessDown = 224,
        BrightnessUp = 225,
        Media = 226,
        SwitchVideoMode = 227,
    }
}

impl VirtualKey {
    /// The Linux evdev code for this key.
    #[must_use]
    pub const fn evdev_code(self) -> u16 {
        self as u16
    }

    /// The key a Linux evdev code names, or `None` when lunette has no name for
    /// it.
    ///
    /// There is no fallback variant. A code lunette cannot name is a code no
    /// provider declared, and inventing a variant would produce a key event
    /// the kernel discards without reporting it.
    #[must_use]
    pub fn from_evdev(code: u16) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|key| key.evdev_code() == code)
    }
}

impl fmt::Display for VirtualKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?} (evdev {})", self.evdev_code())
    }
}

variants! {
    /// A mouse button, named by its Linux evdev code.
    ///
    /// The enum has five buttons. WayVR's virtual pointer provider declares
    /// only `MOUSE_LEFT` through `MOUSE_MIDDLE`, so its pointer covers three.
    /// Back and forward are ordinary buttons on an ordinary mouse, and a
    /// closed set that omits them turns a user's hardware into an
    /// unrepresentable case.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    #[repr(u16)]
    pub enum PointerButton {
        Left = 0x110,
        Right = 0x111,
        Middle = 0x112,
        /// `BTN_SIDE`, which a host desktop usually reads as "back".
        Side = 0x113,
        /// `BTN_EXTRA`, which a host desktop usually reads as "forward".
        Extra = 0x114,
    }
}

impl PointerButton {
    #[must_use]
    pub const fn evdev_code(self) -> u16 {
        self as u16
    }

    #[must_use]
    pub fn from_evdev(code: u16) -> Option<Self> {
        Self::ALL
            .iter()
            .copied()
            .find(|button| button.evdev_code() == code)
    }
}

impl fmt::Display for PointerButton {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?} (evdev {:#x})", self.evdev_code())
    }
}

/// Which modifiers lunette is holding down.
///
/// The bits are the XKB modifier indices of a standard keymap: shift is bit
/// 0, lock is bit 1, control is bit 2, and `Mod1` through `Mod5` follow.
/// `zwp_virtual_keyboard_v1.modifiers` takes exactly this mask, so a second
/// numbering would have to be converted at the one call site that matters.
/// WayVR uses the same bits.
///
/// The type is a newtype, not a bare `u8`. A mask and a key code cannot be
/// transposed, and [`Self::changes`] is the single place that decides which
/// keys a modifier change implies.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyModifiers(u8);

impl KeyModifiers {
    pub const NONE: Self = Self(0);
    pub const SHIFT: Self = Self(0x01);
    pub const CAPS_LOCK: Self = Self(0x02);
    pub const CTRL: Self = Self(0x04);
    pub const ALT: Self = Self(0x08);
    pub const NUM_LOCK: Self = Self(0x10);
    pub const SUPER: Self = Self(0x40);
    pub const ALT_GR: Self = Self(0x80);

    /// The modifiers the host latches. A latched modifier stays set until
    /// pressed again, and a held modifier stays set only while its key is
    /// down.
    ///
    /// `zwp_virtual_keyboard_v1.modifiers` reports depressed and locked
    /// modifiers as separate masks, and a lock reported as depressed toggles
    /// off again on the next update.
    pub const LOCKED: Self = Self(Self::CAPS_LOCK.0 | Self::NUM_LOCK.0);

    /// Every single-bit modifier, paired with the key that produces it.
    ///
    /// Only the left-hand key of each pair is listed. Pressing one of the two
    /// keys sets the modifier, and pressing both would leave the second key
    /// stuck down when the modifier clears.
    const KEYS: [(Self, VirtualKey); 7] = [
        (Self::SHIFT, VirtualKey::LeftShift),
        (Self::CAPS_LOCK, VirtualKey::CapsLock),
        (Self::CTRL, VirtualKey::LeftCtrl),
        (Self::ALT, VirtualKey::LeftAlt),
        (Self::NUM_LOCK, VirtualKey::NumLock),
        (Self::SUPER, VirtualKey::LeftMeta),
        (Self::ALT_GR, VirtualKey::RightAlt),
    ];

    /// Reads a mask, rejecting bits no modifier claims.
    ///
    /// The unknown bits are not masked away. A caller that set a bit meant
    /// something by it, and dropping the bit is silent data loss.
    #[must_use]
    pub const fn from_bits(bits: u8) -> Option<Self> {
        const KNOWN: u8 = KeyModifiers::SHIFT.0
            | KeyModifiers::CAPS_LOCK.0
            | KeyModifiers::CTRL.0
            | KeyModifiers::ALT.0
            | KeyModifiers::NUM_LOCK.0
            | KeyModifiers::SUPER.0
            | KeyModifiers::ALT_GR.0;

        if bits & !KNOWN == 0 {
            Some(Self(bits))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn bits(self) -> u8 {
        self.0
    }

    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// The mask to report as depressed: everything that is not a lock.
    #[must_use]
    pub const fn depressed(self) -> u32 {
        (self.0 & !Self::LOCKED.0) as u32
    }

    /// The mask to report as locked.
    #[must_use]
    pub const fn locked(self) -> u32 {
        (self.0 & Self::LOCKED.0) as u32
    }

    /// The key presses and releases that take the host from `self` to `target`.
    ///
    /// This method is the whole of what a provider's `set_modifiers` decides,
    /// so both providers share it and tests exercise it without either
    /// provider.
    ///
    /// Locks are excluded. A lock toggles on the key press instead of
    /// following the key, so replaying a lock change as a press would flip it
    /// in whichever direction the host happened to be in. The host receives
    /// locks through the modifier mask instead.
    pub fn changes(self, target: Self) -> impl Iterator<Item = (VirtualKey, bool)> {
        let changed = (self.0 ^ target.0) & !Self::LOCKED.0;
        Self::KEYS
            .into_iter()
            .filter(move |(modifier, _)| changed & modifier.0 != 0)
            .map(move |(modifier, key)| (key, target.0 & modifier.0 != 0))
    }
}

impl fmt::Display for KeyModifiers {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0 == 0 {
            return f.write_str("no modifiers");
        }
        let mut first = true;
        for (modifier, key) in Self::KEYS {
            if self.contains(modifier) {
                if !first {
                    f.write_str("+")?;
                }
                write!(f, "{key:?}")?;
                first = false;
            }
        }
        Ok(())
    }
}

/// A keyboard layout, in XKB's version 1 text format.
///
/// The layout is held as text, not as a compiled `xkbcommon` keymap. The only
/// thing a provider does with it is write the bytes into a memfd and hand the
/// descriptor to `zwp_virtual_keyboard_v1.keymap`. Compiling a layout name
/// into this format is the caller's job, which also keeps this crate free of
/// `xkbcommon` and free of any assumption about where a layout comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XkbKeymap(String);

impl XkbKeymap {
    /// Wraps a keymap, rejecting an empty one.
    ///
    /// `zwp_virtual_keyboard_v1` treats an empty keymap as a protocol error,
    /// which disconnects the whole client instead of failing the one request.
    #[must_use]
    pub fn new(text: impl Into<String>) -> Option<Self> {
        let text = text.into();
        (!text.trim().is_empty()).then_some(Self(text))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The bytes to write into the memfd, terminated as the protocol requires.
    ///
    /// `zwp_virtual_keyboard_v1.keymap` takes a size that includes the
    /// terminating NUL, and a compositor that maps the file reads up to it.
    #[must_use]
    pub fn as_bytes_with_nul(&self) -> Vec<u8> {
        let mut bytes = self.0.clone().into_bytes();
        bytes.push(0);
        bytes
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::collections::BTreeSet;

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn every_key_round_trips_through_its_evdev_code() {
        for key in VirtualKey::ALL {
            assert_eq!(
                VirtualKey::from_evdev(key.evdev_code()),
                Some(*key),
                "{key} did not round-trip",
            );
        }
    }

    #[test]
    fn no_two_keys_share_an_evdev_code() {
        let codes: BTreeSet<u16> = VirtualKey::ALL.iter().map(|key| key.evdev_code()).collect();

        assert_eq!(codes.len(), VirtualKey::ALL.len());
    }

    #[test]
    fn a_code_no_key_claims_is_not_a_key() {
        // 0 is KEY_RESERVED, 84 is a gap in the table, and 767 is past KEY_MAX.
        assert_eq!(VirtualKey::from_evdev(0), None);
        assert_eq!(VirtualKey::from_evdev(84), None);
        assert_eq!(VirtualKey::from_evdev(767), None);
    }

    #[test]
    fn every_button_round_trips_through_its_evdev_code() {
        for button in PointerButton::ALL {
            assert_eq!(
                PointerButton::from_evdev(button.evdev_code()),
                Some(*button)
            );
        }
        assert_eq!(PointerButton::from_evdev(0x115), None);
    }

    #[test]
    fn a_mask_with_a_bit_no_modifier_claims_is_rejected() {
        assert_eq!(KeyModifiers::from_bits(0x20), None);
        assert_eq!(
            KeyModifiers::from_bits(0x05),
            Some(KeyModifiers::SHIFT.union(KeyModifiers::CTRL)),
        );
    }

    #[test]
    fn pressing_a_modifier_presses_exactly_its_key() {
        let changes: Vec<_> = KeyModifiers::NONE.changes(KeyModifiers::SHIFT).collect();

        assert_eq!(changes, vec![(VirtualKey::LeftShift, true)]);
    }

    #[test]
    fn releasing_a_modifier_releases_exactly_its_key() {
        let changes: Vec<_> = KeyModifiers::SHIFT.changes(KeyModifiers::NONE).collect();

        assert_eq!(changes, vec![(VirtualKey::LeftShift, false)]);
    }

    #[test]
    fn a_modifier_that_did_not_change_produces_no_key() {
        let held = KeyModifiers::SHIFT.union(KeyModifiers::CTRL);
        let changes: Vec<_> = held.changes(KeyModifiers::CTRL).collect();

        assert_eq!(changes, vec![(VirtualKey::LeftShift, false)]);
    }

    #[test]
    fn a_lock_is_never_replayed_as_a_key_press() {
        // Caps lock toggles on the press instead of following the key, so
        // replaying it would flip the host into whichever state it was not
        // already in.
        let changes: Vec<_> = KeyModifiers::NONE
            .changes(KeyModifiers::CAPS_LOCK)
            .collect();

        assert!(changes.is_empty());
    }

    #[test]
    fn a_lock_is_reported_as_locked_rather_than_as_depressed() {
        let held = KeyModifiers::CAPS_LOCK.union(KeyModifiers::CTRL);

        assert_eq!(held.depressed(), u32::from(KeyModifiers::CTRL.bits()));
        assert_eq!(held.locked(), u32::from(KeyModifiers::CAPS_LOCK.bits()));
    }

    #[test]
    fn changing_nothing_produces_no_keys() {
        let held = KeyModifiers::SHIFT.union(KeyModifiers::SUPER);

        assert_eq!(held.changes(held).count(), 0);
        assert_eq!(KeyModifiers::NONE.changes(KeyModifiers::NONE).count(), 0);
    }

    #[test]
    fn an_empty_keymap_is_not_a_keymap() {
        assert_eq!(XkbKeymap::new(""), None);
        assert_eq!(XkbKeymap::new("  \n"), None);
        assert!(XkbKeymap::new("xkb_keymap {};").is_some());
    }

    #[test]
    fn a_keymap_is_handed_over_nul_terminated() {
        let keymap = XkbKeymap::new("ab").expect("a non-empty keymap");

        assert_eq!(keymap.as_bytes_with_nul(), b"ab\0");
    }
}
