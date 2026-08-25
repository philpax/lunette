//! Compiles XKB keymaps and provides forward and reverse key queries.
//!
//! [`Keymap`] owns libxkbcommon state. The handle is neither `Send` nor `Sync`
//! because libxkbcommon keymaps are not thread-safe. Threads exchange
//! [`KeymapText`] and compile independent copies in their own XKB contexts.
//!
//! Reverse lookup has no libxkbcommon primitive. [`Keymap`] enumerates keycodes
//! under supported level-selecting modifiers once during compilation and caches
//! the result for later queries.
//!
//! Queries use layout group zero. The query API carries no group and cannot read
//! or set the active group, so a multi-group keymap could return results for the
//! wrong group after a layout switch. Explicit multi-group configurations are
//! rejected. An inherited multi-group default is narrowed to its first layout
//! before compilation when its RMLVO names are available.

use std::{collections::HashMap, error::Error, fmt, sync::Arc};

use tracing::warn;
use xkbcommon::xkb;

use crate::protocol::{
    KeyModifier, Keycode, KeymapConfig, KeymapDefaults, KeymapText, Keysym, LayoutName,
    ModifierState,
};

/// A compiled keyboard layout with forward and reverse key queries.
pub struct Keymap {
    text: Arc<KeymapText>,
    keymap: xkb::Keymap,
    layouts: Vec<LayoutName>,
    reverse: HashMap<Keysym, KeyStroke>,
}

impl Keymap {
    /// Compiles a layout from configuration, using the desktop defaults for
    /// fields the configuration leaves absent.
    ///
    /// # Errors
    ///
    /// Returns [`KeymapError`] when the RMLVO names do not compile or when the
    /// configuration names more than one layout group.
    pub fn compile(config: &KeymapConfig, defaults: &KeymapDefaults) -> Result<Self, KeymapError> {
        Self::compile_resolved(&resolve(config, defaults))
    }

    /// Compiles names that were resolved against the defaults.
    ///
    /// The same resolved names can be passed to libxkbcommon and smithay so both
    /// contexts compile the same layout.
    ///
    /// # Errors
    ///
    /// Returns [`KeymapError`] when the names do not compile or when an explicit
    /// configuration names more than one layout group.
    pub(crate) fn compile_resolved(resolved: &ResolvedNames) -> Result<Self, KeymapError> {
        if let LayoutOrigin::Narrowed { from } = &resolved.origin {
            warn!(
                inherited = %from,
                using = resolved.names.layout.as_deref().unwrap_or_default(),
                "the desktop's default names several layouts and a seat carries one, so the first \
                 was taken; a second layout wants a second seat",
            );
        }

        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let name = |value: &Option<String>| value.clone().unwrap_or_default();
        let config = &resolved.names;

        let keymap = xkb::Keymap::new_from_names(
            &context,
            &name(&config.rules),
            &name(&config.model),
            &name(&config.layout),
            &name(&config.variant),
            config.options.clone(),
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .ok_or_else(|| KeymapError {
            kind: KeymapErrorKind::Names {
                config: Box::new(config.clone()),
            },
        })?;

        let count = keymap.num_layouts();
        if count > 1 {
            match resolved.origin {
                LayoutOrigin::Configured => {
                    return Err(KeymapError {
                        kind: KeymapErrorKind::ManyLayouts { count },
                    });
                }
                LayoutOrigin::Inherited | LayoutOrigin::Narrowed { .. } => warn!(
                    count,
                    "the inherited layout carries several groups and no default layout was named \
                     to narrow it to; queries will answer for the first group whichever one the \
                     seat is on",
                ),
            }
        }

        Self::from_xkb(&keymap)
    }

    /// Compiles a keymap from XKB version 1 text.
    ///
    /// Text can cross thread boundaries; the compiled keymap remains in the
    /// context that created it.
    ///
    /// # Errors
    ///
    /// Returns [`KeymapError`] when the text is invalid or contains more than
    /// one layout group. Text has no RMLVO names from which to narrow a group.
    pub fn from_text(text: &KeymapText) -> Result<Self, KeymapError> {
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let keymap = xkb::Keymap::new_from_string(
            &context,
            text.as_str().to_owned(),
            xkb::KEYMAP_FORMAT_TEXT_V1,
            xkb::KEYMAP_COMPILE_NO_FLAGS,
        )
        .ok_or(KeymapError {
            kind: KeymapErrorKind::Text,
        })?;

        let count = keymap.num_layouts();
        if count > 1 {
            return Err(KeymapError {
                kind: KeymapErrorKind::ManyLayouts { count },
            });
        }

        Self::from_xkb(&keymap)
    }

    /// Returns the XKB text used to transfer the layout between threads and to
    /// publish it to clients.
    #[must_use]
    pub fn text(&self) -> &Arc<KeymapText> {
        &self.text
    }

    /// Returns the layout names in declaration order.
    #[must_use]
    pub fn layouts(&self) -> &[LayoutName] {
        &self.layouts
    }

    /// Returns the keysym produced by `key` with `modifiers` held.
    ///
    /// Returns `None` when the key produces no keysym in that state.
    #[must_use]
    pub fn symbol(&self, key: Keycode, modifiers: &ModifierState) -> Option<Keysym> {
        let mut state = xkb::State::new(&self.keymap);
        apply(&self.keymap, &mut state, modifiers);
        symbol_at(&state, key)
    }

    /// Returns the text produced by `key` with `modifiers` held.
    ///
    /// Returns `None` for keys that produce no character, such as function,
    /// arrow, and modifier keys.
    #[must_use]
    pub fn character(&self, key: Keycode, modifiers: &ModifierState) -> Option<String> {
        let mut state = xkb::State::new(&self.keymap);
        apply(&self.keymap, &mut state, modifiers);

        let text = state.key_get_utf8(xkb_keycode(key));
        (!text.is_empty()).then_some(text)
    }

    /// Returns a key and modifiers that produce `symbol`, if one exists.
    ///
    /// The result prefers fewer modifiers, then the lowest keycode. This keeps
    /// unshifted letters unmodified and prefers number-row digits to keypad digits.
    #[must_use]
    pub fn stroke(&self, symbol: Keysym) -> Option<KeyStroke> {
        self.reverse.get(&symbol).cloned()
    }

    /// Returns a key and modifiers that type `character`, if one exists.
    ///
    /// It tries the legacy XKB keysym before the canonical Unicode keysym because
    /// ordinary layouts commonly bind names such as `XK_A`.
    #[must_use]
    pub fn stroke_for(&self, character: char) -> Option<KeyStroke> {
        let legacy = Keysym::from_raw(xkb::utf32_to_keysym(character as u32).raw());
        self.stroke(legacy)
            .or_else(|| self.stroke(Keysym::from_char(character)))
    }

    /// Serializes the keymap and builds its layout list and reverse lookup.
    ///
    /// Serialization can fail even after compilation. The text is required for
    /// client publication and for restoring a layout after synthetic replacement.
    fn from_xkb(keymap: &xkb::Keymap) -> Result<Self, KeymapError> {
        let text = KeymapText::new(keymap.get_as_string(xkb::KEYMAP_FORMAT_TEXT_V1)).ok_or(
            KeymapError {
                kind: KeymapErrorKind::Serialisation,
            },
        )?;

        let layouts = (0..keymap.num_layouts())
            .map(|index| LayoutName::new(keymap.layout_get_name(index)))
            .collect();

        Ok(Self {
            text: Arc::new(text),
            layouts,
            reverse: build_reverse(keymap),
            keymap: keymap.clone(),
        })
    }
}

impl fmt::Debug for Keymap {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Keymap")
            .field("layouts", &self.layouts)
            .field("symbols", &self.reverse.len())
            .finish_non_exhaustive()
    }
}

/// A key and the modifiers required to produce a keysym.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyStroke {
    pub key: Keycode,
    pub modifiers: ModifierState,
}

/// An error produced while compiling or serializing a keymap.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeymapError {
    kind: KeymapErrorKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum KeymapErrorKind {
    /// The RMLVO names did not produce a keymap.
    Names { config: Box<KeymapConfig> },
    /// The text did not parse as an XKB version 1 keymap.
    Text,
    /// The compiled keymap could not be serialized to XKB text.
    Serialisation,
    /// The keymap contains more than one layout group.
    ManyLayouts { count: u32 },
}

impl fmt::Display for KeymapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.kind {
            KeymapErrorKind::Names { config } => write!(
                f,
                "keymap: no layout compiled from rules {}, model {}, layout {}, variant {}, \
                 options {}",
                described(config.rules.as_deref()),
                described(config.model.as_deref()),
                described(config.layout.as_deref()),
                described(config.variant.as_deref()),
                described(config.options.as_deref()),
            ),
            KeymapErrorKind::Text => {
                f.write_str("keymap: the text supplied is not a keymap libxkbcommon accepts")
            }
            KeymapErrorKind::Serialisation => {
                f.write_str("keymap: the compiled layout would not serialise back to text")
            }
            KeymapErrorKind::ManyLayouts { count } => write!(
                f,
                "keymap: {count} layout groups were asked for, and lunette serves one; there is no \
                 way to read or set the active group, so a query would answer for the first \
                 whichever group the seat is on"
            ),
        }
    }
}

impl Error for KeymapError {}

/// RMLVO names resolved from configuration and desktop defaults.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ResolvedNames {
    pub(crate) names: KeymapConfig,
    pub(crate) origin: LayoutOrigin,
}

/// Indicates whether the layout was configured, inherited, or narrowed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum LayoutOrigin {
    /// The configuration supplied the layout.
    Configured,
    /// The layout came from the defaults without narrowing.
    Inherited,
    /// The defaults supplied multiple layouts and the first was retained.
    Narrowed { from: String },
}

/// Resolves configuration fields against desktop defaults.
///
/// The variant follows the layout it was written for. A configured layout does
/// not inherit a variant from a different default layout.
pub(crate) fn resolve(config: &KeymapConfig, defaults: &KeymapDefaults) -> ResolvedNames {
    let fallback = defaults.names();
    let inherited = |named: &Option<String>, default: &Option<String>| {
        named.clone().or_else(|| default.clone())
    };

    let mut names = KeymapConfig {
        rules: inherited(&config.rules, &fallback.rules),
        model: inherited(&config.model, &fallback.model),
        layout: config.layout.clone(),
        variant: config.variant.clone(),
        options: inherited(&config.options, &fallback.options),
    };

    if config.layout.is_some() {
        return ResolvedNames {
            names,
            origin: LayoutOrigin::Configured,
        };
    }

    names.layout = fallback.layout.clone();
    names.variant = inherited(&config.variant, &fallback.variant);

    let Some(layout) = names.layout.clone().filter(|layout| layout.contains(',')) else {
        return ResolvedNames {
            names,
            origin: LayoutOrigin::Inherited,
        };
    };

    names.layout = Some(first_entry(&layout));
    // Layout and variant lists are positional; an empty first variant keeps the
    // first layout unvaried.
    names.variant = names.variant.as_deref().map(first_entry);

    ResolvedNames {
        names,
        origin: LayoutOrigin::Narrowed { from: layout },
    }
}

/// Returns the first trimmed entry of a comma-separated RMLVO list.
fn first_entry(list: &str) -> String {
    list.split(',').next().unwrap_or_default().trim().to_owned()
}

/// Level-selecting modifier combinations, ordered by lookup preference.
///
/// Combinations with fewer modifiers come first. `Control`, `Alt`, and `Logo`
/// are excluded because they do not select character levels. `NumLock` is
/// excluded so keypad digits do not outrank the number row.
const LEVEL_MODIFIERS: &[&[KeyModifier]] = &[
    &[],
    &[KeyModifier::Shift],
    &[KeyModifier::Mod5],
    &[KeyModifier::Mod3],
    &[KeyModifier::Shift, KeyModifier::Mod5],
    &[KeyModifier::Shift, KeyModifier::Mod3],
];

/// Builds the reverse lookup for the supported modifier combinations.
///
/// The combination order selects the fewest modifiers, and ascending keycodes
/// select the lowest keycode when two strokes use the same number.
fn build_reverse(keymap: &xkb::Keymap) -> HashMap<Keysym, KeyStroke> {
    let mut reverse = HashMap::new();
    let min = keymap.min_keycode().raw();
    let max = keymap.max_keycode().raw();

    for combination in LEVEL_MODIFIERS {
        let modifiers: ModifierState = combination.iter().copied().collect();
        let mut state = xkb::State::new(keymap);
        apply(keymap, &mut state, &modifiers);

        for raw in min..=max {
            let Some(key) = evdev_keycode(raw) else {
                continue;
            };
            let Some(symbol) = symbol_at(&state, key) else {
                continue;
            };
            reverse.entry(symbol).or_insert_with(|| KeyStroke {
                key,
                modifiers: modifiers.clone(),
            });
        }
    }

    reverse
}

/// Applies a modifier set directly to XKB state without key events.
///
/// Direct masks keep the queried state accurate and do not synthesize key
/// events for modifiers not present in the requested state.
fn apply(keymap: &xkb::Keymap, state: &mut xkb::State, modifiers: &ModifierState) {
    let (depressed, locked) = masks(keymap, modifiers);
    state.update_mask(depressed, 0, locked, 0, 0, 0);
}

/// Converts modifiers into XKB's depressed and locked masks.
///
/// Lock modifiers use the locked mask. Putting them in the depressed mask would
/// make the next state update toggle them off.
fn masks(keymap: &xkb::Keymap, modifiers: &ModifierState) -> (xkb::ModMask, xkb::ModMask) {
    let mut depressed = 0;
    let mut locked = 0;

    for modifier in modifiers {
        let index = keymap.mod_get_index(xkb_name(*modifier));
        if index == xkb::MOD_INVALID {
            continue;
        }
        let bit = 1 << index;
        if modifier.is_lock() {
            locked |= bit;
        } else {
            depressed |= bit;
        }
    }

    (depressed, locked)
}

/// Returns the XKB name corresponding to a protocol modifier.
///
/// The higher modifiers use positional XKB names such as `Mod1` and `Mod4`;
/// this mapping gives them their protocol meanings.
const fn xkb_name(modifier: KeyModifier) -> &'static str {
    match modifier {
        KeyModifier::Shift => xkb::MOD_NAME_SHIFT,
        KeyModifier::CapsLock => xkb::MOD_NAME_CAPS,
        KeyModifier::Control => xkb::MOD_NAME_CTRL,
        KeyModifier::Alt => xkb::MOD_NAME_ALT,
        KeyModifier::NumLock => xkb::MOD_NAME_NUM,
        KeyModifier::Mod3 => xkb::MOD_NAME_MOD3,
        KeyModifier::Logo => xkb::MOD_NAME_LOGO,
        KeyModifier::Mod5 => xkb::MOD_NAME_ISO_LEVEL3_SHIFT,
    }
}

/// Returns the non-zero keysym produced by `key` in the current state.
fn symbol_at(state: &xkb::State, key: Keycode) -> Option<Keysym> {
    let symbol = state.key_get_one_sym(xkb_keycode(key));
    (symbol.raw() != 0).then(|| Keysym::from_raw(symbol.raw()))
}

/// Converts an evdev keycode to XKB's numbering, which starts eight higher.
fn xkb_keycode(key: Keycode) -> xkb::Keycode {
    xkb::Keycode::new(key.evdev().saturating_add(XKB_KEYCODE_OFFSET))
}

/// Converts an XKB keycode to an evdev keycode that fits the Wayland protocol.
///
/// XKB reserves the eight values below the evdev range, and the protocol carries
/// eight-bit X11-compatible keycodes. Values outside that range cannot be sent
/// to a client and are excluded from reverse lookup.
fn evdev_keycode(raw: u32) -> Option<Keycode> {
    (XKB_KEYCODE_OFFSET..=X11_MAX_KEYCODE)
        .contains(&raw)
        .then(|| Keycode::from_evdev(raw - XKB_KEYCODE_OFFSET))
}

/// XKB's offset from the evdev keycode range.
pub(crate) const XKB_KEYCODE_OFFSET: u32 = 8;

/// Highest keycode representable by the eight-bit X11-compatible protocol.
pub(crate) const X11_MAX_KEYCODE: u32 = 255;

fn described(value: Option<&str>) -> &str {
    value.unwrap_or("(the default)")
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    /// Compiles the explicit US fixture so tests do not depend on host defaults.
    fn us() -> Keymap {
        Keymap::compile(
            &KeymapConfig {
                layout: Some("us".to_owned()),
                ..KeymapConfig::default()
            },
            &KeymapDefaults::default(),
        )
        .expect("the us layout compiles")
    }

    /// Compiles the German fixture with a populated third level.
    fn german() -> Keymap {
        Keymap::compile(
            &KeymapConfig {
                layout: Some("de".to_owned()),
                ..KeymapConfig::default()
            },
            &KeymapDefaults::default(),
        )
        .expect("the de layout compiles")
    }

    const KEY_A: Keycode = Keycode::from_evdev(30);
    const KEY_Q: Keycode = Keycode::from_evdev(16);

    fn modifiers(items: &[KeyModifier]) -> ModifierState {
        items.iter().copied().collect()
    }

    #[test]
    fn a_key_with_no_modifiers_produces_the_character_the_layout_defines() {
        let keymap = us();

        assert_eq!(
            keymap.character(KEY_A, &modifiers(&[])).as_deref(),
            Some("a")
        );
    }

    #[test]
    fn a_key_with_shift_produces_the_layouts_shifted_character() {
        let keymap = us();

        assert_eq!(
            keymap
                .character(KEY_A, &modifiers(&[KeyModifier::Shift]))
                .as_deref(),
            Some("A"),
        );
    }

    #[test]
    fn a_key_on_a_third_level_needs_the_modifier_that_selects_it() {
        // Mod5 selects the third level; the unmodified assertion checks the
        // second level remains unchanged.
        let keymap = german();

        assert_eq!(
            keymap
                .character(KEY_Q, &modifiers(&[KeyModifier::Mod5]))
                .as_deref(),
            Some("@"),
        );
        assert_eq!(
            keymap.character(KEY_Q, &modifiers(&[])).as_deref(),
            Some("q")
        );
    }

    #[test]
    fn a_key_that_types_nothing_reports_nothing_rather_than_an_empty_string() {
        let keymap = us();
        let shift = Keycode::from_evdev(42);

        assert_eq!(keymap.character(shift, &modifiers(&[])), None);
        assert!(keymap.symbol(shift, &modifiers(&[])).is_some());
    }

    #[test]
    fn a_keycode_the_layout_does_not_bind_produces_no_keysym() {
        let keymap = us();
        let absent = Keycode::from_evdev(600);

        assert_eq!(keymap.symbol(absent, &modifiers(&[])), None);
        assert_eq!(keymap.character(absent, &modifiers(&[])), None);
    }

    #[test]
    fn the_reverse_lookup_round_trips_every_keysym_the_layout_expresses() {
        // Use the independent forward lookup so a broken inversion cannot make
        // both sides of the assertion pass.
        for keymap in [us(), german()] {
            assert!(!keymap.reverse.is_empty());
            for (symbol, stroke) in &keymap.reverse {
                assert_eq!(
                    keymap.symbol(stroke.key, &stroke.modifiers),
                    Some(*symbol),
                    "{symbol} did not round-trip through {stroke:?}",
                );
            }
        }
    }

    #[test]
    fn the_reverse_lookup_prefers_the_unmodified_key() {
        let keymap = us();
        let lower = keymap
            .stroke_for('a')
            .expect("the us layout can type a lowercase a");

        assert_eq!(lower.key, KEY_A);
        assert!(lower.modifiers.is_empty());
    }

    #[test]
    fn a_character_that_needs_a_modifier_reports_it() {
        let keymap = us();
        let upper = keymap
            .stroke_for('A')
            .expect("the us layout can type a capital A");

        assert_eq!(upper.key, KEY_A);
        assert_eq!(upper.modifiers, modifiers(&[KeyModifier::Shift]));
    }

    #[test]
    fn a_character_that_lives_on_a_third_level_reports_that_modifier() {
        let keymap = german();
        let at = keymap
            .stroke_for('@')
            .expect("the de layout can type an at sign");

        assert_eq!(at.key, KEY_Q);
        assert_eq!(at.modifiers, modifiers(&[KeyModifier::Mod5]));
    }

    #[test]
    fn a_keysym_the_layout_cannot_express_is_absent_rather_than_mapped_wrongly() {
        let keymap = us();

        assert_eq!(keymap.stroke_for('\u{2603}'), None, "a snowman");
        assert_eq!(keymap.stroke_for('\u{4e00}'), None, "a han character");
        assert_eq!(keymap.stroke_for('ß'), None, "on a us layout");
    }

    #[test]
    fn a_layout_the_de_keymap_has_is_reachable_and_the_us_one_does_not_have_it() {
        assert!(german().stroke_for('ß').is_some());
        assert_eq!(us().stroke_for('ß'), None);
    }

    #[test]
    fn the_layout_list_names_what_was_compiled() {
        let keymap = us();

        assert_eq!(keymap.layouts().len(), 1);
        assert!(
            keymap.layouts()[0].as_str().contains("US"),
            "the layout is {}",
            keymap.layouts()[0],
        );
    }

    #[test]
    fn a_keymap_with_several_layout_groups_is_refused_rather_than_answered_for_the_first() {
        // The query API has no active-group parameter, so accepting this
        // configuration would make results depend on an unobservable group.
        let error = Keymap::compile(
            &KeymapConfig {
                layout: Some("us,de".to_owned()),
                ..KeymapConfig::default()
            },
            &KeymapDefaults::default(),
        )
        .expect_err("two layout groups are more than lunette serves");

        assert!(error.to_string().starts_with("keymap: "));
        assert!(
            error.to_string().contains("layout groups"),
            "the message does not say what was wrong: {error}",
        );
    }

    /// Supplies an inherited multi-layout desktop default for resolution tests.
    fn two_inherited_layouts() -> KeymapDefaults {
        KeymapDefaults::new(KeymapConfig {
            layout: Some("us,de".to_owned()),
            ..KeymapConfig::default()
        })
    }

    #[test]
    fn an_inherited_default_naming_several_layouts_is_narrowed_rather_than_refused() {
        // Inherited multi-layout defaults are narrowed so an ordinary desktop
        // configuration still receives its default seat.
        let keymap = Keymap::compile(&KeymapConfig::default(), &two_inherited_layouts())
            .expect("an inherited two-layout default is narrowed, not refused");

        assert_eq!(keymap.layouts().len(), 1);
        assert!(
            keymap.layouts()[0].as_str().contains("US"),
            "the first entry of the inherited list is the one kept, not {}",
            keymap.layouts()[0],
        );
        assert_eq!(
            keymap.stroke_for('ß'),
            None,
            "the German half is not loaded"
        );
    }

    #[test]
    fn a_configuration_naming_several_layouts_is_still_refused() {
        // Explicit multi-layout configuration remains an error even when the
        // desktop default also contains multiple layouts.
        let error = Keymap::compile(
            &KeymapConfig {
                layout: Some("us,de".to_owned()),
                ..KeymapConfig::default()
            },
            &two_inherited_layouts(),
        )
        .expect_err("a configuration that names two layouts is refused");

        assert!(error.to_string().contains("layout groups"));
    }

    #[test]
    fn a_configured_layout_wins_over_the_inherited_one() {
        let keymap = Keymap::compile(
            &KeymapConfig {
                layout: Some("de".to_owned()),
                ..KeymapConfig::default()
            },
            &two_inherited_layouts(),
        )
        .expect("the configured layout compiles");

        assert!(keymap.stroke_for('ß').is_some());
    }

    #[test]
    fn resolution_takes_each_absent_name_from_the_defaults() {
        let resolved = resolve(
            &KeymapConfig {
                model: Some("pc105".to_owned()),
                ..KeymapConfig::default()
            },
            &KeymapDefaults::new(KeymapConfig {
                rules: Some("evdev".to_owned()),
                model: Some("pc104".to_owned()),
                layout: Some("de".to_owned()),
                variant: Some("neo".to_owned()),
                options: Some("grp:alt_shift_toggle".to_owned()),
            }),
        );

        assert_eq!(
            resolved,
            ResolvedNames {
                names: KeymapConfig {
                    rules: Some("evdev".to_owned()),
                    model: Some("pc105".to_owned()),
                    layout: Some("de".to_owned()),
                    variant: Some("neo".to_owned()),
                    options: Some("grp:alt_shift_toggle".to_owned()),
                },
                origin: LayoutOrigin::Inherited,
            },
        );
    }

    #[test]
    fn narrowing_takes_the_variant_that_belongs_to_the_layout_it_kept() {
        let resolved = resolve(
            &KeymapConfig::default(),
            &KeymapDefaults::new(KeymapConfig {
                layout: Some("us, de".to_owned()),
                variant: Some("dvorak,neo".to_owned()),
                ..KeymapConfig::default()
            }),
        );

        assert_eq!(resolved.names.layout.as_deref(), Some("us"));
        assert_eq!(resolved.names.variant.as_deref(), Some("dvorak"));
        assert_eq!(
            resolved.origin,
            LayoutOrigin::Narrowed {
                from: "us, de".to_owned()
            },
        );
    }

    #[test]
    fn a_configured_layout_does_not_inherit_the_desktops_variant() {
        // A configured layout does not inherit a variant belonging to the
        // desktop's different default layout.
        let resolved = resolve(
            &KeymapConfig {
                layout: Some("us".to_owned()),
                ..KeymapConfig::default()
            },
            &KeymapDefaults::new(KeymapConfig {
                layout: Some("de".to_owned()),
                variant: Some("neo".to_owned()),
                ..KeymapConfig::default()
            }),
        );

        assert_eq!(resolved.names.variant, None);
        assert_eq!(resolved.origin, LayoutOrigin::Configured);
    }

    #[test]
    fn resolution_is_idempotent_on_the_names_it_produced() {
        // A resolved layout is already single-valued, so resolving it again
        // must preserve its names and origin.
        let once = resolve(&KeymapConfig::default(), &two_inherited_layouts());
        let twice = resolve(&once.names, &two_inherited_layouts());

        assert_eq!(twice.names, once.names);
        assert_eq!(twice.origin, LayoutOrigin::Configured);
    }

    #[test]
    fn a_layout_that_does_not_exist_is_refused_rather_than_silently_defaulted() {
        let error = Keymap::compile(
            &KeymapConfig {
                layout: Some("this-is-not-a-layout".to_owned()),
                ..KeymapConfig::default()
            },
            &KeymapDefaults::default(),
        )
        .expect_err("a nonexistent layout does not compile");

        assert!(error.to_string().starts_with("keymap: "));
        assert!(error.to_string().contains("this-is-not-a-layout"));
    }

    #[test]
    fn a_keymap_round_trips_through_its_text() {
        let original = us();
        let recompiled =
            Keymap::from_text(original.text()).expect("a keymap's own text recompiles");

        assert_eq!(recompiled.layouts(), original.layouts());
        assert_eq!(recompiled.stroke_for('A'), original.stroke_for('A'));
        assert_eq!(recompiled.text(), original.text());
    }

    #[test]
    fn text_that_is_not_a_keymap_is_refused() {
        let text = KeymapText::new("this is not a keymap").expect("non-empty");

        assert!(Keymap::from_text(&text).is_err());
    }

    #[test]
    fn a_lock_serialises_into_the_locked_mask_and_not_the_depressed_one() {
        let keymap = us();
        let (depressed, locked) = masks(
            &keymap.keymap,
            &modifiers(&[KeyModifier::CapsLock, KeyModifier::Control]),
        );

        assert_ne!(depressed, 0, "control is depressed");
        assert_ne!(locked, 0, "caps lock is locked");
        assert_eq!(depressed & locked, 0, "no bit is in both masks");
    }

    #[test]
    fn an_empty_modifier_set_serialises_to_no_bits() {
        let keymap = us();

        assert_eq!(masks(&keymap.keymap, &modifiers(&[])), (0, 0));
    }

    #[test]
    fn an_xkb_keycode_below_the_offset_is_not_a_key_a_client_can_be_told_about() {
        assert_eq!(evdev_keycode(0), None);
        assert_eq!(evdev_keycode(7), None);
        assert_eq!(evdev_keycode(8), Some(Keycode::from_evdev(0)));
        assert_eq!(evdev_keycode(255), Some(Keycode::from_evdev(247)));
        assert_eq!(evdev_keycode(256), None);
    }
}
