#![expect(
    clippy::expect_used,
    reason = "Tests fail loudly on a malformed fixture; that is the assertion."
)]

use pretty_assertions::assert_eq;

use super::*;

/// A bundled monospace face from the repository, so every advance is the same.
fn fonts() -> Fonts {
    Fonts::bundled([include_bytes!(
        "../../../../lua/lunette-plugins/theme/arcade/fonts/SpaceMono-Regular.ttf"
    )
    .to_vec()])
}

fn style() -> TextStyle {
    TextStyle {
        family: Some("Space Mono".to_owned()),
        ..TextStyle::default()
    }
}

fn close(a: f32, b: f32) -> bool {
    (a - b).abs() < 1e-5
}

#[test]
fn bundled_fonts_contain_only_the_given_faces() {
    assert_eq!(fonts().families(), vec!["Space Mono".to_owned()]);
}

#[test]
fn empty_text_keeps_one_line() {
    let mut fonts = fonts();
    let mut block = TextBlock::new(&mut fonts, "", style()).expect("valid style");
    let (width, height) = block.measure(&mut fonts, None);
    assert_eq!(width, 0.0);
    assert!(close(height, 0.012 * 1.3), "one line high, got {height}");
}

#[test]
fn monospace_advances_add_up() {
    let mut fonts = fonts();
    let mut one = TextBlock::new(&mut fonts, "a", style()).expect("valid style");
    let mut ten = TextBlock::new(&mut fonts, "aaaaaaaaaa", style()).expect("valid style");
    let (single, _) = one.measure(&mut fonts, None);
    let (tenfold, _) = ten.measure(&mut fonts, None);
    assert!(single > 0.0);
    assert!(close(tenfold, single * 10.0), "{tenfold} against {single}");
}

#[test]
fn wrapping_trades_width_for_height() {
    let mut fonts = fonts();
    let mut block =
        TextBlock::new(&mut fonts, "alpha beta gamma delta", style()).expect("valid style");
    let (wide, one_line) = block.measure(&mut fonts, None);
    let (narrow, lines) = block.measure(&mut fonts, Some(wide / 2.0));
    assert!(narrow <= wide / 2.0 + 1e-6, "fits the width it was given");
    assert!(lines > one_line, "wraps onto more lines");
}

#[test]
fn zero_width_gives_the_longest_word() {
    let mut fonts = fonts();
    let mut word = TextBlock::new(&mut fonts, "gamma", style()).expect("valid style");
    let mut phrase = TextBlock::new(&mut fonts, "be gamma at", style()).expect("valid style");
    let (longest, _) = word.measure(&mut fonts, None);
    let (min_content, _) = phrase.measure(&mut fonts, Some(0.0));
    assert!(
        close(min_content, longest),
        "{min_content} against {longest}"
    );
}

#[test]
fn a_line_limit_caps_the_height() {
    let mut fonts = fonts();
    let limited = TextStyle {
        max_lines: Some(2),
        ..style()
    };
    let mut block = TextBlock::new(&mut fonts, "one two three four five six seven", limited)
        .expect("valid style");
    let (single, _) = block.measure(&mut fonts, None);
    let (_, height) = block.measure(&mut fonts, Some(single / 5.0));
    assert!(
        close(height, 2.0 * 0.012 * 1.3),
        "two lines high, got {height}"
    );
}

#[test]
fn lines_report_glyphs_in_metres() {
    let mut fonts = fonts();
    let mut block = TextBlock::new(&mut fonts, "ab", style()).expect("valid style");
    let lines = block.lines(&mut fonts, None);
    assert_eq!(lines.len(), 1);
    let glyphs = &lines[0].glyphs;
    assert_eq!(glyphs.len(), 2);
    assert!(close(glyphs[0].x, 0.0));
    assert!(close(glyphs[1].x, glyphs[0].advance));
    assert!(close(glyphs[0].size, 0.012));
    assert_eq!((glyphs[1].start, glyphs[1].end), (1, 2));
}

#[test]
fn invalid_styles_are_refused() {
    let mut fonts = fonts();
    for (style, expected) in [
        (
            TextStyle {
                size: 0.0,
                ..style()
            },
            TextStyleError::Size(0.0),
        ),
        (
            TextStyle {
                line_height: -1.0,
                ..style()
            },
            TextStyleError::LineHeight(-1.0),
        ),
        (
            TextStyle {
                weight: 0,
                ..style()
            },
            TextStyleError::Weight(0),
        ),
        (
            TextStyle {
                max_lines: Some(0),
                ..style()
            },
            TextStyleError::MaxLines,
        ),
    ] {
        assert_eq!(TextBlock::new(&mut fonts, "x", style).err(), Some(expected));
    }
}
