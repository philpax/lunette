//! Exercises the layout tree through the production native module.

use std::{cell::RefCell, rc::Rc};

use lunette_ui::test_fonts;

use super::*;
use crate::lua::layout::LayoutFonts;

/// A Lua state whose trees shape with one bundled face, so measurements match on every machine.
fn layout_lua() -> Lua {
    let session = session(Vec::new());
    let lua = lua(&session);
    lua.set_app_data(LayoutFonts(Rc::new(RefCell::new(test_fonts::mono()))));
    lua
}

fn run(lua: &Lua, source: &str) {
    lua.load(source).exec().expect("the script runs");
}

#[test]
fn a_row_is_laid_out_in_metres_through_lua() {
    let lua = layout_lua();
    run(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'box', style = { flexDirection = 'row', gap = 0.004, padding = 0.01 } },
          { op = 'create', id = 2, kind = 'leaf', leaf = { kind = 'fixed', width = 0.0125, height = 0.01 } },
          { op = 'create', id = 3, kind = 'leaf', leaf = { kind = 'fixed', width = 0.02, height = 0.015 } },
          { op = 'children', id = 1, children = { 2, 3 } },
        }
        local flat, failures = tree:compute(1)
        assert(#failures == 0)
        local placed = {}
        for index = 1, #flat, 7 do
          placed[flat[index]] = { u = flat[index + 1], v = flat[index + 2], width = flat[index + 3], height = flat[index + 4] }
        end
        local function near(a, b) return math.abs(a - b) < 1e-6 end
        assert(near(placed[2].u, 0.01) and near(placed[2].v, 0.01), 'padding offsets the first child')
        assert(near(placed[3].u, 0.01 + 0.0125 + 0.004), 'the gap separates the children')
        assert(near(placed[1].width, 0.01 * 2 + 0.0125 + 0.004 + 0.02), 'the row sizes to its content')
        assert(tree.size == 3)
        local again = tree:compute(1)
        assert(#again == 0, 'nothing changed, so nothing is reported')
        ",
    );
}

#[test]
fn a_scripted_layout_measures_and_places_its_children() {
    let lua = layout_lua();
    run(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'box', style = { flexDirection = 'row' } },
          { op = 'create', id = 2, kind = 'scripted' },
          { op = 'create', id = 3, kind = 'leaf', leaf = { kind = 'fixed', width = 0.01, height = 0.02 } },
          { op = 'create', id = 4, kind = 'text', text = 'ring', textStyle = { family = 'Iosevka' } },
          { op = 'children', id = 2, children = { 3, 4 } },
          { op = 'children', id = 1, children = { 2 } },
        }
        local passes = { sizing = 0, final = 0 }
        local flat, failures = tree:compute(1, nil, nil, {
          layout = function(id, input, context)
            assert(id == 2)
            if input.perform then passes.final += 1 else passes.sizing += 1 end
            local u = 0
            local tallest = 0
            for _, child in context.children() do
              local width, height = context.measure(child, 'max-content', 'max-content')
              if input.perform then
                context.place(child, u, 0, { rotation = 0.5 })
              end
              u += width
              tallest = math.max(tallest, height)
            end
            return u, tallest
          end,
        })
        assert(#failures == 0, failures[1] and failures[1].message)
        assert(passes.sizing > 0 and passes.final > 0)
        local placed = {}
        for index = 1, #flat, 7 do
          placed[flat[index]] = { u = flat[index + 1], width = flat[index + 3], rotation = flat[index + 5] }
        end
        assert(placed[1].width == placed[2].width, 'the row sees the scripted size')
        assert(placed[2].width > 0.01, 'sized from the leaf and the text')
        assert(math.abs(placed[4].u - 0.01) < 1e-6, 'the text is placed after the leaf')
        assert(math.abs(placed[3].rotation - 0.5) < 1e-6, 'the layout transform is reported')
        ",
    );
}

#[test]
fn failing_callbacks_are_reported_with_their_messages() {
    let lua = layout_lua();
    run(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'box', style = { flexDirection = 'row' } },
          { op = 'create', id = 2, kind = 'measured' },
          { op = 'create', id = 3, kind = 'scripted' },
          { op = 'create', id = 4, kind = 'leaf', leaf = { kind = 'fixed', width = 0.01, height = 0.01 } },
          { op = 'children', id = 1, children = { 2, 3, 4 } },
        }
        local _, failures = tree:compute(1, nil, nil, {
          measure = function() error('the knob is broken') end,
          layout = function()
            tree:apply { { op = 'remove', id = 4 } }
            return 0, 0
          end,
        })
        local messages = {}
        for _, failure in failures do messages[failure.id] = failure.message end
        assert(string.find(messages[2], 'the knob is broken', 1, true), messages[2])
        assert(string.find(messages[3], 'computing', 1, true), messages[3])
        assert(tree.size == 4, 'the re-entrant apply changed nothing')
        ",
    );
}

#[test]
fn invalid_changes_are_named() {
    let lua = layout_lua();
    for (source, expected) in [
        (
            "tree:apply { { op = 'create', id = 1, kind = 'box', style = { flexDirecton = 'row' } } }",
            "'flexDirecton' is not an option",
        ),
        (
            "tree:apply { { op = 'create', id = 1, kind = 'box', style = { display = 'inline' } } }",
            "display: 'inline' is not one of",
        ),
        (
            "tree:apply { { op = 'create', id = 1, kind = 'blob' } }",
            "'blob' is not a kind",
        ),
        (
            "tree:apply { { op = 'children', id = 9, children = {} } }",
            "node 9 does not exist",
        ),
        (
            "tree:apply { { op = 'create', id = 1, kind = 'box', style = { width = '12px' } } }",
            "'12px' is not a length",
        ),
        ("tree:compute(1)", "node 1 does not exist"),
        ("tree:compute(1, -1)", "the width -1 is not a finite length"),
    ] {
        let error = lua
            .load(format!("local tree = lunette.newLayoutTree() {source}"))
            .exec()
            .expect_err("the change is refused")
            .to_string();
        assert!(error.contains(expected), "{source}: {error}");
    }
}

#[test]
fn text_layout_reports_shaped_lines() {
    let lua = layout_lua();
    run(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'box', style = { width = 0.05 } },
          { op = 'create', id = 2, kind = 'text', text = 'alpha beta gamma', textStyle = { family = 'Iosevka', size = 0.01 } },
          { op = 'children', id = 1, children = { 2 } },
        }
        tree:compute(1)
        local lines = tree:textLayout(2)
        assert(lines and #lines > 1, 'wraps inside 5 cm')
        local first = lines[1].glyphs[1]
        assert(first.byteStart == 1 and first.byteEnd == 1)
        assert(math.abs(first.size - 0.01) < 1e-6)
        assert(tree:textLayout(1) == nil, 'a box is not text')
        ",
    );
}

#[test]
fn a_context_is_valid_only_during_its_call() {
    let lua = layout_lua();
    let error = lua
        .load(
            r"
            local tree = lunette.newLayoutTree()
            tree:apply {
              { op = 'create', id = 1, kind = 'scripted' },
            }
            local kept
            tree:compute(1, nil, nil, { layout = function(_, _, context) kept = context return 0, 0 end })
            kept.children()
            ",
        )
        .exec()
        .expect_err("a context used after its call is refused")
        .to_string();
    assert!(
        error.to_lowercase().contains("destructed") || error.contains("scope"),
        "{error}"
    );
}

#[test]
fn edges_left_out_of_a_table_are_zero() {
    let lua = layout_lua();
    run(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'box', style = { padding = { left = 0.01 }, margin = { top = 0.002 } } },
          { op = 'create', id = 2, kind = 'leaf', leaf = { kind = 'fixed', width = 0.01, height = 0.01 } },
          { op = 'children', id = 1, children = { 2 } },
        }
        local flat = tree:compute(1)
        local placed = {}
        for index = 1, #flat, 7 do
          placed[flat[index]] = { u = flat[index + 1], v = flat[index + 2], height = flat[index + 4] }
        end
        assert(math.abs(placed[2].u - 0.01) < 1e-6, 'the left edge applies')
        assert(math.abs(placed[1].height - 0.01) < 1e-6, 'the top and bottom padding are zero')
        ",
    );
}

#[test]
fn an_absolute_child_is_placed_against_its_nearest_positioned_ancestor() {
    let lua = layout_lua();
    run(
        &lua,
        r"
        local tree = lunette.newLayoutTree()
        tree:apply {
          { op = 'create', id = 1, kind = 'box', style = { flexDirection = 'column', padding = 0.01, width = 0.2, height = 0.2 } },
          { op = 'create', id = 2, kind = 'box', style = { flexDirection = 'column' } },
          { op = 'create', id = 3, kind = 'leaf', leaf = { kind = 'fixed', width = 0.05, height = 0.03 } },
          { op = 'create', id = 4, kind = 'box', style = { position = 'absolute', top = '100%', left = 0, right = 0, height = 0.02 } },
          { op = 'children', id = 2, children = { 3, 4 } },
          { op = 'children', id = 1, children = { 2 } },
        }
        -- Computing reports only the placements that changed, so they accumulate here.
        local placed = {}
        local function placements()
          local flat = tree:compute(1)
          for index = 1, #flat, 7 do
            placed[flat[index]] = { v = flat[index + 2], width = flat[index + 3] }
          end
          return placed
        end
        placements()
        assert(math.abs(placed[4].v - 0.21) < 1e-6, 'a static parent passes the menu to the root: ' .. placed[4].v)
        tree:apply { { op = 'style', id = 2, style = { flexDirection = 'column', position = 'relative' } } }
        placements()
        assert(math.abs(placed[4].v - (0.01 + 0.03)) < 1e-6, 'the menu sits below its positioned parent: ' .. placed[4].v)
        assert(math.abs(placed[4].width - 0.18) < 1e-6, 'the menu spans its positioned parent')
        ",
    );
}
