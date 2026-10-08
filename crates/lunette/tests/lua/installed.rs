//! Loads public UI, menu, keyboard-display, and theme modules from installed manifest copies.
//! Checks that the bundled theme font and licence are copied without changing their bytes.

use std::{
    fs,
    path::{Component, Path},
};

use libtest_mimic::Trial;
use lunette::aliases::install_manifest;
use tempfile::TempDir;

use crate::state::{self, Roots};

pub fn trial(roots: Roots) -> Trial {
    Trial::test(
        "runner::ui_modules_load_from_installed_manifest_roots",
        move || load(&roots).map_err(|error| error.to_string().into()),
    )
}

fn load(roots: &Roots) -> Result<(), Box<dyn std::error::Error>> {
    let installation = TempDir::with_prefix("lunette-ui-load-")?;
    for line in install_manifest().lines() {
        let (source, destination) = line
            .split_once('\t')
            .ok_or("install manifest: missing destination")?;
        let destination = Path::new(destination);
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
    }
    for asset in [
        "lua/lunette-plugins/theme/fonts/SpaceMono-Regular.ttf",
        "lua/lunette-plugins/theme/fonts/OFL.txt",
    ] {
        let repository = fs::read(roots.repository.join(asset))?;
        let installed = fs::read(installation.path().join(asset))?;
        if installed.is_empty() || installed != repository {
            return Err(format!(
                "installed roots: asset is empty or differs from the repository: {asset}"
            )
            .into());
        }
    }
    let installed = Roots::of_repository(installation.path().to_path_buf());
    let lua = state::new(&installed)?;
    lua.load(
        "local ui = require '@lunette-contracts/ui'
         local implementation = require '@lunette-plugins/ui'
         assert(ui.capability ~= nil and implementation.definition ~= nil)
         local generation: ui.Generation = table.freeze { kind = 'ui-generation' }
         assert(generation.kind == 'ui-generation')
         local menu = require '@lunette-contracts/menu'
         local menuProvider = require '@lunette-plugins/menu'
         assert(menu.capability ~= nil and menuProvider.definition ~= nil)
         local display = require '@lunette-contracts/keyboard-display'
         local displayProvider = require '@lunette-plugins/desktop/keyboard'
         assert(display.capability ~= nil and displayProvider ~= nil)
         local theme = require '@lunette-contracts/theme'
         local themeProvider = require '@lunette-plugins/theme'
         assert(theme.capability ~= nil and themeProvider.definition ~= nil)
         local themeSelector = require '@lunette-plugins/desktop/theme'
         assert(themeSelector ~= nil)
         assert(require('@lunette').textBoundaries('é')[2] == 4)",
    )
    .set_name("@installed-ui-main.luau")
    .exec()?;
    let testing: Result<mlua::Value, mlua::Error> = lua.load("return require '@testing'").eval();
    if testing.is_ok() {
        return Err("installed roots: testing unexpectedly loads".into());
    }
    if installation
        .path()
        .join("lua/lunette-plugins/ui/tests")
        .exists()
    {
        return Err("installed roots: UI tests were copied".into());
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
