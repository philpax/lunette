//! Strict checking of the shipped configuration and the desktop root it composes,
//! in a checker-only binary.
use std::path::PathBuf;

use lunette_lovr::analyze::{self, Request};

#[test]
fn shipped_desktop_composition_is_strictly_typed() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        std::iter::once(root.join("etc/xdg/lunette/main.luau"))
            .chain(
                [
                    "init.luau",
                    "compose.luau",
                    "logging.luau",
                    "render.luau",
                    "monitors.luau",
                    "hint.luau",
                    "decorations.luau",
                    "pointing.luau",
                    "input.luau",
                    "bindings.luau",
                    "keyboard.luau",
                    "errors.luau",
                    "workspace.luau",
                    "rules.luau",
                    "pose-memory.luau",
                    "persistence.luau",
                    "arrange.luau",
                    "adoption.luau",
                    "demo-terminal.luau",
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

/// A typed patch is checked against its entry's options: each call in the
/// fixture carries one mistake, and each is reported on its own line.
#[test]
fn a_typed_patch_is_checked_against_its_entrys_options() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let fixture = root.join("crates/lunette/tests/plugin_desktop/configure_checked.luau");
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        vec![fixture.clone()],
    );
    let report =
        analyze::check(&request).unwrap_or_else(|error| panic!("desktop checker: {error}"));
    assert!(report.skipped(&request).is_empty());
    let mut lines = report
        .diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.module.ends_with("configure_checked.luau"))
        .map(|diagnostic| diagnostic.line)
        .collect::<Vec<_>>();
    lines.sort_unstable();
    lines.dedup();
    assert_eq!(
        lines,
        [8, 9, 10, 11, 12, 13, 14],
        "{:#?}",
        report.diagnostics
    );
}
