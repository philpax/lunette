//! The Luau checker over the fixtures in `luau_check/`, which one `.luaurc` there gives every
//! module root. A fixture either checks cleanly or carries one type error on each marked line.
//!
//! A line ending in `-- reject.` carries one type error, and a line ending in
//! `-- reject: <text>.` carries one whose message contains the text. Each fixture module
//! answers where it is as a singleton type, so a require resolved to another file is a type
//! error. `exit_status.rs` runs the relative-require fixture in a session.
#![expect(clippy::expect_used, reason = "a test fails at the first broken step")]

use std::{
    fs,
    path::{Path, PathBuf},
};

use lunette::aliases::{install_manifest, installed_luaurc};
use lunette_lovr::analyze::{self, Kind, Report, Request};
use tempfile::TempDir;

#[test]
fn clean_fixtures_check_without_diagnostics() {
    let report = check(
        [
            "luau_check/authoring/positive.luau",
            "luau_check/authoring/contracts_positive.luau",
            "luau_check/schema/positive.luau",
            "luau_check/native/positive.luau",
            "fixtures/require-relative/lunette/main.luau",
        ]
        .into_iter()
        .map(fixture)
        .collect(),
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

/// Configuration types through `runtime:use`, `reload`, and `context:child`, owners and
/// effects, declaration shapes, opaque native handles, and the unknown-service lint.
#[test]
fn facade_misuse_is_rejected() {
    assert_rejections("luau_check/authoring/negative.luau");
}

/// Real contracts reject wrong services, results, and receivers, and their data properties
/// are read-only.
#[test]
fn contract_misuse_is_rejected() {
    assert_rejections("luau_check/authoring/contracts_negative.luau");
}

/// The native declarations refuse modifier names outside the closed set and the removed entry
/// points.
#[test]
fn native_api_misuse_is_rejected() {
    assert_rejections("luau_check/native/negative.luau");
}

#[test]
fn schema_types_reject_wrong_inputs() {
    assert_rejections("luau_check/schema/negative.luau");
}

#[test]
fn desktop_configuration_is_typed() {
    assert_rejections("luau_check/desktop/configure.luau");
}

#[test]
fn invalid_lovr_configuration_is_rejected() {
    assert_rejections("luau_check/conf/invalid.luau");
}

/// Relative, `@self`, and aliased requires resolve as Luau resolves them, through a linked
/// directory too, and ambiguous, missing, and malformed paths are rejected.
#[test]
fn require_navigation() {
    let report = check(vec![fixture("luau_check/navigation/main.luau")]);
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
    assert_rejections("luau_check/navigation/ambiguous.luau");
    assert_rejections("luau_check/navigation/target/invalid.luau");
}

/// Checks that a fixture's diagnostics are exactly its rejection markers.
/// A configuration beside the `.luaurc` that `--dump-config` writes checks against an
/// installation copied from the install manifest.
#[test]
fn installed_configuration_checks() {
    let installation =
        TempDir::with_prefix("lunette-installed-check-").expect("temporary directory");
    for (source, destination) in install_manifest() {
        copy(
            &repository().join(source),
            &installation.path().join(destination),
        );
    }
    let configuration = installation.path().join("configuration");
    fs::create_dir_all(&configuration).expect("configuration directory");
    fs::write(configuration.join(".luaurc"), installed_luaurc("../lua")).expect(".luaurc");
    let source = configuration.join("main.luau");
    fs::write(
        &source,
        "local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local laser = require '@lunette-plugins/laser'
local desktop = require '@lunette-desktop'
return { lunette, plugin, keyboard, laser, desktop }
",
    )
    .expect("main.luau");
    let request = Request::new(
        Some(installation.path().join("definitions.luau")),
        vec![source],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "skipped: {:#?}",
        report.skipped(&request)
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

fn assert_rejections(path: &str) {
    let source = fs::read_to_string(fixture(path))
        .unwrap_or_else(|error| panic!("{path} could not be read: {error}"));
    let markers: Vec<(u32, Option<&str>)> = source
        .lines()
        .zip(1..)
        .filter_map(|(text, line)| {
            let (_, marker) = text.split_once("-- reject")?;
            let message = marker
                .strip_prefix(": ")
                .map(|message| message.trim_end_matches('.'));
            Some((line, message))
        })
        .collect();
    assert!(!markers.is_empty(), "{path} has no rejection markers");

    let report = check(vec![fixture(path)]);
    let mut lines: Vec<u32> = report
        .diagnostics
        .iter()
        .map(|diagnostic| {
            assert_eq!(diagnostic.kind, Kind::TypeError, "{diagnostic:#?}");
            assert!(diagnostic.module.ends_with(path), "{diagnostic:#?}");
            assert!(
                !diagnostic.message.contains("too complex"),
                "{diagnostic:#?}"
            );
            diagnostic.line
        })
        .collect();
    lines.sort_unstable();
    let expected: Vec<u32> = markers.iter().map(|(line, _)| *line).collect();
    assert_eq!(lines, expected, "{path}: {:#?}", report.diagnostics);

    for (line, message) in markers {
        let Some(message) = message else { continue };
        assert!(
            report
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.line == line && diagnostic.message.contains(message)),
            "{path}:{line} should report {message}: {:#?}",
            report.diagnostics
        );
    }
}

fn check(paths: Vec<PathBuf>) -> Report {
    let request = Request::new(
        Some(repository().join("etc/lunette/definitions.luau")),
        paths,
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "requested modules skipped: {:#?}",
        report.skipped(&request)
    );
    report
}

/// Copies a manifest source, leaving out `tests` directories as `make install` does.
fn copy(source: &Path, destination: &Path) {
    if source.is_dir() {
        for entry in fs::read_dir(source).expect("manifest directory") {
            let entry = entry.expect("manifest entry");
            if entry.file_name() != "tests" {
                copy(&entry.path(), &destination.join(entry.file_name()));
            }
        }
    } else {
        fs::create_dir_all(destination.parent().expect("parent")).expect("parent directory");
        fs::copy(source, destination).expect("manifest file");
    }
}

fn fixture(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join(path)
}

fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
