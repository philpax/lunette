//! Keymaps: compiling one, asking what a key means under it, and asking which
//! key produces a given meaning.
//!
//! Entirely new work. WayVR's keymap handling is forward-only and exists to
//! draw legends on its virtual keyboard (`subsystem/hid/mod.rs:344-386`); there
//! is no reverse lookup anywhere in it, and `docs/input.md:52` asks for one.
//!
//! # One keymap per thread, because libxkbcommon is not thread-safe
//!
//! [`Keymap`] owns an `xkb::Keymap`, which is a refcounted C object with no
//! atomics, so it is neither `Send` nor `Sync` and must not be made so. That is
//! also why smithay refuses a compiled keymap at its API boundary and takes a
//! [`KeymapText`] instead, recompiling it inside its own context
//! (`smithay-0.7.0/src/input/keyboard/mod.rs:810-815`, whose comment says as
//! much).
//!
//! The consequence for lunette is that the *text* is what crosses a thread. The
//! compositor thread holds a [`Keymap`] per seat, publishes its text in the
//! snapshot, and the main thread compiles its own copy from that text when Lua
//! asks a question about it. Two compilations of one string are two
//! independent objects that agree, which is exactly what is wanted.
//!
//! # Why the reverse lookup is a table
//!
//! There is no libxkbcommon call for "which key produces this keysym". The only
//! way to answer is to try every key under every modifier combination that
//! selects a level and invert the result, which is a few thousand lookups. That
//! is cheap once and wasteful per query, so it is built with the keymap and
//! cached — the keymap changes when a seat is created or `typeText` swaps one
//! in, and not otherwise.
//!
//! # One layout group
//!
//! Every query here resolves against layout group zero, and lunette exposes no
//! way to read or set the active group: [`Keymap::stroke`] answers with a
//! keycode and modifiers, and nothing carries a group alongside them. smithay's
//! own state does track one — `KeyboardHandle::input` applies layout-switch
//! actions and `ModifiersState::serialize_back` preserves the effective layout
//! — so a keymap with several groups would have these answers drift out from
//! under it the moment a user pressed the switch.
//!
//! So a keymap carrying more than one group is refused at compile rather than
//! answered for the first. `docs/decisions.md` records the choice and what it
//! would take to lift it.

use std::{collections::HashMap, error::Error, fmt, sync::Arc};

use xkbcommon::xkb;

use crate::protocol::{
    KeyModifier, Keycode, KeymapConfig, KeymapText, Keysym, LayoutName, ModifierState,
};

/// A compiled keyboard layout, with the queries `docs/input.md:50-52` asks for.
///
/// Not `Send` and not `Sync`, and deliberately so: see the module
/// documentation.
pub struct Keymap {
    text: Arc<KeymapText>,
    keymap: xkb::Keymap,
    layouts: Vec<LayoutName>,
    /// Which key and modifiers produce each keysym the layout can express.
    reverse: HashMap<Keysym, KeyStroke>,
}

impl Keymap {
    /// Compiles the layout a caller named.
    ///
    /// A field left absent resolves to libxkbcommon's own default, which is
    /// what a user who configured a layout for their desktop expects to
    /// inherit. Everything else about this crate takes its configuration as a
    /// parameter; this one call defers to the library because "the system
    /// default layout" has no other spelling.
    ///
    /// # Errors
    ///
    /// [`KeymapError`] when the names do not compile, which is what a mistyped
    /// layout looks like.
    pub fn compile(config: &KeymapConfig) -> Result<Self, KeymapError> {
        let context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
        let name = |value: &Option<String>| value.clone().unwrap_or_default();

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

        Self::from_xkb(&keymap)
    }

    /// Compiles a keymap that already exists in its text form.
    ///
    /// This is the path a second thread takes: the compositor publishes the
    /// text and the reader compiles its own copy.
    ///
    /// # Errors
    ///
    /// [`KeymapError`] when the text is not a keymap libxkbcommon accepts.
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

        Self::from_xkb(&keymap)
    }

    /// The serialised form, which is what crosses a thread and what is uploaded
    /// to a client.
    #[must_use]
    pub fn text(&self) -> &Arc<KeymapText> {
        &self.text
    }

    /// Every layout the keymap carries, in the order it declares them.
    #[must_use]
    pub fn layouts(&self) -> &[LayoutName] {
        &self.layouts
    }

    /// The keysym a key produces under a set of modifiers.
    ///
    /// `None` when the key produces nothing there, which is the ordinary answer
    /// for a key the layout does not bind rather than an error.
    #[must_use]
    pub fn symbol(&self, key: Keycode, modifiers: &ModifierState) -> Option<Keysym> {
        let mut state = xkb::State::new(&self.keymap);
        apply(&self.keymap, &mut state, modifiers);
        symbol_at(&state, key)
    }

    /// The text a key types under a set of modifiers.
    ///
    /// `None` for a key that produces no character — a function key, an arrow,
    /// a modifier — as distinct from `Some("")`, which never happens.
    #[must_use]
    pub fn character(&self, key: Keycode, modifiers: &ModifierState) -> Option<String> {
        let mut state = xkb::State::new(&self.keymap);
        apply(&self.keymap, &mut state, modifiers);

        let text = state.key_get_utf8(xkb_keycode(key));
        (!text.is_empty()).then_some(text)
    }

    /// Which key and modifiers produce a keysym, if any combination does.
    ///
    /// The answer prefers the fewest modifiers, then the lowest keycode, so a
    /// digit resolves to the number row rather than to the keypad and an
    /// unshifted letter is never reported as needing shift.
    #[must_use]
    pub fn stroke(&self, symbol: Keysym) -> Option<KeyStroke> {
        self.reverse.get(&symbol).cloned()
    }

    /// Which key and modifiers type a character.
    ///
    /// Two keysyms can name one character — `U+0041` and `XK_A` both mean `A` —
    /// so this asks about both rather than only the canonical Unicode form,
    /// which almost no layout binds directly.
    #[must_use]
    pub fn stroke_for(&self, character: char) -> Option<KeyStroke> {
        let legacy = Keysym::from_raw(xkb::utf32_to_keysym(character as u32).raw());
        self.stroke(legacy)
            .or_else(|| self.stroke(Keysym::from_char(character)))
    }

    /// Compiles the reverse table and the layout list once, with the keymap.
    ///
    /// The serialisation is what makes this fallible. Everything else here is
    /// total over a compiled keymap, but `xkb_keymap_get_as_string` can refuse,
    /// and a keymap whose text cannot be produced is one no client can be told
    /// about and one `typeText` could never restore.
    fn from_xkb(keymap: &xkb::Keymap) -> Result<Self, KeymapError> {
        // Every query below resolves against layout group zero, and nothing in
        // lunette can read or set the active group. A keymap carrying several
        // would answer for the first whichever one the seat is actually on, so
        // it is refused rather than answered wrongly. `docs/decisions.md`
        // records the choice.
        let count = keymap.num_layouts();
        if count > 1 {
            return Err(KeymapError {
                kind: KeymapErrorKind::ManyLayouts { count },
            });
        }

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

/// A key and the modifiers that have to be held with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyStroke {
    pub key: Keycode,
    pub modifiers: ModifierState,
}

/// Why a keymap could not be produced.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeymapError {
    kind: KeymapErrorKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum KeymapErrorKind {
    /// The RMLVO names named nothing libxkbcommon could find or parse.
    Names { config: Box<KeymapConfig> },
    /// The text was not a keymap.
    Text,
    /// The keymap compiled but would not serialise back to text.
    Serialisation,
    /// The keymap carries more than one layout group.
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

/// The modifier combinations a reverse lookup is built over.
///
/// Only the ones that select a shift level, ordered by how many modifiers each
/// holds down, so that the first combination to produce a keysym is the
/// cheapest way to type it. Within one count the order is the modifiers' own,
/// which is what decides a tie between two equally cheap answers.
///
/// Control, alt, and the logo key are absent because they do not select a level
/// in any ordinary layout — they are what a client turns into a binding, and a
/// binding is not a character.
///
/// `NumLock` is absent for a reason worth stating: it would make the keypad's
/// digits reachable, and they would then compete with the number row for the
/// same keysyms. The number row is what a caller means by a digit.
const LEVEL_MODIFIERS: &[&[KeyModifier]] = &[
    &[],
    &[KeyModifier::Shift],
    &[KeyModifier::Mod5],
    &[KeyModifier::Mod3],
    &[KeyModifier::Shift, KeyModifier::Mod5],
    &[KeyModifier::Shift, KeyModifier::Mod3],
];

/// Inverts the keymap: every keysym any level-selecting combination produces.
///
/// The combination loop is outermost so that `or_insert` keeps the cheapest
/// answer, and the keycode loop ascends so that the lowest key wins a tie.
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

/// Brings a state to a modifier set, without pressing anything.
///
/// This is what `docs/input.md:51` means by explicit modifier state: the mask
/// is set directly rather than synthesised as presses of a representative key
/// per bit, which is what WayVR does (`mod.rs:1215-1226`) and which both
/// misreports the state to a client that queries it and produces key events
/// that were never asked for.
fn apply(keymap: &xkb::Keymap, state: &mut xkb::State, modifiers: &ModifierState) {
    let (depressed, locked) = masks(keymap, modifiers);
    state.update_mask(depressed, 0, locked, 0, 0, 0);
}

/// The depressed and locked masks a modifier set serialises to.
///
/// Two masks rather than one, because a lock reported as depressed toggles off
/// again on the next update — the same distinction `KeyModifiers::LOCKED`
/// draws on the host side.
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

/// The name a keymap knows a modifier by.
///
/// XKB names the higher modifiers positionally — `Mod1` is alt and `Mod4` is
/// the logo key on every ordinary keymap — so this is where the positional
/// names and the meaningful ones are tied together once.
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

/// The one keysym a key produces in a state, or nothing.
fn symbol_at(state: &xkb::State, key: Keycode) -> Option<Keysym> {
    let symbol = state.key_get_one_sym(xkb_keycode(key));
    (symbol.raw() != 0).then(|| Keysym::from_raw(symbol.raw()))
}

/// xkb numbers the same keys eight higher than evdev does.
fn xkb_keycode(key: Keycode) -> xkb::Keycode {
    xkb::Keycode::new(key.evdev().saturating_add(XKB_KEYCODE_OFFSET))
}

/// The evdev code an xkb keycode names, when it is one a client can carry.
///
/// `wl_keyboard` carries evdev codes, so a keycode below the offset or past the
/// X11-compatible range is one no client could be told about. Skipping it is
/// what keeps the reverse table answerable: an entry a caller cannot act on is
/// worse than no entry.
fn evdev_keycode(raw: u32) -> Option<Keycode> {
    (XKB_KEYCODE_OFFSET..=X11_MAX_KEYCODE)
        .contains(&raw)
        .then(|| Keycode::from_evdev(raw - XKB_KEYCODE_OFFSET))
}

/// What xkb adds to an evdev code, for X11's historical numbering.
pub(crate) const XKB_KEYCODE_OFFSET: u32 = 8;

/// The highest keycode an X11-compatible keymap uses. Keycodes are eight bits
/// on the wire, and a client cannot be told about anything above this.
pub(crate) const X11_MAX_KEYCODE: u32 = 255;

/// A configuration field, for the error message.
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

    /// A layout every machine's xkb data carries, named explicitly so the tests
    /// do not depend on whatever the machine's default happens to be.
    fn us() -> Keymap {
        Keymap::compile(&KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        })
        .expect("the us layout compiles")
    }

    /// A layout whose third level is populated, so the AltGr paths are real.
    fn german() -> Keymap {
        Keymap::compile(&KeymapConfig {
            layout: Some("de".to_owned()),
            ..KeymapConfig::default()
        })
        .expect("the de layout compiles")
    }

    /// `KEY_A`, which is where the reverse lookup for `a` should land.
    const KEY_A: Keycode = Keycode::from_evdev(30);
    /// `KEY_Q`, which is `q` on a US layout.
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
        // `q` carries `@` on the third level of the German layout, and nothing
        // on the second. Getting there without Mod5 is the case that proves the
        // modifier is actually applied rather than ignored.
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
        // `KEY_LEFTSHIFT`, which produces a keysym and no text.
        let shift = Keycode::from_evdev(42);

        assert_eq!(keymap.character(shift, &modifiers(&[])), None);
        assert!(keymap.symbol(shift, &modifiers(&[])).is_some());
    }

    #[test]
    fn a_keycode_the_layout_does_not_bind_produces_no_keysym() {
        let keymap = us();
        // Past the X11 range entirely, so no keymap binds it.
        let absent = Keycode::from_evdev(600);

        assert_eq!(keymap.symbol(absent, &modifiers(&[])), None);
        assert_eq!(keymap.character(absent, &modifiers(&[])), None);
    }

    #[test]
    fn the_reverse_lookup_round_trips_every_keysym_the_layout_expresses() {
        // The strongest property this has: whatever the table claims types a
        // keysym must actually type it when fed back through the forward path.
        // A restatement of `build_reverse`'s own logic would pass on a broken
        // table, so the check goes through `symbol`, which does not share code
        // with the inversion.
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
        // The same character, present in one layout and not the other, is what
        // separates "the reverse table is empty" from "the table is per-layout".
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
        // Every query resolves against group zero and nothing can read or set
        // the active group, so `us,de` would type `zy` for `yz` the moment the
        // user switched to German. Refusing says so; answering does not.
        let error = Keymap::compile(&KeymapConfig {
            layout: Some("us,de".to_owned()),
            ..KeymapConfig::default()
        })
        .expect_err("two layout groups are more than lunette serves");

        assert!(error.to_string().starts_with("keymap: "));
        assert!(
            error.to_string().contains("layout groups"),
            "the message does not say what was wrong: {error}",
        );
    }

    #[test]
    fn a_layout_that_does_not_exist_is_refused_rather_than_silently_defaulted() {
        let error = Keymap::compile(&KeymapConfig {
            layout: Some("this-is-not-a-layout".to_owned()),
            ..KeymapConfig::default()
        })
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
