//! Strict policy checks isolated from the runtime VM test binary.
use std::{path::PathBuf, sync::Mutex};

use lunette_lovr::analyze::{self, Request};

static CHECKER: Mutex<()> = Mutex::new(());

fn check(paths: &[&str]) {
    let _guard = CHECKER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
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
    check(&["tags/service.lua"]);
}
#[test]
fn rules_service() {
    check(&["rules/policy.lua", "rules/service.lua"]);
}

#[test]
fn placement_service() {
    check(&["placement/init.lua", "placement/service.lua"]);
}

#[test]
fn rules_predicates_and_evaluators() {
    let _guard = CHECKER
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
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
    check(&["layout/arc/geometry.lua", "layouts/init.lua"]);
}
#[test]
fn full_entrypoints() {
    check(&[
        "tags/init.lua",
        "rules/init.lua",
        "layouts/init.lua",
        "layout/arc/init.lua",
        "adoption/init.lua",
        "placement/init.lua",
        "errors/init.lua",
    ]);
}
