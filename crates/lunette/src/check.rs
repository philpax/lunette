//! Linux-only: runs `lunette check` and draws Luau diagnostics to stderr.

use std::{
    collections::HashMap,
    fmt::{self, Display, Formatter},
    fs,
    io::{self, IsTerminal},
    ops::Range,
    path::{Path, PathBuf},
    process::ExitCode,
    slice,
};

use ariadne::{Color, Config, Label, Report, ReportKind, Source};
use lunette_lovr::analyze::{self, Diagnostic, Kind, Request};
use tracing::{error, info};

/// Where the definitions are installed, under the compiled-in prefix.
const INSTALLED_DEFINITIONS: &str = "share/lunette/definitions.luau";

/// Resolves the definitions file, or reports why no definitions are available.
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

/// Typechecks the named roots or the configuration directory and draws diagnostics.
///
/// A skipped root fails the run.
pub fn run(named: &[PathBuf], configuration: &Path, definitions: Option<&Path>) -> ExitCode {
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

    let request = Request::new(Some(definitions), roots);

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

/// Returns named files and `.luau` files under named directories in path order.
///
/// With no named paths, it reads files under `configuration`. It skips hidden
/// names and rejects missing, unreadable, or empty inputs.
pub fn targets(named: &[PathBuf], configuration: &Path) -> Result<Vec<PathBuf>, TargetError> {
    let configuration = configuration.to_owned();
    let paths = if named.is_empty() {
        slice::from_ref(&configuration)
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
    /// The directory holds no `.luau` file.
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
            Self::Empty(path) => write!(formatter, "check: {} holds no .luau file", path.display()),
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
            .is_some_and(|extension| extension == "luau")
        {
            files.push(path);
        }
    }
    Ok(())
}

/// Draws diagnostics against their source, falling back to one-line text when a file is unreadable.
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

/// Returns the diagnostic span clamped to the source text.
///
/// Ariadne indexes source text by character. A definitions error has no source
/// location and maps to the end of the source.
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
    // Ariadne does not draw zero-width spans.
    if begin == end {
        begin..(begin + 1).min(characters)
    } else {
        begin..end
    }
}

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
            "main.luau",
            "conf.luau",
            "nested/a.luau",
            ".luaurc",
            "notes.txt",
            ".hidden/x.luau",
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
            ["conf.luau", "main.luau", "nested/a.luau"].map(|file| directory.path().join(file))
        );
    }

    #[test]
    fn named_paths_replace_the_configuration_directory_and_must_exist() {
        let directory = configuration();
        let elsewhere = configuration();
        let named = [
            elsewhere.path().join("main.luau"),
            elsewhere.path().join("nested"),
        ];
        let found = targets(&named, directory.path()).expect("the files");
        assert_eq!(
            found,
            [
                elsewhere.path().join("main.luau"),
                elsewhere.path().join("nested/a.luau")
            ]
        );

        let missing = directory.path().join("absent.luau");
        assert!(matches!(
            targets(slice::from_ref(&missing), directory.path()),
            Err(TargetError::Missing { path, defaulted: false }) if path == missing
        ));
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
}
