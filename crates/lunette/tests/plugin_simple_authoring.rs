//! Checks per-capability authoring with the real panels, interaction, and keyboard contracts.

use std::path::PathBuf;

use lunette_lovr::analyze::{self, Kind, Report, Request};

#[test]
fn per_capability_authoring_checks_real_contracts_and_rejects_misuse() {
    for fixture in ["positive.luau", "runtime_guarantees.luau"] {
        let report = check(fixture);
        assert!(
            report.diagnostics.is_empty(),
            "{fixture}: {:#?}",
            report.diagnostics
        );
    }
    let report = check("negative.luau");
    let source = include_str!("plugin_simple_authoring/negative.luau");
    let spans = [
        (19, 39, 19, 41),
        (20, 41, 24, 5),
        (25, 41, 25, 54),
        (26, 33, 26, 52),
        (27, 34, 27, 48),
        (28, 22, 28, 35),
        (30, 19, 30, 21),
        (31, 21, 31, 30),
        (32, 38, 32, 43),
        (33, 33, 33, 45),
        (35, 20, 35, 26),
        (36, 6, 36, 22),
        (41, 41, 41, 58),
        (42, 51, 42, 68),
        (44, 34, 44, 36),
        (46, 16, 46, 54),
        (47, 25, 47, 35),
    ];
    let sites: Vec<_> = source
        .lines()
        .enumerate()
        .filter_map(|(line, text)| {
            text.split_once("-- reject: ")
                .map(|(_, message)| (line as u32 + 1, message.trim_end_matches('.')))
        })
        .collect();
    assert_eq!(sites.len(), spans.len(), "rejection markers moved");
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
                    && diagnostic.module.ends_with("negative.luau")
                    && (
                        diagnostic.line,
                        diagnostic.column,
                        diagnostic.end_line,
                        diagnostic.end_column,
                    ) == expected_span
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

fn check(fixture: &str) -> Report {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("crates/lunette/tests/plugin_simple_authoring")
                .join(fixture),
        ],
    );
    let report =
        analyze::check(&request).unwrap_or_else(|error| panic!("simple authoring: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "fixture was not checked"
    );
    report
}
