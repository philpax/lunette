//! The checker resolves the relative-require fixture the way the session does.
//!
//! `exit_status.rs` runs the same fixture in a session. Each module there
//! answers where it is as a singleton type, so a require the checker resolved
//! to another file is a type error here.

use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn the_checker_resolves_relative_requires_against_the_requiring_file() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/require-relative/lunette");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![fixture.join("main.lua")],
    );
    let report =
        analyze::check(&request).unwrap_or_else(|error| panic!("require-relative: {error}"));
    assert!(report.skipped(&request).is_empty());
    assert!(report.diagnostics.is_empty(), "{:#?}", report.diagnostics);
}
