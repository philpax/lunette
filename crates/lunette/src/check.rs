//! Linux-only: `lunette check`, and how a diagnostic is drawn.
//!
//! Diagnostics go to stderr as their own report, outside `tracing`.
//! A type error is a compiler diagnostic. A timestamp and level in front of
//! one obscure the file and position an editor is looking for.

use std::{
    collections::HashMap,
    fmt::{self, Display, Formatter},
    fs,
    io::{self, IsTerminal},
    ops::Range,
    path::{Path, PathBuf},
    process::ExitCode,
};

use ariadne::{Color, Config, Label, Report, ReportKind, Source};
use lunette_lovr::analyze::{self, Diagnostic, Kind, Request};
use tracing::{error, info};

/// Where the definitions are installed, under the compiled-in prefix.
const INSTALLED_DEFINITIONS: &str = "share/lunette/definitions.luau";

/// The definitions to check against, or nothing and the reason.
///
/// Without them every `lovr` global is unknown and every LÖVR type is undeclared.
/// A check against none reports hundreds of diagnostics that do not reflect the
/// files checked. The function returns nothing when no definitions resolve.
fn resolve_definitions(named: Option<&Path>) -> Option<PathBuf> {
    if let Some(path) = named {
        if path.is_file() {
            return Some(path.to_owned());
        }
        error!(path = %path.display(), "check: the definitions are not there");
        return None;
    }

    let installed = Path::new(crate::PREFIX).join(INSTALLED_DEFINITIONS);
    if installed.is_file() {
        return Some(installed);
    }

    error!(
        path = %installed.display(),
        "check: no definitions were given and none is installed; pass --definitions"
    );
    None
}

/// Typechecks `named`, or the configuration directory when nothing is named,
/// drawing what it found.
///
/// `configuration` is the directory a session started the same way would
/// load, so `lunette check` with no paths checks what `lunette` would run. A
/// directory is checked file by file; [`targets`] says which files.
///
/// A root that is not read fails the run on its own. A pass that silently
/// skips its input reports a clean result for a file it never reads.
pub fn run(
    named: &[PathBuf],
    configuration: &Path,
    definitions: Option<&Path>,
    old_solver: bool,
) -> ExitCode {
    let roots = match targets(named, configuration) {
        Ok(roots) => roots,
        Err(error) => {
            error!("{error}");
            return ExitCode::FAILURE;
        }
    };

    let definitions = match resolve_definitions(definitions) {
        Some(path) => path,
        None => return ExitCode::FAILURE,
    };

    let request = Request {
        old_solver,
        ..Request::new(Some(definitions), roots)
    };

    let report = match analyze::check(&request) {
        Ok(report) => report,
        Err(error) => {
            error!("{error}");
            if let analyze::Error::Failed { diagnostics, .. } = &error {
                draw(diagnostics);
            }
            return ExitCode::FAILURE;
        }
    };

    draw(&report.diagnostics);

    let skipped = report.skipped(&request);
    for path in &skipped {
        error!(path = %path.display(), "check: this was never read, so nothing checked it");
    }

    if report.is_clean() && skipped.is_empty() {
        info!(files = report.checked.len(), "check: nothing to report");
        return ExitCode::SUCCESS;
    }
    ExitCode::FAILURE
}

/// The files a check reads: each named file, and each `.lua` or `.luau` file
/// below each named directory, in path order. With nothing named, the files
/// below `configuration`.
///
/// A directory or file whose name begins with `.` is passed over: a
/// configuration's `.luaurc` is not a module, and neither is anything an
/// editor or a version-control tool keeps beside it.
///
/// # Errors
///
/// A path that does not exist, a directory that cannot be read, or a directory
/// that holds no file to check. Each would otherwise be a clean report about
/// nothing.
pub fn targets(named: &[PathBuf], configuration: &Path) -> Result<Vec<PathBuf>, TargetError> {
    let defaulted = [configuration.to_owned()];
    let paths = if named.is_empty() {
        &defaulted[..]
    } else {
        named
    };

    let mut files = Vec::new();
    for path in paths {
        if path.is_file() {
            files.push(path.clone());
        } else if path.is_dir() {
            let before = files.len();
            collect(path, &mut files)?;
            if files.len() == before {
                return Err(TargetError::Empty(path.clone()));
            }
        } else {
            return Err(TargetError::Missing {
                path: path.clone(),
                defaulted: named.is_empty(),
            });
        }
    }
    Ok(files)
}

/// Why `lunette check` has nothing to read.
#[derive(Debug)]
pub enum TargetError {
    /// The path is not there. `defaulted` is set when it is the
    /// configuration directory, which nobody named.
    Missing { path: PathBuf, defaulted: bool },
    /// A directory below the named one could not be read.
    Read(PathBuf, io::Error),
    /// The directory holds no `.lua` or `.luau` file.
    Empty(PathBuf),
}

impl Display for TargetError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing {
                path,
                defaulted: true,
            } => write!(
                formatter,
                "check: no files were named, and the configuration directory {} does not exist; name the files to check, or run lunette --dump-config to create it",
                path.display()
            ),
            Self::Missing {
                path,
                defaulted: false,
            } => write!(formatter, "check: {} does not exist", path.display()),
            Self::Read(path, error) => {
                write!(
                    formatter,
                    "check: {} could not be read: {error}",
                    path.display()
                )
            }
            Self::Empty(path) => write!(
                formatter,
                "check: {} holds no .lua or .luau file",
                path.display()
            ),
        }
    }
}

impl std::error::Error for TargetError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Read(_, error) => Some(error),
            Self::Missing { .. } | Self::Empty(_) => None,
        }
    }
}

/// Appends the files below `directory` to `files`, in path order.
fn collect(directory: &Path, files: &mut Vec<PathBuf>) -> Result<(), TargetError> {
    let read = |error| TargetError::Read(directory.to_owned(), error);
    let mut entries = fs::read_dir(directory)
        .map_err(read)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(read)?;
    entries.sort();
    for path in entries {
        let hidden = path
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with('.'));
        if hidden {
            continue;
        }
        if path.is_dir() {
            collect(&path, files)?;
        } else if path
            .extension()
            .is_some_and(|extension| extension == "lua" || extension == "luau")
        {
            files.push(path);
        }
    }
    Ok(())
}

/// Draws each diagnostic against the source it came from.
///
/// A file that cannot be read falls back to the plain one-line form, so a
/// diagnostic is not lost to a failure in drawing it.
fn draw(diagnostics: &[Diagnostic]) {
    let mut sources = Sources::default();
    let colour = io::stderr().is_terminal();

    for diagnostic in diagnostics {
        let name = diagnostic.module.display().to_string();
        let Some(source) = sources.get(&diagnostic.module) else {
            eprintln!("{diagnostic}");
            continue;
        };

        let span = span_of(source.text(), diagnostic);
        let report = Report::build(kind_of(diagnostic.kind), (name.clone(), span.clone()))
            .with_config(Config::new().with_color(colour))
            .with_message(&diagnostic.message)
            .with_label(
                Label::new((name.clone(), span))
                    .with_color(colour_of(diagnostic.kind))
                    .with_message(&diagnostic.message),
            )
            .finish();

        if report.eprint((name, source.clone())).is_err() {
            eprintln!("{diagnostic}");
        }
    }
}

/// The character range `diagnostic` covers, clamped to the source it is drawn
/// on.
///
/// ariadne indexes a `Source` by character, so the offsets count characters.
/// A byte offset reads too far by however many multi-byte characters precede
/// it. A definitions failure arrives with no location, so its position is past
/// the end of the source and collapses onto it without panicking.
fn span_of(text: &str, diagnostic: &Diagnostic) -> Range<usize> {
    let starts = line_starts(text);
    let characters = text.chars().count();
    let offset = |line: u32, column: u32| -> usize {
        let index = (line.max(1) as usize) - 1;
        let start = starts.get(index).copied().unwrap_or(characters);
        (start + column as usize).min(characters)
    };

    let begin = offset(diagnostic.line, diagnostic.column);
    let end = offset(diagnostic.end_line, diagnostic.end_column).max(begin);
    // A zero-width span draws nothing, so it is widened onto its own character.
    if begin == end {
        begin..(begin + 1).min(characters)
    } else {
        begin..end
    }
}

/// Where each line begins, counted in characters.
fn line_starts(text: &str) -> Vec<usize> {
    let mut starts = vec![0];
    for (index, character) in text.chars().enumerate() {
        if character == '\n' {
            starts.push(index + 1);
        }
    }
    starts
}

fn kind_of(kind: Kind) -> ReportKind<'static> {
    match kind {
        Kind::LintWarning => ReportKind::Warning,
        Kind::TypeError | Kind::SyntaxError | Kind::LintError => ReportKind::Error,
    }
}

fn colour_of(kind: Kind) -> Color {
    match kind {
        Kind::LintWarning => Color::Yellow,
        Kind::TypeError | Kind::SyntaxError | Kind::LintError => Color::Red,
    }
}

/// The sources drawn against, read once each.
#[derive(Default)]
struct Sources {
    read: HashMap<PathBuf, Option<Source<String>>>,
}

impl Sources {
    fn get(&mut self, path: &Path) -> Option<&Source<String>> {
        self.read
            .entry(path.to_owned())
            .or_insert_with(|| fs::read_to_string(path).ok().map(Source::from))
            .as_ref()
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

    fn configuration() -> TempDir {
        let directory = TempDir::new().expect("a temporary directory");
        for file in [
            "main.lua",
            "conf.lua",
            "nested/a.luau",
            ".luaurc",
            "notes.txt",
            ".hidden/x.lua",
        ] {
            let path = directory.path().join(file);
            fs::create_dir_all(path.parent().expect("a parent")).expect("the directory");
            fs::write(&path, "").expect("the file");
        }
        directory
    }

    #[test]
    fn nothing_named_checks_the_configuration_directory() {
        let directory = configuration();
        let found = targets(&[], directory.path()).expect("the files");
        assert_eq!(
            found,
            ["conf.lua", "main.lua", "nested/a.luau"].map(|file| directory.path().join(file))
        );
    }

    #[test]
    fn named_paths_replace_the_configuration_directory() {
        let directory = configuration();
        let elsewhere = configuration();
        let named = [
            elsewhere.path().join("main.lua"),
            elsewhere.path().join("nested"),
        ];
        let found = targets(&named, directory.path()).expect("the files");
        assert_eq!(
            found,
            [
                elsewhere.path().join("main.lua"),
                elsewhere.path().join("nested/a.luau")
            ]
        );
    }

    #[test]
    fn a_missing_configuration_directory_says_how_to_make_one() {
        let directory = TempDir::new().expect("a temporary directory");
        let missing = directory.path().join("lunette");
        let error = targets(&[], &missing).expect_err("nothing to check");
        assert!(matches!(
            &error,
            TargetError::Missing {
                defaulted: true,
                ..
            }
        ));
        assert!(error.to_string().contains("--dump-config"), "{error}");
    }

    #[test]
    fn a_directory_with_nothing_to_check_is_an_error() {
        let directory = TempDir::new().expect("a temporary directory");
        fs::write(directory.path().join("notes.txt"), "").expect("the file");
        assert!(matches!(
            targets(&[], directory.path()),
            Err(TargetError::Empty(path)) if path == directory.path()
        ));
    }

    #[test]
    fn a_missing_named_path_is_an_error() {
        let directory = configuration();
        let missing = directory.path().join("absent.lua");
        assert!(matches!(
            targets(std::slice::from_ref(&missing), directory.path()),
            Err(TargetError::Missing { path, defaulted: false }) if path == missing
        ));
    }
}
