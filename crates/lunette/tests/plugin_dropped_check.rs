//! Checks the dropped boundary without linking the runtime fixture VM.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn panels_dropped_boundary_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-contracts/panels.lua"),
            root.join("lua/lunette-contracts/interaction.lua"),
            root.join("lua/lunette-plugins/adoption/init.lua"),
            root.join("lua/lunette-plugins/adoption/service.lua"),
            root.join("lua/lunette-plugins/panels/events.lua"),
            root.join("lua/lunette-plugins/panels/init.lua"),
            root.join("lua/lunette-plugins/interaction/init.lua"),
            root.join("lua/lunette-plugins/interaction/grab.lua"),
            root.join("lua/lunette-plugins/interaction/pose.lua"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("panels: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
