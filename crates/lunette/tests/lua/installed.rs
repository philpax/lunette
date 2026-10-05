//! Loads the public UI contract and provider from files copied by the installation manifest.

use std::{fs, path::Path};

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
        copy(
            &roots.repository.join(source),
            &installation.path().join(destination),
        )?;
    }
    let installed = Roots::of_repository(installation.path().to_path_buf());
    let lua = state::new(&installed)?;
    lua.load(
        "local ui = require '@lunette-contracts/ui'
         local implementation = require '@lunette-plugins/ui'
         assert(ui.capability ~= nil and implementation.definition ~= nil)
         local generation: ui.Generation = table.freeze { kind = 'ui-generation' }
         assert(generation.kind == 'ui-generation')
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

fn copy(source: &Path, destination: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if source.is_dir() {
        fs::create_dir_all(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            if entry.file_name() != "tests" {
                copy(&entry.path(), &destination.join(entry.file_name()))?;
            }
        }
    } else if source
        .extension()
        .is_some_and(|extension| extension == "luau")
        || source
            .file_name()
            .is_some_and(|name| name == "installed.luaurc")
    {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(source, destination)?;
    }
    Ok(())
}
