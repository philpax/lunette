//! Generates the Luau definitions the type checker loads.
//!
//! Runs lovr-docs' `generators/luau.lua` against the pinned lovr-docs
//! `api/init.lua` using the Luau embedded in LÖVR, splices in what lovr-docs
//! does not describe, and writes `etc/lunette/definitions.luau`.
//!
//! This executes the literal lovr-docs generator rather than porting it, so
//! the definitions cannot diverge from the metadata. The generator is
//! standalone: it reads its `api` argument (the aggregated table from
//! `api/init.lua`), builds an `out` table, and writes it to
//! `lovr.filesystem.getSource() .. '/luau/lovr.d.luau'`. This driver supplies
//! the two `lovr` globals it touches, points `getSource` at a temporary
//! directory, runs the generator, and reads the file it wrote.
//!
//! `--check` generates into memory and compares against what is checked in,
//! reporting the first line that differs and exiting non-zero. CONTRIBUTING.md
//! requires a generated document to be verified rather than remembered, and
//! this is what verifies these two.

use std::{
    env, fs,
    path::{Path, PathBuf},
    process::ExitCode,
};

use mlua::{Lua, Table};
use tracing::{error, info};

/// The generator's own name, and the metadata it reads.
const GENERATOR: &str = "vendor/lovr-docs/api/generators/luau.lua";
const METADATA: &str = "vendor/lovr-docs/api/init.lua";
/// What the checker loads: the generated definitions, plus what lovr-docs does
/// not describe.
const CHECKER_DEFINITIONS: &str = "etc/lunette/definitions.luau";

/// What the checker needs that lovr-docs does not describe.
///
/// Luau registers the standard functions itself, correctly typed, so declaring
/// them here would replace good types with `any`. There is no `io` at all: the
/// runtime has none, and declaring one hid four calls that failed whenever they
/// were reached.
const FORK_GLOBALS: &str = "
-- The shipped configuration sets this once, deliberately, to remember that the
-- demonstration window was already spawned across soft reloads. Written through
-- `_G` so the assignment is visible to the checker.
declare _G: {
    lunetteDemonstrationSpawned: boolean,
    -- Anything else a configuration leaves on the global table.
    [string]: any,
}

";

/// The fields lunette adds to the `lovr` table at boot (the custom event
/// callbacks from `etc/boot.lua`), which lovr-docs does not know. They are
/// spliced into the generated `declare lovr` table.
///
/// Optional, as every LÖVR callback is: nothing sets one by default, and a
/// configuration defines the handlers it wants. Each takes the event table the
/// dispatcher pushes, which carries the handle under a field rather than being
/// the handle itself.
const LUNETTE_LOVR_FIELDS: &str = "    lun: ((name: string, ...any) -> ())?,
    lunerror: ((error: any) -> ())?,
    lunlayergranted: ((event: any) -> ())?,
    lunprocessexited: ((event: any) -> ())?,
    lunwindowclosed: ((event: any) -> ())?,
    lunwindowopened: ((event: any) -> ())?,
";

fn main() -> ExitCode {
    // Diagnostics go to stderr, so that a caller redirecting stdout gets
    // nothing it did not ask for. Neither mode writes to stdout.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .without_time()
        .with_target(false)
        .init();

    let checking = env::args().any(|argument| argument == "--check");

    match run(checking) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(error) => {
            error!("{error}");
            ExitCode::FAILURE
        }
    }
}

/// Generates both files, and either writes them or compares them.
///
/// Answers whether the run is a success. A comparison that differs is a
/// failure; a write always succeeds or returns the error that stopped it.
fn run(checking: bool) -> Result<bool, Box<dyn std::error::Error>> {
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

    // The generator writes to the filesystem rather than returning its output.
    let generator = fs::read_to_string(root.join(GENERATOR))?;
    let generator_fn: mlua::Function = lua
        .load(&generator)
        .set_name("@lovr-docs/generators/luau.lua")
        .eval()?;

    generator_fn.call::<()>(&api)?;

    // The generator wrote to getSource()/luau/lovr.d.luau. Discover where
    // getSource pointed.
    let lovr: Table = lua.globals().get("lovr")?;
    let filesystem: Table = lovr.get("filesystem")?;
    let get_source: mlua::Function = filesystem.get("getSource")?;
    let source_dir: String = get_source.call(())?;
    let generated = PathBuf::from(source_dir).join("luau").join("lovr.d.luau");
    let text = fs::read_to_string(&generated)?;

    let definitions = format!("{FORK_GLOBALS}\n{}", with_lunette_fields(&text)?);

    if checking {
        let current = compare(&root.join(CHECKER_DEFINITIONS), &definitions)?;

        if current {
            info!("the generated definitions are up to date");
        } else {
            error!("run `cargo run -p lunette-generate-definitions` and commit the result");
        }

        return Ok(current);
    }

    fs::create_dir_all(root.join("etc/lunette"))?;
    fs::write(root.join(CHECKER_DEFINITIONS), &definitions)?;
    info!(
        path = %root.join(CHECKER_DEFINITIONS).display(),
        bytes = definitions.len(),
        "wrote"
    );

    Ok(true)
}

/// Compares a checked-in file against what the generator produced.
///
/// Reports the first line that differs, with its number, so that a stale file
/// says what changed rather than only that something did. A file that is
/// missing entirely is reported as such.
fn compare(path: &Path, generated: &str) -> Result<bool, Box<dyn std::error::Error>> {
    let Ok(current) = fs::read_to_string(path) else {
        error!(path = %path.display(), "the file is not there");
        return Ok(false);
    };

    if current == generated {
        return Ok(true);
    }

    let difference = current
        .lines()
        .zip(generated.lines())
        .enumerate()
        .find(|(_, (left, right))| left != right);

    match difference {
        Some((index, (current_line, generated_line))) => error!(
            path = %path.display(),
            line = index + 1,
            holds = current_line,
            wants = generated_line,
            "the file is stale"
        ),
        None => error!(
            path = %path.display(),
            holds = current.lines().count(),
            wants = generated.lines().count(),
            "the file is stale, and the two differ in length"
        ),
    }

    Ok(false)
}

/// Provides the small `lovr` surface the generator touches: `filesystem.getSource`
/// pointing at a temporary output directory, and `system.getOS` saying Linux.
fn install_generator_globals(lua: &Lua) -> mlua::Result<()> {
    let out_dir = std::env::temp_dir().join("lovr-docs-generator");
    fs::create_dir_all(&out_dir).map_err(mlua::Error::external)?;

    let globals = lua.globals();
    let lovr = lua.create_table()?;

    let filesystem = lua.create_table()?;
    let get_source =
        lua.create_function(move |_, ()| Ok(out_dir.to_string_lossy().into_owned()))?;
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

/// Splices lunette's own `lovr` fields into the generated table.
///
/// A second `declare lovr` block does not merge with the first, it replaces it,
/// so the fields have to go inside the one the generator wrote. The closing
/// brace is the first line that is a brace alone after the block opens.
fn with_lunette_fields(text: &str) -> Result<String, Box<dyn std::error::Error>> {
    let opens = text
        .find("declare lovr: {")
        .ok_or("the generated definitions declare no lovr table")?;
    let closes = text[opens..]
        .find("\n}\n")
        .ok_or("the generated lovr table is not closed")?
        + opens
        + 1;

    let mut spliced = String::with_capacity(text.len() + LUNETTE_LOVR_FIELDS.len());
    spliced.push_str(&text[..closes]);
    spliced.push_str(LUNETTE_LOVR_FIELDS);
    spliced.push_str(&text[closes..]);
    Ok(spliced)
}
