use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn persistence_state_and_binding_typecheck() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-desktop/persist/init.luau"),
            root.join("crates/lunette/tests/plugin_persistence/consumer.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("persistence: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "requested modules skipped"
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
