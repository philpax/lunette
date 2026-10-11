//! Linux-only: checks source-written Luau function annotations for repository validation.

use std::{io, path::PathBuf, process::ExitCode};

use clap::Parser;
use lunette_lovr::analyze::{self, Diagnostic, Request};
use tracing::{Level, error, info};

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_max_level(Level::INFO)
        .init();

    let mut arguments = Arguments::parse();
    arguments.files.sort();
    arguments.files.dedup();
    let request = Request::new(None, arguments.files);
    let report = match analyze::check_annotations(&request.roots) {
        Ok(report) => report,
        Err(error) => {
            error!("check-annotations: {error}");
            if let analyze::Error::Failed { diagnostics, .. } = &error {
                draw(diagnostics);
            }
            return ExitCode::FAILURE;
        }
    };
    draw(&report.diagnostics);

    let skipped = report.skipped(&request);
    for path in &skipped {
        error!(path = %path.display(), "check-annotations: this was not parsed successfully");
    }
    info!(
        files = report.checked.len(),
        diagnostics = report.diagnostics.len(),
        skipped = skipped.len(),
        "check-annotations: completed"
    );
    if report.is_clean() && skipped.is_empty() && !report.checked.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// Require parameter annotations and return annotations for functions with return expressions.
///
/// Every explicit parameter, including `_` and varargs, needs an annotation.
/// Functions with only bare returns or fallthrough may omit a return annotation.
/// A forwarding `return call()` still requires one because the check parses source without inference.
#[derive(Parser)]
struct Arguments {
    /// Explicit source files to parse. Repository enumeration is handled by the Makefile.
    #[arg(value_name = "FILE", required = true, num_args = 1..)]
    files: Vec<PathBuf>,
}

fn draw(diagnostics: &[Diagnostic]) {
    for diagnostic in diagnostics {
        error!(
            "{}:{}:{}: {}",
            diagnostic.module.display(),
            diagnostic.line,
            diagnostic.column.saturating_add(1),
            diagnostic.message,
        );
    }
}
