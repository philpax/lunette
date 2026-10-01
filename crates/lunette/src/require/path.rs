//! What a relative require names, as a pure function of the requiring chunk's
//! name and the required path.
//!
//! The rules are Luau's require-by-string rules, which the checker applies
//! through Luau's own navigator:
//!
//! - A module's path is its file's path without the `.lua` or `.luau` suffix,
//!   and a directory's `init.lua` or `init.luau` is the module named by the
//!   directory.
//! - `./` and `../` start from the directory that holds the module: the parent
//!   of the module's path. In `keyboard/init.luau`, whose module is `keyboard`,
//!   `./draw` is `draw`, a sibling of the directory.
//! - `@self` starts from the module's own path. In `keyboard/init.luau`,
//!   `@self/draw` is `keyboard/draw`.
//!
//! A session's configuration is mounted at the root of LÖVR's virtual
//! filesystem and each module root at its `@` alias, so a resolved path names
//! a module the session's loader finds. A path cannot leave the root it
//! starts in: the checker would resolve one that does against the directory
//! tree on disk, which the session's virtual filesystem does not have.

use std::fmt;

/// Where the requiring chunk came from, read from its chunk name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Requirer<'a> {
    /// A chunk loaded from a file, named by its path in the virtual
    /// filesystem, such as `nested/a.luau` or `@lunette-contracts/scale.luau`.
    File(&'a str),
    /// A chunk with no file, such as one `lunctl eval` sends. It resolves as a
    /// module at the configuration root would, as a REPL resolves against its
    /// working directory.
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

/// Resolves `path` as `requirer` requires it.
///
/// Answers `None` for a path that is not relative, such as an alias
/// (`@lunette-contracts/scale`), which the session's loader resolves as it stands.
///
/// # Errors
///
/// A relative path that leaves its root, names a root rather than a module,
/// carries a component the session's loader would misread, or is `@self` in a
/// chunk with no file.
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
    /// The path as the chunk gave it.
    pub path: String,
    /// The requiring file, or `None` for a chunk with no file.
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
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
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
            // A top-level module requires a sibling.
            ("@main.luau", "./split", "split"),
            // A nested module requires its sibling.
            ("@nested/a.luau", "./b", "nested/b"),
            // A parent path climbs one directory.
            ("@nested/deeper/a.luau", "../b", "nested/b"),
            // An init file's sibling is beside its directory.
            ("@nested/init.luau", "./b", "b"),
            // Self in an init file is its directory.
            ("@nested/init.luau", "@self/b", "nested/b"),
            // Self in any other file is the module's own path.
            ("@nested/a.luau", "@self/b", "nested/a/b"),
            // A `.lua` file names its module the same way: LÖVR still loads
            // a main.lua, and the require path still searches for `.lua`.
            ("@nested/a.lua", "@self/b", "nested/a/b"),
            ("@nested/init.lua", "@self/b", "nested/b"),
            // A mounted root resolves within itself.
            (
                "@@lunette-contracts/scale.luau",
                "./pacing",
                "@lunette-contracts/pacing",
            ),
            (
                "@@lunette-plugins/keyboard/init.luau",
                "@self/draw",
                "@lunette-plugins/keyboard/draw",
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

    #[test]
    fn an_error_names_the_path_and_the_requiring_file() {
        let error = resolve(Requirer::File("./nested//a.luau"), "../../x").expect_err("an escape");
        assert_eq!(
            error.to_string(),
            "require: '../../x' from nested/a.luau leaves the root it starts in"
        );
    }

    fn component() -> impl Strategy<Value = String> {
        "[a-z][a-z0-9_-]{0,6}"
    }

    proptest! {
        /// Any path below a file's directory resolves to that directory joined
        /// with the path, whichever root the file is in.
        #[test]
        fn a_sibling_path_is_joined_to_the_requiring_directory(
            root in prop_oneof![Just(String::new()), component().prop_map(|name| format!("@{name}/"))],
            directory in prop::collection::vec(component(), 0..4),
            file in component(),
            path in prop::collection::vec(component(), 1..4),
        ) {
            let mut requirer = root.clone();
            for part in &directory {
                requirer.push_str(part);
                requirer.push('/');
            }
            requirer.push_str(&file);
            requirer.push_str(".luau");

            let mut expected = root.clone();
            for part in directory.iter().chain(&path) {
                expected.push_str(part);
                expected.push('/');
            }
            expected.pop();

            let chunk = format!("@{requirer}");
            prop_assert_eq!(
                resolve(Requirer::from_chunk_name(&chunk), &format!("./{}", path.join("/"))),
                Ok(Some(expected))
            );
        }

        /// Climbing out of a directory and back into it is the same module.
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
