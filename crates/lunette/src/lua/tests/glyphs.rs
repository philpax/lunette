//! Exercises the glyph atlas through the production native module.

use std::{cell::RefCell, rc::Rc};

use lunette_ui::text::Fonts;

use super::*;
use crate::lua::layout::LayoutFonts;

/// A Lua state whose fonts are one bundled face, so glyph ids and outlines match on every machine.
fn glyph_lua() -> Lua {
    let session = session(Vec::new());
    let lua = lua(&session);
    lua.set_app_data(LayoutFonts(Rc::new(RefCell::new(Fonts::bundled([
        include_bytes!(
            "../../../../../lua/lunette-plugins/theme/arcade/fonts/SpaceMono-Regular.ttf"
        )
        .to_vec(),
    ])))));
    lua
}

#[test]
fn shaped_glyphs_are_placed_in_the_atlas_and_their_page_uploads() {
    let lua = glyph_lua();
    lua.load(
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'text', text = 'H H', textStyle = { family = 'Space Mono', size = 0.01 } },
        }
        tree:compute(1)
        local glyphs = assert(tree:textLayout(1))[1].glyphs
        local atlas = lunette.glyphAtlas()
        assert(atlas == lunette.glyphAtlas(), 'the atlas is shared')
        assert(atlas.pages == 0, 'nothing is generated before it is asked for')
        local letter, failure = atlas:glyph(glyphs[1].face, glyphs[1].id)
        assert(letter and failure == nil, failure)
        assert(letter.page == 1, 'the first glyph opens the first page')
        assert(letter.u1 > letter.u0 and letter.v1 > letter.v0, 'the texture rectangle has an area')
        assert(letter.top > 0.5 and letter.width > 0 and letter.height > 0.5, 'a capital stands above the baseline')
        local space = atlas:glyph(glyphs[2].face, glyphs[2].id)
        assert(space == nil, 'a space draws nothing')
        local again = atlas:glyph(glyphs[3].face, glyphs[3].id)
        assert(again.u0 == letter.u0 and again.v0 == letter.v0, 'a glyph keeps its place')
        assert(atlas:revision(1) == 1, 'the page was written once')
        local pixels = assert(atlas:pixels(1))
        assert(#pixels == atlas.pageSize * atlas.pageSize * 4, 'the page is RGBA8')
        assert(atlas:pixels(2) == nil and atlas:revision(2) == nil, 'a missing page answers nil')
        local inside = false
        local size = atlas.pageSize
        local x0, y0 = math.floor(letter.u0 * size), math.floor(letter.v0 * size)
        local x1, y1 = math.floor(letter.u1 * size) - 1, math.floor(letter.v1 * size) - 1
        for y = y0, y1 do
          for x = x0, x1 do
            local r, g, b = string.byte(pixels, (y * size + x) * 4 + 1, (y * size + x) * 4 + 3)
            local median = math.max(math.min(r, g), math.min(math.max(r, g), b))
            if median > 160 then
              inside = true
            end
          end
        end
        assert(inside, 'the field holds the inside of the letter')
        ",
    )
    .exec()
    .expect("the script runs");
}

#[test]
fn an_unknown_face_draws_nothing() {
    let lua = glyph_lua();
    lua.load(
        r"
        local placement, failure = lunette.glyphAtlas():glyph(99, 3)
        assert(placement == nil and failure == nil, 'a face that does not exist has no outline')
        local ok = pcall(function() return lunette.glyphAtlas():glyph(0, 70000) end)
        assert(not ok, 'a glyph id past 65535 is refused')
        ",
    )
    .exec()
    .expect("the script runs");
}
