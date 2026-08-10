//! Whether a string can be written as a Lua name.
//!
//! Two callers need the same answer for the same reason. `crate::control::serialise`
//! renders a path as `.title` where it can and as `['with space']` where it
//! cannot, and `lunctl` renders a table key the same two ways. Both promise that
//! what they print is what a reader would have written, so a name that is not a
//! name has to be spelled as a subscript in both.
//!
//! A reserved word is not a name. `{ end = 1 }` is a syntax error, so a renderer
//! that treated `end` as a name would print something that does not parse — which
//! is the promise `lunctl`'s output makes and the reason the list below is
//! checked against the interpreter rather than trusted.

/// Whether `name` can be written bare, as `name = ` rather than as `['name'] = `.
#[must_use]
pub fn is_identifier(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with(|first: char| first.is_ascii_digit())
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
        && !KEYWORDS.contains(&name)
}

/// The words LuaJIT reserves, which are Lua 5.1's.
///
/// `goto` is deliberately absent. LuaJIT 2.1 lexes it as a name outside
/// statement position, so `{ goto = 1 }` parses, and the test below holds the
/// list to what the interpreter this build links actually refuses.
const KEYWORDS: [&str; 21] = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];

#[cfg(test)]
mod tests {
    use mlua::Lua;

    use super::*;

    /// The oracle: the interpreter decides, and this list has to agree with it.
    ///
    /// A hand-written keyword list drifts from the language it describes. This
    /// asks LuaJIT to parse `{ name = 1 }` for every candidate and requires the
    /// same answer, so a reserved word added or removed by a LuaJIT bump is a
    /// failure here rather than output that does not parse.
    #[test]
    fn the_keyword_list_agrees_with_the_interpreter() {
        let lua = crate::test_lua::session_lua();
        let candidates = [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
            "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until",
            "while", "self", "continue", "title", "_x", "x1",
        ];

        for name in candidates {
            let parses = lua
                .load(format!("return {{ {name} = 1 }}"))
                .into_function()
                .is_ok();
            assert_eq!(
                is_identifier(name),
                parses,
                "'{name}' parses as a bare key: {parses}"
            );
        }
    }

    #[test]
    fn a_name_that_is_not_a_name_is_refused() {
        assert!(is_identifier("appId"));
        assert!(is_identifier("_"));
        assert!(!is_identifier(""));
        assert!(!is_identifier("with space"));
        assert!(!is_identifier("1st"));
        assert!(!is_identifier("café"));
    }
}
