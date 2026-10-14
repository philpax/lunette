//! Copies the install manifest into a temporary installation and loads every installed module
//! from it, with no development-only root reachable.

use std::{
    cell::RefCell,
    fs,
    path::{Component, Path, PathBuf},
    rc::Rc,
};

use libtest_mimic::Trial;
use lunette::aliases::{DEVELOPMENT_ALIASES, INSTALLED_ALIASES, Resolution, install_manifest};
use mlua::{Function, Lua, MultiValue, Table, Value};
use tempfile::TempDir;

use crate::{
    plugin_dependencies::{
        catalog::{CONTRACT_SCHEMAS, PLUGINS, REMOVED_HELPERS},
        ownership::public_plugin_files,
        scan::installed_scan,
    },
    state::{self, Roots},
};

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
    let report = installed_scan(installation.path())?;
    if report.diagnostics().next().is_some() {
        return Err(format!("installed roots: {report}").into());
    }
    if report.sources.is_empty() || report.observation_count == 0 {
        return Err("installed roots: dependency scan has no sources or imports".into());
    }
    reject_development_roots(&[roots.repository.join("etc/xdg/lunette")])?;
    require_every_module(installation.path(), &roots.repository)
}

/// Requires each installed module in a cold state, so missing dependencies and import-time
/// acquisitions fail through the same runtime resolver used by the other Lua trials.
fn require_every_module(
    installation: &Path,
    repository: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let lua = state::new(&Roots::of_repository(installation.to_path_buf()))?;
    let package = lua.globals().get::<Table>("package")?;
    let loaded = package.get::<Table>("loaded")?;
    if loaded.pairs::<Value, Value>().next().is_some() {
        return Err("installed roots: package.loaded is not cold before instrumentation".into());
    }
    let acquisitions = record_acquisitions(&lua, &package)?;
    if loaded.pairs::<Value, Value>().next().is_some() {
        return Err(
            "installed roots: instrumentation loads a module before the cold import".into(),
        );
    }
    let require = lua.globals().get::<Function>("require")?;
    for alias in INSTALLED_ALIASES
        .iter()
        .filter(|alias| alias.resolution == Resolution::Mounted)
    {
        let mut sources = Vec::new();
        collect_sources(&installation.join("lua").join(alias.name), &mut sources)?;
        for source in sources {
            let name = module_name(source.strip_prefix(installation)?)?;
            require
                .call::<Value>(name.as_str())
                .map_err(|error| format!("installed roots: {name}: {error}"))?;
        }
    }
    for path in public_plugin_files().into_iter().chain(
        CONTRACT_SCHEMAS
            .iter()
            .map(|schema| format!("lua/lunette-contracts/schemas/{schema}.luau")),
    ) {
        if !installation.join(&path).is_file() {
            return Err(format!("installed roots: declared public file {path} is missing").into());
        }
        let name = module_name(Path::new(&path))?;
        require
            .call::<Value>(name.as_str())
            .map_err(|error| format!("installed roots: public export {name}: {error}"))?;
    }
    if !acquisitions.borrow().is_empty() {
        return Err(format!(
            "installed roots: import-time resource acquisitions: {}",
            acquisitions.borrow().join(", ")
        )
        .into());
    }
    for plugin in PLUGINS
        .iter()
        .filter(|plugin| plugin.previous != plugin.leaf)
    {
        require_missing(&require, &format!("@lunette-plugins/{}", plugin.previous))?;
    }
    for helper in REMOVED_HELPERS {
        require_missing(&require, &format!("@lunette-plugins/{helper}"))?;
    }
    state::use_configuration(&lua, installation.to_path_buf())?;
    require_development_unreachable(&require, installation, repository)?;
    Ok(())
}

fn module_name(path: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let relative = path.strip_prefix("lua")?;
    let module = if relative.file_stem().is_some_and(|stem| stem == "init") {
        relative.parent().map(Path::to_path_buf).unwrap_or_default()
    } else {
        relative.with_extension("")
    };
    Ok(format!("@{}", module.display()))
}

/// Records attempted effects even when a module catches the fail-on-use error.
/// Native declarations remain real; a runtime cannot start and obtain an effect-owning context.
fn record_acquisitions(lua: &Lua, package: &Table) -> mlua::Result<Rc<RefCell<Vec<String>>>> {
    let acquisitions = Rc::new(RefCell::new(Vec::new()));
    let preload = package.get::<Table>("preload")?;
    let native = preload.get::<Function>("@lunette")?.call::<Table>(())?;
    preload.raw_remove("@testing/host")?;
    // The resource constructors and subscriptions are declared in src/lua/mod.rs and src/events.
    for name in [
        "spawn",
        "openAudio",
        "selectMonitors",
        "claimLayer",
        "newSeat",
        "newOutput",
        "onError",
        "onWindowOpened",
        "onWindowClosed",
        "onMonitorAdded",
        "onProcessExited",
        "onProcessOutput",
    ] {
        native.set(
            name,
            fail_acquisition(lua, &acquisitions, &format!("lunette.{name}"))?,
        )?;
    }
    native.get::<Table>("plugin")?.set(
        "runtime",
        fail_acquisition(lua, &acquisitions, "lunette.plugin.runtime")?,
    )?;
    let lovr = lua.globals().get::<Table>("lovr")?;
    let graphics = lua.create_table()?;
    // Mesh/shader acquisition lives in graphics libraries, panels, laser, and backdrop;
    // theme/resolver acquires fonts, including the lazily created default font.
    for name in ["newMesh", "newShader", "newFont", "getDefaultFont"] {
        graphics.set(
            name,
            fail_acquisition(lua, &acquisitions, &format!("lovr.graphics.{name}"))?,
        )?;
    }
    lovr.set("graphics", graphics)?;
    let filesystem = lua.create_table()?;
    // Persistence reads and writes only after activation, never when its files are imported.
    for name in ["getSaveDirectory", "read", "write"] {
        filesystem.set(
            name,
            fail_acquisition(lua, &acquisitions, &format!("lovr.filesystem.{name}"))?,
        )?;
    }
    lovr.set("filesystem", filesystem)?;
    Ok(acquisitions)
}

fn fail_acquisition(
    lua: &Lua,
    acquisitions: &Rc<RefCell<Vec<String>>>,
    name: &str,
) -> mlua::Result<Function> {
    let acquisitions = Rc::clone(acquisitions);
    let name = name.to_owned();
    lua.create_function(move |_, _: MultiValue| {
        acquisitions.borrow_mut().push(name.clone());
        Err::<(), _>(mlua::Error::runtime(format!(
            "installed roots: import-time acquisition through {name}"
        )))
    })
}

fn require_missing(require: &Function, name: &str) -> Result<(), Box<dyn std::error::Error>> {
    match require.call::<Value>(name) {
        Err(error)
            if error
                .to_string()
                .contains(&format!("module '{name}' not found under")) =>
        {
            Ok(())
        }
        Err(error) => {
            Err(format!("installed roots: {name} did not fail resolution: {error}").into())
        }
        Ok(_) => Err(format!("installed roots: unexpected reachable module {name}").into()),
    }
}

fn require_development_unreachable(
    require: &Function,
    installation: &Path,
    repository: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    for alias in DEVELOPMENT_ALIASES
        .iter()
        .filter(|alias| !INSTALLED_ALIASES.contains(alias))
    {
        if installation.join("lua").join(alias.name).exists() {
            return Err(format!(
                "installed roots: development root {} is installed",
                alias.name
            )
            .into());
        }
        require_missing(require, &format!("@{}", alias.name))?;
        let mut sources = Vec::new();
        collect_sources(&repository.join("lua").join(alias.name), &mut sources)?;
        for source in sources {
            require_missing(require, &module_name(source.strip_prefix(repository)?)?)?;
        }
    }
    let mut sources = Vec::new();
    collect_sources(&repository.join("dev"), &mut sources)?;
    collect_sources(&repository.join("lua"), &mut sources)?;
    for source in sources.iter().filter(|source| {
        source.starts_with(repository.join("dev"))
            || source.components().any(|part| part.as_os_str() == "tests")
    }) {
        let relative = source.strip_prefix(repository)?;
        if installation.join(relative).exists() {
            return Err(format!(
                "installed roots: development file {} is installed",
                relative.display()
            )
            .into());
        }
        let name = if relative.starts_with("lua") {
            module_name(relative)?
        } else {
            relative.with_extension("").display().to_string()
        };
        require_missing(require, &name)?;
    }
    Ok(())
}

/// Fails when the shipped configuration names a root that an installation lacks.
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
