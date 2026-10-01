//! Strict checking of the shipped configuration in a checker-only binary.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn shipped_desktop_composition_is_strictly_typed() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        [
            "main.lua",
            "desktop/logging.lua",
            "desktop/base.lua",
            "desktop/pointing.lua",
            "desktop/input.lua",
            "desktop/keyboard.lua",
            "desktop/errors.lua",
            "desktop/policy.lua",
        ]
        .into_iter()
        .map(|path| root.join("etc/xdg/lunette").join(path))
        .collect(),
    );
    let report =
        analyze::check(&request).unwrap_or_else(|error| panic!("desktop checker: {error}"));
    assert!(
        report.skipped(&request).is_empty(),
        "requested modules skipped"
    );
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
