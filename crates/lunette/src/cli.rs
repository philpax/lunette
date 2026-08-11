//! Linux-only: the command line, and the one operation that does not start a
//! session.
//!
//! Parsing lives here rather than in `main` so that the arguments LÖVR is handed
//! are what remains after lunette has taken its own. `boot` builds Lua's `arg`
//! table from them, and a flag meant for lunette appearing there would reach a
//! configuration that has no idea what it is.

use std::{
    ffi::OsString,
    fmt::{self, Display, Formatter},
    fs, io,
    path::{Path, PathBuf},
};

use clap::Parser;

/// What lunette was asked to do.
#[derive(Debug, Parser)]
#[command(
    name = "lunette",
    about = "An XR window manager and Wayland compositor.",
    version
)]
pub struct Cli {
    /// What to do instead of running a session.
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Load the configuration from this directory instead of searching for one.
    ///
    /// The search path is `$XDG_CONFIG_HOME/lunette`, then
    /// `$HOME/.config/lunette`, then the system directory. Naming a directory
    /// here is how a session is pointed at a configuration without setting
    /// `$XDG_CONFIG_HOME`, which everything lunette spawns would otherwise
    /// inherit and look for its own configuration under.
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
        /// The files to check. Defaults to the configuration directory's own.
        #[arg(value_name = "FILE")]
        roots: Vec<PathBuf>,

        /// The definitions to check against, naming the runtime globals.
        #[arg(long, value_name = "FILE")]
        definitions: Option<PathBuf>,

        /// Typecheck with the old solver rather than the current one.
        #[arg(long)]
        old_solver: bool,
    },
}

/// Copies `source` to `destination`, refusing to overwrite anything.
///
/// Refusing rather than merging is the point: the file this writes is one the
/// user is about to edit, and a copy landing on top of an edited configuration
/// would destroy the work it was meant to start.
pub fn dump(source: &Path, destination: &Path) -> Result<Vec<PathBuf>, DumpError> {
    if !source.is_dir() {
        return Err(DumpError::NoDefault(source.to_owned()));
    }

    let entries = fs::read_dir(source)
        .map_err(|error| DumpError::Read(source.to_owned(), error))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| DumpError::Read(source.to_owned(), error))?;

    let mut written = Vec::with_capacity(entries.len());
    for entry in &entries {
        let target = destination.join(entry.file_name());
        if target.exists() {
            return Err(DumpError::Exists(target));
        }
    }

    fs::create_dir_all(destination)
        .map_err(|error| DumpError::Write(destination.to_owned(), error))?;

    for entry in entries {
        // One level deep. The default configuration is a flat directory of Lua
        // files, and a recursive copy would be machinery for a case that does
        // not exist yet.
        if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            continue;
        }
        let target = destination.join(entry.file_name());
        fs::copy(entry.path(), &target).map_err(|error| DumpError::Write(target.clone(), error))?;
        written.push(target);
    }

    Ok(written)
}

/// Why a configuration could not be written.
#[derive(Debug)]
pub enum DumpError {
    /// The installed default configuration is not where it should be.
    NoDefault(PathBuf),
    /// The default configuration could not be read.
    Read(PathBuf, io::Error),
    /// Something is already there, and a copy would overwrite it.
    Exists(PathBuf),
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
            Self::NoDefault(_) | Self::Exists(_) => None,
        }
    }
}
