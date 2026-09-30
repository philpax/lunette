//! Checker-only regression for the real keyboard definition and recursive contracts.

use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn keyboard_provider_and_consumer_graph_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-plugins/panels/init.lua"),
            root.join("lua/lunette-plugins/panels/events.lua"),
            root.join("lua/lunette-plugins/panels/layer.lua"),
            root.join("lua/lunette-plugins/panels/raycast.lua"),
            root.join("lua/lunette-plugins/interaction/init.lua"),
            root.join("lua/lunette-plugins/interaction/grab.lua"),
            root.join("lua/lunette-plugins/interaction/pose.lua"),
            root.join("lua/lunette-plugins/keyboard/init.lua"),
            root.join("lua/lunette-plugins/keyboard/service.lua"),
            root.join("lua/lunette-plugins/keyboard/layout.lua"),
            root.join("lua/lunette-plugins/keyboard/draw.lua"),
            root.join("crates/lunette/tests/plugin_keyboard/recursive_definition.luau"),
            root.join("crates/lunette/tests/plugin_keyboard/mappings.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("keyboard: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
