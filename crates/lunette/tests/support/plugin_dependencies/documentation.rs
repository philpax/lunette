//! Validates maintained Markdown navigation, local links, and supported plugin imports.
//!
//! The scope comes from the catalog and filesystem, so source archives use the same checks as Git trees.

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt, fs, io,
    path::{Component, Path, PathBuf},
};

#[path = "documentation_headings.rs"]
mod headings;

use self::headings::{
    atx_heading, collect_explicit_anchors, heading_slug, implementation_heading, setext_level,
};
use crate::plugin_dependencies::catalog;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentationIssue {
    Read,
    MissingTarget,
    MissingAnchor,
    MalformedMarkdown,
    MissingNavigation,
    CategoryEntry,
    PrivateAdvertisement,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentationDiagnostic {
    pub source: PathBuf,
    pub line: usize,
    pub target: String,
    pub issue: DocumentationIssue,
    pub message: String,
}

impl fmt::Display for DocumentationDiagnostic {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "documentation: {}:{}: target {:?}: {}",
            self.source.display(),
            self.line,
            self.target,
            self.message
        )
    }
}

/// Includes required guides, filesystem plugin READMEs, and linked user workflows.
pub fn maintained_documentation(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut paths: BTreeSet<_> = catalog::DOCUMENTATION_FILES
        .iter()
        .map(PathBuf::from)
        .collect();
    paths.extend(category_guides());
    paths.extend(leaf_guides());
    collect_markdown(root, Path::new(PLUGIN_ROOT), true, &mut paths)?;
    for directory in catalog::DOCUMENTATION_DIRECTORIES {
        collect_markdown(root, Path::new(directory), false, &mut paths)?;
    }
    let mut visited = BTreeSet::new();
    while let Some(source) = paths.iter().find(|path| !visited.contains(*path)).cloned() {
        visited.insert(source.clone());
        let text = match fs::read_to_string(root.join(&source)) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        for link in parse_markdown(&text).links {
            if let Some((target, _)) = local_target(&source, &link.target)
                && target.starts_with("docs/users")
                && target
                    .extension()
                    .is_some_and(|extension| extension == "md")
            {
                paths.insert(target);
            }
        }
    }
    Ok(paths.into_iter().collect())
}

/// Requires category coverage, root/category navigation, and no category activation module.
pub fn check_navigation(root: &Path) -> Vec<DocumentationDiagnostic> {
    let mut errors = Vec::new();
    let root_guide = PathBuf::from(PLUGIN_GUIDE);
    let root_links = navigation_targets(root, &root_guide, &mut errors);
    for category in catalog::CATEGORIES {
        let guide = PathBuf::from(format!("{PLUGIN_ROOT}/{category}/README.md"));
        require_navigation(&root_guide, &guide, &root_links, &mut errors);
        let links = navigation_targets(root, &guide, &mut errors);
        require_navigation(&guide, &root_guide, &links, &mut errors);
        for plugin in catalog::PLUGINS
            .iter()
            .filter(|plugin| plugin.leaf.split('/').next() == Some(category))
        {
            let leaf = PathBuf::from(format!("{PLUGIN_ROOT}/{}/README.md", plugin.leaf));
            require_navigation(&guide, &leaf, &links, &mut errors);
            read_guide(root, &leaf, &mut errors);
        }
        for library in catalog::LIBRARIES
            .iter()
            .filter(|library| library.module.split('/').next() == Some(category))
        {
            let module = PathBuf::from(format!("{PLUGIN_ROOT}/{}.luau", library.module));
            require_navigation(&guide, &module, &links, &mut errors);
        }
        let entry = format!("{PLUGIN_ROOT}/{category}/init.luau");
        match fs::symlink_metadata(root.join(&entry)) {
            Ok(_) => errors.push(diagnostic(&guide, 1, &entry, DocumentationIssue::CategoryEntry, "a category has no activation entry; link its independent plugin leaves and exact public libraries")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {},
            Err(error) => errors.push(diagnostic(&guide, 1, &entry, DocumentationIssue::Read, &error.to_string())),
        }
    }
    errors
}

/// Checks local inline/reference links and Markdown heading or explicit HTML anchors.
pub fn check_links(root: &Path, sources: &[PathBuf]) -> Vec<DocumentationDiagnostic> {
    let mut errors = Vec::new();
    let mut anchors = BTreeMap::new();
    for source in sources {
        let Some(text) = read_guide(root, source, &mut errors) else {
            continue;
        };
        let markdown = parse_markdown(&text);
        append_parse_errors(source, &markdown, &mut errors);
        for link in markdown.links {
            if external_target(&link.target) {
                continue;
            }
            let Some((target, fragment)) = local_target(source, &link.target) else {
                errors.push(diagnostic(
                    source,
                    link.line,
                    &link.target,
                    DocumentationIssue::MissingTarget,
                    "local link escapes the repository or has invalid percent encoding",
                ));
                continue;
            };
            let absolute = root.join(&target);
            let canonical = match fs::canonicalize(&absolute) {
                Ok(path) => path,
                Err(error) => {
                    errors.push(diagnostic(
                        source,
                        link.line,
                        &link.target,
                        DocumentationIssue::MissingTarget,
                        &format!(
                            "local target {} does not resolve: {error}{}",
                            target.display(),
                            removed_path_hint(&target)
                        ),
                    ));
                    continue;
                }
            };
            match fs::canonicalize(root) {
                Ok(root) if !canonical.starts_with(&root) => {
                    errors.push(diagnostic(
                        source,
                        link.line,
                        &link.target,
                        DocumentationIssue::MissingTarget,
                        "local target resolves outside the repository",
                    ));
                    continue;
                }
                Err(error) => {
                    errors.push(diagnostic(
                        source,
                        link.line,
                        &link.target,
                        DocumentationIssue::Read,
                        &error.to_string(),
                    ));
                    continue;
                }
                _ => {}
            }
            if fragment.is_empty() {
                continue;
            }
            if target.extension().is_none_or(|extension| extension != "md") {
                if source_line_anchor(&fragment) {
                    continue;
                }
                errors.push(diagnostic(
                    source,
                    link.line,
                    &link.target,
                    DocumentationIssue::MissingAnchor,
                    "non-Markdown targets support only source line anchors such as #L10-L20",
                ));
                continue;
            }
            if !anchors.contains_key(&target) {
                match fs::read_to_string(&absolute) {
                    Ok(text) => {
                        anchors.insert(target.clone(), parse_markdown(&text).anchors);
                    }
                    Err(error) => {
                        errors.push(diagnostic(
                            source,
                            link.line,
                            &link.target,
                            DocumentationIssue::Read,
                            &format!("cannot read anchor target {}: {error}", target.display()),
                        ));
                        continue;
                    }
                }
            }
            if !anchors
                .get(&target)
                .is_some_and(|anchors| anchors.contains(&fragment))
            {
                errors.push(diagnostic(
                    source,
                    link.line,
                    &link.target,
                    DocumentationIssue::MissingAnchor,
                    &format!("anchor #{fragment} does not exist in {}", target.display()),
                ));
            }
        }
    }
    errors
}

/// Checks author-facing plugin links and literal alias examples against exact declared exports.
pub fn check_author_exports(root: &Path, sources: &[PathBuf]) -> Vec<DocumentationDiagnostic> {
    let mut errors = Vec::new();
    for source in sources.iter().filter(|source| author_guide(source)) {
        let Some(text) = read_guide(root, source, &mut errors) else {
            continue;
        };
        let markdown = parse_markdown(&text);
        append_parse_errors(source, &markdown, &mut errors);
        for link in markdown.links.iter().filter(|link| !link.implementation) {
            let Some((target, _)) = local_target(source, &link.target) else {
                continue;
            };
            let Some(module) = linked_plugin_module(&target) else {
                continue;
            };
            if !public_module(&module) && !public_guide(&target) && !provenance_link(&target) {
                errors.push(diagnostic(source, link.line, &link.target, DocumentationIssue::PrivateAdvertisement, &format!("{} is not an author-supported export; {}. Private code links belong under an implementation/reference heading", target.display(), public_boundary(&module))));
            }
        }
        for (line, literal) in markdown.imports {
            let module = literal.strip_prefix(PLUGIN_ALIAS).unwrap_or(&literal);
            if !public_module(module) {
                errors.push(diagnostic(source, line, &literal, DocumentationIssue::PrivateAdvertisement, &format!("literal plugin import is not an author-supported export; {}. Implementation/reference headings do not permit private import examples", public_boundary(module))));
            }
        }
    }
    errors
}

const PLUGIN_ROOT: &str = "lua/lunette-plugins";
const PLUGIN_GUIDE: &str = "lua/lunette-plugins/README.md";
const PLUGIN_ALIAS: &str = "@lunette-plugins/";

fn category_guides() -> impl Iterator<Item = PathBuf> {
    catalog::CATEGORIES
        .iter()
        .map(|category| PathBuf::from(format!("{PLUGIN_ROOT}/{category}/README.md")))
}

fn leaf_guides() -> impl Iterator<Item = PathBuf> {
    catalog::PLUGINS
        .iter()
        .map(|plugin| PathBuf::from(format!("{PLUGIN_ROOT}/{}/README.md", plugin.leaf)))
}

fn collect_markdown(
    root: &Path,
    directory: &Path,
    readmes_only: bool,
    paths: &mut BTreeSet<PathBuf>,
) -> io::Result<()> {
    let mut entries = fs::read_dir(root.join(directory))?.collect::<Result<Vec<_>, _>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = directory.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            collect_markdown(root, &path, readmes_only, paths)?;
        } else if path.extension().is_some_and(|extension| extension == "md")
            && (!readmes_only || path.file_name().is_some_and(|name| name == "README.md"))
        {
            paths.insert(path);
        }
    }
    Ok(())
}

fn read_guide(
    root: &Path,
    source: &Path,
    errors: &mut Vec<DocumentationDiagnostic>,
) -> Option<String> {
    match fs::read_to_string(root.join(source)) {
        Ok(text) => Some(text),
        Err(error) => {
            errors.push(diagnostic(
                source,
                1,
                &source.to_string_lossy(),
                DocumentationIssue::Read,
                &format!("required guide cannot be read: {error}"),
            ));
            None
        }
    }
}

fn diagnostic(
    source: &Path,
    line: usize,
    target: &str,
    issue: DocumentationIssue,
    message: &str,
) -> DocumentationDiagnostic {
    DocumentationDiagnostic {
        source: source.to_path_buf(),
        line,
        target: target.to_owned(),
        issue,
        message: message.to_owned(),
    }
}

fn navigation_targets(
    root: &Path,
    guide: &Path,
    errors: &mut Vec<DocumentationDiagnostic>,
) -> BTreeSet<PathBuf> {
    let Some(text) = read_guide(root, guide, errors) else {
        return BTreeSet::new();
    };
    let markdown = parse_markdown(&text);
    append_parse_errors(guide, &markdown, errors);
    markdown
        .links
        .iter()
        .filter_map(|link| local_target(guide, &link.target).map(|(path, _)| path))
        .collect()
}

fn require_navigation(
    source: &Path,
    target: &Path,
    links: &BTreeSet<PathBuf>,
    errors: &mut Vec<DocumentationDiagnostic>,
) {
    if !links.contains(target) {
        errors.push(diagnostic(
            source,
            1,
            &target.to_string_lossy(),
            DocumentationIssue::MissingNavigation,
            "required navigation link is absent; link the catalog guide or exact public library",
        ));
    }
}

fn external_target(target: &str) -> bool {
    target.starts_with("//")
        || target.split_once(':').is_some_and(|(scheme, _)| {
            !scheme.is_empty()
                && scheme.chars().enumerate().all(|(index, character)| {
                    if index == 0 {
                        character.is_ascii_alphabetic()
                    } else {
                        character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.')
                    }
                })
        })
}

fn local_target(source: &Path, target: &str) -> Option<(PathBuf, String)> {
    if external_target(target) {
        return None;
    }
    let (path, fragment) = target.split_once('#').unwrap_or((target, ""));
    let path = percent_decode(path.split_once('?').map_or(path, |(path, _)| path))?;
    let fragment = percent_decode(fragment)?;
    let path = if path.is_empty() {
        source.to_path_buf()
    } else {
        source.parent()?.join(path)
    };
    Some((normalize_relative(&path)?, fragment))
}

fn normalize_relative(path: &Path) -> Option<PathBuf> {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => result.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                if !result.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(result)
}

fn percent_decode(text: &str) -> Option<String> {
    let mut result = Vec::new();
    let bytes = text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let pair = text.get(index + 1..index + 3)?;
            result.push(u8::from_str_radix(pair, 16).ok()?);
            index += 3;
        } else {
            result.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(result).ok()
}

fn source_line_anchor(fragment: &str) -> bool {
    let (first, last) = fragment.split_once('-').unwrap_or((fragment, fragment));
    [first, last].iter().all(|part| {
        part.strip_prefix('L').is_some_and(|number| {
            !number.is_empty() && number.chars().all(|character| character.is_ascii_digit())
        })
    })
}

fn author_guide(path: &Path) -> bool {
    path.starts_with("docs/plugins")
        || path.starts_with(PLUGIN_ROOT) && path.file_name().is_some_and(|name| name == "README.md")
}

fn linked_plugin_module(path: &Path) -> Option<String> {
    let relative = path.strip_prefix(PLUGIN_ROOT).ok()?.to_str()?;
    let module = relative.strip_suffix(".luau").unwrap_or(relative);
    Some(module.strip_suffix("/init").unwrap_or(module).to_owned())
}

fn public_guide(path: &Path) -> bool {
    path == Path::new(PLUGIN_GUIDE)
        || category_guides()
            .chain(leaf_guides())
            .any(|guide| guide == path)
}

fn provenance_link(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            let name = name.to_ascii_uppercase();
            matches!(
                name.as_str(),
                "CREDITS.MD"
                    | "PROVENANCE.MD"
                    | "OFL.TXT"
                    | "COPYING"
                    | "COPYING.TXT"
                    | "LICENSE"
                    | "LICENSE.MD"
                    | "LICENSE.TXT"
                    | "LICENCE"
                    | "LICENCE.MD"
                    | "LICENCE.TXT"
            )
        })
}

fn public_module(module: &str) -> bool {
    catalog::PLUGINS.iter().any(|plugin| {
        module == plugin.leaf
            || plugin.config && module == format!("{}/config", plugin.leaf)
            || plugin
                .extensions
                .iter()
                .any(|extension| module == format!("{}/{extension}", plugin.leaf))
    }) || catalog::LIBRARIES
        .iter()
        .any(|library| module == library.module)
}

fn public_boundary(module: &str) -> String {
    if let Some(plugin) = catalog::PLUGINS
        .iter()
        .find(|plugin| module == plugin.leaf || module.starts_with(&format!("{}/", plugin.leaf)))
    {
        let mut exports = vec![format!("{PLUGIN_ALIAS}{}", plugin.leaf)];
        if plugin.config {
            exports.push(format!("{PLUGIN_ALIAS}{}/config", plugin.leaf));
        }
        exports.extend(
            plugin
                .extensions
                .iter()
                .map(|extension| format!("{PLUGIN_ALIAS}{}/{extension}", plugin.leaf)),
        );
        return format!("owner {} permits only {}", plugin.leaf, exports.join(", "));
    }
    let category = module.split('/').next().unwrap_or(module);
    let libraries: Vec<_> = catalog::LIBRARIES
        .iter()
        .filter(|library| library.module.split('/').next() == Some(category))
        .map(|library| format!("{PLUGIN_ALIAS}{}", library.module))
        .collect();
    if !libraries.is_empty() {
        return format!(
            "category {category} permits independent plugin entry/config/declared extension exports and only these libraries: {}",
            libraries.join(", ")
        );
    }
    format!(
        "no public module is declared at {module}; use an independent plugin entry, its declared config/extension, or an exact catalog library (categories have no import)"
    )
}

fn removed_path_hint(target: &Path) -> String {
    let Some(module) = linked_plugin_module(target) else {
        return String::new();
    };
    if let Some(plugin) = catalog::PLUGINS
        .iter()
        .filter(|plugin| plugin.previous != plugin.leaf)
        .find(|plugin| {
            module == plugin.previous || module.starts_with(&format!("{}/", plugin.previous))
        })
    {
        return format!(
            "; obsolete plugin path, use {PLUGIN_ALIAS}{} and its declared public exports",
            plugin.leaf
        );
    }
    if catalog::REMOVED_HELPERS.contains(&module.as_str()) {
        return "; obsolete helper path, use an exact catalog library or neutral contract schema"
            .to_owned();
    }
    String::new()
}

#[derive(Default)]
struct Markdown {
    links: Vec<MarkdownLink>,
    imports: Vec<(usize, String)>,
    anchors: BTreeSet<String>,
    errors: Vec<(usize, String, String)>,
}

struct MarkdownLink {
    line: usize,
    target: String,
    implementation: bool,
}

struct MarkdownLine {
    number: usize,
    text: String,
    implementation: bool,
}

fn append_parse_errors(
    source: &Path,
    markdown: &Markdown,
    errors: &mut Vec<DocumentationDiagnostic>,
) {
    errors.extend(markdown.errors.iter().map(|(line, target, message)| {
        diagnostic(
            source,
            *line,
            target,
            DocumentationIssue::MalformedMarkdown,
            message,
        )
    }));
}

// The bounded parser covers inline/reference links, ATX/setext headings, fences, comments, and explicit anchors.
fn parse_markdown(text: &str) -> Markdown {
    let mut markdown = Markdown::default();
    let mut lines = Vec::new();
    let mut comment = false;
    let mut fence: Option<(char, usize)> = None;
    let mut sections: Vec<(usize, bool)> = Vec::new();
    let mut heading_counts = BTreeMap::new();
    let mut previous = None;
    for (offset, raw) in text.lines().enumerate() {
        let number = offset + 1;
        let text = without_comments(raw, &mut comment);
        let trimmed = text.trim_start();
        if let Some((marker, length)) = fence {
            collect_imports(&text, number, &mut markdown.imports);
            if trimmed.starts_with(&marker.to_string().repeat(length))
                && trimmed.trim_matches(marker).trim().is_empty()
            {
                fence = None;
            }
            previous = None;
            continue;
        }
        if let Some(open) = fence_marker(trimmed) {
            fence = Some(open);
            previous = None;
            continue;
        }
        collect_imports(&text, number, &mut markdown.imports);
        let heading = atx_heading(&text)
            .map(|(level, title)| (level, title.to_owned()))
            .or_else(|| {
                setext_level(&text).and_then(|level| previous.take().map(|title| (level, title)))
            });
        if let Some((level, title)) = heading {
            while sections.last().is_some_and(|(parent, _)| *parent >= level) {
                sections.pop();
            }
            let inherited = sections
                .last()
                .is_some_and(|(_, implementation)| *implementation);
            let public_section = matches!(
                heading_slug(&title).as_str(),
                "supported-imports"
                    | "public-imports"
                    | "author-imports"
                    | "public-exports"
                    | "supported-exports"
            );
            sections.push((
                level,
                implementation_heading(&title) || inherited && !public_section,
            ));
            let slug = heading_slug(&title);
            let count = heading_counts.entry(slug.clone()).or_insert(0);
            let anchor = if *count == 0 {
                slug
            } else {
                format!("{slug}-{count}")
            };
            *count += 1;
            markdown.anchors.insert(anchor);
            previous = None;
        } else if !text.trim().is_empty() {
            previous = Some(text.trim().to_owned());
        } else {
            previous = None;
        }
        collect_explicit_anchors(&text, &mut markdown.anchors);
        lines.push(MarkdownLine {
            number,
            text: without_inline_code(&text),
            implementation: sections
                .last()
                .is_some_and(|(_, implementation)| *implementation),
        });
    }
    let mut references = BTreeMap::new();
    let mut definitions = BTreeSet::new();
    for line in &lines {
        if let Some((name, target)) = reference_definition(&line.text) {
            definitions.insert(line.number);
            references.entry(reference_name(name)).or_insert(target);
        }
    }
    for line in &lines {
        if !definitions.contains(&line.number) {
            collect_links(line, &references, &mut markdown);
        }
    }
    markdown
}

fn without_comments(text: &str, inside: &mut bool) -> String {
    let mut result = String::new();
    let mut rest = text;
    while !rest.is_empty() {
        if *inside {
            let Some(end) = rest.find("-->") else { break };
            *inside = false;
            rest = &rest[end + 3..];
        } else if let Some(start) = rest.find("<!--") {
            result.push_str(&rest[..start]);
            *inside = true;
            rest = &rest[start + 4..];
        } else {
            result.push_str(rest);
            break;
        }
    }
    result
}

fn fence_marker(text: &str) -> Option<(char, usize)> {
    let marker = text.chars().next()?;
    if !matches!(marker, '`' | '~') {
        return None;
    }
    let length = text
        .chars()
        .take_while(|character| *character == marker)
        .count();
    (length >= 3).then_some((marker, length))
}

fn collect_imports(text: &str, line: usize, imports: &mut Vec<(usize, String)>) {
    let mut rest = text;
    while let Some(start) = rest.find(PLUGIN_ALIAS) {
        rest = &rest[start..];
        let end = rest
            .char_indices()
            .find(|(_, character)| {
                !character.is_ascii_alphanumeric()
                    && !matches!(character, '@' | '/' | '-' | '_' | '.')
            })
            .map_or(rest.len(), |(index, _)| index);
        imports.push((line, rest[..end].to_owned()));
        rest = &rest[end..];
    }
}

fn without_inline_code(text: &str) -> String {
    let mut bytes = text.as_bytes().to_vec();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'`' {
            index += 1;
            continue;
        }
        let length = bytes[index..]
            .iter()
            .take_while(|byte| **byte == b'`')
            .count();
        let start = index;
        index += length;
        let mut close = None;
        while index < bytes.len() {
            if bytes[index] == b'`' {
                let run = bytes[index..]
                    .iter()
                    .take_while(|byte| **byte == b'`')
                    .count();
                if run == length {
                    close = Some(index + run);
                    break;
                }
                index += run;
            } else {
                index += 1;
            }
        }
        if let Some(end) = close {
            bytes[start..end].fill(b' ');
            index = end;
        }
    }
    String::from_utf8(bytes).unwrap_or_default()
}

fn reference_name(name: &str) -> String {
    name.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn reference_definition(text: &str) -> Option<(&str, String)> {
    let text = text.trim_start().strip_prefix('[')?;
    let end = text.find("]:")?;
    let name = &text[..end];
    let (target, _) = link_destination(&text[end + 2..], false)?;
    Some((name, target))
}

fn link_destination(text: &str, inline: bool) -> Option<(String, usize)> {
    let trimmed = text.trim_start();
    let leading = text.len() - trimmed.len();
    let mut index = 0;
    let mut destination = String::new();
    if trimmed.starts_with('<') {
        let end = trimmed.find('>')?;
        destination.push_str(&trimmed[1..end]);
        index = end + 1;
    } else {
        let mut depth = 0;
        let bytes = trimmed.as_bytes();
        while index < bytes.len() {
            match bytes[index] {
                b'\\' if index + 1 < bytes.len() => {
                    index += 1;
                    destination.push(bytes[index] as char);
                }
                b'(' => {
                    depth += 1;
                    destination.push('(');
                }
                b')' if depth == 0 => break,
                b')' => {
                    depth -= 1;
                    destination.push(')');
                }
                byte if byte.is_ascii_whitespace() && depth == 0 => break,
                _ => {
                    let character = trimmed[index..].chars().next()?;
                    destination.push(character);
                    index += character.len_utf8();
                    continue;
                }
            }
            index += 1;
        }
        if depth != 0 {
            return None;
        }
    }
    let rest = trimmed[index..].trim_start();
    index += trimmed[index..].len() - rest.len();
    if let Some(quote) = rest
        .chars()
        .next()
        .filter(|character| matches!(character, '\'' | '"' | '('))
    {
        let close = if quote == '(' { ')' } else { quote };
        let end = rest[1..].find(close)? + 2;
        index += end;
        let rest = &trimmed[index..];
        index += rest.len() - rest.trim_start().len();
    }
    if inline {
        if trimmed.as_bytes().get(index) != Some(&b')') {
            return None;
        }
        index += 1;
    } else if !trimmed[index..].trim().is_empty() {
        return None;
    }
    Some((destination, leading + index))
}

fn collect_links(
    line: &MarkdownLine,
    references: &BTreeMap<String, String>,
    markdown: &mut Markdown,
) {
    let text = &line.text;
    let bytes = text.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'[' || index > 0 && bytes[index - 1] == b'\\' {
            index += 1;
            continue;
        }
        let start = index + 1;
        let Some(end) = bracket_end(text, start) else {
            break;
        };
        let label = &text[start..end];
        index = end + 1;
        let target = if bytes.get(index) == Some(&b'(') {
            match link_destination(&text[index + 1..], true) {
                Some((target, consumed)) => {
                    index += consumed + 1;
                    Some(target)
                }
                None => {
                    markdown.errors.push((
                        line.number,
                        label.to_owned(),
                        "malformed or unsupported inline Markdown link".to_owned(),
                    ));
                    None
                }
            }
        } else if bytes.get(index) == Some(&b'[') {
            let Some(end) = bracket_end(text, index + 1) else {
                break;
            };
            let name = &text[index + 1..end];
            let name = if name.is_empty() { label } else { name };
            index = end + 1;
            let target = references.get(&reference_name(name)).cloned();
            if target.is_none() {
                markdown.errors.push((
                    line.number,
                    name.to_owned(),
                    "reference link has no destination definition".to_owned(),
                ));
            }
            target
        } else {
            references.get(&reference_name(label)).cloned()
        };
        if let Some(target) = target {
            markdown.links.push(MarkdownLink {
                line: line.number,
                target,
                implementation: line.implementation,
            });
        }
    }
}

fn bracket_end(text: &str, start: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut depth = 0;
    let mut escaped = false;
    for (index, byte) in bytes.iter().enumerate().skip(start) {
        if escaped {
            escaped = false;
            continue;
        }
        match byte {
            b'\\' => escaped = true,
            b'[' => depth += 1,
            b']' if depth == 0 => return Some(index),
            b']' => depth -= 1,
            _ => {}
        }
    }
    None
}
