//! Linux-only: the command line, and the one operation that does not start a
//! session.
//!
//! Parsing happens here, not in `main`, so the arguments handed to LÖVR are
//! what remains after lunette removes its own. `boot` builds Lua's `arg`
//! table from them. A flag meant for lunette left in the arguments reaches a
//! configuration not written to handle it.

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
        /// The files or directories to check. A directory is checked file
        /// by file: every `.lua` and `.luau` file below it, passing over
        /// names that begin with `.`. Each `@` alias resolves through the
        /// `.luaurc` beside the file.
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
/// installed `@lunette-desktop` root, which `main.luau` composes, so a copied
/// configuration patches them rather than carrying copies of them.
const CONFIG_ARTIFACTS: &[&str] = &["main.luau", "conf.luau"];

/// The contents of each of [`CONFIG_ARTIFACTS`], in its order, as this binary
/// was built with them.
///
/// The copy is embedded rather than read from `$SYSCONFDIR/xdg/lunette`,
/// which is fixed when the binary is built: a binary that was never installed
/// has nothing there, and an installed one could find a configuration from
/// another version there. The embedded files are the ones written against
/// the module roots this binary mounts. The array's length is the
/// inventory's, and a test checks that each entry is the shipped file of the
/// same name.
const DEFAULT_CONFIGURATION: [&str; CONFIG_ARTIFACTS.len()] = [
    include_str!("../../../etc/xdg/lunette/main.luau"),
    include_str!("../../../etc/xdg/lunette/conf.luau"),
];

/// Writes the default configuration to `destination`, refusing to overwrite
/// anything.
///
/// The function refuses to overwrite, because the file it writes is one
/// the user is about to edit. A copy that replaces an edited configuration
/// destroys the user's edits.
///
/// The `.luaurc` is written from `standard_library`, and it names
/// `standard_library` by an absolute path. The file in the source tree
/// resolves its aliases relative to itself; copied beside a user's
/// configuration, it names a directory that is not there, and every
/// `require '@lunette-desktop/…'` fails to resolve for the checker and for the
/// user's editor. For the same reason a `standard_library` that lacks a root
/// the `.luaurc` names is refused: it is what a binary run from a source tree
/// without `$LUNETTE_STDLIB_PATH` resolves, and the session it would start
/// could not load the configuration either.
pub fn dump(destination: &Path, standard_library: &Path) -> Result<Vec<PathBuf>, DumpError> {
    let roots = ModuleRoots::installed(standard_library);
    if let Some(missing) = roots
        .iter()
        .filter(|root| !root.optional())
        .find(|root| !root.source.is_dir())
    {
        return Err(DumpError::NoModuleData {
            root: missing.source.clone(),
            standard_library: standard_library.to_owned(),
        });
    }

    let targets = CONFIG_ARTIFACTS
        .iter()
        .map(|name| destination.join(name))
        .chain(std::iter::once(destination.join(ALIAS_FILE)))
        .collect::<Vec<_>>();
    if let Some(existing) = targets.iter().find(|target| target.exists()) {
        return Err(DumpError::Exists(existing.clone()));
    }

    fs::create_dir_all(destination)
        .map_err(|error| DumpError::Write(destination.to_owned(), error))?;

    let mut written = Vec::with_capacity(targets.len());
    for (name, contents) in CONFIG_ARTIFACTS.iter().zip(DEFAULT_CONFIGURATION) {
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
    /// Something already exists where a copy would go, and the copy is
    /// refused.
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
    fn the_lua_files_are_the_shipped_configuration() {
        let library = standard_library();
        let destination = TempDir::new().expect("a temporary directory");
        let destination = destination.path().join("lunette");

        dump(&destination, library.path()).expect("the copy");

        let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../etc/xdg/lunette");
        for artifact in CONFIG_ARTIFACTS {
            assert_eq!(
                fs::read_to_string(destination.join(artifact)).expect("the copy"),
                fs::read_to_string(shipped.join(artifact)).expect("the shipped file"),
            );
        }
        assert!(destination.join(".luaurc").is_file());
    }

    /// A binary built from a source tree resolves the installed prefix when
    /// `$LUNETTE_STDLIB_PATH` is unset; a `.luaurc` naming it would resolve
    /// nothing.
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
