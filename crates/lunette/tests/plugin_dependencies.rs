//! Checks resolved production imports against plugin ownership boundaries.

use std::{
    collections::BTreeSet,
    error::Error,
    fs,
    path::{Path, PathBuf},
};

use lunette_lovr::analyze::{self, Request};

#[test]
fn production_imports_respect_plugin_ownership() -> Result<(), Box<dyn Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()?;
    let mut directories: Vec<_> = [
        "lua/lunette",
        "lua/lunette-plugin",
        "lua/lunette-contracts",
        "lua/lunette-plugins",
        "lua/lunette-desktop",
        "etc/xdg/lunette",
        "examples",
        "dev",
    ]
    .into_iter()
    .map(|path| root.join(path))
    .collect();
    let mut sources = BTreeSet::new();
    while let Some(directory) = directories.pop() {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let path = entry.path();
            if entry.file_type()?.is_symlink() || entry.file_name() == "tests" {
                continue;
            }
            if path.is_dir() {
                directories.push(path);
            } else if path
                .extension()
                .is_some_and(|extension| extension == "luau")
            {
                sources.insert(path.canonicalize()?);
            }
        }
    }
    let request = Request::new(
        Some(root.join("etc/lunette/definitions.luau")),
        sources.iter().cloned().collect(),
    );
    let report = analyze::check(&request)?;
    assert!(report.is_clean(), "{:?}", report.diagnostics);
    assert!(report.skipped(&request).is_empty(), "skipped source roots");
    let mut leaves = BTreeSet::new();
    for source in &sources {
        let path = source.strip_prefix(&root)?;
        if path.starts_with("lua/lunette-plugins") && path.ends_with("init.luau") {
            leaves.insert(path.with_file_name(""));
        }
    }
    for edge in report.dependencies {
        let source = edge.source.canonicalize()?;
        let target = edge.target.canonicalize()?;
        let source = source.strip_prefix(&root)?;
        let target = target.strip_prefix(&root)?;
        assert!(
            allowed(&leaves, source, target),
            "unsupported production import: {source:?} -> {target:?}"
        );
    }
    Ok(())
}

fn allowed(leaves: &BTreeSet<PathBuf>, source: &Path, target: &Path) -> bool {
    let source_owner = leaves.iter().find(|owner| source.starts_with(owner));
    let target_owner = leaves.iter().find(|owner| target.starts_with(owner));
    let shipped = source.starts_with("lua") || source.starts_with("etc/xdg/lunette");
    if target.components().any(|part| part.as_os_str() == "tests")
        || shipped && (target.starts_with("dev") || target.starts_with("lua/testing"))
    {
        return false;
    }
    let neutral = ["lua/lunette", "lua/lunette-plugin", "lua/lunette-contracts"]
        .iter()
        .any(|root| source.starts_with(root));
    let plugin_source = source.starts_with("lua/lunette-plugins");
    let library = plugin_source && source_owner.is_none();
    if neutral && target.starts_with("lua/lunette-plugins")
        || (neutral || plugin_source) && target.starts_with("lua/lunette-desktop")
        || library && target_owner.is_some()
    {
        return false;
    }
    let Some(owner) = target_owner else {
        return !target.starts_with("lua/lunette-plugins")
            || matches!(
                target.to_str(),
                Some(
                    "lua/lunette-plugins/diagnostics/protected-call.luau"
                        | "lua/lunette-plugins/diagnostics/desktop-logging.luau"
                        | "lua/lunette-plugins/graphics/pass-state.luau"
                        | "lua/lunette-plugins/graphics/client-pixels.luau"
                        | "lua/lunette-plugins/graphics/rounded-geometry.luau"
                        | "lua/lunette-plugins/graphics/rounded-drawing.luau"
                        | "lua/lunette-plugins/registration/listeners.luau"
                        | "lua/lunette-plugins/registration/registry.luau"
                        | "lua/lunette-plugins/lifecycle/cleanup.luau"
                        | "lua/lunette-plugins/interaction/picking.luau"
                        | "lua/lunette-plugins/theme/base.luau"
                        | "lua/lunette-plugins/theme/configuration.luau"
                )
            );
    };
    if source_owner == Some(owner) {
        return true;
    }
    matches!(
        target.strip_prefix(owner).ok().and_then(Path::to_str),
        Some("init.luau" | "config.luau")
    ) || matches!(
        target.to_str(),
        Some(
            "lua/lunette-plugins/input/keyboard/hooks.luau"
                | "lua/lunette-plugins/input/keyboard/legend.luau"
                | "lua/lunette-plugins/layout/arc/geometry.luau"
        )
    )
}

#[test]
fn ownership_rejects_unknown_exports_and_shared_implementation_imports() {
    let keyboard = Path::new("lua/lunette-plugins/input/keyboard");
    let other = Path::new("lua/lunette-plugins/input/display/init.luau");
    let leaves = BTreeSet::from([keyboard.to_path_buf(), other.with_file_name("")]);
    let permits = |source: &Path, module: &str| allowed(&leaves, source, &keyboard.join(module));
    assert!(permits(other, "legend.luau"));
    assert!(permits(&keyboard.join("legend.luau"), "legend-bounds.luau"));
    assert!(!permits(other, "legend-bounds.luau"));
    assert!(!permits(other, "undocumented.luau"));
    let contract = Path::new("lua/lunette-contracts/keyboard.luau");
    let library = Path::new("lua/lunette-plugins/input/library.luau");
    assert!(!permits(contract, "init.luau"));
    assert!(!permits(library, "init.luau"));
    assert!(!allowed(&leaves, other, Path::new("lua/testing/init.luau")));
    assert!(allowed(
        &leaves,
        other,
        Path::new("lua/lunette-plugins/graphics/pass-state.luau")
    ));
    assert!(!allowed(
        &leaves,
        other,
        Path::new("lua/lunette-plugins/graphics/undocumented.luau")
    ));
    assert!(!permits(
        Path::new("lua/lunette-plugin/adapter.luau"),
        "init.luau"
    ));
    assert!(!permits(Path::new("lua/lunette/init.luau"), "init.luau"));
    assert!(!allowed(
        &leaves,
        &keyboard.join("init.luau"),
        Path::new("lua/lunette-desktop/init.luau")
    ));
}
