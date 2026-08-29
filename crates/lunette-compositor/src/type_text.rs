//! Plans typing text that the active layout may not express.
//!
//! A synthetic keymap binds otherwise untypable keysyms to spare keycodes. The
//! plan carries serialized keymap text because libxkbcommon keymaps are not
//! thread-safe; each XKB context compiles its own copy.
//!
//! The executor runs plans on the compositor thread and preserves ordering with
//! other key events for the same seat. Callers must not interleave a plan with
//! manual key events on that seat because the active keymap changes during it.
//!
//! After loading a synthetic keymap, the executor attempts to restore the seat's
//! original keymap even if a later chunk fails. A failed restore leaves the
//! synthetic keymap tracked for repair before later native typing. Planning errors
//! are returned before any upload.
//!
//! The planner is pure, so chunking, resolution, and emitted sequences can be
//! tested without a client, display, or device.

use std::{error::Error, fmt, fmt::Write as _};

use xkbcommon::xkb;

use crate::{
    keymap::{KeyStroke, Keymap},
    protocol::{Keycode, KeymapText, Keysym, ModifierState},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TypePlan {
    chunks: Vec<Chunk>,
}

impl TypePlan {
    pub(crate) fn chunks(&self) -> &[Chunk] {
        &self.chunks
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Chunk {
    /// Serialized synthetic keymap for these steps, if they use synthetic keycodes.
    keymap: Option<KeymapText>,
    steps: Vec<TypeStep>,
}

impl Chunk {
    pub(crate) const fn keymap(&self) -> Option<&KeymapText> {
        self.keymap.as_ref()
    }

    pub(crate) fn steps(&self) -> &[TypeStep] {
        &self.steps
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TypeStep {
    Modifiers(ModifierState),
    Tap(Keycode),
}

/// Plans typing `text` on `keymap` with the given synthetic-keymap capacity.
///
/// # Errors
///
/// Returns [`TypeTextError`] when the capacity is zero or exceeds
/// [`SPARE_KEYCODES`], or when a character cannot be represented in a generated
/// keymap.
pub(crate) fn plan(
    text: &str,
    keymap: &Keymap,
    capacity: usize,
) -> Result<TypePlan, TypeTextError> {
    if capacity == 0 {
        return Err(TypeTextError {
            kind: TypeTextErrorKind::NoCapacity,
        });
    }
    if capacity > SPARE_KEYCODES {
        return Err(TypeTextError {
            kind: TypeTextErrorKind::TooMuchCapacity { capacity },
        });
    }

    let mut chunks = Vec::new();
    for run in runs(text, keymap) {
        match run {
            Run::Native(strokes) => chunks.push(Chunk {
                keymap: None,
                steps: native_steps(&strokes),
            }),
            Run::Synthetic(symbols) => {
                for batch in batches(&symbols, capacity) {
                    chunks.push(synthetic_chunk(&batch)?);
                }
            }
        }
    }

    Ok(TypePlan { chunks })
}

/// The maximum number of distinct keysyms in one synthetic keymap.
///
/// `xkb_code` starts at the XKB minimum of eight, and `wl_keyboard` carries the
/// resulting evdev keycodes in an eight-bit field. The inclusive X11 range ends
/// at 255, so the capacity is 255 - 8 + 1 = 248.
pub(crate) const SPARE_KEYCODES: usize = (X11_MAX_KEYCODE - XKB_MINIMUM_KEYCODE + 1) as usize;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TypeTextError {
    kind: TypeTextErrorKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TypeTextErrorKind {
    NoCapacity,
    /// The requested capacity exceeds `wl_keyboard`'s eight-bit keycode range.
    TooMuchCapacity {
        capacity: usize,
    },
    Unbindable {
        symbol: Keysym,
    },
    Uncompilable,
}

impl fmt::Display for TypeTextError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.kind {
            TypeTextErrorKind::NoCapacity => {
                f.write_str("type text: a keymap with no spare keycodes can type nothing")
            }
            TypeTextErrorKind::TooMuchCapacity { capacity } => write!(
                f,
                "type text: {capacity} spare keycodes were asked for and the eight-bit range \
                 wl_keyboard carries holds {SPARE_KEYCODES}"
            ),
            TypeTextErrorKind::Unbindable { symbol } => write!(
                f,
                "type text: the synthesised keymap does not type {symbol}"
            ),
            TypeTextErrorKind::Uncompilable => {
                f.write_str("type text: the synthesised keymap did not compile")
            }
        }
    }
}

impl Error for TypeTextError {}

enum Run {
    Native(Vec<KeyStroke>),
    Synthetic(Vec<Keysym>),
}

fn runs(text: &str, keymap: &Keymap) -> Vec<Run> {
    let mut runs: Vec<Run> = Vec::new();

    for character in text.chars() {
        match keymap.stroke_for(character) {
            Some(stroke) => match runs.last_mut() {
                Some(Run::Native(strokes)) => strokes.push(stroke),
                _ => runs.push(Run::Native(vec![stroke])),
            },
            None => {
                let symbol = Keysym::from_char(character);
                match runs.last_mut() {
                    Some(Run::Synthetic(symbols)) => symbols.push(symbol),
                    _ => runs.push(Run::Synthetic(vec![symbol])),
                }
            }
        }
    }

    runs
}

/// Wayland permits a `wl_keyboard.keymap` event between chunks. This lets a
/// synthetic run exceed one map's keycode range while preserving text order.
fn batches(symbols: &[Keysym], capacity: usize) -> Vec<Vec<Keysym>> {
    let mut batches = Vec::new();
    let mut current: Vec<Keysym> = Vec::new();
    let mut distinct: Vec<Keysym> = Vec::new();

    for symbol in symbols {
        if !distinct.contains(symbol) && distinct.len() == capacity {
            batches.push(std::mem::take(&mut current));
            distinct.clear();
        }
        if !distinct.contains(symbol) {
            distinct.push(*symbol);
        }
        current.push(*symbol);
    }

    if !current.is_empty() {
        batches.push(current);
    }
    batches
}

/// A final empty modifier state prevents a run ending with a shifted stroke from
/// leaving Shift or another modifier held for the next input operation.
fn native_steps(strokes: &[KeyStroke]) -> Vec<TypeStep> {
    let mut steps = Vec::new();
    let mut held = ModifierState::new();

    for stroke in strokes {
        if stroke.modifiers != held {
            held = stroke.modifiers.clone();
            steps.push(TypeStep::Modifiers(held.clone()));
        }
        steps.push(TypeStep::Tap(stroke.key));
    }

    if !held.is_empty() {
        steps.push(TypeStep::Modifiers(ModifierState::new()));
    }
    steps
}

/// Synthetic symbols bind at the first level of their keys, so each chunk starts
/// by clearing modifiers before tapping them.
fn synthetic_chunk(symbols: &[Keysym]) -> Result<Chunk, TypeTextError> {
    let mut distinct: Vec<Keysym> = Vec::new();
    for symbol in symbols {
        if !distinct.contains(symbol) {
            distinct.push(*symbol);
        }
    }

    let keymap = synthesise(&distinct)?;
    let mut steps = vec![TypeStep::Modifiers(ModifierState::new())];
    for symbol in symbols {
        let index = distinct
            .iter()
            .position(|candidate| candidate == symbol)
            .unwrap_or_else(|| unreachable!("every symbol was collected into the distinct list"));
        steps.push(TypeStep::Tap(spare_key(index)));
    }

    Ok(Chunk {
        keymap: Some(keymap),
        steps,
    })
}

/// Generated keymap text crosses to the executor because libxkbcommon keymaps are
/// not thread-safe; the executor recompiles it in its own XKB context. Compiling
/// the text here and verifying its bindings returns generator errors before an
/// invalid map reaches a client.
fn synthesise(symbols: &[Keysym]) -> Result<KeymapText, TypeTextError> {
    let maximum = XKB_MINIMUM_KEYCODE + u32::try_from(symbols.len().max(1)).unwrap_or(1) - 1;

    let mut text = String::new();
    text.push_str("xkb_keymap {\n");

    let _ = writeln!(
        text,
        "xkb_keycodes \"{KEYMAP_NAME}\" {{\nminimum = {XKB_MINIMUM_KEYCODE};\nmaximum = \
         {maximum};"
    );
    for index in 0..symbols.len() {
        let code = xkb_code(index);
        let _ = writeln!(text, "<K{code}> = {code};");
    }
    text.push_str("};\n");

    // Include the stock types and compatibility maps so the client's xkb state
    // resolves modifier levels and compatibility actions in the generated map.
    let _ = writeln!(
        text,
        "xkb_types \"{KEYMAP_NAME}\" {{ include \"complete\" }};"
    );
    let _ = writeln!(
        text,
        "xkb_compatibility \"{KEYMAP_NAME}\" {{ include \"complete\" }};"
    );

    let _ = writeln!(text, "xkb_symbols \"{KEYMAP_NAME}\" {{");
    for (index, symbol) in symbols.iter().enumerate() {
        let _ = writeln!(
            text,
            "key <K{}> {{ [ {} ] }};",
            xkb_code(index),
            symbol_name(*symbol),
        );
    }
    text.push_str("};\n};\n");

    let text = KeymapText::new(text).ok_or(TypeTextError {
        kind: TypeTextErrorKind::Uncompilable,
    })?;
    let compiled = Keymap::from_text(&text).map_err(|_| TypeTextError {
        kind: TypeTextErrorKind::Uncompilable,
    })?;

    // Verify the bindings through the same representation that the client reads,
    // so an unparseable keysym name cannot silently drop text.
    for (index, symbol) in symbols.iter().enumerate() {
        if compiled.symbol(spare_key(index), &ModifierState::new()) != Some(*symbol) {
            return Err(TypeTextError {
                kind: TypeTextErrorKind::Unbindable { symbol: *symbol },
            });
        }
    }

    Ok(text)
}

/// Returns the libxkbcommon name that the generated keymap binds.
///
/// Unrecognised keysyms use hexadecimal names that libxkbcommon parses back;
/// `synthesise` verifies that the compiled map preserves the original symbol.
fn symbol_name(symbol: Keysym) -> String {
    xkb::keysym_get_name(xkb::Keysym::new(symbol.raw()))
}

const fn spare_key(index: usize) -> Keycode {
    Keycode::from_evdev(xkb_code(index) - XKB_KEYCODE_OFFSET)
}

const fn xkb_code(index: usize) -> u32 {
    XKB_MINIMUM_KEYCODE + index as u32
}

const XKB_MINIMUM_KEYCODE: u32 = XKB_KEYCODE_OFFSET;

const XKB_KEYCODE_OFFSET: u32 = 8;

const X11_MAX_KEYCODE: u32 = 255;

const KEYMAP_NAME: &str = "lunette-typetext";

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::protocol::{KeyModifier, KeymapConfig, KeymapDefaults};

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

    fn planned(text: &str) -> TypePlan {
        plan(text, &us(), SPARE_KEYCODES).expect("the plan is buildable")
    }

    fn uploads(plan: &TypePlan) -> usize {
        plan.chunks()
            .iter()
            .filter(|chunk| chunk.keymap().is_some())
            .count()
    }

    /// Resolves taps through a freshly compiled keymap, the client's readback path.
    ///
    /// This stays independent of the planner so a wrong keycode or modifier step
    /// cannot make its own test oracle pass.
    fn typed(plan: &TypePlan, active: &Keymap) -> String {
        let mut text = String::new();

        for chunk in plan.chunks() {
            let chunk_keymap = chunk
                .keymap()
                .map(|text| Keymap::from_text(text).expect("a synthesised keymap compiles"));
            let keymap = chunk_keymap.as_ref().unwrap_or(active);

            let mut held = ModifierState::new();
            for step in chunk.steps() {
                match step {
                    TypeStep::Modifiers(modifiers) => held = modifiers.clone(),
                    TypeStep::Tap(key) => {
                        text.push_str(
                            &keymap
                                .character(*key, &held)
                                .unwrap_or_else(|| panic!("{key:?} types nothing under {held:?}")),
                        );
                    }
                }
            }
        }

        text
    }

    #[test]
    fn empty_text_plans_nothing() {
        let plan = planned("");

        assert!(plan.is_empty());
        assert_eq!(uploads(&plan), 0);
    }

    #[test]
    fn text_the_layout_expresses_uploads_no_keymap() {
        let plan = planned("ls -la");

        assert_eq!(uploads(&plan), 0, "the ordinary path is not the exception");
        assert_eq!(plan.chunks().len(), 1);
        assert_eq!(typed(&plan, &us()), "ls -la");
    }

    #[test]
    fn a_character_needing_a_modifier_gets_one_and_gives_it_back() {
        let plan = planned("Ab");
        let steps = plan.chunks()[0].steps();

        assert_eq!(
            steps.first(),
            Some(&TypeStep::Modifiers(ModifierState::from_iter([
                KeyModifier::Shift
            ]))),
        );
        assert_eq!(
            steps.iter().rev().find_map(|step| match step {
                TypeStep::Modifiers(modifiers) => Some(modifiers.clone()),
                TypeStep::Tap(_) => None,
            }),
            Some(ModifierState::new()),
            "a run whose last modifier change is not empty leaves something held",
        );
        assert_eq!(typed(&plan, &us()), "Ab");
    }

    #[test]
    fn a_run_at_one_level_sets_its_modifiers_once() {
        let plan = planned("ABC");
        let changes = plan.chunks()[0]
            .steps()
            .iter()
            .filter(|step| matches!(step, TypeStep::Modifiers(_)))
            .count();

        assert_eq!(changes, 2, "one to take shift, one to give it back");
    }

    #[test]
    fn text_the_layout_cannot_express_triggers_exactly_one_upload() {
        let plan = planned("\u{2603}\u{2604}");

        assert_eq!(uploads(&plan), 1);
        assert_eq!(plan.chunks().len(), 1);
        assert_eq!(typed(&plan, &us()), "\u{2603}\u{2604}");
    }

    #[test]
    fn text_that_is_entirely_unrepresentable_still_types() {
        let text = "\u{4e00}\u{4e8c}\u{4e09}";
        let plan = planned(text);

        assert_eq!(uploads(&plan), 1);
        assert_eq!(typed(&plan, &us()), text);
    }

    #[test]
    fn a_foreign_character_among_native_ones_splits_into_runs() {
        let plan = planned("a\u{2603}b");

        assert_eq!(plan.chunks().len(), 3);
        assert_eq!(uploads(&plan), 1, "only the middle run needs a keymap");
        assert!(plan.chunks()[0].keymap().is_none());
        assert!(plan.chunks()[1].keymap().is_some());
        assert!(plan.chunks()[2].keymap().is_none());
        assert_eq!(typed(&plan, &us()), "a\u{2603}b");
    }

    #[test]
    fn text_needing_more_keysyms_than_one_keymap_holds_is_chunked() {
        let text = "\u{2600}\u{2601}\u{2602}\u{2603}";
        let plan = plan(text, &us(), 2).expect("the plan is buildable");

        assert_eq!(plan.chunks().len(), 2);
        assert_eq!(uploads(&plan), 2, "each chunk uploads and restores");
        assert_eq!(typed(&plan, &us()), text);
    }

    #[test]
    fn repeats_of_one_character_share_a_keycode_rather_than_forcing_a_chunk() {
        let text = "\u{2603}\u{2603}\u{2603}";
        let plan = plan(text, &us(), 1).expect("the plan is buildable");

        assert_eq!(plan.chunks().len(), 1);
        assert_eq!(typed(&plan, &us()), text);
    }

    #[test]
    fn a_keymap_with_no_spare_keycodes_is_refused_rather_than_looping() {
        let error = plan("\u{2603}", &us(), 0).expect_err("nothing can be typed on no keys");

        assert!(error.to_string().starts_with("type text: "));
    }

    #[test]
    fn the_capacity_a_synthetic_chunk_can_hold_is_the_x11_keycode_range() {
        assert_eq!(SPARE_KEYCODES, 248);
    }

    #[test]
    fn a_capacity_past_the_keycode_range_is_refused_rather_than_emitting_unreachable_keys() {
        assert!(plan("\u{2603}", &us(), SPARE_KEYCODES).is_ok());

        let error = plan("\u{2603}", &us(), SPARE_KEYCODES + 1)
            .expect_err("the eight-bit range is what a client can be told about");
        assert!(error.to_string().starts_with("type text: "));
    }

    #[test]
    fn a_synthesised_keymap_binds_each_keysym_to_its_own_key() {
        let symbols = [Keysym::from_char('\u{2603}'), Keysym::from_char('\u{4e00}')];
        let text = synthesise(&symbols).expect("the keymap synthesises");
        let keymap = Keymap::from_text(&text).expect("it compiles");

        for (index, symbol) in symbols.iter().enumerate() {
            assert_eq!(
                keymap.symbol(spare_key(index), &ModifierState::new()),
                Some(*symbol),
            );
        }
    }

    #[test]
    fn a_keysym_with_no_name_of_its_own_binds_through_its_hexadecimal_form() {
        // libxkbcommon prints an unrecognised keysym as hexadecimal and parses
        // that form back, so the fallback covers keysyms without named bindings.
        let symbol = Keysym::from_raw(0x1100_0000);
        assert!(symbol_name(symbol).starts_with("0x"));

        let text = synthesise(&[symbol]).expect("the fallback name binds");
        let keymap = Keymap::from_text(&text).expect("it compiles");
        assert_eq!(
            keymap.symbol(spare_key(0), &ModifierState::new()),
            Some(symbol),
        );
    }

    #[test]
    fn a_keysym_the_keymap_would_not_type_is_refused_rather_than_bound() {
        // `NoSymbol` compiles into a key that types nothing. Verification rejects
        // it so the generated sequence cannot silently drop text.
        let error = synthesise(&[Keysym::from_raw(0)]).expect_err("nothing binds NoSymbol");

        assert!(error.to_string().starts_with("type text: "));
    }

    #[test]
    fn every_character_a_test_types_binds() {
        for character in ['a', 'A', '\u{2603}', '\u{4e00}', '£'] {
            let symbol = Keysym::from_char(character);
            assert!(
                synthesise(&[symbol]).is_ok(),
                "{character} has no bindable name",
            );
        }
    }

    #[test]
    fn mixed_text_types_in_the_order_it_was_written() {
        let text = "cd \u{2603}/x";
        let plan = planned(text);

        assert_eq!(typed(&plan, &us()), text);
    }
}
