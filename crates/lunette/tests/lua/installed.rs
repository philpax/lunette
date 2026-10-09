//! Copies the install manifest into a temporary installation, then loads every installed
//! module from it and checks that no installed source or the shipped configuration requires
//! a development-only root. `luau_check.rs` typechecks a configuration against the same
//! copy, because the checker changes process-wide Luau state that later Lua states inherit.

use std::{
    fs,
    path::{Component, Path, PathBuf},
};

use libtest_mimic::Trial;
use lunette::aliases::{DEVELOPMENT_ALIASES, INSTALLED_ALIASES, Resolution, install_manifest};
use tempfile::TempDir;

use crate::state::{self, Roots};

pub fn trial(roots: Roots) -> Trial {
    Trial::test(
        "runner::installed_roots_load_without_development_roots",
        move || load(&roots).map_err(|error| error.to_string().into()),
    )
}

fn load(roots: &Roots) -> Result<(), Box<dyn std::error::Error>> {
    let installation = TempDir::with_prefix("lunette-installed-")?;
    for (source, destination) in install_manifest() {
        let destination = Path::new(&destination);
        if destination.as_os_str().is_empty()
            || destination
                .components()
                .any(|component| !matches!(component, Component::Normal(_)))
        {
            return Err(format!(
                "install manifest: destination is not a safe relative path: {}",
                destination.display()
            )
            .into());
        }
        let source = roots.repository.join(source);
        let destination = installation.path().join(destination);
        if source.is_dir() {
            copy_modules(&source, &destination)?;
        } else {
            copy_file(&source, &destination)?;
        }
        if !destination.exists() {
            return Err(format!(
                "installed roots: {} was not installed",
                destination.display()
            )
            .into());
        }
    }
    reject_development_roots(&[
        installation.path().join("lua"),
        roots.repository.join("etc/xdg/lunette"),
    ])?;
    require_every_module(installation.path())
}

/// Requires each module under the installed file-backed roots, so a module the manifest
/// misses fails whichever module reaches for it.
fn require_every_module(installation: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let lua = state::new(&Roots::of_repository(installation.to_path_buf()))?;
    let require = lua.globals().get::<mlua::Function>("require")?;
    for alias in INSTALLED_ALIASES
        .iter()
        .filter(|alias| alias.resolution == Resolution::Mounted)
    {
        let root = installation.join("lua").join(alias.name);
        let mut sources = Vec::new();
        collect_sources(&root, &mut sources)?;
        for source in sources {
            let relative = source.strip_prefix(&root)?;
            let module = if relative.file_stem().is_some_and(|stem| stem == "init") {
                relative.parent().map(Path::to_path_buf).unwrap_or_default()
            } else {
                relative.with_extension("")
            };
            let name = if module.as_os_str().is_empty() {
                format!("@{}", alias.name)
            } else {
                format!("@{}/{}", alias.name, module.display())
            };
            require
                .call::<mlua::Value>(name.as_str())
                .map_err(|error| format!("installed roots: {name}: {error}"))?;
        }
    }
    Ok(())
}

/// Typechecks a configuration beside the installation, with the aliases `--dump-config`
/// writes and the installed definitions.
/// Fails when an installed source or the shipped configuration names a root that an
/// installation lacks.
fn reject_development_roots(directories: &[PathBuf]) -> Result<(), Box<dyn std::error::Error>> {
    let development_only: Vec<String> = DEVELOPMENT_ALIASES
        .iter()
        .filter(|alias| !INSTALLED_ALIASES.contains(alias))
        .map(|alias| format!("@{}", alias.name))
        .collect();
    let mut sources = Vec::new();
    for directory in directories {
        collect_sources(directory, &mut sources)?;
    }
    for path in sources {
        let text = fs::read_to_string(&path)?;
        if development_only.iter().any(|root| {
            text.contains(&format!("'{root}/"))
                || text.contains(&format!("\"{root}/"))
                || text.contains(&format!("'{root}'"))
                || text.contains(&format!("\"{root}\""))
        }) {
            return Err(format!(
                "installed roots: {} requires a development-only root",
                path.display()
            )
            .into());
        }
    }
    Ok(())
}

/// Every `.luau` file under `directory`, in path order.
fn collect_sources(
    directory: &Path,
    found: &mut Vec<PathBuf>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut entries = fs::read_dir(directory)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<_>, _>>()?;
    entries.sort();
    for path in entries {
        if path.is_dir() {
            collect_sources(&path, found)?;
        } else if path
            .extension()
            .is_some_and(|extension| extension == "luau")
        {
            found.push(path);
        }
    }
    Ok(())
}

fn copy_modules(source: &Path, destination: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if source.is_dir() {
        fs::create_dir_all(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            if entry.file_name() != "tests" {
                copy_modules(&entry.path(), &destination.join(entry.file_name()))?;
            }
        }
    } else if source
        .extension()
        .is_some_and(|extension| extension == "luau")
    {
        copy_file(source, destination)?;
    }
    Ok(())
}

fn copy_file(source: &Path, destination: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, destination)?;
    Ok(())
}
