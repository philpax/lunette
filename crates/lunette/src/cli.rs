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
use lunette::aliases;

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
///
/// The `.luaurc` is written rather than copied, and it names `standard_library`
/// by an absolute path. The one in the source tree resolves its aliases
/// relative to itself, which is true only where it sits; a copy of it beside a
/// user's configuration would name a directory that is not there, and every
/// `require '@mullion/…'` would fail to resolve for the checker and for their
/// editor.
pub fn dump(
    source: &Path,
    destination: &Path,
    standard_library: &Path,
) -> Result<Vec<PathBuf>, DumpError> {
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
        // Written below against this installation rather than copied from a
        // tree whose relative paths do not survive the move.
        if entry.file_name() == ALIAS_FILE {
            continue;
        }
        let target = destination.join(entry.file_name());
        fs::copy(entry.path(), &target).map_err(|error| DumpError::Write(target.clone(), error))?;
        written.push(target);
    }

    let target = destination.join(ALIAS_FILE);
    fs::write(
        &target,
        aliases::luaurc(&standard_library.display().to_string()),
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

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use tempfile::TempDir;

    use super::*;

    /// Builds a default configuration directory with the `.luaurc` a source
    /// tree carries, whose relative aliases are true only where it sits.
    fn source() -> TempDir {
        let directory = TempDir::new().expect("a temporary directory");
        fs::write(directory.path().join("main.lua"), "-- main\n").expect("main.lua");
        fs::write(directory.path().join("conf.lua"), "-- conf\n").expect("conf.lua");
        fs::write(
            directory.path().join(".luaurc"),
            aliases::luaurc("../../../lua"),
        )
        .expect("a source .luaurc");
        directory
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

        assert_eq!(
            fs::read_to_string(destination.join("main.lua")).expect("main.lua"),
            "-- main\n"
        );
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
