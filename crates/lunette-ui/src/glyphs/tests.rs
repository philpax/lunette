#![expect(
    clippy::expect_used,
    reason = "Tests fail loudly on a malformed fixture; that is the assertion."
)]

use pretty_assertions::assert_eq;

use super::*;
use crate::text::{Fonts, TextBlock, TextStyle};

/// A generator that fills the cell with one value and records each request.
#[derive(Default)]
struct Fill {
    requests: Vec<FieldRequest>,
    fail: bool,
    short: bool,
}

impl FieldGenerator for Fill {
    fn generate(
        &mut self,
        _outline: &Outline,
        request: &FieldRequest,
    ) -> Result<Vec<f32>, FieldError> {
        self.requests.push(*request);
        if self.fail {
            return Err(FieldError("the shape has no edges".to_owned()));
        }
        let count = request.width as usize * request.height as usize * 3;
        Ok(vec![1.0; if self.short { count - 1 } else { count }])
    }
}

fn square(left: f32, bottom: f32, size: f32) -> Outline {
    let (right, top) = (left + size, bottom + size);
    Outline {
        contours: vec![vec![
            Segment::Line([left, bottom], [right, bottom]),
            Segment::Line([right, bottom], [right, top]),
            Segment::Line([right, top], [left, top]),
            Segment::Line([left, top], [left, bottom]),
        ]],
    }
}

fn small() -> AtlasConfig {
    AtlasConfig {
        em_pixels: 10,
        range_pixels: 2,
        page_size: 64,
    }
}

const FACE: FaceHandle = FaceHandle::new(0);

#[test]
fn a_glyph_without_an_outline_is_remembered_as_empty() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let mut reads = 0;
    for _ in 0..2 {
        let placement = atlas
            .glyph(
                FACE,
                3,
                || {
                    reads += 1;
                    None
                },
                &mut generator,
            )
            .expect("an empty glyph is not an error");
        assert_eq!(placement, None);
    }
    assert_eq!(reads, 1, "the outline is read once");
    assert!(atlas.pages().is_empty(), "an empty glyph takes no page");
}

#[test]
fn a_glyph_maps_its_outline_into_its_padded_cell() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let placement = atlas
        .glyph(FACE, 1, || Some(square(0.1, -0.2, 0.5)), &mut generator)
        .expect("the glyph fits")
        .expect("the glyph has an outline");
    let request = generator.requests[0];
    assert!(
        (request.range - 0.2).abs() < 1e-9,
        "the range is in ems: {}",
        request.range
    );
    // The padding is half the range rounded up, plus a pixel.
    let padding = 2.0;
    assert_eq!((request.width, request.height), (5 + 4, 5 + 4));
    let pixel = |[x, y]: Point| {
        [
            request.scale[0] * (f64::from(x) + request.translate[0]),
            request.scale[1] * (f64::from(y) + request.translate[1]),
        ]
    };
    let [left, top] = pixel([0.1, 0.3]);
    let [right, bottom] = pixel([0.6, -0.2]);
    assert!(
        (left - padding).abs() < 1e-4,
        "the left edge is one padding in: {left}"
    );
    assert!(
        (top - padding).abs() < 1e-4,
        "the top edge is one padding down: {top}"
    );
    assert!(
        (right - (f64::from(request.width) - padding)).abs() < 1e-4,
        "{right}"
    );
    assert!(
        (bottom - (f64::from(request.height) - padding)).abs() < 1e-4,
        "{bottom}"
    );
    assert_eq!(placement.page, 0);
    let close = |a: f32, b: f32| (a - b).abs() < 1e-5;
    assert!(
        close(placement.quad[0], (1.0 - padding as f32) / 10.0),
        "{:?}",
        placement.quad
    );
    assert!(
        close(placement.quad[1], (3.0 + padding as f32) / 10.0),
        "{:?}",
        placement.quad
    );
    assert!(close(placement.quad[2], 0.9) && close(placement.quad[3], 0.9));
    assert_eq!(placement.uv, [0.0, 0.0, 9.0 / 64.0, 9.0 / 64.0]);
    let page = &atlas.pages()[0];
    assert_eq!(page.revision, 1);
    let at = |x: usize, y: usize| page.pixels[(y * 64 + x) * 4];
    assert_eq!(
        (at(0, 0), at(8, 8), at(9, 0), at(0, 9)),
        (255, 255, 0, 0),
        "only the cell is written"
    );
}

#[test]
fn glyphs_fill_shelves_and_then_new_pages_without_overlapping() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let mut placements = Vec::new();
    for glyph in 0..40 {
        let size = 0.3 + f32::from(glyph % 4) * 0.1;
        let placement = atlas
            .glyph(FACE, glyph, || Some(square(0.0, 0.0, size)), &mut generator)
            .expect("the glyph fits")
            .expect("the glyph has an outline");
        placements.push(placement);
    }
    assert!(
        atlas.pages().len() > 1,
        "forty glyphs need a second small page"
    );
    for (index, a) in placements.iter().enumerate() {
        assert!(a.uv[2] <= 1.0 && a.uv[3] <= 1.0, "a cell stays on its page");
        for b in &placements[index + 1..] {
            let apart = a.page != b.page
                || a.uv[2] <= b.uv[0]
                || b.uv[2] <= a.uv[0]
                || a.uv[3] <= b.uv[1]
                || b.uv[3] <= a.uv[1];
            assert!(apart, "{a:?} overlaps {b:?}");
        }
    }
    let again = atlas
        .glyph(
            FACE,
            5,
            || panic!("a known glyph reads no outline"),
            &mut generator,
        )
        .expect("a known glyph is not an error");
    assert_eq!(again, Some(placements[5]), "a glyph keeps its placement");
}

#[test]
fn failures_are_errors_and_are_not_remembered() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let large = atlas.glyph(FACE, 1, || Some(square(0.0, 0.0, 8.0)), &mut generator);
    assert!(
        matches!(large, Err(AtlasError::TooLarge { .. })),
        "{large:?}"
    );
    generator.fail = true;
    let failed = atlas.glyph(FACE, 2, || Some(square(0.0, 0.0, 0.5)), &mut generator);
    let error = failed.expect_err("a failing generator is an error");
    assert!(
        error
            .to_string()
            .starts_with("glyph atlas: glyph 2 of face 0: distance field:"),
        "{error}"
    );
    generator.fail = false;
    generator.short = true;
    let short = atlas.glyph(FACE, 2, || Some(square(0.0, 0.0, 0.5)), &mut generator);
    assert!(
        matches!(short, Err(AtlasError::FieldSize { .. })),
        "{short:?}"
    );
    generator.short = false;
    let recovered = atlas
        .glyph(FACE, 2, || Some(square(0.0, 0.0, 0.5)), &mut generator)
        .expect("the glyph is tried again");
    assert!(recovered.is_some());
    assert_eq!(
        atlas.len(),
        1,
        "only the glyph that succeeded is remembered"
    );
}

#[test]
fn a_shaped_glyph_has_a_closed_outline_inside_its_em() {
    let mut fonts = Fonts::bundled([include_bytes!(
        "../../../../lua/lunette-plugins/theme/arcade/fonts/SpaceMono-Regular.ttf"
    )
    .to_vec()]);
    let style = TextStyle {
        family: Some("Space Mono".to_owned()),
        ..TextStyle::default()
    };
    let mut block = TextBlock::new(&mut fonts, "H ", style).expect("the style is valid");
    let lines = block.lines(&mut fonts, None);
    let glyphs = &lines[0].glyphs;
    let letter = fonts
        .outline(glyphs[0].handle, glyphs[0].id)
        .expect("H has an outline");
    let [left, bottom, right, top] = letter.bounds().expect("the outline has points");
    assert!(
        left >= 0.0 && right <= 1.0 && bottom >= -0.01 && top <= 1.0,
        "{left} {bottom} {right} {top}"
    );
    assert!(top - bottom > 0.5, "a capital is most of an em tall");
    for contour in &letter.contours {
        let first = contour.first().expect("a contour has segments");
        let last = contour.last().expect("a contour has segments");
        let start = match first {
            Segment::Line(a, _) | Segment::Quadratic(a, ..) | Segment::Cubic(a, ..) => *a,
        };
        let end = match last {
            Segment::Line(_, b) | Segment::Quadratic(.., b) | Segment::Cubic(.., b) => *b,
        };
        assert_eq!(start, end, "the contour is closed");
    }
    assert_eq!(
        fonts.outline(glyphs[1].handle, glyphs[1].id),
        None,
        "a space has no outline"
    );
    assert_eq!(glyphs[0].handle, glyphs[1].handle, "one face, one handle");
}
