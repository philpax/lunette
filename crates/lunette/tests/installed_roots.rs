//! The installed roots do not require a development-only root.
//!
//! `@spec` exists only in a source tree, so a shipped module requiring it would
//! check clean and fail in every installed session. The test refuses any
//! string literal naming a non-installed root in the installed roots and the
//! shipped configuration. Both lists come from `lunette::aliases`.

use std::{
    fs,
    path::{Path, PathBuf},
};

use lunette::aliases::{DEVELOPMENT_ALIASES, INSTALLED_ALIASES, Resolution, install_manifest};

/// The shipped configuration, which an installation runs and which is not a
/// module root.
const SHIPPED_CONFIGURATION: &str = "etc/xdg/lunette";

#[test]
fn no_installed_root_requires_a_development_only_root() {
    let development_only: Vec<String> = DEVELOPMENT_ALIASES
        .iter()
        .filter(|alias| !INSTALLED_ALIASES.contains(alias))
        .map(|alias| format!("@{}", alias.name))
        .collect();
    assert!(
        !development_only.is_empty(),
        "the spec root is development-only"
    );

    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut sources = Vec::new();
    for alias in INSTALLED_ALIASES
        .iter()
        .filter(|alias| alias.resolution == Resolution::Mounted)
    {
        let installed = format!("lua/{}", alias.directory);
        assert!(
            install_manifest()
                .lines()
                .any(|line| line.starts_with(&format!("{installed}\t"))),
            "{installed} is installed"
        );
        collect(&workspace.join(&installed), &mut sources);
    }
    collect(&workspace.join(SHIPPED_CONFIGURATION), &mut sources);
    assert!(!sources.is_empty(), "the installed roots hold Lua sources");

    let offenders: Vec<String> = sources
        .iter()
        .filter(|path| {
            let text = fs::read_to_string(path)
                .unwrap_or_else(|error| panic!("{} is readable: {error}", path.display()));
            development_only.iter().any(|root| {
                text.contains(&format!("'{root}/"))
                    || text.contains(&format!("\"{root}/"))
                    || text.contains(&format!("'{root}'"))
                    || text.contains(&format!("\"{root}\""))
            })
        })
        .map(|path| path.display().to_string())
        .collect();
    assert!(offenders.is_empty(), "{offenders:#?}");
}

/// Every `.luau` file under `directory`.
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
            .is_some_and(|extension| extension == "luau")
        {
            found.push(path);
        }
    }
}
