//! Stateless text segmentation for the native Lua API.

use mlua::LuaString;
use unicode_segmentation::UnicodeSegmentation;

/// Returns one-based byte offsets of extended grapheme clusters and the terminal offset.
///
/// Empty text has only the terminal offset, `1`. The result is fresh on each call.
///
/// # Errors
///
/// Returns an error if the Lua string is not valid UTF-8.
pub fn text_boundaries(text: LuaString) -> mlua::Result<Vec<usize>> {
    let text = text.to_str().map_err(|error| {
        mlua::Error::runtime(format!(
            "lunette: textBoundaries: text is not valid UTF-8: {error}"
        ))
    })?;

    Ok(text
        .grapheme_indices(true)
        .map(|(offset, _)| offset + 1)
        .chain(std::iter::once(text.len() + 1))
        .collect())
}
