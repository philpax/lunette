//! Generates the Luau definitions the type checker loads.
//!
//! Runs lovr-docs' own `api/main.lua` against the pinned metadata using the Luau
//! embedded in LÖVR, adds what lovr-docs does not describe, and writes
//! `etc/lunette/definitions.luau`.
//!
//! The driver runs the aggregator; it does not consume the aggregate.
//! `api/init.lua` is a generated file of some forty-six thousand lines, and
//! consuming it means a fix to a per-file document has no effect until that
//! file is regenerated. Nothing enforces that regeneration step. Running the
//! aggregator reads the per-file documents directly.
//!
//! `api/main.lua` is written to run inside LÖVR. It walks the tree with
//! `lovr.filesystem`, loads each document with `require`, reads `arg` for the
//! generator's name, and finishes by calling `lovr.event.quit`. The driver
//! supplies each of those over the on-disk directory. It also supplies
//! `io.popen`, which the aggregator uses to read the current branch. The
//! driver returns the fork's branch, so the aggregator's `dev` checks stay
//! off.
//!
//! The driver does not port the generator. It executes the literal lovr-docs
//! generator, so the definitions cannot diverge from the metadata. The
//! generator is standalone: it reads its `api` argument (the aggregated table
//! from `api/init.lua`), builds an `out` table, and writes it to
//! `lovr.filesystem.getSource() .. '/luau/lovr.d.luau'`. The driver supplies
//! the two `lovr` globals the generator uses, points `getSource` at a
//! temporary directory, runs the generator, and reads the file it writes.
//!
//! `--check` generates into memory and compares against what is checked in,
//! reporting the first line that differs and exiting non-zero. CONTRIBUTING.md
//! requires a generated document to be verified. The command performs that
//! verification for the generated files.

use std::{
    env, fs,
    path::{Path, PathBuf},
    process::ExitCode,
};

use mlua::{Lua, Table};
use tracing::{error, info};

#[cfg(test)]
mod tests;

/// The aggregator script, and the directory the script and its documents are read from.
const AGGREGATOR: &str = "vendor/lovr-docs/api/main.lua";
const API_ROOT: &str = "vendor/lovr-docs/api";

/// The generator name `api/main.lua` reads from `arg[1]`.
const GENERATOR: &str = "luau";

/// What `io.popen` returns when the aggregator reads the branch. Any
/// name but `dev` keeps the unreleased-API checks off, and the fork's branch
/// is `lunette`.
const FORK_BRANCH: &str = "lunette";
/// What the checker loads: the generated definitions, plus what lovr-docs does
/// not describe.
const CHECKER_DEFINITIONS: &str = "etc/lunette/definitions.luau";

/// The `lunette` module the checker loads, rendered from the Rust
/// registration surface. The lovr-docs metadata does not describe it.
const MODULE_DECLARATIONS: &str = "lua/lunette/init.luau";

type AliasFile = (&'static str, &'static str, fn(&str) -> String);

/// The `.luaurc` files the checker reads to resolve a `@root`, and the path
/// each one reaches the standard library by. The path is written as Luau
/// resolves it: relative to the file's own directory.
///
/// The development file includes the testing root; the others do not, since
/// the test scaffolding is not installed. The installed file resolves relative to
/// `lua/.luaurc`, so no prefix is embedded.
const ALIAS_FILES: &[AliasFile] = &[
    ("lua/.luaurc", ".", lunette::aliases::luaurc),
    (
        "etc/xdg/lunette/.luaurc",
        "../../../lua",
        lunette::aliases::installed_luaurc,
    ),
    (
        "etc/lunette/installed.luaurc",
        ".",
        lunette::aliases::installed_luaurc,
    ),
    (
        "examples/desktop/.luaurc",
        "../../lua",
        lunette::aliases::installed_luaurc,
    ),
    (
        "examples/first-plugin/.luaurc",
        "../../lua",
        lunette::aliases::installed_luaurc,
    ),
    (
        "examples/keyboard/.luaurc",
        "../../lua",
        lunette::aliases::installed_luaurc,
    ),
    (
        "examples/layout/.luaurc",
        "../../lua",
        lunette::aliases::installed_luaurc,
    ),
];

/// What the checker needs that lovr-docs does not describe.
///
/// Luau declares the standard functions itself, with accurate types.
/// Declaring them in the definitions would replace accurate types with `any`.
/// The runtime has no `io`, and declaring one would let four calls pass the
/// checker; those calls fail at runtime.
const FORK_GLOBALS: &str = "
-- The shipped desktop (@lunette-desktop) sets this once, deliberately, to
-- remember that the demonstration window was already spawned across soft
-- reloads. Written through
-- `_G` so the assignment is visible to the checker.
declare _G: {
    lunetteDemonstrationSpawned: boolean,
    -- Anything else a configuration leaves on the global table.
    [string]: any,
}

";

fn main() -> ExitCode {
    // Diagnostics go to stderr. A caller that redirects stdout receives no
    // diagnostics in it. Neither mode writes to stdout.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .without_time()
        .with_target(false)
        .init();

    let arguments = env::args().collect::<Vec<_>>();
    if arguments.iter().any(|argument| argument == "--manifest") {
        print!("{}", lunette::aliases::install_manifest());
        return ExitCode::SUCCESS;
    }

    let checking = arguments.iter().any(|argument| argument == "--check");

    match run(checking) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(error) => {
            error!("{error}");
            ExitCode::FAILURE
        }
    }
}

/// Generates the generated files, and either writes them or compares them.
///
/// Returns whether the run is a success. A comparison that differs is a
/// failure; a write always succeeds or returns the error that stopped it.
fn run(checking: bool) -> Result<bool, Box<dyn std::error::Error>> {
    // The workspace root, relative to CARGO_MANIFEST_DIR
    // (crates/lunette-generate-definitions).
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let root = root.canonicalize()?;

    let lua = Lua::new();

    let api_root = root.join(API_ROOT);
    install_generator_globals(&lua, &api_root)?;

    // `api/main.lua` puts its work in `lovr.load` and runs the generator from
    // there. Loading the chunk defines `lovr.load`; calling the function
    // executes the generator.
    let aggregator = fs::read_to_string(root.join(AGGREGATOR))?;
    lua.load(&aggregator)
        .set_name("@lovr-docs/api/main.lua")
        .exec()?;

    let lovr: Table = lua.globals().get("lovr")?;
    let load: mlua::Function = lovr.get("load")?;
    load.call::<()>(())?;

    // The generator writes to getSource()/luau/lovr.d.luau. Find where
    // getSource points.
    let filesystem: Table = lovr.get("filesystem")?;
    let get_source: mlua::Function = filesystem.get("getSource")?;
    let source_dir: String = get_source.call(())?;
    let generated = PathBuf::from(source_dir).join("luau").join("lovr.d.luau");
    let text = fs::read_to_string(&generated)?;

    let definitions = format!("{FORK_GLOBALS}\n{text}");
    let mut generated = vec![
        (CHECKER_DEFINITIONS, definitions),
        (MODULE_DECLARATIONS, lunette::lua::declarations::render()),
    ];
    generated.extend(
        ALIAS_FILES
            .iter()
            .map(|(path, root, render)| (*path, render(root))),
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
/// Reports the first line that differs, with its number, and the differing
/// line in both versions. A missing file is reported as such.
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

/// Provides the small `lovr` surface the generator uses:
/// `filesystem.getSource` pointing at a temporary output directory, and
/// `system.getOS` returning Linux.
fn install_generator_globals(lua: &Lua, api_root: &Path) -> mlua::Result<()> {
    let out_dir = std::env::temp_dir().join("lovr-docs-generator");
    fs::create_dir_all(&out_dir).map_err(mlua::Error::external)?;

    let globals = lua.globals();
    let lovr = lua.create_table()?;

    let filesystem = lua.create_table()?;
    let get_source =
        lua.create_function(move |_, ()| Ok(out_dir.to_string_lossy().into_owned()))?;
    filesystem.set("getSource", get_source)?;

    // The aggregator's view of the documents. Every path it passes is relative
    // to `api/`. The listing is sorted so a run is reproducible; the sort order
    // is the order of the generated declarations.
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

    // The aggregator's last statement. Nothing here has a session to end.
    let event = lua.create_table()?;
    event.set("quit", lua.create_function(|_, ()| Ok(()))?)?;
    lovr.set("event", event)?;

    let system = lua.create_table()?;
    let get_os = lua.create_function(|_, ()| Ok("Linux".to_string()))?;
    system.set("getOS", get_os)?;
    lovr.set("system", system)?;

    globals.set("lovr", lovr)?;

    // The generator to run, read from `arg[1]`.
    globals.set("arg", lua.create_sequence_from([GENERATOR])?)?;

    install_require(lua, api_root)?;

    // The generator makes its output directory via `os.execute` and writes the
    // definitions through `io.open`. mlua's safe environment exposes neither,
    // so provide minimal versions of both. `os.execute` runs `mkdir -p` for
    // the given path. `io.open(path, 'w')` writes with Rust and returns a
    // handle whose `write` and `close` methods append to the file. The
    // generator calls `file:write(table.concat(out))` once and `file:close()`.
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
        // The generator writes the whole output in one `write`. Buffer it and
        // flush on `close`.
        let buffer = std::rc::Rc::new(std::cell::RefCell::new(String::new()));
        let handle = lua.create_table()?;
        let write_buf = std::rc::Rc::clone(&buffer);
        // Colon-call: `file:write(x)` passes the handle as the first
        // argument, so the closure receives `(_self, text)`.
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
    // The aggregator reaches a LÖVR type's metatable through
    // `debug.getregistry` and compares the documented methods with the
    // implementation. Luau has no such function and there is no live LÖVR
    // here. The function returns an empty table: the checks that use it are
    // already behind the `dev` flag.
    let debug_table: Table = globals.get("debug")?;
    let get_registry = lua.create_function(|lua, ()| lua.create_table())?;
    debug_table.set("getregistry", get_registry)?;

    // The aggregator's first three lines read which branch git has checked
    // out, and turn `dev` into a flag that enables checks against unreleased
    // API. The read function returns the fork's branch, so those checks stay
    // off.
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
/// LÖVR's loader copies the module name into a path, substituting `.` for
/// `/`, and the aggregator relies on that rule: it builds slash-separated
/// paths and appends `.init` for a directory's own document, so
/// `lovr/math.init` names `lovr/math/init.lua`. The rule is rooted at `api/`.
///
/// Results are cached. The aggregator loads a document once per reference,
/// and there are several thousand references.
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
