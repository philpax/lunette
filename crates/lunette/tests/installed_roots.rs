//! Installed modules and the shipped configuration do not require development roots.
//!
//! Test modules are excluded from installation. The test compares source aliases
//! against the development and installed root lists in `lunette::aliases`.

use std::{
    fs,
    path::{Path, PathBuf},
};

use lunette::aliases::{DEVELOPMENT_ALIASES, INSTALLED_ALIASES, Resolution, install_manifest};

/// The shipped configuration directory.
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
        "the testing root is development-only"
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

#[test]
fn development_configuration_and_plugins_stay_out_of_installation() {
    let manifest = install_manifest();
    for line in manifest.lines() {
        let (source, destination) = line.split_once('\t').unwrap_or_else(|| {
            panic!("install manifest line has a source and destination: {line}")
        });
        assert!(!source.starts_with("dev/"), "{source} is development-only");
        assert!(
            !destination.starts_with("dev/"),
            "{destination} is development-only"
        );
    }
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    assert!(
        workspace.join("dev/main.luau").is_file(),
        "the development configuration exists"
    );
    assert!(
        !workspace
            .join("lua/lunette-plugins/desktop/demo-terminal")
            .exists(),
        "the demonstration terminal is not in an installed module root"
    );
}

/// Collects installed `.luau` files outside `tests` directories.
fn collect(directory: &Path, found: &mut Vec<PathBuf>) {
    let entries = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{} is readable: {error}", directory.display()));
    for entry in entries {
        let path = entry
            .unwrap_or_else(|error| panic!("{} lists: {error}", directory.display()))
            .path();
        if path.is_dir() {
            if path.file_name().is_some_and(|name| name == "tests") {
                continue;
            }
            collect(&path, found);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "luau")
        {
            found.push(path);
        }
    }
}
