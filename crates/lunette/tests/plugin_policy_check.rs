//! Strict policy checks isolated from the runtime VM test binary.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

fn check(paths: &[&str]) {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        paths
            .iter()
            .map(|path| root.join("lua/lunette-plugins").join(path))
            .collect(),
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("policy checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "requested modules skipped"
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn tags_service() {
    check(&["tags/service.luau"]);
}
#[test]
fn rules_service() {
    check(&["rules/policy.luau", "rules/service.luau"]);
}

#[test]
fn placement_service() {
    check(&["placement/init.luau", "placement/service.luau"]);
}

#[test]
fn rules_predicates_and_evaluators() {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for (name, negative) in [
        ("rules_positive.luau", false),
        ("rules_negative.luau", true),
    ] {
        let request = Request::new(
            Some(manifest.join("../../etc/lunette/definitions.luau")),
            vec![manifest.join("tests/plugin_policy/fixtures").join(name)],
        );
        let report =
            analyze::check(&request).unwrap_or_else(|error| panic!("rules fixture: {error}"));
        assert!(report.skipped(&request).is_empty());
        if negative {
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
        } else {
            assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
        }
    }
}
#[test]
fn arc_geometry_and_layouts_broker() {
    check(&["layout/arc/geometry.luau", "layouts/init.luau"]);
}
#[test]
fn full_entrypoints() {
    check(&[
        "tags/init.luau",
        "rules/init.luau",
        "layouts/init.luau",
        "layout/arc/init.luau",
        "adoption/init.luau",
        "placement/init.luau",
        "errors/init.luau",
    ]);
}
