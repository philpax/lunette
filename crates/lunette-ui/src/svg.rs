//! Rasterisation of SVG documents, such as icons from icon themes, with resvg.
//!
//! A document is SVG text or gzip-compressed svgz. It is drawn into a canvas of the requested pixel size, scaled to fit with its aspect
//! ratio preserved and centred, and returned as straight-alpha RGBA8 pixels, the layout LÖVR
//! images use. Rasterisation reads nothing but the document: hrefs to files are not followed, so
//! a document cannot read the filesystem or block on it. Embedded `data:` images are drawn. Text
//! elements are not drawn, because the toolkit's icons are shapes and text shaping is the
//! toolkit's own concern.

use std::fmt;

use resvg::{
    tiny_skia::{Pixmap, Transform},
    usvg::{self, ImageHrefResolver, Options, Tree},
};

/// The largest width or height a document is rasterised at, in pixels.
pub const MAX_SIDE: u32 = 4096;

/// A validated canvas size, in pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RasterSize {
    width: u32,
    height: u32,
}

impl RasterSize {
    /// A canvas size from two pixel counts, each a whole number from 1 to [`MAX_SIDE`]. The
    /// counts are taken as `f64` because they arrive as Lua numbers, and a fractional count is
    /// an error rather than a rounding.
    pub fn new(width: f64, height: f64) -> Result<Self, SvgError> {
        Ok(Self {
            width: side(Axis::Width, width)?,
            height: side(Axis::Height, height)?,
        })
    }

    pub fn width(self) -> u32 {
        self.width
    }

    pub fn height(self) -> u32 {
        self.height
    }
}

/// A rasterised document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Raster {
    pub width: u32,
    pub height: u32,
    /// Tightly packed rows of straight-alpha RGBA8 pixels, top row first.
    pub pixels: Vec<u8>,
}

/// Rasterises an SVG document into a canvas of `size`, fitted and centred.
pub fn rasterize(document: &[u8], size: RasterSize) -> Result<Raster, SvgError> {
    let options = Options {
        image_href_resolver: ImageHrefResolver {
            resolve_data: ImageHrefResolver::default_data_resolver(),
            resolve_string: Box::new(|_, _| None),
        },
        ..Options::default()
    };
    let tree = Tree::from_data(document, &options).map_err(SvgError::Parse)?;
    let mut pixmap = Pixmap::new(size.width, size.height).ok_or(SvgError::Allocation { size })?;
    resvg::render(&tree, fit(&tree, size), &mut pixmap.as_mut());
    Ok(Raster {
        width: size.width,
        height: size.height,
        pixels: pixmap.take_demultiplied(),
    })
}

/// An axis of a canvas.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    Width,
    Height,
}

impl fmt::Display for Axis {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Width => "width",
            Self::Height => "height",
        })
    }
}

/// A document that cannot be rasterised.
#[derive(Debug)]
pub enum SvgError {
    /// A canvas side is not a whole number of pixels from 1 to [`MAX_SIDE`].
    Size { axis: Axis, value: f64 },
    /// The document is not an SVG document usvg can read.
    Parse(usvg::Error),
    /// The canvas could not be allocated.
    Allocation { size: RasterSize },
}

impl fmt::Display for SvgError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Size { axis, value } => write!(
                f,
                "svg: the {axis} {value} is not a whole number of pixels from 1 to {MAX_SIDE}"
            ),
            Self::Parse(error) => match error {
                usvg::Error::NotAnUtf8Str => f.write_str("svg: the document is not UTF-8 text"),
                usvg::Error::SvgzFeatureNotEnabled => {
                    f.write_str("svg: the document is compressed, and svgz is not supported")
                }
                usvg::Error::MalformedGZip => {
                    f.write_str("svg: the document's gzip compression is malformed")
                }
                usvg::Error::ElementsLimitReached => {
                    f.write_str("svg: the document has more elements than usvg accepts")
                }
                usvg::Error::InvalidSize => f.write_str(
                    "svg: the document has no positive width and height and no view box",
                ),
                usvg::Error::ParsingFailed(cause) => {
                    write!(f, "svg: the document is not well-formed XML: {cause}")
                }
            },
            Self::Allocation { size } => write!(
                f,
                "svg: a {}x{} canvas could not be allocated",
                size.width, size.height
            ),
        }
    }
}

impl std::error::Error for SvgError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Parse(error) => Some(error),
            Self::Size { .. } | Self::Allocation { .. } => None,
        }
    }
}

fn side(axis: Axis, value: f64) -> Result<u32, SvgError> {
    if value.fract() == 0.0 && (1.0..=f64::from(MAX_SIDE)).contains(&value) {
        #[expect(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "The value is a whole number from 1 to MAX_SIDE."
        )]
        Ok(value as u32)
    } else {
        Err(SvgError::Size { axis, value })
    }
}

/// The transform that scales the document to fit the canvas and centres it. usvg applies the
/// view box inside the tree, so the document's size is its extent in tree units.
fn fit(tree: &Tree, size: RasterSize) -> Transform {
    #[expect(
        clippy::cast_precision_loss,
        reason = "Canvas sides are at most MAX_SIDE, which f32 represents exactly."
    )]
    let (width, height) = (size.width as f32, size.height as f32);
    let document = tree.size();
    let scale = (width / document.width()).min(height / document.height());
    Transform::from_row(
        scale,
        0.0,
        0.0,
        scale,
        (width - document.width() * scale) / 2.0,
        (height - document.height() * scale) / 2.0,
    )
}

#[cfg(test)]
mod tests;
