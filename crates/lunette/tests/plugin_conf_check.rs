//! Checks LÖVR configuration declarations without linking a runtime fixture VM.

use std::path::PathBuf;

use lunette_lovr::analyze::{self, Kind, Report, Request};

#[test]
fn shipped_configuration_is_strictly_typed() {
    let report = check("etc/xdg/lunette/conf.luau");
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn supported_configuration_fields_and_nullable_values_typecheck() {
    let report = check("crates/lunette/tests/plugin_conf_check/supported.luau");
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn invalid_configuration_fields_types_and_enums_are_rejected() {
    let report = check("crates/lunette/tests/plugin_conf_check/invalid.luau");
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

fn check(path: &str) -> Report {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![root.join(path)],
    );
    let report =
        analyze::check(&request).unwrap_or_else(|error| panic!("configuration checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "configuration was not checked"
    );
    report
}
