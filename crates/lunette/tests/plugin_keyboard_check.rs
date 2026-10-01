//! Checker-only regression for the real keyboard definition and recursive contracts.

use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn keyboard_provider_and_consumer_graph_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-plugins/panels/init.luau"),
            root.join("lua/lunette-plugins/panels/events.luau"),
            root.join("lua/lunette-plugins/panels/layer.luau"),
            root.join("lua/lunette-plugins/panels/panel.luau"),
            root.join("lua/lunette-plugins/interaction/init.luau"),
            root.join("lua/lunette-plugins/interaction/grab.luau"),
            root.join("lua/lunette-plugins/keyboard/init.luau"),
            root.join("lua/lunette-plugins/keyboard/service.luau"),
            root.join("lua/lunette-plugins/keyboard/board.luau"),
            root.join("lua/lunette-plugins/keyboard/validation.luau"),
            root.join("lua/lunette-plugins/keyboard/layout.luau"),
            root.join("lua/lunette-plugins/keyboard/draw.luau"),
            root.join("lua/lunette-plugins/keyboard/rows.luau"),
            root.join("lua/lunette-contracts/keys.luau"),
            root.join("crates/lunette/tests/plugin_keyboard/recursive_definition.luau"),
            root.join("crates/lunette/tests/plugin_keyboard/mappings.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("keyboard: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
