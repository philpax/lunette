//! Exercises SVG rasterisation through the production native module.

use super::*;

fn svg_lua() -> Lua {
    lua(&session(Vec::new()))
}

#[test]
fn a_document_rasterises_to_straight_alpha_rgba_through_lua() {
    let lua = svg_lua();
    lua.load(
        r##"
        local wide = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2 1">'
          .. '<rect width="2" height="1" fill="#ff8000" fill-opacity="0.5"/></svg>'
        local pixels, width, height = lunette.rasterizeSvg(wide, 4, 4)
        assert(width == 4 and height == 4, 'the canvas has the requested size')
        assert(#pixels == 4 * 4 * 4, 'the rows are tightly packed RGBA8')
        local function at(x, y)
          return string.byte(pixels, (y * width + x) * 4 + 1, (y * width + x) * 4 + 4)
        end
        local r, g, b, a = at(0, 0)
        assert(r == 0 and g == 0 and b == 0 and a == 0, 'the band above the fitted document is clear')
        r, g, b, a = at(1, 2)
        assert(r == 255 and g == 128 and b == 0, 'the colour is straight, not premultiplied')
        assert(a == 127 or a == 128, 'the alpha is half')
        r, g, b, a = at(3, 3)
        assert(a == 0, 'the band below the fitted document is clear')
        "##,
    )
    .exec()
    .expect("the script runs");
}

#[test]
fn invalid_documents_and_sizes_are_refused() {
    let lua = svg_lua();
    let square = r#"'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>'"#;
    for (source, expected) in [
        (
            "lunette.rasterizeSvg('<svg', 4, 4)".to_owned(),
            "svg: the document is not well-formed XML",
        ),
        (
            "lunette.rasterizeSvg('', 4, 4)".to_owned(),
            "svg: the document is not well-formed XML",
        ),
        (
            format!("lunette.rasterizeSvg({square}, 0, 4)"),
            "svg: the width 0 is not a whole number of pixels from 1 to 4096",
        ),
        (
            format!("lunette.rasterizeSvg({square}, 4, 4097)"),
            "svg: the height 4097 is not a whole number of pixels from 1 to 4096",
        ),
        (
            format!("lunette.rasterizeSvg({square}, 2.5, 4)"),
            "svg: the width 2.5 is not a whole number of pixels from 1 to 4096",
        ),
        (
            format!("lunette.rasterizeSvg({square}, 4, 0 / 0)"),
            "svg: the height NaN is not a whole number of pixels",
        ),
    ] {
        let error = lua
            .load(&source)
            .exec()
            .expect_err("the call is refused")
            .to_string();
        assert!(error.contains(expected), "{source}: {error}");
    }
}
