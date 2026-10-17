//! Shaping, wrapping, and measurement of text, in metres.
//!
//! cosmic-text works in abstract units. Text here is shaped in millimetres, so font sizes and
//! positions stay in the range its layout code expects, and converted to metres at the edge.

use std::{collections::HashMap, fmt, sync::Arc};

pub use cosmic_text::fontdb::ID as FaceId;
use cosmic_text::{
    Align, Attrs, Buffer, Ellipsize, EllipsizeHeightLimit, Family, FontSystem, Metrics,
    PlatformFallback, Shaping, Weight, Wrap, fontdb,
    skrifa::{
        FontRef, GlyphId, MetadataProvider,
        instance::{LocationRef, Size},
        outline::{DrawSettings, OutlinePen},
    },
};

use crate::glyphs::{Outline, Point, Segment};

/// Metres per shaping unit.
const METRES_PER_UNIT: f32 = 0.001;

/// The fonts text is shaped with.
pub struct Fonts {
    system: FontSystem,
    /// The files given so far, so a file given again, as on a source reload, adds no faces.
    files: Vec<Arc<Vec<u8>>>,
    /// The faces that shaped glyphs came from, in the order they were first seen, so a face can
    /// cross into Lua as a small integer.
    handles: Vec<FaceId>,
    handle_of: HashMap<FaceId, FaceHandle>,
}

/// A face as a small integer that stays the same for the fonts' lifetime.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FaceHandle(u32);

impl FaceHandle {
    pub const fn new(value: u32) -> Self {
        Self(value)
    }

    pub const fn get(self) -> u32 {
        self.0
    }
}

impl Fonts {
    /// Fonts from the given font files only. Measurements depend on nothing but these files, so
    /// tests get the same results on every machine.
    pub fn bundled(files: impl IntoIterator<Item = Vec<u8>>) -> Self {
        let mut fonts = Self::from_database(fontdb::Database::new());
        for data in files {
            fonts.add(data);
        }
        fonts
    }

    /// The given font files and the system's fonts. Enumerating system fonts takes far longer
    /// than a frame, so this is called once, at startup.
    pub fn with_system(files: impl IntoIterator<Item = Vec<u8>>) -> Self {
        let mut db = fontdb::Database::new();
        db.load_system_fonts();
        let mut fonts = Self::from_database(db);
        for data in files {
            fonts.add(data);
        }
        fonts
    }

    fn from_database(db: fontdb::Database) -> Self {
        Self {
            system: FontSystem::new_with_locale_and_db_and_fallback(
                "en-US".to_owned(),
                db,
                PlatformFallback,
            ),
            files: Vec::new(),
            handles: Vec::new(),
            handle_of: HashMap::new(),
        }
    }

    /// The handle of a face, assigned on first use.
    pub fn handle(&mut self, face: FaceId) -> FaceHandle {
        if let Some(handle) = self.handle_of.get(&face) {
            return *handle;
        }
        let handle = FaceHandle(self.handles.len() as u32);
        self.handles.push(face);
        self.handle_of.insert(face, handle);
        handle
    }

    /// A glyph's outline in em units with y up, or nil for a glyph with no outline, such as a
    /// space, or a face or glyph that does not exist. Variable faces draw their default instance.
    pub fn outline(&self, face: FaceHandle, glyph: u16) -> Option<Outline> {
        let id = *self.handles.get(face.0 as usize)?;
        self.system
            .db()
            .with_face_data(id, |data, index| {
                let font = FontRef::from_index(data, index).ok()?;
                let outline = font.outline_glyphs().get(GlyphId::new(u32::from(glyph)))?;
                let mut pen = Pen::default();
                outline
                    .draw(
                        DrawSettings::unhinted(Size::new(1.0), LocationRef::default()),
                        &mut pen,
                    )
                    .ok()?;
                pen.finish();
                if pen.outline.contours.is_empty() {
                    None
                } else {
                    Some(pen.outline)
                }
            })
            .flatten()
    }

    /// Adds the faces in one font file, answering how many it added. A file that is not a font
    /// holds none, and a file with the same bytes as one given before adds none.
    pub fn add(&mut self, data: Vec<u8>) -> usize {
        if self
            .files
            .iter()
            .any(|file| file.as_slice() == data.as_slice())
        {
            return 0;
        }
        let data = Arc::new(data);
        self.files.push(data.clone());
        let before = self.system.db().len();
        self.system
            .db_mut()
            .load_font_source(fontdb::Source::Binary(data));
        self.system.db().len() - before
    }
}

impl fmt::Debug for Fonts {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Fonts")
            .field("faces", &self.system.db().len())
            .finish()
    }
}

/// Horizontal alignment, in logical terms.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Alignment {
    #[default]
    Start,
    Center,
    End,
}

/// How text breaks across lines.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Wrapping {
    /// One line, however long.
    None,
    /// Breaks at word boundaries.
    #[default]
    Word,
    /// Breaks at word boundaries, and inside a word that does not fit on a line of its own.
    WordOrGlyph,
}

/// The style of one text node.
#[derive(Clone, Debug, PartialEq)]
pub struct TextStyle {
    /// A family name, or `None` for the default sans-serif family.
    pub family: Option<String>,
    /// The font size, in metres.
    pub size: f32,
    /// The line height, as a multiple of the font size.
    pub line_height: f32,
    /// The weight, from 100 to 900.
    pub weight: u16,
    /// Extra space after each glyph, as a multiple of the font size; zero sets text as the font spaces it.
    pub letter_spacing: f32,
    pub alignment: Alignment,
    pub wrapping: Wrapping,
    /// The most lines shown; later lines are replaced by an ellipsis on the last one.
    pub max_lines: Option<usize>,
}

impl Default for TextStyle {
    fn default() -> Self {
        Self {
            family: None,
            size: 0.012,
            line_height: 1.3,
            weight: 400,
            letter_spacing: 0.0,
            alignment: Alignment::Start,
            wrapping: Wrapping::Word,
            max_lines: None,
        }
    }
}

/// An error in a text style.
#[derive(Debug, Clone, PartialEq)]
pub enum TextStyleError {
    /// The size is not a positive finite number.
    Size(f32),
    /// The line height is not a positive finite number.
    LineHeight(f32),
    /// The weight is outside 1 to 1000.
    Weight(u16),
    /// The letter spacing is not a finite number.
    LetterSpacing(f32),
    /// The maximum line count is zero.
    MaxLines,
}

impl fmt::Display for TextStyleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Size(size) => write!(f, "text style: the size {size} is not a positive length"),
            Self::LineHeight(height) => {
                write!(
                    f,
                    "text style: the line height {height} is not a positive multiple"
                )
            }
            Self::Weight(weight) => {
                write!(f, "text style: the weight {weight} is outside 1 to 1000")
            }
            Self::LetterSpacing(spacing) => {
                write!(
                    f,
                    "text style: the letter spacing {spacing} is not a finite number"
                )
            }
            Self::MaxLines => write!(f, "text style: the maximum line count is zero"),
        }
    }
}

impl std::error::Error for TextStyleError {}

impl TextStyle {
    /// Checks that every value can be shaped.
    ///
    /// # Errors
    ///
    /// Returns the first value that cannot.
    pub fn validate(&self) -> Result<(), TextStyleError> {
        if !(self.size.is_finite() && self.size > 0.0) {
            return Err(TextStyleError::Size(self.size));
        }
        if !(self.line_height.is_finite() && self.line_height > 0.0) {
            return Err(TextStyleError::LineHeight(self.line_height));
        }
        if !(1..=1000).contains(&self.weight) {
            return Err(TextStyleError::Weight(self.weight));
        }
        if !self.letter_spacing.is_finite() {
            return Err(TextStyleError::LetterSpacing(self.letter_spacing));
        }
        if self.max_lines == Some(0) {
            return Err(TextStyleError::MaxLines);
        }
        Ok(())
    }

    fn metrics(&self) -> Metrics {
        let size = self.size / METRES_PER_UNIT;
        Metrics::new(size, size * self.line_height)
    }
}

/// One shaped line, in metres from the text node's top-left corner.
#[derive(Clone, Debug, PartialEq)]
pub struct Line {
    pub top: f32,
    pub height: f32,
    pub width: f32,
    /// The baseline, measured from the top of the node.
    pub baseline: f32,
    pub glyphs: Vec<Glyph>,
}

/// One positioned glyph.
#[derive(Clone, Debug, PartialEq)]
pub struct Glyph {
    /// The font face the glyph comes from.
    pub face: FaceId,
    /// The same face as a handle, for the glyph atlas.
    pub handle: FaceHandle,
    /// The glyph's id in its face. Shaping produces glyph ids, not codepoints.
    pub id: u16,
    /// The glyph's origin on the baseline, in metres from the node's left edge.
    pub x: f32,
    /// Shaping's placement of the glyph relative to its origin, in metres, with y down, as a
    /// combining mark has.
    pub offset_x: f32,
    pub offset_y: f32,
    pub advance: f32,
    pub size: f32,
    /// The byte range of the text this glyph draws.
    pub start: usize,
    pub end: usize,
}

/// A shaped block of text that measures itself at a width.
pub struct TextBlock {
    buffer: Buffer,
    style: TextStyle,
    text: String,
    /// The most recent measurement: the width asked for and the size that came back.
    last: Option<(Option<f32>, (f32, f32))>,
}

impl fmt::Debug for TextBlock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TextBlock")
            .field("text", &self.text)
            .field("style", &self.style)
            .finish()
    }
}

impl TextBlock {
    /// Shapes `text` in `style`.
    ///
    /// # Errors
    ///
    /// Returns an error if the style cannot be shaped.
    pub fn new(fonts: &mut Fonts, text: &str, style: TextStyle) -> Result<Self, TextStyleError> {
        style.validate()?;
        let mut block = Self {
            buffer: Buffer::new(&mut fonts.system, style.metrics()),
            style,
            text: String::new(),
            last: None,
        };
        block.set(fonts, text, block.style.clone())?;
        Ok(block)
    }

    /// Replaces the text and the style.
    ///
    /// # Errors
    ///
    /// Returns an error if the style cannot be shaped; the block keeps its previous contents.
    pub fn set(
        &mut self,
        fonts: &mut Fonts,
        text: &str,
        style: TextStyle,
    ) -> Result<(), TextStyleError> {
        style.validate()?;
        let mut buffer = self.buffer.borrow_with(&mut fonts.system);
        buffer.set_metrics(style.metrics());
        buffer.set_wrap(match style.wrapping {
            Wrapping::None => Wrap::None,
            Wrapping::Word => Wrap::Word,
            Wrapping::WordOrGlyph => Wrap::WordOrGlyph,
        });
        buffer.set_ellipsize(match style.max_lines {
            Some(lines) => Ellipsize::End(EllipsizeHeightLimit::Lines(lines)),
            None => Ellipsize::None,
        });
        let family = match &style.family {
            Some(name) => Family::Name(name),
            None => Family::SansSerif,
        };
        let attrs = Attrs::new()
            .family(family)
            .weight(Weight(style.weight))
            .letter_spacing(style.letter_spacing);
        let align = match style.alignment {
            Alignment::Start => None,
            Alignment::Center => Some(Align::Center),
            Alignment::End => Some(Align::End),
        };
        buffer.set_text(text, &attrs, Shaping::Advanced, align);
        self.text = text.to_owned();
        self.style = style;
        self.last = None;
        Ok(())
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn style(&self) -> &TextStyle {
        &self.style
    }

    /// The size of the text laid out at `width` metres, or on unbounded lines when `width` is
    /// `None`. A width of zero gives the min-content size: every break opportunity is taken.
    pub fn measure(&mut self, fonts: &mut Fonts, width: Option<f32>) -> (f32, f32) {
        if let Some((asked, size)) = self.last
            && asked == width
        {
            return size;
        }
        let size = self.lay_out(fonts, width);
        self.last = Some((width, size));
        size
    }

    /// The shaped lines at `width`, for drawing.
    pub fn lines(&mut self, fonts: &mut Fonts, width: Option<f32>) -> Vec<Line> {
        self.lay_out(fonts, width);
        let unit = METRES_PER_UNIT;
        let mut handle = |face: FaceId| fonts.handle(face);
        self.buffer
            .layout_runs()
            .map(|run| Line {
                top: run.line_top * unit,
                height: run.line_height * unit,
                width: run.line_w * unit,
                baseline: run.line_y * unit,
                glyphs: run
                    .glyphs
                    .iter()
                    .map(|glyph| Glyph {
                        face: glyph.font_id,
                        handle: handle(glyph.font_id),
                        id: glyph.glyph_id,
                        x: glyph.x * unit,
                        offset_x: glyph.font_size * glyph.x_offset * unit,
                        offset_y: (glyph.y - glyph.font_size * glyph.y_offset) * unit,
                        advance: glyph.w * unit,
                        size: glyph.font_size * unit,
                        start: glyph.start,
                        end: glyph.end,
                    })
                    .collect(),
            })
            .collect()
    }

    fn lay_out(&mut self, fonts: &mut Fonts, width: Option<f32>) -> (f32, f32) {
        let width_units = width.map(|width| (width / METRES_PER_UNIT).max(0.0));
        let mut buffer = self.buffer.borrow_with(&mut fonts.system);
        buffer.set_size(width_units, None);
        buffer.shape_until_scroll(false);
        let mut widest: f32 = 0.0;
        let mut bottom: f32 = 0.0;
        for run in buffer.layout_runs() {
            widest = widest.max(run.line_w);
            bottom = bottom.max(run.line_top + run.line_height);
        }
        if bottom == 0.0 {
            // Empty text still takes one line, so an empty label keeps its row.
            bottom = self.style.metrics().line_height;
        }
        (widest * METRES_PER_UNIT, bottom * METRES_PER_UNIT)
    }
}

/// Collects an outline from skrifa's drawing commands, closing each contour.
#[derive(Default)]
struct Pen {
    outline: Outline,
    contour: Vec<Segment>,
    start: Point,
    current: Point,
}

impl Pen {
    fn finish(&mut self) {
        if self.current != self.start && !self.contour.is_empty() {
            self.contour.push(Segment::Line(self.current, self.start));
        }
        if !self.contour.is_empty() {
            self.outline
                .contours
                .push(std::mem::take(&mut self.contour));
        }
        self.current = self.start;
    }
}

impl OutlinePen for Pen {
    fn move_to(&mut self, x: f32, y: f32) {
        self.finish();
        self.start = [x, y];
        self.current = [x, y];
    }

    fn line_to(&mut self, x: f32, y: f32) {
        self.contour.push(Segment::Line(self.current, [x, y]));
        self.current = [x, y];
    }

    fn quad_to(&mut self, cx0: f32, cy0: f32, x: f32, y: f32) {
        self.contour
            .push(Segment::Quadratic(self.current, [cx0, cy0], [x, y]));
        self.current = [x, y];
    }

    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        self.contour
            .push(Segment::Cubic(self.current, [cx0, cy0], [cx1, cy1], [x, y]));
        self.current = [x, y];
    }

    fn close(&mut self) {
        self.finish();
    }
}

#[cfg(test)]
mod tests;
