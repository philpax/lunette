//! Linux-only: the command line, and the one operation that does not start a
//! session.
//!
//! Parsing happens here, not in `main`, so the arguments handed to LÖVR are
//! what remains after lunette removes its own. `boot` builds Lua's `arg`
//! table from them. A flag meant for lunette left in the arguments reaches a
//! configuration not written to handle it.

use std::{
    collections::BTreeSet,
    ffi::OsString,
    fmt::{self, Display, Formatter},
    fs, io,
    path::{Path, PathBuf},
};

use clap::Parser;
use lunette::aliases;

/// What the user asked lunette to do.
#[derive(Debug, Parser)]
#[command(
    name = "lunette",
    about = "An XR window manager and Wayland compositor.",
    version
)]
pub struct Cli {
    /// What lunette does when it does not start a session.
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Load the configuration from this directory without searching for
    /// one.
    ///
    /// The search path is `$XDG_CONFIG_HOME/lunette`, then
    /// `$HOME/.config/lunette`, then the system directory. Naming a directory
    /// here points a session at a configuration without setting
    /// `$XDG_CONFIG_HOME`; everything lunette spawns would otherwise inherit
    /// it and look for its own configuration under it.
    #[arg(long, value_name = "DIR")]
    pub config_path: Option<PathBuf>,

    /// Write a copy of the default configuration and exit.
    ///
    /// Without a directory it writes to the first entry of the search path.
    #[arg(long, value_name = "DIR", num_args = 0..=1, default_missing_value = "")]
    pub dump_config: Option<PathBuf>,

    /// Passed through to LÖVR, and on to the configuration as `arg`.
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    pub forwarded: Vec<OsString>,
}

#[derive(Debug, clap::Subcommand)]
pub enum Command {
    /// Typecheck a configuration and the standard library it uses.
    Check {
        /// The files to check. Defaults to the files in the configuration
        /// directory.
        #[arg(value_name = "FILE")]
        roots: Vec<PathBuf>,

        /// The definitions to check against, naming the runtime globals.
        #[arg(long, value_name = "FILE")]
        definitions: Option<PathBuf>,

        /// Typecheck with the old solver, not the current one.
        #[arg(long)]
        old_solver: bool,
    },
}

/// Files that make up the shipped default configuration, relative to its root.
///
/// Keep this inventory explicit: adding a configuration file must be a
/// deliberate packaging change, not an accidental consequence of a tree walk.
///
/// The desktop's consumers are not configuration files: they are the
/// installed `@lunette-desktop` root, which `main.lua` composes, so a copied
/// configuration patches them rather than carrying copies of them.
const CONFIG_ARTIFACTS: &[&str] = &["main.lua", "conf.lua"];

/// Copies `source` to `destination`, refusing to overwrite anything.
///
/// The function refuses to overwrite, because the file it writes is one
/// the user is about to edit. A copy that replaces an edited configuration
/// destroys the user's edits.
///
/// The `.luaurc` is written from `standard_library`, not copied, and it
/// names `standard_library` by an absolute path. The file in the source
/// tree resolves its aliases relative to itself; copied beside a user's
/// configuration, it names a directory that is not there, and every
/// `require '@lunette-desktop/…'` fails to resolve for the checker and for the
/// user's editor.
pub fn dump(
    source: &Path,
    destination: &Path,
    standard_library: &Path,
) -> Result<Vec<PathBuf>, DumpError> {
    if !source.is_dir() {
        return Err(DumpError::NoDefault(source.to_owned()));
    }

    let entries = read_config_entries(source)?;
    validate_config_entries(&entries)?;

    let targets = CONFIG_ARTIFACTS
        .iter()
        .map(|artifact| destination.join(artifact))
        .chain(std::iter::once(destination.join(ALIAS_FILE)))
        .collect::<Vec<_>>();
    if let Some(existing) = targets.iter().find(|target| target.exists()) {
        return Err(DumpError::Exists(existing.clone()));
    }

    fs::create_dir_all(destination)
        .map_err(|error| DumpError::Write(destination.to_owned(), error))?;

    let mut written = Vec::with_capacity(targets.len());
    for artifact in CONFIG_ARTIFACTS {
        let source_path = source.join(artifact);
        let target = destination.join(artifact);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| DumpError::Write(parent.to_owned(), error))?;
        }
        fs::copy(&source_path, &target).map_err(|error| DumpError::Write(target.clone(), error))?;
        written.push(target);
    }

    let target = destination.join(ALIAS_FILE);
    fs::write(
        &target,
        aliases::installed_luaurc(&standard_library.display().to_string()),
    )
    .map_err(|error| DumpError::Write(target.clone(), error))?;
    written.push(target);

    Ok(written)
}

/// Collects source paths and their filesystem kinds without following links.
fn read_config_entries(source: &Path) -> Result<Vec<(PathBuf, ConfigEntryKind)>, DumpError> {
    let mut entries = Vec::new();
    let mut pending = vec![source.to_owned()];
    while let Some(directory) = pending.pop() {
        let children =
            fs::read_dir(&directory).map_err(|error| DumpError::Read(directory.clone(), error))?;
        for child in children {
            let child = child.map_err(|error| DumpError::Read(directory.clone(), error))?;
            let path = child.path();
            let relative = path
                .strip_prefix(source)
                .map_err(|_| DumpError::Unsupported(path.clone()))?
                .to_owned();
            let file_type = child
                .file_type()
                .map_err(|error| DumpError::Read(path.clone(), error))?;
            let kind = if file_type.is_dir() {
                pending.push(path);
                ConfigEntryKind::Directory
            } else if file_type.is_file() {
                ConfigEntryKind::File
            } else {
                ConfigEntryKind::Unsupported
            };
            entries.push((relative, kind));
        }
    }
    Ok(entries)
}

/// The filesystem shapes accepted beneath the shipped configuration root.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ConfigEntryKind {
    Directory,
    File,
    Unsupported,
}

/// Checks the filesystem inventory against the declared shipped artifacts.
fn validate_config_entries(entries: &[(PathBuf, ConfigEntryKind)]) -> Result<(), DumpError> {
    let expected = CONFIG_ARTIFACTS
        .iter()
        .map(PathBuf::from)
        .collect::<BTreeSet<_>>();
    let mut found = BTreeSet::new();
    for (path, kind) in entries {
        if path == Path::new(ALIAS_FILE) && *kind == ConfigEntryKind::File {
            continue;
        }
        match kind {
            ConfigEntryKind::File if expected.contains(path) => {
                found.insert(path.clone());
            }
            ConfigEntryKind::Directory
                if expected.iter().any(|artifact| artifact.starts_with(path)) => {}
            ConfigEntryKind::Directory => return Err(DumpError::Unsupported(path.clone())),
            ConfigEntryKind::File | ConfigEntryKind::Unsupported => {
                return Err(DumpError::Unsupported(path.clone()));
            }
        }
    }
    if let Some(missing) = expected.difference(&found).next() {
        return Err(DumpError::Missing(missing.clone()));
    }
    Ok(())
}

/// What Luau reads a directory's aliases from.
const ALIAS_FILE: &str = ".luaurc";

/// Why a configuration could not be written.
#[derive(Debug)]
pub enum DumpError {
    /// The path to the installed default configuration does not point at a
    /// configuration directory.
    NoDefault(PathBuf),
    /// The default configuration could not be read.
    Read(PathBuf, io::Error),
    /// Something already exists where a copy would go, and the copy is
    /// refused.
    Exists(PathBuf),
    /// A declared default-configuration file is absent.
    Missing(PathBuf),
    /// A filesystem entry is not represented by the shipped artifact manifest.
    Unsupported(PathBuf),
    /// The copy could not be written.
    Write(PathBuf, io::Error),
}

impl Display for DumpError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoDefault(path) => write!(
                formatter,
                "dump-config: no default configuration is installed at {}",
                path.display()
            ),
            Self::Read(path, error) => write!(
                formatter,
                "dump-config: the default configuration at {} could not be read: {error}",
                path.display()
            ),
            Self::Exists(path) => write!(
                formatter,
                "dump-config: {} already exists, and a copy would replace it",
                path.display()
            ),
            Self::Missing(path) => write!(
                formatter,
                "dump-config: the declared default-configuration file {} is missing",
                path.display()
            ),
            Self::Unsupported(path) => write!(
                formatter,
                "dump-config: the default configuration contains unsupported content at {}",
                path.display()
            ),
            Self::Write(path, error) => write!(
                formatter,
                "dump-config: {} could not be written: {error}",
                path.display()
            ),
        }
    }
}

impl std::error::Error for DumpError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Read(_, error) | Self::Write(_, error) => Some(error),
            Self::NoDefault(_) | Self::Exists(_) | Self::Missing(_) | Self::Unsupported(_) => None,
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    /// Builds a default configuration directory carrying the `.luaurc` a
    /// source tree has, whose aliases resolve relative to the source tree.
    fn source() -> TempDir {
        let directory = TempDir::new().expect("a temporary directory");
        for artifact in CONFIG_ARTIFACTS {
            let path = directory.path().join(artifact);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("artifact directory");
            }
            fs::write(&path, format!("-- {artifact}\n")).expect("configuration artifact");
        }
        fs::write(
            directory.path().join(".luaurc"),
            aliases::luaurc("../../../lua"),
        )
        .expect("a source .luaurc");
        directory
    }

    #[test]
    fn config_artifact_manifest_names_the_shipped_files() {
        assert_eq!(CONFIG_ARTIFACTS, &["main.lua", "conf.lua"]);
    }

    #[test]
    fn the_manifest_accepts_exact_files() {
        let entries = [
            (PathBuf::from("main.lua"), ConfigEntryKind::File),
            (PathBuf::from("conf.lua"), ConfigEntryKind::File),
            (PathBuf::from(".luaurc"), ConfigEntryKind::File),
        ];
        assert!(validate_config_entries(&entries).is_ok());
    }

    #[test]
    fn the_manifest_rejects_the_desktop_consumers_it_no_longer_carries() {
        let mut entries = CONFIG_ARTIFACTS
            .iter()
            .map(|path| (PathBuf::from(path), ConfigEntryKind::File))
            .collect::<Vec<_>>();
        entries.push((PathBuf::from("desktop"), ConfigEntryKind::Directory));
        assert!(matches!(
            validate_config_entries(&entries),
            Err(DumpError::Unsupported(path)) if path == Path::new("desktop")
        ));
    }

    #[test]
    fn the_manifest_rejects_missing_and_unsupported_content() {
        let missing = [(PathBuf::from("main.lua"), ConfigEntryKind::File)];
        assert!(matches!(
            validate_config_entries(&missing),
            Err(DumpError::Missing(_))
        ));

        let mut unsupported = CONFIG_ARTIFACTS
            .iter()
            .map(|path| (PathBuf::from(path), ConfigEntryKind::File))
            .collect::<Vec<_>>();
        unsupported.push((PathBuf::from("extra.lua"), ConfigEntryKind::File));
        assert!(matches!(
            validate_config_entries(&unsupported),
            Err(DumpError::Unsupported(path)) if path == Path::new("extra.lua")
        ));

        let mut symlink = CONFIG_ARTIFACTS
            .iter()
            .map(|path| (PathBuf::from(path), ConfigEntryKind::File))
            .collect::<Vec<_>>();
        symlink.push((PathBuf::from("link.lua"), ConfigEntryKind::Unsupported));
        assert!(matches!(
            validate_config_entries(&symlink),
            Err(DumpError::Unsupported(path)) if path == Path::new("link.lua")
        ));
    }

    #[test]
    fn a_dumped_configuration_carries_aliases_that_resolve_from_where_it_lands() {
        let source = source();
        let destination = TempDir::new().expect("a temporary directory");
        let destination = destination.path().join("lunette");

        let written = dump(
            source.path(),
            &destination,
            Path::new("/usr/local/share/lunette/lua"),
        )
        .expect("the configuration to be written");

        assert!(written.contains(&destination.join(".luaurc")));
        let rendered = fs::read_to_string(destination.join(".luaurc")).expect("the written file");
        assert!(
            rendered.contains("\"mullion\": \"/usr/local/share/lunette/lua/mullion\""),
            "{rendered}"
        );
        assert!(
            rendered
                .contains("\"lunette-desktop\": \"/usr/local/share/lunette/lua/lunette-desktop\""),
            "{rendered}"
        );
        assert!(
            !rendered.contains(".."),
            "a relative alias survived the copy: {rendered}"
        );
    }

    #[test]
    fn the_lua_files_are_copied_as_they_stand() {
        let source = source();
        let destination = TempDir::new().expect("a temporary directory");
        let destination = destination.path().join("lunette");

        dump(source.path(), &destination, Path::new("/somewhere/lua")).expect("the copy");

        for artifact in CONFIG_ARTIFACTS {
            assert_eq!(
                fs::read_to_string(destination.join(artifact)).expect("configuration artifact"),
                format!("-- {artifact}\n")
            );
        }
        assert!(destination.join(".luaurc").is_file());
    }

    #[test]
    fn nothing_is_overwritten() {
        let source = source();
        let destination = TempDir::new().expect("a temporary directory");
        fs::write(destination.path().join("main.lua"), "-- theirs\n").expect("their main.lua");

        let error = dump(
            source.path(),
            destination.path(),
            Path::new("/somewhere/lua"),
        )
        .expect_err("a refusal");

        assert!(matches!(error, DumpError::Exists(_)));
        assert_eq!(
            fs::read_to_string(destination.path().join("main.lua")).expect("their main.lua"),
            "-- theirs\n",
        );
    }
}
