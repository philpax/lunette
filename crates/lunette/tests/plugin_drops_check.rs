//! Checks the drops boundary without linking the runtime fixture VM.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn drops_boundary_typechecks() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![
            root.join("lua/lunette-contracts/drops.luau"),
            root.join("lua/lunette-contracts/interaction.luau"),
            root.join("lua/lunette-plugins/drops/init.luau"),
            root.join("lua/lunette-plugins/interaction/init.luau"),
            root.join("lua/lunette-plugins/interaction/grab.luau"),
            root.join("lua/lunette-desktop/pose-memory.luau"),
            root.join("lua/lunette-desktop/persistence.luau"),
            root.join("lua/lunette-desktop/arrange.luau"),
        ],
    );
    let report = analyze::check(&request).unwrap_or_else(|error| panic!("drops: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
