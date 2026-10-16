//! Layout and text mechanism for lunette's UI toolkit.
//!
//! The crate holds no plugin state and knows nothing about Lua. [`layout`] lays out a tree of
//! nodes that the host identifies by integer ids, over taffy's low-level API, and calls back
//! through [`layout::Scripts`] for layouts and measurements that the host implements. [`text`]
//! shapes, wraps, and measures text with cosmic-text. Layout and text use metres throughout.
//! [`glyphs`] packs distance field glyphs into a paged atlas. [`svg`] rasterises SVG documents
//! with resvg, in pixels.

pub mod glyphs;
pub mod layout;
pub mod svg;
pub mod text;
