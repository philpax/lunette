//! Checks the typed plugin facade and its owner, effect, child, and declaration APIs.

use std::path::PathBuf;

use lunette_lovr::analyze::{self, Kind, Report, Request};

#[test]
fn owner_effect_child_and_configuration_types_check() {
    for fixture in ["positive.luau", "recursive.luau", "extra_keys.luau"] {
        let report = check(fixture);
        assert!(
            report.diagnostics.is_empty(),
            "{fixture}: {:#?}",
            report.diagnostics
        );
    }
}

#[test]
fn invalid_owner_effect_and_configuration_sites_are_reported_exactly() {
    assert_rejections(
        "negative.luau",
        include_str!("plugin_authoring/negative.luau"),
        &[
            (11, 33, 11, 71),
            (12, 33, 12, 46),
            (13, 19, 13, 28),
            (14, 23, 14, 37),
            (15, 4, 15, 19),
            (16, 4, 16, 11),
            (21, 35, 21, 37),
            (23, 27, 23, 29),
            (29, 35, 29, 40),
        ],
    );
}

#[test]
fn plugin_handles_are_not_satisfied_by_tables_or_other_handles() {
    assert_rejections(
        "opaque_handles.luau",
        include_str!("plugin_authoring/opaque_handles.luau"),
        &[(5, 20, 5, 22), (6, 12, 6, 14), (7, 12, 7, 17)],
    );
}

#[test]
fn malformed_declarations_are_reported_exactly() {
    assert_rejections(
        "malformed.luau",
        include_str!("plugin_authoring/malformed.luau"),
        &[(4, 52, 4, 59), (5, 45, 5, 72), (6, 63, 6, 65)],
    );
}

fn assert_rejections(fixture: &str, source: &str, spans: &[(u32, u32, u32, u32)]) {
    let report = check(fixture);
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
        let matches: Vec<_> = report
            .diagnostics
            .iter()
            .filter(|diagnostic| {
                diagnostic.kind == Kind::TypeError
                    && diagnostic.module.ends_with(fixture)
                    && (
                        diagnostic.line,
                        diagnostic.column,
                        diagnostic.end_line,
                        diagnostic.end_column,
                    ) == *expected_span
                    && diagnostic.message.contains(message)
                    && !diagnostic.message.contains("too complex")
            })
            .collect();
        assert_eq!(
            matches.len(),
            1,
            "missing {message} at {expected_span:?}: {:#?}",
            report.diagnostics
        );
    }
}

fn check(fixture: &str) -> Report {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let request = Request::new(
        Some(manifest.join("../../etc/lunette/definitions.luau")),
        vec![manifest.join("tests/plugin_authoring").join(fixture)],
    );
    let report =
        analyze::check(&request).unwrap_or_else(|error| panic!("plugin authoring: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "fixture was not checked"
    );
    report
}
