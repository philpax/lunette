//! Checker-only regression for the interaction provider and recursive contracts.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn interaction_provider_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-plugins/panels/init.lua"),
            root.join("lua/lunette-plugins/panels/events.lua"),
            root.join("lua/lunette-plugins/panels/layer.lua"),
            root.join("lua/lunette-plugins/panels/panel.lua"),
            root.join("lua/lunette-plugins/interaction/init.lua"),
            root.join("lua/lunette-plugins/interaction/grab.lua"),
            root.join("lua/lunette-plugins/interaction/pose.lua"),
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
            root.join("lua/lunette-plugins/panels/init.lua"),
            root.join("lua/lunette-plugins/panels/events.lua"),
            root.join("lua/lunette-plugins/panels/layer.lua"),
            root.join("lua/lunette-plugins/panels/panel.lua"),
            root.join("lua/lunette-plugins/interaction/init.lua"),
            root.join("lua/lunette-plugins/interaction/grab.lua"),
            root.join("lua/lunette-plugins/interaction/pose.lua"),
            root.join("lua/lunette-plugins/laser/init.lua"),
            root.join("lua/lunette-plugins/laser/input.lua"),
            root.join("lua/lunette-plugins/laser/draw.lua"),
            root.join("lua/lunette-plugins/laser/registry.lua"),
            root.join("crates/lunette/tests/plugin_laser/recursive_definition.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("laser: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
