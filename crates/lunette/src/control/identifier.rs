//! Whether a string can be written as a Lua name.
//!
//! Two callers need the same answer for the same reason.
//! `crate::control::serialise` renders a path as `.title` where it can and as
//! `['with space']` where it cannot.
//! `lunctl` renders a table key the same two ways.
//! Both print what a reader would write, so a string that is not a name is
//! spelled as a subscript in both.
//!
//! A reserved word is not a name. `{ end = 1 }` is a syntax error, so a
//! renderer that treats `end` as a name prints output that does not parse.
//! The keyword list is checked against the interpreter because the output
//! must parse.

/// Whether `name` can be written bare as `name = ` or must be written as `['name'] = `.
#[must_use]
pub fn is_identifier(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with(|first: char| first.is_ascii_digit())
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_')
        && !KEYWORDS.contains(&name)
}

/// Luau reserves the Lua 5.1 words.
///
/// `goto` is not a Luau keyword, and `continue` is one only in statement
/// position, so `{ goto = 1 }` and `{ continue = 1 }` parse. A test in this
/// module checks the list against the linked interpreter.
const KEYWORDS: [&str; 21] = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];

#[cfg(test)]
mod tests {
    use super::*;

    /// The interpreter is the reference. The list must agree with it.
    ///
    /// A hand-written keyword list drifts from the language it describes. This
    /// test loads `{ name = 1 }` for every candidate and requires the same
    /// answer, so a reserved word added or removed by a Luau bump changes the
    /// outcome from unparseable output to a test failure.
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
