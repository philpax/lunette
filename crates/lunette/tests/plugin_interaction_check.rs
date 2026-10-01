//! Checker-only regression for the interaction provider and recursive contracts.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn interaction_provider_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-plugins/panels/init.luau"),
            root.join("lua/lunette-plugins/panels/events.luau"),
            root.join("lua/lunette-plugins/panels/layer.luau"),
            root.join("lua/lunette-plugins/panels/panel.luau"),
            root.join("lua/lunette-plugins/drops/init.luau"),
            root.join("lua/lunette-plugins/focus/init.luau"),
            root.join("lua/lunette-plugins/focus/holders.luau"),
            root.join("lua/lunette-plugins/interaction/init.luau"),
            root.join("lua/lunette-plugins/interaction/grab.luau"),
            root.join("lua/lunette-plugins/interaction/picking.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("interaction: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}

#[test]
fn laser_provider_and_consumer_graph_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-plugins/panels/init.luau"),
            root.join("lua/lunette-plugins/panels/events.luau"),
            root.join("lua/lunette-plugins/panels/layer.luau"),
            root.join("lua/lunette-plugins/panels/panel.luau"),
            root.join("lua/lunette-plugins/panels/shape.luau"),
            root.join("lua/lunette-plugins/interaction/init.luau"),
            root.join("lua/lunette-plugins/interaction/grab.luau"),
            root.join("lua/lunette-plugins/interaction/picking.luau"),
            root.join("lua/lunette-plugins/laser/init.luau"),
            root.join("lua/lunette-plugins/laser/input.luau"),
            root.join("lua/lunette-plugins/laser/draw.luau"),
            root.join("lua/lunette-plugins/laser/registry.luau"),
            root.join("crates/lunette/tests/plugin_laser/recursive_definition.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("laser: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
