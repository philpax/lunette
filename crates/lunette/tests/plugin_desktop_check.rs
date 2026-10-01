//! Strict checking of the shipped configuration and the desktop root it composes,
//! in a checker-only binary.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn shipped_desktop_composition_is_strictly_typed() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        std::iter::once(root.join("etc/xdg/lunette/main.lua"))
            .chain(
                [
                    "init.lua",
                    "compose.lua",
                    "logging.lua",
                    "base.lua",
                    "pointing.lua",
                    "input.lua",
                    "keyboard.lua",
                    "errors.lua",
                    "policy.lua",
                ]
                .into_iter()
                .map(|path| root.join("lua/lunette-desktop").join(path)),
            )
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
