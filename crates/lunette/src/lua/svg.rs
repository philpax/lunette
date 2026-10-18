//! `lunette.rasterizeSvg`: SVG rasterisation for the UI toolkit, from `lunette-ui`.
//!
//! The pixels cross the boundary as one Lua string, which `lovr.data.newBlob` wraps for
//! `lovr.data.newImage` without a per-pixel loop in Lua.

use lunette_ui::svg::{RasterSize, SvgError, rasterize};
use mlua::{Lua, LuaString};

/// Rasterises an SVG document into a canvas of `width` by `height` pixels, answering the
/// straight-alpha RGBA8 pixels and the canvas size.
pub fn rasterize_svg(
    lua: &Lua,
    document: &LuaString,
    width: f64,
    height: f64,
) -> mlua::Result<(LuaString, u32, u32)> {
    let size = RasterSize::new(width, height).map_err(runtime)?;
    let raster = rasterize(&document.as_bytes(), size).map_err(runtime)?;
    Ok((
        lua.create_string(&raster.pixels)?,
        raster.width,
        raster.height,
    ))
}

fn runtime(error: SvgError) -> mlua::Error {
    mlua::Error::runtime(error.to_string())
}
