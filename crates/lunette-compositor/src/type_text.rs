//! Typing text the active layout may not be able to express.
//!
//! Entirely new work. Nothing in WayVR generates a keymap for arbitrary text,
//! and nothing there saves or restores one.
//!
//! # The technique
//!
//! `docs/input.md:58-62` frames it: a temporary keymap binds spare keycodes to
//! the keysyms the text needs, the key events are driven against it, and the
//! client's own keymap is put back. That is what makes clipboard-less paste,
//! dictation, and `lunctl` telling a terminal to run a command possible at all.
//!
//! It is deliberately the exception. Text the layout can already type takes the
//! ordinary path and uploads nothing, because a `wl_keyboard.keymap` event
//! makes every toolkit recompile a layout, and doing that to type "ls" would be
//! absurd.
//!
//! # Why this file is pure
//!
//! Everything here is a function from text and a keymap to a [`TypePlan`]. The
//! upload, the key events, and the restore live in [`crate::state::input`],
//! where the seat is. That split is what lets the chunking, the resolution, and
//! the emitted sequence be tested without a client, a display, or a device.
//!
//! # Restoring is part of the contract
//!
//! `lunette-v1.AC4.3` requires the client's own keymap handling to work
//! afterwards, so the caller restores even when a chunk fails. A client left
//! holding lunette's synthetic layout has a keyboard on which every key types
//! the wrong thing, which is worse than the failure that produced it.

use std::{error::Error, fmt, fmt::Write as _};

use xkbcommon::xkb;

use crate::{
    keymap::{KeyStroke, Keymap},
    protocol::{Keycode, KeymapText, Keysym, ModifierState},
};

/// What typing one piece of text takes.
///
/// A plan is a list of chunks because a temporary keymap holds a bounded number
/// of keysyms. Text needing more than one keymap's worth is split into runs
/// that fit rather than refused: a caller pasting a paragraph of emoji gets the
/// paragraph, and the client sees several keymap changes, which is legal.
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

/// One keymap's worth of typing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Chunk {
    /// The layout to upload before these steps, and to restore after them.
    /// Absent when the seat's own layout already types everything here.
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

/// One thing the caller does to the seat.
///
/// Modifier changes are steps rather than being folded into each tap, so the
/// emitted sequence is what a client actually sees and a run of characters at
/// the same level costs one modifier update rather than one per character.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum TypeStep {
    /// Bring the seat's modifiers to exactly this set.
    Modifiers(ModifierState),
    /// Press and release a key.
    Tap(Keycode),
}

/// Works out what typing `text` on `keymap` takes.
///
/// `capacity` is how many distinct keysyms one synthetic keymap holds. It is a
/// parameter rather than a constant because it is the property the chunking
/// turns on, and [`SPARE_KEYCODES`] is what production passes.
///
/// # Errors
///
/// [`TypeTextError`] when the capacity is zero, or when a character resolves to
/// a keysym libxkbcommon will not name — which is what a keymap cannot be
/// written for.
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

/// How many distinct keysyms one synthetic keymap holds.
///
/// The whole keycode space, because the temporary keymap replaces the seat's
/// own: every keycode in it is lunette's for the duration. The range is the
/// X11-compatible one, since `wl_keyboard` carries eight-bit keycodes and a
/// client could not be told about anything above it.
pub(crate) const SPARE_KEYCODES: usize = (X11_MAX_KEYCODE - XKB_MINIMUM_KEYCODE + 1) as usize;

/// Why text could not be typed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct TypeTextError {
    kind: TypeTextErrorKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TypeTextErrorKind {
    /// A keymap with no spare keycodes, which nothing could be typed on.
    NoCapacity,
    /// The generated keymap does not type what it was generated for, which
    /// means the generator is wrong.
    Unbindable { symbol: Keysym },
    /// The generated text did not compile, which means the generator is wrong.
    Uncompilable,
}

impl fmt::Display for TypeTextError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.kind {
            TypeTextErrorKind::NoCapacity => {
                f.write_str("type text: a keymap with no spare keycodes can type nothing")
            }
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

/// One stretch of text that is typed the same way.
enum Run {
    /// Characters the seat's own layout types.
    Native(Vec<KeyStroke>),
    /// Characters it does not, as the keysyms a temporary keymap must bind.
    Synthetic(Vec<Keysym>),
}

/// Splits text into stretches the layout can type and stretches it cannot.
///
/// Adjacent characters of the same kind stay together, so text the layout types
/// entirely produces one run and uploads nothing, and a single foreign
/// character in the middle of a sentence costs one upload rather than one per
/// character.
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

/// Splits a synthetic run into batches of at most `capacity` distinct keysyms.
///
/// Distinct, not total: a keymap binds each keysym once, so a hundred copies of
/// one character fit in a single-keycode keymap. The split respects order, so
/// the text arrives in the order it was written.
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

/// The steps a run of native strokes takes.
///
/// A modifier step is emitted only when the set changes, and a trailing step
/// brings the seat back to holding nothing — otherwise a run ending on a
/// capital would leave shift held for whatever the caller does next.
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

/// A chunk that binds each of `symbols` to a spare keycode and taps them.
///
/// Every keysym lands on the first level of its own key, so no modifier is
/// needed and the whole chunk types with the seat holding nothing.
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

/// The keymap binding `symbols` to consecutive spare keycodes.
///
/// Generated as text rather than built through libxkbcommon's API, because text
/// is what has to cross to smithay anyway: it recompiles the string in its own
/// context, since libxkbcommon is not thread-safe. Compiling it here first is
/// how a generator mistake is caught where it was made rather than as a
/// keyboard that stops working.
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

    // The stock types and compatibility maps. A keymap without them compiles,
    // and then a client's own `xkb_state` has no shift level to resolve against,
    // so `xkb_keymap` is not the only thing that has to be complete.
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

    // What the client will read, read the same way. A name libxkbcommon prints
    // and then declines to parse back would otherwise compile into a key that
    // types nothing, and the hole would appear in the middle of the user's text
    // rather than here.
    for (index, symbol) in symbols.iter().enumerate() {
        if compiled.symbol(spare_key(index), &ModifierState::new()) != Some(*symbol) {
            return Err(TypeTextError {
                kind: TypeTextErrorKind::Unbindable { symbol: *symbol },
            });
        }
    }

    Ok(text)
}

/// The name a keymap binds a keysym under.
///
/// libxkbcommon names anything: a recognised keysym by its own name, and
/// anything else by its hexadecimal value, which its parser reads back. The
/// caller verifies the result rather than trusting either form.
fn symbol_name(symbol: Keysym) -> String {
    xkb::keysym_get_name(xkb::Keysym::new(symbol.raw()))
}

/// The evdev keycode the nth spare key is addressed by.
const fn spare_key(index: usize) -> Keycode {
    Keycode::from_evdev(xkb_code(index) - XKB_KEYCODE_OFFSET)
}

/// The xkb keycode the nth spare key is declared as.
const fn xkb_code(index: usize) -> u32 {
    XKB_MINIMUM_KEYCODE + index as u32
}

/// The lowest keycode an X11-compatible keymap uses, which is also xkb's
/// offset from evdev.
const XKB_MINIMUM_KEYCODE: u32 = XKB_KEYCODE_OFFSET;

/// What xkb adds to an evdev code.
const XKB_KEYCODE_OFFSET: u32 = 8;

/// The highest keycode `wl_keyboard`'s eight-bit numbering reaches.
const X11_MAX_KEYCODE: u32 = 255;

/// What the synthetic keymap's sections are called. Visible to a client that
/// inspects the layout it was handed, so it says where it came from.
const KEYMAP_NAME: &str = "lunette-typetext";

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::protocol::{KeyModifier, KeymapConfig};

    fn us() -> Keymap {
        Keymap::compile(&KeymapConfig {
            layout: Some("us".to_owned()),
            ..KeymapConfig::default()
        })
        .expect("the us layout compiles")
    }

    fn planned(text: &str) -> TypePlan {
        plan(text, &us(), SPARE_KEYCODES).expect("the plan is buildable")
    }

    /// How many chunks upload a keymap.
    fn uploads(plan: &TypePlan) -> usize {
        plan.chunks()
            .iter()
            .filter(|chunk| chunk.keymap().is_some())
            .count()
    }

    /// The characters a chunk's taps would type, read back through the keymap
    /// the chunk uploads or through the seat's own.
    ///
    /// Deliberately not a restatement of the planner: it resolves each tap
    /// through a compiled keymap, which is the same path a client takes.
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
        // Four distinct foreign characters against a keymap that holds two.
        let text = "\u{2600}\u{2601}\u{2602}\u{2603}";
        let plan = plan(text, &us(), 2).expect("the plan is buildable");

        assert_eq!(plan.chunks().len(), 2);
        assert_eq!(uploads(&plan), 2, "each chunk uploads and restores");
        assert_eq!(typed(&plan, &us()), text);
    }

    #[test]
    fn repeats_of_one_character_share_a_keycode_rather_than_forcing_a_chunk() {
        // A keymap that holds one keysym still types this in one chunk, because
        // a keymap binds each keysym once however often it is typed.
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
        // libxkbcommon names an unrecognised keysym `0x…` and reads that form
        // back, so the fallback is a real binding rather than a hole. It is
        // what makes the generator total over the Unicode keysym range.
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
        // `NoSymbol`, which libxkbcommon names and then compiles into a key that
        // types nothing. Sending it would be a silent hole in the user's text,
        // which is the failure the verification in `synthesise` exists to catch.
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
