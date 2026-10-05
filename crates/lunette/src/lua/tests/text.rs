//! Exercises grapheme boundaries through the production native module.

use mlua::Function;
use pretty_assertions::assert_eq;
use proptest::{
    prelude::*,
    test_runner::{Config, RngSeed},
};

use super::*;

#[test]
fn text_boundaries_cluster_cases() {
    let session = session(Vec::new());
    let lua = lua(&session);
    let boundaries = text_boundaries_function(&lua);

    for (text, expected) in [
        ("", vec![1]),
        ("a", vec![1, 2]),
        ("abc", vec![1, 2, 3, 4]),
        ("é界", vec![1, 3, 6]),
        ("e\u{301}x", vec![1, 4, 5]),
        ("\u{301}\u{308}a", vec![1, 5, 6]),
        ("\r\n", vec![1, 3]),
        ("a\0b", vec![1, 2, 3, 4]),
        ("\u{1100}\u{1161}\u{11a8}x", vec![1, 10, 11]),
        ("\u{915}\u{93e}x", vec![1, 7, 8]),
        ("👩‍👩‍👧‍👦x", vec![1, 26, 27]),
        ("👩🏽‍💻x", vec![1, 16, 17]),
        ("🇳🇿🇨🇦🇺", vec![1, 9, 17, 21]),
    ] {
        assert_eq!(
            boundaries
                .call::<Vec<usize>>(text)
                .expect("valid UTF-8 is segmented"),
            expected,
            "text: {text:?}"
        );
    }
}

#[test]
fn text_boundaries_reject_invalid_utf8_at_the_native_boundary() {
    let session = session(Vec::new());
    let lua = lua(&session);
    let boundaries = text_boundaries_function(&lua);

    for bytes in [
        &b"\xff"[..],
        &b"\xc0\xaf"[..],
        &b"\xed\xa0\x80"[..],
        &b"\xf0\x9f\x91"[..],
        &b"a\x80b"[..],
    ] {
        let text = lua
            .create_string(bytes)
            .expect("Lua strings preserve bytes");
        let error = boundaries
            .call::<Vec<usize>>(text)
            .expect_err("invalid UTF-8 is rejected rather than repaired")
            .to_string();
        assert!(error.contains("textBoundaries"), "error: {error}");
        assert!(error.to_lowercase().contains("utf-8"), "error: {error}");
    }
}

#[test]
fn text_boundaries_return_a_fresh_lua_array_for_each_call() {
    let session = session(Vec::new());
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "local first = lunette.textBoundaries('é')
         local second = lunette.textBoundaries('é')
         first[1] = 99
         return first ~= second and second[1] == 1 and second[2] == 4 and #second == 2"
    ));
}

proptest! {
    #![proptest_config(Config {
        cases: 256,
        failure_persistence: None,
        rng_seed: RngSeed::Fixed(0x7465_7874_6279_7465),
        ..Config::default()
    })]

    #[test]
    fn text_boundaries_partition_utf8_without_changing_any_bytes(
        characters in prop::collection::vec(any::<char>(), 0..256),
    ) {
        let session = session(Vec::new());
        let lua = lua(&session);
        let text: String = characters.into_iter().collect();
        let offsets = text_boundaries_function(&lua)
            .call::<Vec<usize>>(text.as_str())
            .expect("valid UTF-8 is segmented");

        prop_assert_eq!(offsets.first(), Some(&1));
        prop_assert_eq!(offsets.last(), Some(&(text.len() + 1)));
        prop_assert!(offsets.windows(2).all(|pair| pair[0] < pair[1]));
        let valid_offsets = offsets.iter().all(|offset| {
            (1..=text.len() + 1).contains(offset) && text.is_char_boundary(offset - 1)
        });
        prop_assert!(valid_offsets);

        let slices: Vec<&str> = offsets.windows(2)
            .map(|pair| &text[pair[0] - 1..pair[1] - 1])
            .collect();
        prop_assert_eq!(slices.concat(), text);
    }

    #[test]
    fn text_boundaries_keep_known_clusters_whole_between_ascii_separators(
        clusters in prop::collection::vec(prop::sample::select(vec![
            "a", "é", "界", "e\u{301}", "\r\n", "\0",
            "\u{1100}\u{1161}\u{11a8}", "\u{915}\u{93e}", "👩‍👩‍👧‍👦", "👩🏽‍💻", "🇳🇿",
        ]), 0..64),
    ) {
        let session = session(Vec::new());
        let lua = lua(&session);
        let expected: Vec<&str> = clusters.into_iter()
            .flat_map(|cluster| [cluster, "|"])
            .collect();
        let text = expected.concat();
        let offsets = text_boundaries_function(&lua)
            .call::<Vec<usize>>(text.as_str())
            .expect("valid UTF-8 is segmented");
        let slices: Vec<&str> = offsets.windows(2)
            .map(|pair| &text[pair[0] - 1..pair[1] - 1])
            .collect();

        prop_assert_eq!(slices, expected);
    }
}

fn text_boundaries_function(lua: &Lua) -> Function {
    run(lua, "return lunette.textBoundaries")
}
