//! A paged atlas of multi-channel signed distance field glyphs, keyed by face and glyph id.
//!
//! Shaping produces glyph ids, which LÖVR's fonts cannot draw, so the toolkit draws glyphs from
//! this atlas through its own shader. Outlines come from [`crate::text::Fonts::outline`] in em
//! units with y up. A [`FieldGenerator`] turns an outline into distance field pixels; the host's
//! implementation calls msdfgen, and tests substitute their own. Pages are RGBA8, top row first,
//! and a glyph keeps its page and position for the atlas's lifetime, so instance data that refers
//! to it stays valid as the atlas grows.

use std::{collections::HashMap, fmt};

use crate::text::FaceHandle;

/// The atlas's raster parameters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AtlasConfig {
    /// Pixels per em at which glyphs are generated.
    pub em_pixels: u32,
    /// The distance field's range in pixels: the distance over which it goes from inside to
    /// outside. A larger range keeps edges sharp when glyphs are drawn far smaller.
    pub range_pixels: u32,
    /// The width and height of each page.
    pub page_size: u32,
}

impl Default for AtlasConfig {
    fn default() -> Self {
        Self {
            em_pixels: 48,
            range_pixels: 6,
            page_size: 1024,
        }
    }
}

/// A point in em units, y up.
pub type Point = [f32; 2];

/// One edge of a contour.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Segment {
    Line(Point, Point),
    Quadratic(Point, Point, Point),
    Cubic(Point, Point, Point, Point),
}

impl Segment {
    /// The segment's points, including control points, which bound the curve.
    fn points(&self) -> impl Iterator<Item = Point> {
        let (points, count): ([Point; 4], usize) = match *self {
            Segment::Line(a, b) => ([a, b, b, b], 2),
            Segment::Quadratic(a, b, c) => ([a, b, c, c], 3),
            Segment::Cubic(a, b, c, d) => ([a, b, c, d], 4),
        };
        points.into_iter().take(count)
    }
}

/// A glyph's outline: closed contours of segments, in em units with y up.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outline {
    pub contours: Vec<Vec<Segment>>,
}

impl Outline {
    /// The smallest box holding every point and control point, as left, bottom, right, and top,
    /// or nil for an outline with no segments.
    pub fn bounds(&self) -> Option<[f32; 4]> {
        let mut points = self.contours.iter().flatten().flat_map(Segment::points);
        let first = points.next()?;
        let mut bounds = [first[0], first[1], first[0], first[1]];
        for [x, y] in points {
            bounds[0] = bounds[0].min(x);
            bounds[1] = bounds[1].min(y);
            bounds[2] = bounds[2].max(x);
            bounds[3] = bounds[3].max(y);
        }
        Some(bounds)
    }
}

/// What a generator draws: a field of `width` by `height` pixels, where an outline point `p`
/// lands on pixel `scale * (p + translate)`. The scale's y is negative, so row 0 is the top.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FieldRequest {
    pub width: u32,
    pub height: u32,
    /// The field's range in outline units, as msdfgen measures it: the atlas's range in pixels
    /// divided by its pixels per em.
    pub range: f64,
    pub scale: [f64; 2],
    pub translate: [f64; 2],
}

/// Turns an outline into a multi-channel distance field.
pub trait FieldGenerator {
    /// Answers `width * height` RGB triples, top row first, with 0.5 on the outline, more inside,
    /// and less outside.
    fn generate(
        &mut self,
        outline: &Outline,
        request: &FieldRequest,
    ) -> Result<Vec<f32>, FieldError>;
}

/// A generator that could not draw a field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldError(pub String);

impl fmt::Display for FieldError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "distance field: {}", self.0)
    }
}

impl std::error::Error for FieldError {}

/// Where a glyph is in the atlas and how to place its quad.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Placement {
    /// The page, from zero.
    pub page: u32,
    /// The texture rectangle, as left, top, right, and bottom in texture coordinates.
    pub uv: [f32; 4],
    /// The quad, in em units from the glyph's origin on the baseline: its left edge, its top edge
    /// above the baseline, its width, and its height.
    pub quad: [f32; 4],
}

/// One atlas page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page {
    pub size: u32,
    /// RGBA8 pixels, top row first.
    pub pixels: Vec<u8>,
    /// Advances whenever a glyph is written to the page, so the host knows to upload it again.
    pub revision: u64,
    shelves: Vec<Shelf>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Shelf {
    top: u32,
    height: u32,
    used: u32,
}

/// Why a glyph could not be added.
#[derive(Debug)]
pub enum AtlasError {
    /// The glyph needs a cell larger than a page.
    TooLarge {
        face: FaceHandle,
        glyph: u16,
        width: u32,
        height: u32,
    },
    /// The generator failed.
    Field {
        face: FaceHandle,
        glyph: u16,
        source: FieldError,
    },
    /// The generator answered the wrong number of values.
    FieldSize {
        face: FaceHandle,
        glyph: u16,
        expected: usize,
        actual: usize,
    },
}

impl fmt::Display for AtlasError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AtlasError::TooLarge {
                face,
                glyph,
                width,
                height,
            } => write!(
                f,
                "glyph atlas: glyph {glyph} of face {} needs a {width}x{height} cell, larger than a page",
                face.get()
            ),
            AtlasError::Field {
                face,
                glyph,
                source,
            } => write!(
                f,
                "glyph atlas: glyph {glyph} of face {}: {source}",
                face.get()
            ),
            AtlasError::FieldSize {
                face,
                glyph,
                expected,
                actual,
            } => write!(
                f,
                "glyph atlas: glyph {glyph} of face {}: the field has {actual} values rather than {expected}",
                face.get()
            ),
        }
    }
}

impl std::error::Error for AtlasError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            AtlasError::Field { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// Glyphs generated so far, and the pages that hold them.
#[derive(Debug)]
pub struct Atlas {
    config: AtlasConfig,
    pages: Vec<Page>,
    /// Every glyph asked for. A glyph with no outline, such as a space, maps to nil.
    glyphs: HashMap<(FaceHandle, u16), Option<Placement>>,
}

impl Atlas {
    pub fn new(config: AtlasConfig) -> Self {
        Self {
            config,
            pages: Vec::new(),
            glyphs: HashMap::new(),
        }
    }

    pub fn config(&self) -> AtlasConfig {
        self.config
    }

    pub fn pages(&self) -> &[Page] {
        &self.pages
    }

    /// The number of glyphs asked for, including those with no outline.
    pub fn len(&self) -> usize {
        self.glyphs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.glyphs.is_empty()
    }

    /// The glyph's placement, generating it on first use from the outline that `outline` reads.
    /// A glyph with no outline answers nil, and is remembered so its outline is read once.
    ///
    /// # Errors
    ///
    /// A glyph larger than a page, or a generator failure, is an error, and the glyph is not
    /// remembered, so a later call tries again.
    pub fn glyph(
        &mut self,
        face: FaceHandle,
        glyph: u16,
        outline: impl FnOnce() -> Option<Outline>,
        generator: &mut dyn FieldGenerator,
    ) -> Result<Option<Placement>, AtlasError> {
        if let Some(known) = self.glyphs.get(&(face, glyph)) {
            return Ok(*known);
        }
        let placement = match outline() {
            Some(outline) => self.add(face, glyph, &outline, generator)?,
            None => None,
        };
        self.glyphs.insert((face, glyph), placement);
        Ok(placement)
    }

    fn add(
        &mut self,
        face: FaceHandle,
        glyph: u16,
        outline: &Outline,
        generator: &mut dyn FieldGenerator,
    ) -> Result<Option<Placement>, AtlasError> {
        let Some([left, bottom, right, top]) = outline.bounds() else {
            return Ok(None);
        };
        let em = self.config.em_pixels as f32;
        let padding = self.config.range_pixels.div_ceil(2) + 1;
        let x0 = (left * em).floor() as i64;
        let y0 = (bottom * em).floor() as i64;
        let x1 = (right * em).ceil() as i64;
        let y1 = (top * em).ceil() as i64;
        let width = u32::try_from(x1 - x0).unwrap_or(0) + 2 * padding;
        let height = u32::try_from(y1 - y0).unwrap_or(0) + 2 * padding;
        let size = self.config.page_size;
        if width > size || height > size {
            return Err(AtlasError::TooLarge {
                face,
                glyph,
                width,
                height,
            });
        }
        let request = FieldRequest {
            width,
            height,
            range: f64::from(self.config.range_pixels) / f64::from(em),
            scale: [f64::from(em), -f64::from(em)],
            translate: [
                (padding as f64 - x0 as f64) / f64::from(em),
                -(y1 as f64 + padding as f64) / f64::from(em),
            ],
        };
        let field = generator
            .generate(outline, &request)
            .map_err(|source| AtlasError::Field {
                face,
                glyph,
                source,
            })?;
        let expected = width as usize * height as usize * 3;
        if field.len() != expected {
            return Err(AtlasError::FieldSize {
                face,
                glyph,
                expected,
                actual: field.len(),
            });
        }
        let (page, x, y) = self.allocate(width, height);
        let target = &mut self.pages[page];
        write_field(target, x, y, width, height, &field);
        let scale = 1.0 / size as f32;
        let padding = padding as f32;
        Ok(Some(Placement {
            page: page as u32,
            uv: [
                x as f32 * scale,
                y as f32 * scale,
                (x + width) as f32 * scale,
                (y + height) as f32 * scale,
            ],
            quad: [
                (x0 as f32 - padding) / em,
                (y1 as f32 + padding) / em,
                width as f32 / em,
                height as f32 / em,
            ],
        }))
    }

    /// Finds room for a cell on a shelf of an existing page, opening a shelf or a page if needed.
    fn allocate(&mut self, width: u32, height: u32) -> (usize, u32, u32) {
        let size = self.config.page_size;
        for (index, page) in self.pages.iter_mut().enumerate() {
            if let Some((x, y)) = place(page, size, width, height) {
                return (index, x, y);
            }
        }
        let mut page = Page {
            size,
            pixels: vec![0; size as usize * size as usize * 4],
            revision: 0,
            shelves: Vec::new(),
        };
        // A new page holds any cell no larger than itself, which `add` has checked.
        let (x, y) = place(&mut page, size, width, height).unwrap_or((0, 0));
        self.pages.push(page);
        (self.pages.len() - 1, x, y)
    }
}

/// Places a cell on the page's shelves: the first shelf tall enough with room left, or a new
/// shelf below the last.
fn place(page: &mut Page, size: u32, width: u32, height: u32) -> Option<(u32, u32)> {
    for shelf in &mut page.shelves {
        if height <= shelf.height && shelf.used + width <= size {
            let x = shelf.used;
            shelf.used += width;
            return Some((x, shelf.top));
        }
    }
    let top = page
        .shelves
        .last()
        .map_or(0, |shelf| shelf.top + shelf.height);
    if top + height > size {
        return None;
    }
    page.shelves.push(Shelf {
        top,
        height,
        used: width,
    });
    Some((0, top))
}

fn write_field(page: &mut Page, x: u32, y: u32, width: u32, height: u32, field: &[f32]) {
    let stride = page.size as usize * 4;
    for row in 0..height as usize {
        for column in 0..width as usize {
            let source = (row * width as usize + column) * 3;
            let target = (y as usize + row) * stride + (x as usize + column) * 4;
            for channel in 0..3 {
                page.pixels[target + channel] = quantise(field[source + channel]);
            }
            page.pixels[target + 3] = 255;
        }
    }
    page.revision += 1;
}

fn quantise(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

#[cfg(test)]
mod tests;
