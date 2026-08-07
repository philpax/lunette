//! What a seat's keyboard is configured with.
//!
//! A keymap is text in XKB's own format, which is what the protocol carries and
//! what `xkbcommon` compiles; the rest is the repeat policy that travels with
//! it. Compiling one is [`crate::keymap`]'s; this is only the shape of what is
//! asked for.

use std::fmt;

/// A keyboard layout's name, as the keymap gives it.
///
/// Human-readable rather than an identifier: `"English (US)"`, not `"us"`. It
/// is what a virtual keyboard puts on a layout switcher.
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

/// A compiled keyboard layout, in XKB's version 1 text format.
///
/// Text rather than a compiled keymap because that is the only form that
/// crosses a thread: libxkbcommon is not thread-safe, and smithay refuses a
/// compiled keymap at its own API boundary for exactly that reason
/// (`smithay-0.7.0/src/input/keyboard/mod.rs:810-815`, which recompiles the
/// string inside its own context and says so in a comment).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct KeymapText(String);

impl KeymapText {
    /// Wraps a keymap, rejecting an empty one.
    ///
    /// An empty keymap compiles to nothing and, uploaded over
    /// `zwp_virtual_keyboard_v1`, is a protocol error that disconnects the
    /// whole client rather than failing the one request.
    #[must_use]
    pub fn new(text: impl Into<String>) -> Option<Self> {
        let text = text.into();
        (!text.trim().is_empty()).then_some(Self(text))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The text, for an API that takes ownership of a `String`.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

/// Which layout a seat's keyboard is compiled from.
///
/// The five RMLVO names `xkb_keymap_new_from_names` takes. Every one is
/// optional, and absent means the name is taken from [`KeymapDefaults`] — the
/// desktop's own configuration, which is what a user who has configured a
/// layout for their session expects lunette to inherit.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeymapConfig {
    /// How the remaining four names are interpreted; `"evdev"` on Linux.
    pub rules: Option<String>,
    pub model: Option<String>,
    /// A comma-separated list, one entry per layout the keymap carries.
    pub layout: Option<String>,
    /// A comma-separated list, one entry per layout.
    pub variant: Option<String>,
    /// A comma-separated list of options, such as which key switches layout.
    pub options: Option<String>,
}

/// The names a [`KeymapConfig`] falls back to for a field it leaves absent.
///
/// libxkbcommon resolves an empty RMLVO name from the `XKB_DEFAULT_*`
/// environment variables. A library does not read the environment, so the
/// desktop's own names arrive here as a parameter instead, and the binary is
/// where they are read. That is not only house style: the defaults have to be
/// *nameable* for a multi-layout default to be narrowed to its first entry,
/// and libxkbcommon offers no way to ask a compiled keymap which RMLVO layout
/// it came from.
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
    /// libxkbcommon's own compiled-in layout, spelled out.
    ///
    /// Spelled rather than left absent so that a caller which has not read the
    /// environment — every test, and any embedder that does not want the
    /// desktop's configuration — gets the same single-group keymap on every
    /// machine. The binary replaces this with what it read from `XKB_DEFAULT_*`.
    fn default() -> Self {
        Self(KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        })
    }
}

/// How long a held key waits, and how fast it then repeats.
///
/// Policy rather than mechanism: WayVR fixes it at seat construction
/// (`mod.rs:262`), and `docs/input.md:56` puts it in Lua because it is timing
/// that should differ per input device. This carries what Lua chose.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RepeatPolicy {
    pub delay: RepeatDelay,
    pub rate: RepeatRate,
}

impl Default for RepeatPolicy {
    /// WayVR's values (`mod.rs:262`), which are also what most desktops ship.
    fn default() -> Self {
        Self {
            delay: RepeatDelay::from_millis(200),
            rate: RepeatRate::per_second(50),
        }
    }
}

/// How long a key is held before it starts repeating, in milliseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RepeatDelay(u16);

impl RepeatDelay {
    /// Saturating at `u16::MAX`, which is a little over a minute — long enough
    /// that a caller asking for more meant "never", and short enough that the
    /// value fits the `i32` the protocol carries without a cast that can wrap.
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

/// How many times a second a held key repeats. Zero disables repeat, which is
/// what `wl_keyboard.repeat_info` defines zero to mean.
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

/// Everything a seat's keyboard is created with.
///
/// A parameter struct rather than two more arguments on the seat command: the
/// keymap and the repeat policy are one cohesive decision Lua makes, and they
/// travel together to the one place that applies them.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyboardConfig {
    pub keymap: KeymapConfig,
    pub repeat: RepeatPolicy,
}
