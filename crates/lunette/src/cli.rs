//! Linux-only: the command line, and the one operation that does not start a session.
//!
//! Lunette removes its own flags here, so the configuration's `arg` holds only what it forwards.

use std::{
    ffi::OsString,
    fmt::{self, Display, Formatter},
    fs, io,
    path::{Path, PathBuf},
};

use clap::Parser;
use lunette::aliases::{self, ModuleRoots};

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
    /// `$HOME/.config/lunette`, then the system directory. This avoids setting
    /// `$XDG_CONFIG_HOME`, which every spawned client would inherit.
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
        /// The files or directories to check. A directory checks every `.luau`
        /// file below it, skipping names that begin with `.`. Each `@` alias
        /// resolves through the `.luaurc` beside the file.
        ///
        /// Without any, the configuration directory a session would load:
        /// `--config-path`, then `$LUNETTE_CONFIG_PATH`,
        /// `$XDG_CONFIG_HOME/lunette`, `$HOME/.config/lunette`, and the system
        /// directory, the first that exists.
        #[arg(value_name = "PATH")]
        roots: Vec<PathBuf>,

        /// The definitions to check against, naming the runtime globals.
        #[arg(long, value_name = "FILE")]
        definitions: Option<PathBuf>,
    },
    /// Require parameter annotations and return annotations for value-returning functions.
    ///
    /// Every explicit parameter, including `_` and varargs, needs an annotation.
    /// Functions with only bare returns or fallthrough may omit a return annotation.
    /// A return with expressions, including a forwarding call, needs an annotation
    /// because this check only parses source and loads no definitions or inferred types.
    CheckAnnotations {
        /// The files or directories to parse. A directory checks every `.luau`
        /// file below it, skipping names that begin with `.`.
        #[arg(value_name = "PATH", required = true, num_args = 1..)]
        roots: Vec<PathBuf>,
    },
}

/// The shipped default configuration's files, which `install-config` also installs.
///
/// They are embedded because `$SYSCONFDIR/xdg/lunette` may be absent or hold
/// another version's configuration.
const DEFAULT_CONFIGURATION: &[(&str, &str)] = &[
    (
        "main.luau",
        include_str!("../../../etc/xdg/lunette/main.luau"),
    ),
    (
        "conf.luau",
        include_str!("../../../etc/xdg/lunette/conf.luau"),
    ),
];

/// Writes the default configuration to `destination`, refusing to overwrite
/// anything.
///
/// The `.luaurc` names `standard_library` by an absolute path, because a relative
/// alias copied beside a user's configuration names a directory that is not
/// there. A `standard_library` lacking a named root is refused, since a session
/// could not load the configuration either.
pub fn dump(destination: &Path, standard_library: &Path) -> Result<Vec<PathBuf>, DumpError> {
    let roots = ModuleRoots::installed(standard_library);
    if let Some(missing) = roots.iter().find(|root| !root.source.is_dir()) {
        return Err(DumpError::NoModuleData {
            root: missing.source.clone(),
            standard_library: standard_library.to_owned(),
        });
    }

    let targets = DEFAULT_CONFIGURATION
        .iter()
        .map(|(name, _)| destination.join(name))
        .chain(std::iter::once(destination.join(ALIAS_FILE)))
        .collect::<Vec<_>>();
    if let Some(existing) = targets.iter().find(|target| target.exists()) {
        return Err(DumpError::Exists(existing.clone()));
    }

    fs::create_dir_all(destination)
        .map_err(|error| DumpError::Write(destination.to_owned(), error))?;

    let mut written = Vec::with_capacity(targets.len());
    for (name, contents) in DEFAULT_CONFIGURATION {
        let target = destination.join(name);
        fs::write(&target, contents).map_err(|error| DumpError::Write(target.clone(), error))?;
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

/// What Luau reads a directory's aliases from.
const ALIAS_FILE: &str = ".luaurc";

/// Why a configuration could not be written.
#[derive(Debug)]
pub enum DumpError {
    /// A root the `.luaurc` would name is not below the standard library.
    NoModuleData {
        root: PathBuf,
        standard_library: PathBuf,
    },
    /// Something already exists where a copy would go.
    Exists(PathBuf),
    /// The copy could not be written.
    Write(PathBuf, io::Error),
}

impl Display for DumpError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoModuleData {
                root,
                standard_library,
            } => write!(
                formatter,
                "dump-config: the Lua roots are not installed at {}, so a .luaurc naming them would resolve nothing ({} is not a directory); install lunette, or set LUNETTE_STDLIB_PATH to a source tree's lua directory",
                standard_library.display(),
                root.display()
            ),
            Self::Exists(path) => write!(
                formatter,
                "dump-config: {} already exists, and a copy would replace it",
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
            Self::Write(_, error) => Some(error),
            Self::NoModuleData { .. } | Self::Exists(_) => None,
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;
    use tempfile::TempDir;

    use super::*;

    /// A standard library with every root a `.luaurc` names.
    fn standard_library() -> TempDir {
        let directory = TempDir::new().expect("a temporary directory");
        for root in ModuleRoots::installed(directory.path()).iter() {
            fs::create_dir_all(&root.source).expect("a root");
        }
        directory
    }

    #[test]
    fn a_dumped_configuration_carries_aliases_that_resolve_from_where_it_lands() {
        let library = standard_library();
        let destination = TempDir::new().expect("a temporary directory");
        let destination = destination.path().join("lunette");

        let written = dump(&destination, library.path()).expect("the configuration to be written");

        assert!(written.contains(&destination.join(".luaurc")));
        let rendered = fs::read_to_string(destination.join(".luaurc")).expect("the written file");
        let expected = library.path().join("lunette-desktop");
        assert!(
            rendered.contains(&format!("\"lunette-desktop\": \"{}\"", expected.display())),
            "{rendered}"
        );
        assert!(
            !rendered.contains(".."),
            "a relative alias survived the copy: {rendered}"
        );
    }

    #[test]
    fn a_standard_library_without_its_roots_is_refused() {
        let library = TempDir::new().expect("a temporary directory");
        let destination = TempDir::new().expect("a temporary directory");

        let error = dump(destination.path(), library.path()).expect_err("a refusal");

        assert!(matches!(error, DumpError::NoModuleData { .. }));
        assert!(error.to_string().contains("LUNETTE_STDLIB_PATH"), "{error}");
        assert!(!destination.path().join("main.luau").exists());
    }

    #[test]
    fn nothing_is_overwritten() {
        let library = standard_library();
        let destination = TempDir::new().expect("a temporary directory");
        fs::write(destination.path().join("main.luau"), "-- theirs\n").expect("their main.luau");

        let error = dump(destination.path(), library.path()).expect_err("a refusal");

        assert!(matches!(error, DumpError::Exists(_)));
        assert_eq!(
            fs::read_to_string(destination.path().join("main.luau")).expect("their main.luau"),
            "-- theirs\n",
        );
    }
}
