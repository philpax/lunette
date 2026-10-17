//! Exercises the glyph atlas through the production native module.

use std::{
    cell::RefCell,
    rc::Rc,
    thread,
    time::{Duration, Instant},
};

use lunette_ui::test_fonts;

use super::*;
use crate::lua::layout::LayoutFonts;

/// A Lua state whose fonts are one bundled face, so glyph ids and outlines match on every machine.
fn glyph_lua() -> Lua {
    let session = session(Vec::new());
    let lua = lua(&session);
    lua.set_app_data(LayoutFonts(Rc::new(RefCell::new(test_fonts::mono()))));
    lua
}

/// Runs `script`, which defines a global `poll` answering true once its condition holds, then calls
/// `poll` until it does, as frames would, and runs `after`.
fn run_until(lua: &Lua, script: &str, after: &str) {
    lua.load(script).exec().expect("the script runs");
    let poll: mlua::Function = lua.globals().get("poll").expect("the script defines poll");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !poll.call::<bool>(()).expect("poll runs") {
        assert!(
            Instant::now() < deadline,
            "the condition did not hold in time"
        );
        thread::sleep(Duration::from_millis(1));
    }
    lua.load(after).exec().expect("the script runs");
}

#[test]
fn shaped_glyphs_are_placed_in_the_atlas_and_their_page_uploads() {
    let lua = glyph_lua();
    run_until(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'text', text = 'H H', textStyle = { family = 'Iosevka', size = 0.01 } },
        }
        tree:compute(1)
        glyphs = assert(tree:textLayout(1))[1].glyphs
        atlas = lunette.glyphAtlas()
        assert(atlas == lunette.glyphAtlas(), 'the atlas is shared')
        assert(atlas.pages == 0, 'nothing is generated before it is asked for')
        local first, failure, pending = atlas:glyph(glyphs[1].face, glyphs[1].id)
        assert(first == nil and failure == nil and pending, 'a new glyph starts generating')
        assert(atlas.pending == 1, 'one glyph is pending')
        local _, _, again = atlas:glyph(glyphs[3].face, glyphs[3].id)
        assert(again and atlas.pending == 1, 'the same glyph is not generated twice')
        local space, _, spacePending = atlas:glyph(glyphs[2].face, glyphs[2].id)
        assert(space == nil and not spacePending, 'a space draws nothing and needs no field')
        function poll()
          atlas:update()
          letter, failure = atlas:glyph(glyphs[1].face, glyphs[1].id)
          assert(failure == nil, failure)
          return letter ~= nil
        end
        ",
        r"
        assert(atlas.pending == 0, 'nothing is pending once the glyph is placed')
        assert(letter.page == 1, 'the first glyph opens the first page')
        assert(letter.u1 > letter.u0 and letter.v1 > letter.v0, 'the texture rectangle has an area')
        assert(letter.top > 0.5 and letter.width > 0 and letter.height > 0.5, 'a capital stands above the baseline')
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
    );
}

#[test]
fn many_glyphs_generate_in_the_background_and_all_arrive() {
    let lua = glyph_lua();
    run_until(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        local text = 'The quick brown fox jumps over the lazy dog 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        tree:apply {
          { op = 'create', id = 1, kind = 'text', text = text, textStyle = { family = 'Iosevka', size = 0.01 } },
        }
        tree:compute(1)
        atlas = lunette.glyphAtlas()
        glyphs = {}
        for _, line in assert(tree:textLayout(1)) do
          for _, glyph in line.glyphs do
            table.insert(glyphs, glyph)
          end
        end
        local started = os.clock()
        for _, glyph in glyphs do
          atlas:glyph(glyph.face, glyph.id)
        end
        assert(os.clock() - started < 0.05, 'asking for every glyph does not wait for their fields')
        function poll()
          atlas:update()
          local waiting = false
          for _, glyph in glyphs do
            local _, failure, pending = atlas:glyph(glyph.face, glyph.id)
            assert(failure == nil, failure)
            waiting = waiting or pending
          end
          return not waiting
        end
        ",
        r"
        assert(atlas.pending == 0, 'every field arrived')
        local placed = 0
        for _, glyph in glyphs do
          if atlas:glyph(glyph.face, glyph.id) then
            placed += 1
          end
        end
        assert(placed > 40, 'the letters and digits are placed: ' .. placed)
        ",
    );
}

#[test]
fn an_unknown_face_draws_nothing() {
    let lua = glyph_lua();
    lua.load(
        r"
        local placement, failure, pending = lunette.glyphAtlas():glyph(99, 3)
        assert(placement == nil and failure == nil and not pending, 'a face that does not exist has no outline')
        local ok = pcall(function() return lunette.glyphAtlas():glyph(0, 70000) end)
        assert(not ok, 'a glyph id past 65535 is refused')
        ",
    )
    .exec()
    .expect("the script runs");
}
