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
const DEFINITIONS_OUTPUT: &str = "etc/lunette/lovr.declarations.luau";
/// The full checker definitions file, generated as the declarations plus the
/// 5.1/fork globals lovr-docs does not cover.
const CHECKER_DEFINITIONS: &str = "etc/lunette/definitions.luau";

/// The 5.1/fork runtime globals the config and standard library use that
/// lovr-docs does not declare: `io`, the `_G` shape, and the standard
/// functions. These are part of the runtime contract rather than the LÖVR API,
/// so they are fixed text appended to the generated declarations.
const FORK_GLOBALS: &str = "
declare io: {
    open: (string, string?) -> any,
    lines: (string) -> { string },
    write: (...any) -> (),
    read: (string) -> (),
    type: (string) -> string?,
    stderr: any,
}

-- The shipped configuration sets this once, deliberately, to remember that the
-- demonstration window was already spawned across soft reloads. Written through
-- `_G` so the assignment is visible to the checker.
declare _G: {
    lunetteDemonstrationSpawned: boolean,
    -- Anything else a configuration leaves on the global table.
    [string]: any,
}
declare print: (...any) -> ()
declare pcall: any
declare xpcall: any
declare ipairs: any
declare pairs: any
declare select: any
declare type: any
declare tostring: any
declare tonumber: any
declare error: any
declare require: any
";

/// The callbacks `vendor/lovr/etc/boot.lua` assigns a default implementation
/// to, so the field always holds a function and is called as well as assigned.
///
/// `lovr.log` is one: LÖVR's event handler calls it, so a nil there would fault
/// the engine rather than remove a callback. The standard library calls it to
/// report diagnostics, which is what the docs sanction ("It is also possible to
/// emit custom log messages ... by calling the callback") and what `boot.lua`
/// itself does for its own module-load warnings.
const CALLBACKS_WITH_DEFAULTS: [&str; 1] = ["log"];

/// The fields lunette adds to the `lovr` table at boot (the custom event
/// callbacks from `etc/boot.lua`), which lovr-docs does not know. They are
/// spliced into the generated `declare lovr` table.
const LUNETTE_LOVR_FIELDS: &str = "    lun: (name: string, ...any) -> (),
    lunerror: (error: any) -> (),
    lunlayergranted: (layer: any) -> (),
    lunprocessexited: (info: any) -> (),
    lunwindowclosed: (window: any) -> (),
    lunwindowopened: (window: any) -> (),
";

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

    generator_fn.call::<()>(&api)?;

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
    let declarations = to_definitions(&lua, &api)?;
    fs::write(root.join(DEFINITIONS_OUTPUT), &declarations)?;
    fs::write(
        root.join(CHECKER_DEFINITIONS),
        format!("{FORK_GLOBALS}\n{declarations}"),
    )?;
    println!("wrote {} ({} bytes)", root.join(OUTPUT).display(), text_len);
    println!("wrote {}", root.join(DEFINITIONS_OUTPUT).display());
    println!("wrote {}", root.join(CHECKER_DEFINITIONS).display());

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

/// Renders a `--definitions`-compatible `declare lovr` table from the same
/// `api` metadata the luau generator consumed. The full `lovr.d.luau` the
/// generator writes carries classes and extern types, which the analyzer's
/// definitions parser rejects; this subset declares only the function-call
/// surface (each module's `functions`, and the callbacks), which is what
/// mullion references. It is derived from the same table, so it cannot
/// diverge from the full output.
fn to_definitions(lua: &Lua, api: &Table) -> mlua::Result<String> {
    let modules: mlua::Table = api.get("modules")?;
    let callbacks: mlua::Table = api.get("callbacks")?;
    let mut out = String::from("declare lovr: {\n");

    let mut module_names = Vec::new();
    for pair in modules.pairs::<mlua::Value, mlua::Table>() {
        let (_, module) = pair?;
        module_names.push(module);
    }
    module_names.sort_by(|a, b| {
        let an: String = a.get("name").unwrap_or_default();
        let bn: String = b.get("name").unwrap_or_default();
        an.cmp(&bn)
    });

    let mut module_fns: Vec<(String, String)> = Vec::new();
    let mut submodule_lines: Vec<(String, String)> = Vec::new();
    for module in module_names {
        let name: String = module.get("name").unwrap_or_default();
        let empty = lua.create_table()?;
        let functions: mlua::Table = module.get("functions").unwrap_or(empty);
        let mut lines = Vec::new();
        for pair in functions.pairs::<mlua::Value, mlua::Table>() {
            let (_, f) = pair?;
            let fname: String = f.get("name").unwrap_or_default();
            lines.push(function_line(lua, &f, &fname)?);
        }
        if name == "lovr" {
            module_fns.extend(lines.into_iter().map(|l| (String::new(), l)));
        } else if !lines.is_empty() {
            submodule_lines.push((name, lines.join(",\n")));
        }
    }

    // The callbacks (lovr.conf, lovr.load, lovr.lunerror, ...) are top-level
    // fields on the lovr table, a numeric array. Callbacks may return nothing
    // (the config's draw/quit do), so type them `-> ()`; the docs' boolean?
    // returns are advisory and the checker does not depend on them.
    let callback_len: i64 = callbacks.len()?;
    let mut rendered = 0usize;
    for i in 1..=callback_len {
        let cb: mlua::Table = callbacks.get(i)?;
        let cbname: String = cb.get("name").unwrap_or_default();
        let line = function_line(lua, &cb, &cbname)?;
        // The field is assignable: a caller may set it to nil (removing the
        // callback), so make the value itself optional; the return is void.
        // The exception is a callback `boot.lua` defines a default for, which
        // is therefore never nil and is called rather than only assigned.
        let (field, fntype) = line.split_once(": ").unwrap_or(("", &line));
        let fntype = fntype.split("->").next().unwrap_or(fntype).trim_end();
        let line = if CALLBACKS_WITH_DEFAULTS.contains(&cbname.as_str()) {
            format!("{field}: {fntype} -> ()")
        } else {
            format!("{field}: ({fntype} -> ())?")
        };
        module_fns.push((String::new(), line));
        rendered += 1;
    }
    eprintln!("lovr-docs: rendered {rendered} callbacks");
    module_fns.sort_by(|a, b| a.1.cmp(&b.1));
    for (_mod, line) in module_fns {
        out.push_str(&format!("  {line},\n"));
    }

    for (name, body) in submodule_lines {
        out.push_str(&format!("  {name}: {{\n{body}\n  }},\n"));
    }

    // The lunette-added callbacks, after the lovr-docs surface.
    out.push_str(LUNETTE_LOVR_FIELDS);
    out.push_str("}\n");
    Ok(out)
}

/// One function's declaration line, from its first variant's arguments and
/// returns (the same source the luau generator uses for its `FunctionType`).
fn function_line(lua: &Lua, f: &mlua::Table, name: &str) -> mlua::Result<String> {
    let empty = lua.create_table()?;
    let variants: mlua::Table = f.get("variants").unwrap_or(empty);
    let empty = lua.create_table()?;
    let variant: mlua::Table = variants.get(1).unwrap_or(empty);
    let args = render_args(lua, &variant)?;
    let rets = render_rets(lua, &variant)?;
    // A function the metadata declares with no arguments still accepts callers
    // that pass values (the docs omit variadics for constructors like
    // newMat4); expose it as variadic so the checker does not reject the
    // standard library's real calls.
    let args = if args.is_empty() {
        "...any".to_string()
    } else {
        args
    };
    Ok(format!("{name}: ({args}) -> {rets}"))
}

fn render_args(lua: &Lua, variant: &mlua::Table) -> mlua::Result<String> {
    let empty = lua.create_table()?;
    let arguments: mlua::Table = variant.get("arguments").unwrap_or(empty);
    let mut parts = Vec::new();
    for pair in arguments.pairs::<mlua::Value, mlua::Table>() {
        let (_, arg) = pair?;
        let aname: String = arg.get("name").unwrap_or_default();
        // The definitions parser accepts no variadic (`...`) argument; the
        // checker does not need it, so drop it from the signature. lovr-docs
        // names variadics `...name`.
        if aname.starts_with("...") {
            continue;
        }
        let atype: String = sanitize_type(&arg.get::<String>("type").unwrap_or_default());
        // A `table` argument type is rejected by the definitions parser the
        // same way the return is; the checker does not rely on the arg being
        // table-typed, so `any` is equivalent.
        let atype = if atype == "table" {
            "any".to_string()
        } else {
            atype
        };
        parts.push(format!("{aname}: {atype}"));
    }
    Ok(parts.join(", "))
}

fn render_rets(lua: &Lua, variant: &mlua::Table) -> mlua::Result<String> {
    let empty = lua.create_table()?;
    let returns: mlua::Table = variant.get("returns").unwrap_or(empty);
    let mut parts = Vec::new();
    for pair in returns.pairs::<mlua::Value, mlua::Table>() {
        let (_, ret) = pair?;
        let rname: String = ret.get("name").unwrap_or_default();
        let rtype: String = sanitize_type(&ret.get::<String>("type").unwrap_or_default());
        // A `...` return (the docs' shorthand for a variadic, e.g. getAxis's
        // axes) means one or more values; expose it as a variadic return so
        // callers that unpack multiple values typecheck.
        if rname == "..." || rtype == "..." {
            return Ok("...any".to_string());
        }
        // A bare `table` return is not a type the definitions parser accepts
        // in a `declare` function's return position; `any` is equivalent for
        // the checker's purpose.
        let rtype = if rtype == "table" {
            "any".to_string()
        } else {
            rtype
        };
        parts.push(rtype);
    }
    if parts.is_empty() {
        return Ok("()".to_string());
    }
    if parts.len() == 1 {
        return Ok(parts[0].clone());
    }
    Ok(format!("({})", parts.join(", ")))
}

/// Maps a lovr-docs type string to one the analyzer's definitions parser
/// resolves. Builtin primitives pass through; named types that the docs
/// derive from classes or enums (which the definitions parser does not know
/// without their declarations) become `any`.
fn sanitize_type(t: &str) -> String {
    // Only the primitives the definitions parser reliably accepts. `table` and
    // `userdata` (in arg or return position) are rejected, and named types
    // would need their class/enum declarations; the checker does not rely on
    // the precise lovr types, so everything else becomes `any`.
    match t {
        "number" | "string" | "boolean" | "nil" | "..." => t.to_string(),
        "" => "any".to_string(),
        _ => "any".to_string(),
    }
}
