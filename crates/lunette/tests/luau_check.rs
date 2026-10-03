//! The Luau checker over the shipped roots and the checker fixtures.
//!
//! One case checks every shipped root together and fails on any diagnostic,
//! lint warnings included, which `lunette check` would let through. The other
//! cases check fixtures outside `lua/`: ones that must check cleanly, and ones
//! whose mistakes must be reported at an exact span, on an exact set of lines,
//! or within line ranges.
//!
//! `exit_status.rs` runs the relative-require fixture in a session. Each module
//! there answers where it is as a singleton type, so a require the checker
//! resolved to another file is a type error here.

use std::{
    fs,
    path::{Path, PathBuf},
};

use lunette_lovr::analyze::{self, Kind, Report, Request};

#[test]
fn every_shipped_root_checks_without_diagnostics() {
    let root = repository();
    let mut paths = Vec::new();
    for directory in [
        "lua/lunette",
        "lua/lunette-plugin",
        "lua/lunette-contracts",
        "lua/lunette-plugins",
        "lua/lunette-desktop",
        "examples",
    ] {
        collect_sources(&root.join(directory), &mut paths);
    }
    paths.push(root.join("etc/xdg/lunette/main.luau"));
    paths.push(root.join("etc/xdg/lunette/conf.luau"));
    let report = check(paths);
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn clean_fixtures_check_without_diagnostics() {
    let report = check(
        [
            "plugin_laser/recursive_definition.luau",
            "plugin_keyboard/recursive_definition.luau",
            "plugin_keyboard/mappings.luau",
            "fixtures/require-relative/lunette/main.luau",
            "plugin_conf_check/supported.luau",
            "plugin_policy/fixtures/rules_positive.luau",
            "plugin_authoring/positive.luau",
            "plugin_authoring/recursive.luau",
            "plugin_authoring/extra_keys.luau",
            "plugin_simple_authoring/positive.luau",
            "plugin_simple_authoring/runtime_guarantees.luau",
        ]
        .into_iter()
        .map(fixture)
        .collect(),
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn invalid_configuration_fields_types_and_enums_are_rejected() {
    let report = check(vec![fixture("plugin_conf_check/invalid.luau")]);
    let source = include_str!("plugin_conf_check/invalid.luau");
    let sites: Vec<_> = source
        .lines()
        .enumerate()
        .filter_map(|(index, text)| text.contains("-- reject.").then_some(index as u32 + 1))
        .collect();
    assert_eq!(
        report.diagnostics.len(),
        sites.len(),
        "{:#?}",
        report.diagnostics
    );
    for line in sites {
        let diagnostics: Vec<_> = report
            .diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.line == line && diagnostic.kind == Kind::TypeError)
            .collect();
        assert_eq!(
            diagnostics.len(),
            1,
            "line {line}: {:#?}",
            report.diagnostics
        );
        assert!(!diagnostics[0].message.contains("too complex"));
    }
}

/// A typed patch is checked against its entry's options: each call in the
/// fixture carries one mistake, and each is reported on its own line.
#[test]
fn a_typed_patch_is_checked_against_its_entrys_options() {
    let report = check(vec![fixture("plugin_desktop/configure_checked.luau")]);
    let mut lines = report
        .diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.module.ends_with("configure_checked.luau"))
        .map(|diagnostic| diagnostic.line)
        .collect::<Vec<_>>();
    lines.sort_unstable();
    lines.dedup();
    assert_eq!(
        lines,
        [8, 9, 10, 11, 12, 13, 14],
        "{:#?}",
        report.diagnostics
    );
}

#[test]
fn rules_predicates_and_evaluators_reject_misuse() {
    let name = "rules_negative.luau";
    let report = check(vec![fixture("plugin_policy/fixtures/rules_negative.luau")]);
    for (first, last) in [(2, 6), (7, 11), (12, 16), (17, 21), (22, 22)] {
        assert!(
            report.diagnostics.iter().any(|diagnostic| {
                diagnostic.module.ends_with(name)
                    && diagnostic.line <= last
                    && diagnostic.end_line >= first
            }),
            "missing diagnostic in lines {first}..={last}: {:#?}",
            report.diagnostics
        );
    }
    assert!(
        report
            .diagnostics
            .iter()
            .all(|d| d.module.ends_with(name) && (2..=22).contains(&d.line)),
        "unexpected diagnostics: {:#?}",
        report.diagnostics
    );
}

#[test]
fn invalid_owner_effect_and_configuration_sites_are_reported_exactly() {
    assert_rejections(
        "plugin_authoring/negative.luau",
        include_str!("plugin_authoring/negative.luau"),
        &[
            (10, 33, 10, 71),
            (11, 33, 11, 46),
            (12, 19, 12, 28),
            (13, 23, 13, 37),
            (14, 4, 14, 19),
            (15, 4, 15, 11),
            (20, 35, 20, 37),
            (22, 27, 22, 29),
            (29, 35, 29, 40),
        ],
    );
}

#[test]
fn plugin_handles_are_not_satisfied_by_tables_or_other_handles() {
    assert_rejections(
        "plugin_authoring/opaque_handles.luau",
        include_str!("plugin_authoring/opaque_handles.luau"),
        &[(5, 20, 5, 22), (6, 12, 6, 14), (7, 12, 7, 17)],
    );
}

#[test]
fn malformed_declarations_are_reported_exactly() {
    assert_rejections(
        "plugin_authoring/malformed.luau",
        include_str!("plugin_authoring/malformed.luau"),
        &[(4, 52, 4, 59), (5, 45, 5, 72), (6, 63, 6, 65)],
    );
}

/// `plugin.capability` without `<<Service>>` checks as a `Capability<unknown>`,
/// which Luau accepts silently; the checker reports the call that made it.
#[test]
fn a_capability_without_its_service_type_is_reported_at_the_call() {
    assert_rejections(
        "plugin_authoring/unnamed_service.luau",
        include_str!("plugin_authoring/unnamed_service.luau"),
        &[(5, 16, 5, 74)],
    );
}

#[test]
fn per_capability_authoring_rejects_misuse_of_real_contracts() {
    assert_rejections(
        "plugin_simple_authoring/negative.luau",
        include_str!("plugin_simple_authoring/negative.luau"),
        &[
            (20, 39, 20, 41),
            (21, 41, 25, 5),
            (26, 41, 26, 54),
            (27, 33, 27, 52),
            (28, 34, 28, 48),
            (29, 35, 29, 47),
            (31, 19, 31, 21),
            (32, 21, 32, 30),
            (33, 38, 33, 43),
            (34, 33, 34, 45),
            (37, 39, 37, 45),
            (38, 8, 38, 29),
            (44, 41, 44, 58),
            (45, 51, 45, 68),
            (47, 34, 47, 36),
            (49, 16, 49, 54),
            (50, 38, 50, 40),
        ],
    );
}

/// Checks that the fixture's diagnostics are exactly its `-- reject: ` markers:
/// one type error per marker, at the expected span, carrying the marker's text.
fn assert_rejections(path: &str, source: &str, spans: &[(u32, u32, u32, u32)]) {
    let report = check(vec![fixture(path)]);
    let sites: Vec<_> = source
        .lines()
        .enumerate()
        .filter_map(|(line, text)| {
            text.split_once("-- reject: ")
                .map(|(_, message)| (line as u32 + 1, message.trim_end_matches('.')))
        })
        .collect();
    assert_eq!(sites.len(), spans.len(), "{:#?}", report.diagnostics);
    assert_eq!(
        report.diagnostics.len(),
        spans.len(),
        "{:#?}",
        report.diagnostics
    );
    for ((line, message), expected_span) in sites.iter().zip(spans) {
        assert_eq!(*line, expected_span.2, "rejection marker moved");
        let matches = report
            .diagnostics
            .iter()
            .filter(|diagnostic| {
                diagnostic.kind == Kind::TypeError
                    && diagnostic.module.ends_with(path)
                    && (
                        diagnostic.line,
                        diagnostic.column,
                        diagnostic.end_line,
                        diagnostic.end_column,
                    ) == *expected_span
                    && diagnostic.message.contains(message)
                    && !diagnostic.message.contains("too complex")
            })
            .count();
        assert_eq!(
            matches, 1,
            "missing {message} at {expected_span:?}: {:#?}",
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

fn collect_sources(directory: &Path, paths: &mut Vec<PathBuf>) {
    let mut entries: Vec<_> = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{}: {error}", directory.display()))
        .map(|entry| {
            entry
                .unwrap_or_else(|error| panic!("{}: {error}", directory.display()))
                .path()
        })
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            collect_sources(&path, paths);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "luau")
        {
            paths.push(path);
        }
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
