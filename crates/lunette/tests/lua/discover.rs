//! Discovers Lua test files under `lua/` and the repository-only `dev/` configuration.
//!
//! Test files are `.luau` files directly inside `tests` directories. Helpers
//! belong under `tests/support`; other files under `tests` are reported as errors.

use std::{
    fmt, fs, io,
    path::{Component, Path, PathBuf},
};

use lunette::aliases::{DEVELOPMENT_ALIASES, Resolution};

const TESTS: &str = "tests";
/// The directory under `tests` that holds helpers.
const SUPPORT: &str = "support";

/// A test file, and the names it runs and is required by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TestFile {
    /// The display path, without its extension. Development files carry a `dev/` prefix.
    pub name: String,
    /// The aliased or configuration-relative module name used to require the file.
    pub module: String,
    /// The source tree whose module resolution the file uses.
    pub source: Source,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Library,
    Development,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Test,
    Support,
    /// A file under a `tests` directory that is neither.
    Stray,
    /// A module, or anything outside a `tests` directory.
    Other,
}

pub fn classify(relative: &Path) -> Kind {
    let components: Vec<&str> = relative
        .components()
        .filter_map(|component| match component {
            Component::Normal(name) => name.to_str(),
            _ => None,
        })
        .collect();
    let Some(tests) = components.iter().position(|name| *name == TESTS) else {
        return Kind::Other;
    };
    let below = &components[tests + 1..];
    let is_luau = relative
        .extension()
        .is_some_and(|extension| extension == "luau");
    match below {
        [_file] if is_luau => Kind::Test,
        [first, _, ..] if *first == SUPPORT => Kind::Support,
        _ => Kind::Stray,
    }
}

/// Every test file below the library and development configuration, sorted by name.
pub fn test_files(repository: &Path) -> Result<Vec<TestFile>, DiscoveryError> {
    let mut files = Vec::new();
    for (directory, source) in [("lua", Source::Library), ("dev", Source::Development)] {
        let root = repository.join(directory);
        walk(&root, &root, source, &mut files)?;
    }
    files.sort_by(|left, right| left.name.cmp(&right.name));
    if files.is_empty() {
        return Err(DiscoveryError::Empty(repository.to_path_buf()));
    }
    Ok(files)
}

fn walk(
    root: &Path,
    directory: &Path,
    source: Source,
    files: &mut Vec<TestFile>,
) -> Result<(), DiscoveryError> {
    let entries = fs::read_dir(directory)
        .map_err(|error| DiscoveryError::Read(directory.to_path_buf(), error))?;
    for entry in entries {
        let path = entry
            .map_err(|error| DiscoveryError::Read(directory.to_path_buf(), error))?
            .path();
        if path.is_dir() {
            walk(root, &path, source, files)?;
            continue;
        }
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        match classify(relative) {
            Kind::Test => files.push(test_file(relative, source)?),
            Kind::Stray => return Err(DiscoveryError::Stray(relative.to_path_buf())),
            Kind::Support | Kind::Other => {}
        }
    }
    Ok(())
}

/// Names a test file relative to its library or development configuration root.
pub fn test_file(relative: &Path, source: Source) -> Result<TestFile, DiscoveryError> {
    let stem = relative.with_extension("");
    let name = stem
        .to_str()
        .ok_or_else(|| DiscoveryError::Unnamed(relative.to_path_buf()))?
        .to_owned();
    let (name, module) = match source {
        Source::Library => {
            let (directory, rest) = name
                .split_once('/')
                .ok_or_else(|| DiscoveryError::Unrooted(relative.to_path_buf()))?;
            let alias = DEVELOPMENT_ALIASES
                .iter()
                .find(|alias| alias.name == directory && alias.resolution == Resolution::Mounted)
                .ok_or_else(|| DiscoveryError::Unrooted(relative.to_path_buf()))?;
            let module = format!("@{}/{rest}", alias.name);
            (name, module)
        }
        Source::Development => (format!("dev/{name}"), name),
    };
    Ok(TestFile {
        name,
        module,
        source,
    })
}

/// Why the test files could not be listed.
#[derive(Debug)]
pub enum DiscoveryError {
    Read(PathBuf, io::Error),
    /// A file under a `tests` directory that is neither a test file nor a
    /// helper.
    Stray(PathBuf),
    /// A test file outside every module root, which nothing could require.
    Unrooted(PathBuf),
    /// A test file whose path is not UTF-8.
    Unnamed(PathBuf),
    /// No test files exist under the test roots.
    Empty(PathBuf),
}

impl fmt::Display for DiscoveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read(path, error) => {
                write!(
                    formatter,
                    "discovery: {} could not be listed: {error}",
                    path.display()
                )
            }
            Self::Stray(path) => write!(
                formatter,
                "discovery: {} is under a tests directory but is neither a test file directly \
                 inside it nor a helper under tests/support",
                path.display()
            ),
            Self::Unrooted(path) => write!(
                formatter,
                "discovery: {} is not below a mounted module root",
                path.display()
            ),
            Self::Unnamed(path) => {
                write!(
                    formatter,
                    "discovery: {} is not a UTF-8 path",
                    path.display()
                )
            }
            Self::Empty(path) => {
                write!(
                    formatter,
                    "discovery: no test file was found under {}",
                    path.display()
                )
            }
        }
    }
}

impl std::error::Error for DiscoveryError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Read(_, error) => Some(error),
            _ => None,
        }
    }
}
