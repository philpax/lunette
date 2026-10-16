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
        max_pages: 4,
    }
}

/// Adds a glyph in one step, as the host does across threads.
fn add(
    atlas: &mut Atlas,
    face: FaceHandle,
    glyph: u16,
    outline: impl FnOnce() -> Option<Outline>,
    generator: &mut dyn FieldGenerator,
) -> Result<Option<Placement>, AtlasError> {
    match atlas.prepare(face, glyph, outline)? {
        Prepared::Known(known) => Ok(known),
        Prepared::Job(job) => {
            let field = job.generate(generator);
            atlas.complete(&job, field)
        }
    }
}

const FACE: FaceHandle = FaceHandle::new(0);

#[test]
fn a_glyph_without_an_outline_is_remembered_as_empty() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let mut reads = 0;
    for _ in 0..2 {
        let placement = add(
            &mut atlas,
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
    let placement = add(
        &mut atlas,
        FACE,
        1,
        || Some(square(0.1, -0.2, 0.5)),
        &mut generator,
    )
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
    // The cell sits inside a one-pixel gutter.
    assert_eq!(
        placement.uv,
        [1.0 / 64.0, 1.0 / 64.0, 10.0 / 64.0, 10.0 / 64.0]
    );
    let page = &atlas.pages()[0];
    assert_eq!(page.revision, 1);
    let at = |x: usize, y: usize| page.pixels[(y * 64 + x) * 4];
    assert_eq!((at(1, 1), at(9, 9)), (255, 255), "the cell is written");
    for i in 0..=10 {
        assert_eq!(
            (at(i, 0), at(0, i), at(i, 10), at(10, i)),
            (0, 0, 0, 0),
            "the gutter around the cell stays empty at {i}"
        );
    }
}

#[test]
fn glyphs_fill_shelves_and_then_new_pages_without_overlapping() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let mut placements = Vec::new();
    for glyph in 0..40 {
        let size = 0.3 + f32::from(glyph % 4) * 0.1;
        let placement = add(
            &mut atlas,
            FACE,
            glyph,
            || Some(square(0.0, 0.0, size)),
            &mut generator,
        )
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
    let again = add(
        &mut atlas,
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
    let large = add(
        &mut atlas,
        FACE,
        1,
        || Some(square(0.0, 0.0, 8.0)),
        &mut generator,
    );
    assert!(
        matches!(large, Err(AtlasError::TooLarge { .. })),
        "{large:?}"
    );
    generator.fail = true;
    let failed = add(
        &mut atlas,
        FACE,
        2,
        || Some(square(0.0, 0.0, 0.5)),
        &mut generator,
    );
    let error = failed.expect_err("a failing generator is an error");
    assert!(
        error
            .to_string()
            .starts_with("glyph atlas: glyph 2 of face 0: distance field:"),
        "{error}"
    );
    generator.fail = false;
    generator.short = true;
    let short = add(
        &mut atlas,
        FACE,
        2,
        || Some(square(0.0, 0.0, 0.5)),
        &mut generator,
    );
    assert!(
        matches!(short, Err(AtlasError::FieldSize { .. })),
        "{short:?}"
    );
    generator.short = false;
    let recovered = add(
        &mut atlas,
        FACE,
        2,
        || Some(square(0.0, 0.0, 0.5)),
        &mut generator,
    )
    .expect("the glyph is tried again");
    assert!(recovered.is_some());
    assert_eq!(
        atlas.len(),
        1,
        "only the glyph that succeeded is remembered"
    );
}

#[test]
fn a_full_atlas_refuses_new_glyphs_and_keeps_the_ones_it_holds() {
    let mut atlas = Atlas::new(AtlasConfig {
        max_pages: 1,
        ..small()
    });
    let mut generator = Fill::default();
    // A 2 em square needs a 24 pixel cell and a 26 pixel slot with its gutter, so a 64 pixel page holds
    // four.
    for glyph in 0..4 {
        add(
            &mut atlas,
            FACE,
            glyph,
            || Some(square(0.0, 0.0, 2.0)),
            &mut generator,
        )
        .expect("the page has room")
        .expect("the glyph has an outline");
    }
    let refused = add(
        &mut atlas,
        FACE,
        4,
        || Some(square(0.0, 0.0, 2.0)),
        &mut generator,
    );
    assert!(
        matches!(refused, Err(AtlasError::Full { pages: 1, .. })),
        "{refused:?}"
    );
    assert_eq!(
        generator.requests.len(),
        4,
        "a glyph with no room is refused before its field is generated"
    );
    assert_eq!(atlas.pages().len(), 1, "no page opens past the limit");
    let small_glyph = add(
        &mut atlas,
        FACE,
        5,
        || Some(square(0.0, 0.0, 0.5)),
        &mut generator,
    )
    .expect("a smaller glyph fits beside the others");
    assert!(small_glyph.is_some());
    let kept = add(
        &mut atlas,
        FACE,
        0,
        || panic!("a known glyph reads no outline"),
        &mut generator,
    )
    .expect("a held glyph stays available");
    assert!(kept.is_some());
}

#[test]
fn a_job_that_finds_the_atlas_full_when_it_completes_is_refused() {
    let mut atlas = Atlas::new(AtlasConfig {
        max_pages: 1,
        ..small()
    });
    let mut generator = Fill::default();
    let jobs: Vec<Job> = (0..5)
        .map(|glyph| {
            match atlas
                .prepare(FACE, glyph, || Some(square(0.0, 0.0, 2.0)))
                .expect("the empty atlas has room")
            {
                Prepared::Job(job) => job,
                Prepared::Known(known) => panic!("a new glyph is a job, not {known:?}"),
            }
        })
        .collect();
    let results: Vec<_> = jobs
        .iter()
        .map(|job| {
            let field = job.generate(&mut generator);
            atlas.complete(job, field)
        })
        .collect();
    assert!(
        results[..4]
            .iter()
            .all(|result| matches!(result, Ok(Some(_))))
    );
    assert!(
        matches!(results[4], Err(AtlasError::Full { .. })),
        "{:?}",
        results[4]
    );
    assert_eq!(
        atlas.known(FACE, 4),
        None,
        "a refused glyph is not remembered"
    );
}

#[test]
fn a_glyph_completed_twice_keeps_its_first_placement() {
    let mut atlas = Atlas::new(small());
    let mut generator = Fill::default();
    let job = match atlas
        .prepare(FACE, 1, || Some(square(0.0, 0.0, 0.5)))
        .expect("the glyph fits")
    {
        Prepared::Job(job) => job,
        Prepared::Known(known) => panic!("a new glyph is a job, not {known:?}"),
    };
    let first = atlas
        .complete(&job, job.generate(&mut generator))
        .expect("the field is placed");
    let second = atlas
        .complete(&job, job.generate(&mut generator))
        .expect("a second completion is not an error");
    assert_eq!(first, second);
    assert_eq!(atlas.pages()[0].revision, 1, "the page is written once");
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
