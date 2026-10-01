//! The shipped roots other than `@mullion` do not require it.
//!
//! `@mullion` is optional: an installation may leave it out, and a
//! configuration that never mentions it is supported. A built-in provider, a
//! contract, the plugin facade, the desktop, or the shipped configuration that
//! required it would make every installation without it fail to start. The
//! test reads the checked-in sources and refuses any string literal naming the
//! root, which is the form a `require` of it takes; a computed module name
//! would pass, and the shipped roots compute none.

use std::{
    fs,
    path::{Path, PathBuf},
};

/// The roots that must not depend on `@mullion`.
const ROOTS: [&str; 5] = [
    "lua/lunette-plugin",
    "lua/lunette-contracts",
    "lua/lunette-plugins",
    "lua/lunette-desktop",
    "etc/xdg/lunette",
];

#[test]
fn no_shipped_root_requires_the_optional_library() {
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut sources = Vec::new();
    for root in ROOTS {
        collect(&workspace.join(root), &mut sources);
    }
    assert!(!sources.is_empty(), "the shipped roots hold Lua sources");

    let offenders: Vec<String> = sources
        .iter()
        .filter(|path| {
            let text = fs::read_to_string(path)
                .unwrap_or_else(|error| panic!("{} is readable: {error}", path.display()));
            text.contains("'@mullion") || text.contains("\"@mullion")
        })
        .map(|path| path.display().to_string())
        .collect();
    assert!(offenders.is_empty(), "{offenders:#?}");
}

/// Every `.lua` and `.luau` file under `directory`.
fn collect(directory: &Path, found: &mut Vec<PathBuf>) {
    let entries = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{} is readable: {error}", directory.display()));
    for entry in entries {
        let path = entry
            .unwrap_or_else(|error| panic!("{} lists: {error}", directory.display()))
            .path();
        if path.is_dir() {
            collect(&path, found);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "lua" || extension == "luau")
        {
            found.push(path);
        }
    }
}
