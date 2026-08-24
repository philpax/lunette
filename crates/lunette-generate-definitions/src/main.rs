//! Generates the Luau artifacts the type checker loads.
//!
//! Runs the literal lovr-docs generator against the pinned per-file metadata in
//! `vendor/lovr-docs/api`, using the Luau embedded in LÖVR. This keeps the output
//! aligned with the metadata rather than a port of the generator. The driver
//! supplies the LÖVR and filesystem surfaces the aggregator needs, then combines
//! its output with lunette's declarations and generated alias files.
//!
//! Normal runs write the generated artifacts. `--check` keeps them in memory,
//! compares them with the checked-in files, reports the first differing line,
//! and exits non-zero when they are stale.

use std::{
    env, fs,
    path::{Path, PathBuf},
    process::ExitCode,
};

use mlua::{Lua, Table};
use tracing::{error, info};

/// The aggregator, and the directory it and its documents are read from.
const AGGREGATOR: &str = "vendor/lovr-docs/api/main.lua";
const API_ROOT: &str = "vendor/lovr-docs/api";

/// Which generator `api/main.lua` is told to run, as `arg[1]`.
const GENERATOR: &str = "luau";

/// What `io.popen` answers when the aggregator asks git for the branch. Any
/// name but `dev` leaves its unreleased-API checks off, and this is the fork's.
const FORK_BRANCH: &str = "lunette";
/// What the checker loads: the generated definitions, plus what lovr-docs does
/// not describe.
const CHECKER_DEFINITIONS: &str = "etc/lunette/definitions.luau";

/// The `lunette` module as the checker sees it, rendered from the Rust
/// registration surface rather than from lovr-docs.
const MODULE_DECLARATIONS: &str = "lua/lunette/init.luau";

/// The `.luaurc` files that tell the checker where a `@root` resolves, and the
/// path each one reaches the standard library by, written as Luau resolves it:
/// relative to the file's own directory.
///
/// Generated because the session mounts the same roots from
/// [`lunette::aliases`], and a root added to one and not the other is a
/// configuration that runs but cannot be checked.
const ALIAS_FILES: &[(&str, &str)] = &[
    ("lua/.luaurc", "."),
    ("etc/xdg/lunette/.luaurc", "../../../lua"),
];

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
    // Resolve paths from the workspace root.
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let root = root.canonicalize()?;

    let lua = Lua::new();

    let api_root = root.join(API_ROOT);
    install_generator_globals(&lua, &api_root)?;

    // The aggregator defines `lovr.load`; calling it runs the generator.
    let aggregator = fs::read_to_string(root.join(AGGREGATOR))?;
    lua.load(&aggregator)
        .set_name("@lovr-docs/api/main.lua")
        .exec()?;

    let lovr: Table = lua.globals().get("lovr")?;
    let load: mlua::Function = lovr.get("load")?;
    load.call::<()>(())?;

    // Read the file written under `getSource()/luau/lovr.d.luau`.
    let filesystem: Table = lovr.get("filesystem")?;
    let get_source: mlua::Function = filesystem.get("getSource")?;
    let source_dir: String = get_source.call(())?;
    let generated = PathBuf::from(source_dir).join("luau").join("lovr.d.luau");
    let text = fs::read_to_string(&generated)?;

    let definitions = format!("{FORK_GLOBALS}\n{text}");
    let declarations = lunette::lua::declarations::render();

    let mut generated = vec![
        (CHECKER_DEFINITIONS, definitions),
        (MODULE_DECLARATIONS, declarations),
    ];
    generated.extend(
        ALIAS_FILES
            .iter()
            .map(|(path, root)| (*path, lunette::aliases::luaurc(root))),
    );

    if checking {
        let mut current = true;
        for (path, contents) in &generated {
            current &= compare(&root.join(path), contents)?;
        }

        if current {
            info!("the generated definitions are up to date");
        } else {
            error!("run `cargo run -p lunette-generate-definitions` and commit the result");
        }

        return Ok(current);
    }

    for (path, contents) in &generated {
        let path = root.join(path);
        if let Some(directory) = path.parent() {
            fs::create_dir_all(directory)?;
        }
        fs::write(&path, contents)?;
        info!(path = %path.display(), bytes = contents.len(), "wrote");
    }

    Ok(true)
}

/// Compares a checked-in file against what the generator produced.
///
/// Reports the first differing line, or that the file is missing.
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
fn install_generator_globals(lua: &Lua, api_root: &Path) -> mlua::Result<()> {
    let out_dir = std::env::temp_dir().join("lovr-docs-generator");
    fs::create_dir_all(&out_dir).map_err(mlua::Error::external)?;

    let globals = lua.globals();
    let lovr = lua.create_table()?;

    let filesystem = lua.create_table()?;
    let get_source =
        lua.create_function(move |_, ()| Ok(out_dir.to_string_lossy().into_owned()))?;
    filesystem.set("getSource", get_source)?;

    // List documents relative to `api/` in a reproducible order.
    let listing_root = api_root.to_path_buf();
    let get_directory_items = lua.create_function(move |lua, path: String| {
        let mut names: Vec<String> = fs::read_dir(listing_root.join(&path))
            .map_err(mlua::Error::external)?
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        lua.create_sequence_from(names)
    })?;
    filesystem.set("getDirectoryItems", get_directory_items)?;

    let file_root = api_root.to_path_buf();
    let is_file =
        lua.create_function(move |_, path: String| Ok(file_root.join(&path).is_file()))?;
    filesystem.set("isFile", is_file)?;

    let directory_root = api_root.to_path_buf();
    let is_directory =
        lua.create_function(move |_, path: String| Ok(directory_root.join(&path).is_dir()))?;
    filesystem.set("isDirectory", is_directory)?;

    lovr.set("filesystem", filesystem)?;

    // The aggregator calls this when it finishes; there is no session to end.
    let event = lua.create_table()?;
    event.set("quit", lua.create_function(|_, ()| Ok(()))?)?;
    lovr.set("event", event)?;

    let system = lua.create_table()?;
    let get_os = lua.create_function(|_, ()| Ok("Linux".to_string()))?;
    system.set("getOS", get_os)?;
    lovr.set("system", system)?;

    globals.set("lovr", lovr)?;

    // Tell the aggregator which generator to run as `arg[1]`.
    globals.set("arg", lua.create_sequence_from([GENERATOR])?)?;

    install_require(lua, api_root)?;

    // Provide the minimal `os.execute` and `io.open` surfaces the generator uses.
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
        // Buffer the single full write and flush it on `close`.
        let buffer = std::rc::Rc::new(std::cell::RefCell::new(String::new()));
        let handle = lua.create_table()?;
        let write_buf = std::rc::Rc::clone(&buffer);
        // A colon call passes the handle as the first argument.
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
    // The aggregator uses this for live LÖVR checks, which are disabled off `dev`.
    let debug_table: Table = globals.get("debug")?;
    let get_registry = lua.create_function(|lua, ()| lua.create_table())?;
    debug_table.set("getregistry", get_registry)?;

    // Report the fork branch so the aggregator keeps unreleased-API checks off.
    let io_popen = lua.create_function(|lua, _command: String| {
        let handle = lua.create_table()?;
        let read = lua.create_function(|_, (_self, _format): (mlua::Table, Option<String>)| {
            Ok(FORK_BRANCH.to_owned())
        })?;
        handle.set("read", read)?;
        handle.set(
            "close",
            lua.create_function(|_, (_self,): (mlua::Table,)| Ok(()))?,
        )?;
        Ok(handle)
    })?;

    let io_table = lua.create_table()?;
    io_table.set("open", io_open)?;
    io_table.set("popen", io_popen)?;
    globals.set("io", io_table)?;

    Ok(())
}

/// Installs the `require` the aggregator loads each document with.
///
/// LÖVR's loader copies the module name into a path substituting only `.` for
/// `/`, and the aggregator relies on that: it builds slash-separated paths and
/// appends `.init` for a directory's own document, so `lovr/math.init` names
/// `lovr/math/init.lua`. This is that rule, rooted at `api/`.
///
/// Results are cached, as `require` requires: the aggregator loads a document
/// once per reference and there are several thousand references.
fn install_require(lua: &Lua, api_root: &Path) -> mlua::Result<()> {
    let root = api_root.to_path_buf();
    let loaded = lua.create_table()?;

    let require = lua.create_function(move |lua, name: String| {
        let loaded: Table = lua.named_registry_value("lovr-docs-loaded")?;
        if let Ok(value) = loaded.get::<mlua::Value>(name.clone())
            && !value.is_nil()
        {
            return Ok(value);
        }

        let path = root.join(format!("{}.lua", name.replace('.', "/")));
        let source = fs::read_to_string(&path)
            .map_err(|cause| mlua::Error::external(format!("{}: {cause}", path.display())))?;
        let value: mlua::Value = lua
            .load(&source)
            .set_name(format!("@lovr-docs/api/{}.lua", name.replace('.', "/")))
            .eval()?;
        loaded.set(name, value.clone())?;
        Ok(value)
    })?;

    lua.set_named_registry_value("lovr-docs-loaded", loaded)?;
    lua.globals().set("require", require)?;
    Ok(())
}
