//! Linux-only: `lunette check`, and how a diagnostic is drawn.
//!
//! Diagnostics go to stderr as their own report, outside `tracing`.
//! A type error is a compiler diagnostic. A timestamp and level in front of
//! one obscure the file and position an editor is looking for.

use std::{
    collections::HashMap,
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

/// Typechecks `roots`, drawing what it found.
///
/// A root that is not read fails the run on its own. A pass that silently
/// skips its input reports a clean result for a file it never reads.
pub fn run(roots: &[PathBuf], definitions: Option<&Path>, old_solver: bool) -> ExitCode {
    if roots.is_empty() {
        error!("check: no files were named; name the files to check, such as main.lua");
        return ExitCode::FAILURE;
    }

    let definitions = match resolve_definitions(definitions) {
        Some(path) => path,
        None => return ExitCode::FAILURE,
    };

    let request = Request {
        old_solver,
        ..Request::new(Some(definitions), roots.to_vec())
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
