//! Recognises Markdown headings, section boundaries, and local anchors.

use std::collections::BTreeSet;

pub(super) fn atx_heading(text: &str) -> Option<(usize, &str)> {
    let text = text.trim_start();
    let level = text
        .chars()
        .take_while(|character| *character == '#')
        .count();
    if !(1..=6).contains(&level) || !text.get(level..)?.starts_with(char::is_whitespace) {
        return None;
    }
    let title = text[level..].trim();
    let without_hashes = title.trim_end_matches('#');
    let title = if without_hashes.ends_with(char::is_whitespace) {
        without_hashes.trim_end()
    } else {
        title
    };
    Some((level, title))
}

pub(super) fn setext_level(text: &str) -> Option<usize> {
    let text = text.trim();
    if !text.is_empty() && text.chars().all(|character| character == '=') {
        Some(1)
    } else if text.len() >= 3 && text.chars().all(|character| character == '-') {
        Some(2)
    } else {
        None
    }
}

pub(super) fn implementation_heading(title: &str) -> bool {
    matches!(
        heading_slug(title).as_str(),
        "implementation"
            | "implementation-reference"
            | "implementation-references"
            | "implementation-details"
            | "implementation-notes"
            | "reference"
            | "references"
            | "source-reference"
            | "source-references"
            | "internal-implementation"
    )
}

pub(super) fn heading_slug(title: &str) -> String {
    let mut result = String::new();
    let mut tag = false;
    for character in title.to_lowercase().chars() {
        match character {
            '<' => tag = true,
            '>' if tag => tag = false,
            _ if tag => {}
            character if character.is_alphanumeric() || matches!(character, '-' | '_') => {
                result.push(character)
            }
            character if character.is_whitespace() => result.push('-'),
            _ => {}
        }
    }
    result
}

pub(super) fn collect_explicit_anchors(text: &str, anchors: &mut BTreeSet<String>) {
    for attribute in ["id=\"", "name=\"", "id='", "name='"] {
        let quote = attribute.as_bytes()[attribute.len() - 1] as char;
        let mut rest = text;
        while let Some(start) = rest.find(attribute) {
            rest = &rest[start + attribute.len()..];
            let Some(end) = rest.find(quote) else { break };
            anchors.insert(rest[..end].to_owned());
            rest = &rest[end + 1..];
        }
    }
}
