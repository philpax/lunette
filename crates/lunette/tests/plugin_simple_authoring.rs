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
