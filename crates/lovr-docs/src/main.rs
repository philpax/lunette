//! Runs lovr-docs' `generators/luau.lua` against the pinned lovr-docs
//! `api/init.lua` using the Luau embedded in LÖVR, and writes the generated
//! `lovr.d.luau` to `etc/lunette/`.
//!
//! This executes the literal lovr-docs generator rather than porting it, so
//! the definitions cannot diverge from the metadata. The generator is
//! standalone: it reads its `api` argument (the aggregated table from
//! `api/init.lua`), builds an `out` table, and writes it to
//! `lovr.filesystem.getSource() .. '/luau/lovr.d.luau'`. This driver supplies
//! the two `lovr` globals it touches, points `getSource` at a temporary
//! directory, runs the generator, and reads the file it wrote.

use std::{
    fs,
    path::{Path, PathBuf},
};

use mlua::{Lua, Table};

/// The generator's own name, and the file it writes.
const GENERATOR: &str = "vendor/lovr-docs/api/generators/luau.lua";
const METADATA: &str = "vendor/lovr-docs/api/init.lua";
const OUTPUT: &str = "etc/lunette/lovr.d.luau";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The workspace root, relative to CARGO_MANIFEST_DIR (crates/lovr-docs).
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let root = root.canonicalize()?;

    let lua = Lua::new();

    install_generator_globals(&lua)?;

    // Load the aggregated API metadata into `api`.
    let metadata = fs::read_to_string(root.join(METADATA))?;
    let api: Table = lua
        .load(&metadata)
        .set_name("@lovr-docs/api/init.lua")
        .eval()?;

    // Run the generator. Its `out` table is returned? No — the generator writes
    // to the filesystem; run it and read the file back.
    let generator = fs::read_to_string(root.join(GENERATOR))?;
    let generator_fn: mlua::Function = lua
        .load(&generator)
        .set_name("@lovr-docs/generators/luau.lua")
        .eval()?;

    generator_fn.call::<()>(api)?;

    // The generator wrote to getSource()/luau/lovr.d.luau. Discover where
    // getSource pointed.
    let lovr: Table = lua.globals().get("lovr")?;
    let filesystem: Table = lovr.get("filesystem")?;
    let get_source: mlua::Function = filesystem.get("getSource")?;
    let source_dir: String = get_source.call(())?;
    let generated = PathBuf::from(source_dir).join("luau").join("lovr.d.luau");
    let text = fs::read_to_string(&generated)?;
    let text_len = text.len();

    fs::create_dir_all(root.join("etc/lunette"))?;
    fs::write(root.join(OUTPUT), text)?;
    println!("wrote {} ({} bytes)", root.join(OUTPUT).display(), text_len);

    Ok(())
}

/// Provides the small `lovr` surface the generator touches: `filesystem.getSource`
/// pointing at a temporary output directory, and `system.getOS` saying Linux.
fn install_generator_globals(lua: &Lua) -> mlua::Result<()> {
    let out_dir = std::env::temp_dir().join("lovr-docs-generator");
    fs::create_dir_all(&out_dir).map_err(mlua::Error::external)?;

    let globals = lua.globals();
    let lovr = lua.create_table()?;

    let filesystem = lua.create_table()?;
    let get_source = lua.create_function(move |_, ()| Ok(out_dir.to_string_lossy().into_owned()))?;
    filesystem.set("getSource", get_source)?;
    lovr.set("filesystem", filesystem)?;

    let system = lua.create_table()?;
    let get_os = lua.create_function(|_, ()| Ok("Linux".to_string()))?;
    system.set("getOS", get_os)?;
    lovr.set("system", system)?;

    globals.set("lovr", lovr)?;

    // The generator makes its output directory via `os.execute` and writes the
    // definitions through `io.open`. mlua's safe environment exposes neither,
    // so provide minimal versions: `os.execute` runs `mkdir -p` for the given
    // path, and `io.open(path, 'w')` writes with Rust and returns a handle
    // whose `write`/`close` append to it. The generator calls
    // `file:write(table.concat(out))` once and `file:close()`.
    let os_table = lua.create_table()?;
    let os_execute = lua.create_function(|_, command: String| {
        let status = std::process::Command::new("sh")
            .arg("-c")
            .arg(&command)
            .status()
            .map_err(mlua::Error::external)?;
        Ok(status.code().unwrap_or(1))
    })?;
    os_table.set("execute", os_execute)?;
    globals.set("os", os_table)?;

    let io_open = lua.create_function(|lua, (path, _mode): (String, String)| {
        if let Some(parent) = Path::new(&path).parent() {
            let _ = fs::create_dir_all(parent);
        }
        // The generator writes the whole output in one `write`, so buffer it
        // and flush on `close`.
        let buffer = std::rc::Rc::new(std::cell::RefCell::new(String::new()));
        let handle = lua.create_table()?;
        let write_buf = std::rc::Rc::clone(&buffer);
        // Colon-call: `file:write(x)` passes the handle as the first argument,
        // so the closure receives `(_self, text)`.
        let write = lua.create_function(move |_, (_self, text): (mlua::Table, String)| {
            write_buf.borrow_mut().push_str(&text);
            Ok(())
        })?;
        handle.set("write", write)?;
        let flush_buf = std::rc::Rc::clone(&buffer);
        let close_path = path.clone();
        let close = lua.create_function(move |_, (_self,): (mlua::Table,)| {
            std::fs::write(&close_path, flush_buf.borrow().as_bytes())
                .map_err(mlua::Error::external)?;
            Ok(())
        })?;
        handle.set("close", close)?;
        Ok(handle)
    })?;
    let io_table = lua.create_table()?;
    io_table.set("open", io_open)?;
    globals.set("io", io_table)?;

    Ok(())
}