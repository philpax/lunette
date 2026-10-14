//! Resolves relative module paths from the requiring chunk name.
//!
//! A module path omits its suffix, and `init.luau` names its directory. `./` and
//! `../` start from the parent directory; `@self` starts from the module path.
//! Resolution cannot leave the configuration or module root because the session
//! filesystem does not expose paths outside that root.

use std::fmt;

/// Where the requiring chunk came from, read from its chunk name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Requirer<'a> {
    /// A chunk loaded from a file, named by its path in the virtual
    /// filesystem, such as `nested/a.luau` or `@lunette-contracts/scale.luau`.
    File(&'a str),
    /// A chunk with no file, such as one `lunctl eval` sends. It resolves at
    /// the configuration root.
    Unnamed,
}

impl<'a> Requirer<'a> {
    /// Reads a chunk name. Lua marks a chunk named after a file with a
    /// leading `@`; any other chunk name has no file.
    #[must_use]
    pub fn from_chunk_name(chunk_name: &'a str) -> Self {
        match chunk_name.strip_prefix('@') {
            Some(path) if !path.is_empty() => Self::File(path),
            _ => Self::Unnamed,
        }
    }
}

/// Resolves `path` as `requirer` requires it, or `None` for a non-relative
/// path such as an alias, which the session's loader resolves as it stands.
pub fn resolve(requirer: Requirer<'_>, path: &str) -> Result<Option<String>, ResolveError> {
    let (start, rest) = if let Some(rest) = path.strip_prefix("@self") {
        if !(rest.is_empty() || rest.starts_with('/')) {
            return Ok(None);
        }
        (Start::Module, rest)
    } else if path.starts_with("./") || path.starts_with("../") {
        (Start::Parent, path)
    } else {
        return Ok(None);
    };

    let error = |kind| ResolveError {
        kind,
        path: path.to_owned(),
        requirer: match requirer {
            Requirer::File(file) => Some(normalised(file)),
            Requirer::Unnamed => None,
        },
    };

    let mut components = match (requirer, start) {
        (Requirer::File(file), Start::Module) => module_components(file),
        (Requirer::File(file), Start::Parent) => {
            let mut module = module_components(file);
            // The parent of a root's own module, its `init` file, is outside
            // the root.
            match module.pop() {
                Some(last) if !(module.is_empty() && last.starts_with('@')) => module,
                _ => return Err(error(ResolveErrorKind::Escapes)),
            }
        }
        (Requirer::Unnamed, Start::Parent) => Vec::new(),
        (Requirer::Unnamed, Start::Module) => return Err(error(ResolveErrorKind::NoSelf)),
    };

    for component in rest.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                // A module root's alias is its first component, and the
                // configuration root has none; neither can be left.
                match components.last() {
                    Some(last) if !(components.len() == 1 && last.starts_with('@')) => {
                        components.pop();
                    }
                    _ => return Err(error(ResolveErrorKind::Escapes)),
                }
            }
            name if name.contains('.') => {
                return Err(error(ResolveErrorKind::Dotted(name.to_owned())));
            }
            name => components.push(name),
        }
    }

    match components.as_slice() {
        [] => Err(error(ResolveErrorKind::NamesRoot)),
        [only] if only.starts_with('@') => Err(error(ResolveErrorKind::NamesRoot)),
        _ => Ok(Some(components.join("/"))),
    }
}

/// Why a relative require could not be resolved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolveError {
    pub kind: ResolveErrorKind,
    pub path: String,
    pub requirer: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ResolveErrorKind {
    /// The path leaves the configuration root or the module root it starts
    /// in.
    Escapes,
    /// The path names the root itself, which is not a module.
    NamesRoot,
    /// A component holds a `.`, which the session's loader reads as a
    /// directory separator.
    Dotted(String),
    /// `@self` in a chunk that has no file, and so no module of its own.
    NoSelf,
}

impl fmt::Display for ResolveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let from = match &self.requirer {
            Some(file) => format!("from {file}"),
            None => "from a chunk with no file".to_owned(),
        };
        write!(formatter, "require: '{}' {from} ", self.path)?;
        match &self.kind {
            ResolveErrorKind::Escapes => formatter.write_str("leaves the root it starts in"),
            ResolveErrorKind::NamesRoot => formatter.write_str("names a root, not a module"),
            ResolveErrorKind::Dotted(component) => write!(
                formatter,
                "has the component '{component}', and a module name cannot hold a '.'"
            ),
            ResolveErrorKind::NoSelf => {
                formatter.write_str("cannot use @self, because only a module in a file has one")
            }
        }
    }
}

impl std::error::Error for ResolveError {}

/// Where a relative path starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Start {
    /// The directory holding the module: `./` and `../`.
    Parent,
    /// The module's own path: `@self`.
    Module,
}

/// The components of the module a file is, without empty and `.` components
/// and without its suffix or `init` file.
fn module_components(file: &str) -> Vec<&str> {
    let mut components = Vec::new();
    for component in file.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                components.pop();
            }
            name => components.push(name),
        }
    }
    match components.last().copied() {
        Some("init.lua" | "init.luau") => {
            components.pop();
        }
        Some(last) => {
            let stem = last
                .strip_suffix(".luau")
                .or_else(|| last.strip_suffix(".lua"))
                .unwrap_or(last);
            if let Some(slot) = components.last_mut() {
                *slot = stem;
            }
        }
        None => {}
    }
    components
}

/// The file as an error names it: its normalised path.
fn normalised(file: &str) -> String {
    file.split('/')
        .filter(|component| !component.is_empty() && *component != ".")
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;

    use super::*;

    fn resolved(file: &str, path: &str) -> Result<Option<String>, ResolveErrorKind> {
        resolve(Requirer::from_chunk_name(file), path).map_err(|error| error.kind)
    }

    #[test]
    fn relative_paths_resolve() {
        let cases = [
            ("@main.luau", "./split", "split"),
            ("@nested/a.luau", "./b", "nested/b"),
            ("@nested/deeper/a.luau", "../b", "nested/b"),
            ("@nested/init.luau", "./b", "b"),
            ("@nested/init.luau", "@self/b", "nested/b"),
            ("@nested/a.luau", "@self/b", "nested/a/b"),
            ("@nested/a.lua", "@self/b", "nested/a/b"),
            ("@nested/init.lua", "@self/b", "nested/b"),
            (
                "@@lunette-contracts/scale.luau",
                "./pacing",
                "@lunette-contracts/pacing",
            ),
            (
                "@@lunette-plugins/input/keyboard/init.luau",
                "@self/private/draw",
                "@lunette-plugins/input/keyboard/private/draw",
            ),
            // Empty components in a chunk name are skipped.
            ("@//split.luau", "./other", "other"),
            // A chunk with no file resolves at the root.
            ("=lunctl", "./tool", "tool"),
            // Dot and empty path components are skipped.
            ("@nested/a.luau", "./x/./y//z", "nested/x/y/z"),
        ];
        for (file, path, expected) in cases {
            assert_eq!(
                resolved(file, path),
                Ok(Some(expected.to_owned())),
                "{path} from {file}"
            );
        }
    }

    #[test]
    fn other_paths_are_left_to_the_loader() {
        for path in ["@lunette-contracts/scale", "main", "@selfish/x"] {
            assert_eq!(resolved("@nested/a.luau", path), Ok(None), "{path}");
        }
    }

    #[test]
    fn unrepresentable_paths_are_errors() {
        let cases = [
            ("@main.luau", "../x", ResolveErrorKind::Escapes),
            (
                "@@lunette-contracts/scale.luau",
                "../x",
                ResolveErrorKind::Escapes,
            ),
            (
                "@@lunette-contracts/init.luau",
                "./x",
                ResolveErrorKind::Escapes,
            ),
            ("@nested/a.luau", "../", ResolveErrorKind::NamesRoot),
            (
                "@@lunette-contracts/a.luau",
                "./",
                ResolveErrorKind::NamesRoot,
            ),
            (
                "@nested/a.luau",
                "./my.module",
                ResolveErrorKind::Dotted("my.module".to_owned()),
            ),
            ("=lunctl", "@self/x", ResolveErrorKind::NoSelf),
        ];
        for (file, path, expected) in cases {
            assert_eq!(resolved(file, path), Err(expected), "{path} from {file}");
        }
    }

    fn component() -> impl Strategy<Value = String> {
        "[a-z][a-z0-9_-]{0,6}"
    }

    proptest! {
        #[test]
        fn climbing_out_and_back_in_is_the_same_module(
            directory in prop::collection::vec(component(), 1..4),
            file in component(),
            target in component(),
        ) {
            let chunk = format!("@{}/{file}.luau", directory.join("/"));
            let last = directory.last().cloned().unwrap_or_default();
            let direct = resolve(Requirer::from_chunk_name(&chunk), &format!("./{target}"));
            let around = resolve(Requirer::from_chunk_name(&chunk), &format!("../{last}/{target}"));
            prop_assert_eq!(direct, around);
        }
    }
}
