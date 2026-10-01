//! Registers the checked-in Lua roots as module loaders for a test state, so a
//! harness lists only its own fakes and fixtures.

use std::{fs, path::Path};

use mlua::{Lua, Table};

/// The roots registered, and the alias each one resolves under.
const ROOTS: [(&str, &str); 4] = [
    ("lua/lunette-plugin", "@lunette-plugin"),
    ("lua/lunette-contracts", "@lunette-contracts"),
    ("lua/lunette-plugins", "@lunette-plugins"),
    ("lua/lunette-desktop", "@lunette-desktop"),
];

/// Sets a loader in `loaders` for every Lua module under the shipped roots,
/// with an `init.luau` named for its directory.
pub fn register(lua: &Lua, loaders: &Table) -> mlua::Result<()> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for (directory, alias) in ROOTS {
        register_directory(lua, loaders, &root.join(directory), alias)?;
    }
    Ok(())
}

/// Sets a loader for every Lua module under `directory`, named under `prefix`.
pub fn register_directory(
    lua: &Lua,
    loaders: &Table,
    directory: &Path,
    prefix: &str,
) -> mlua::Result<()> {
    for entry in fs::read_dir(directory).map_err(mlua::Error::external)? {
        let path = entry.map_err(mlua::Error::external)?.path();
        let stem = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .ok_or_else(|| mlua::Error::external("module name is not utf8"))?;
        let name = if prefix.is_empty() {
            stem.to_owned()
        } else {
            format!("{prefix}/{stem}")
        };
        if path.is_dir() {
            register_directory(lua, loaders, &path, &name)?;
        } else if path
            .extension()
            .is_some_and(|extension| extension == "luau")
        {
            let name = if stem == "init" { prefix } else { &name };
            let source = fs::read_to_string(&path).map_err(mlua::Error::external)?;
            loaders.set(
                name,
                lua.load(&source)
                    .set_name(path.to_string_lossy())
                    .into_function()?,
            )?;
        }
    }
    Ok(())
}
