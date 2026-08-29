//! Keyboard configuration exchanged with a seat.
//!
//! Keymap text uses XKB version 1 format. Repeat delays are milliseconds, and
//! repeat rates are repeats per second, matching `wl_keyboard.repeat_info`.

use std::fmt;

/// A human-readable name for an XKB layout.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LayoutName(String);

impl LayoutName {
    #[must_use]
    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for LayoutName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// XKB version 1 text crosses compositor threads and is published through
/// `wl_keyboard.keymap`; each thread compiles its own handle because libxkbcommon
/// handles are not thread-safe.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeymapText(String);

impl KeymapText {
    /// Rejects text that is empty or entirely whitespace before it reaches a keymap
    /// upload.
    ///
    /// A keymap upload must carry a non-empty XKB text object. The receiving
    /// Wayland protocol rejects an empty payload by disconnecting the client;
    /// the failure has no recoverable request error.
    #[must_use]
    pub fn new(text: impl Into<String>) -> Option<Self> {
        let text = text.into();
        (!text.trim().is_empty()).then_some(Self(text))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

/// The optional RMLVO names passed to libxkbcommon for a seat's keymap.
///
/// An absent field is resolved from [`KeymapDefaults`]. Layout, variant, and
/// options use libxkbcommon's comma-separated list syntax.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeymapConfig {
    pub rules: Option<String>,
    pub model: Option<String>,
    pub layout: Option<String>,
    pub variant: Option<String>,
    pub options: Option<String>,
}

/// RMLVO values supplied by the application for absent configuration fields.
///
/// The binary reads `XKB_DEFAULT_*` and passes the snapshot to this library;
/// this library does not read the environment. Keeping the names lets the
/// resolver narrow an inherited multi-layout default to its first layout.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeymapDefaults(KeymapConfig);

impl KeymapDefaults {
    #[must_use]
    pub const fn new(names: KeymapConfig) -> Self {
        Self(names)
    }

    #[must_use]
    pub const fn names(&self) -> &KeymapConfig {
        &self.0
    }
}

impl Default for KeymapDefaults {
    /// Uses `us` when the application supplies no desktop default.
    ///
    /// This fixed value keeps library tests and embedders independent of the
    /// process environment; the binary can replace it with its environment snapshot.
    fn default() -> Self {
        Self(KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        })
    }
}

/// Delay and rate passed to `wl_keyboard.repeat_info` when a seat is created.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RepeatPolicy {
    pub delay: RepeatDelay,
    pub rate: RepeatRate,
}

impl Default for RepeatPolicy {
    /// Uses a 200-millisecond delay and 50 repeats per second.
    fn default() -> Self {
        Self {
            delay: RepeatDelay::from_millis(200),
            rate: RepeatRate::per_second(50),
        }
    }
}

/// A `wl_keyboard.repeat_info` delay in milliseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RepeatDelay(u16);

impl RepeatDelay {
    /// Saturates at `u16::MAX` before conversion to the protocol's signed 32-bit field.
    #[must_use]
    pub const fn from_millis(millis: u32) -> Self {
        Self(if millis > u16::MAX as u32 {
            u16::MAX
        } else {
            millis as u16
        })
    }

    #[must_use]
    pub const fn millis(self) -> i32 {
        self.0 as i32
    }
}

/// A `wl_keyboard.repeat_info` rate in repeats per second. Zero disables repeat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RepeatRate(u16);

impl RepeatRate {
    #[must_use]
    pub const fn per_second(rate: u32) -> Self {
        Self(if rate > u16::MAX as u32 {
            u16::MAX
        } else {
            rate as u16
        })
    }

    #[must_use]
    pub const fn get(self) -> i32 {
        self.0 as i32
    }
}

/// Keymap names and repeat policy supplied when a seat is created.
///
/// The two values are kept together because seat creation applies them as one
/// keyboard configuration.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyboardConfig {
    pub keymap: KeymapConfig,
    pub repeat: RepeatPolicy,
}
