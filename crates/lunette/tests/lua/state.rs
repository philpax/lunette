//! Builds the Lua state used by each test file.
//!
//! `@lunette` provides the native parts that need no device, and `@testing/native` fakes the
//! rest. `lovr.math` comes from `liblovr.so`, so pose tests use LÖVR's own `Mat4`.

use std::{
    ffi::c_int,
    fs, io, mem,
    path::PathBuf,
    rc::Rc,
    sync::{Arc, Mutex},
};

use lunette::{
    aliases::{DEVELOPMENT_ALIASES, Resolution},
    callback_error::{TracedError, report_traced},
    lua::{
        glyphs::glyph_atlas,
        keys::{KeyCodes, locking_modifier_names, modifier_names},
        layout::{LayoutFonts, load_layout_font, new_layout_tree},
        svg::rasterize_svg,
        text_boundaries,
    },
    mirrors::NoMonitors,
    plugin::{
        attachment::{self, PluginFailure},
        declarations,
    },
    reload, require, scale,
};
use lunette_ui::text::Fonts;
use mlua::{Function, Lua, Table, Value, ffi::lua_State};
use tracing_subscriber::fmt::MakeWriter;

unsafe extern "C-unwind" {
    /// LÖVR's opener for `lovr.math`, which needs no window, device, or other module.
    fn luaopen_lovr_math(state: *mut lua_State) -> c_int;
}

/// The directories a state resolves modules from.
#[derive(Clone, Debug)]
pub struct Roots {
    pub repository: PathBuf,
    /// The `lua/` directory, holding every module root.
    pub lua: PathBuf,
}

impl Roots {
    pub fn of_repository(repository: PathBuf) -> Self {
        let lua = repository.join("lua");
        Self { repository, lua }
    }
}

/// `configuration` is where bare module names, such as `main`, resolve.
struct Sources {
    roots: Roots,
    configuration: Option<PathBuf>,
}

#[derive(Default)]
struct Reports(Vec<String>);

pub fn new(roots: &Roots) -> mlua::Result<Lua> {
    let lua = Lua::new();
    let lovr = lua.create_table()?;
    // SAFETY: the opener follows the Lua C function protocol, and the state
    // shares the Luau build `liblovr.so` exports.
    let open = unsafe { lua.create_c_function(luaopen_lovr_math)? };
    lovr.set("math", open.call::<Table>(())?)?;
    lua.globals().set("lovr", lovr)?;
    install(&lua, roots)?;
    Ok(lua)
}

/// Installs repository modules and plugin reporting into a caller-owned state.
/// The caller opens the LÖVR modules its tests need before installing this support.
pub fn install(lua: &Lua, roots: &Roots) -> mlua::Result<()> {
    lua.set_app_data(Sources {
        roots: roots.clone(),
        configuration: None,
    });
    lua.set_app_data(Reports::default());
    attachment::set_reporter(
        lua,
        Rc::new(|lua: &Lua, failure: &PluginFailure| {
            if let Some(mut reports) = lua.app_data_mut::<Reports>() {
                reports.0.push(failure.to_string());
            }
        }),
    );

    let package = lua.create_table()?;
    let preload = lua.create_table()?;
    package.set("loaded", lua.create_table()?)?;
    package.set("preload", preload.clone())?;
    lua.globals().set("package", package)?;
    lua.globals()
        .set("require", lua.create_function(require_module)?)?;
    require::install(lua)?;

    // Layout tests measure text with bundled faces only, so results match on every machine.
    let mut fonts = Vec::new();
    for path in [
        "lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf",
        "lunette-plugins/ui/standard/fonts/IBMPlexSans-Medium.ttf",
        "lunette-plugins/ui/standard/fonts/IBMPlexSans-SemiBold.ttf",
        "lunette-plugins/ui/standard/fonts/Iosevka-Regular.ttf",
    ] {
        fonts.push(fs::read(roots.lua.join(path)).map_err(|error| {
            mlua::Error::runtime(format!("the test font {path} could not be read: {error}"))
        })?);
    }
    lua.set_app_data(LayoutFonts(Rc::new(std::cell::RefCell::new(
        Fonts::bundled(fonts),
    ))));

    let native = native(lua)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, ()| Ok(native.clone()))?,
    )?;
    let host = host(lua)?;
    preload.set(
        "@testing/host",
        lua.create_function(move |_, ()| Ok(host.clone()))?,
    )?;
    Ok(())
}

pub fn take_reports(lua: &Lua) -> Vec<String> {
    lua.app_data_mut::<Reports>()
        .map(|mut reports| mem::take(&mut reports.0))
        .unwrap_or_default()
}

/// Selects the configuration directory used by bare and relative module names.
pub fn use_configuration(lua: &Lua, directory: PathBuf) -> mlua::Result<()> {
    if !directory.is_dir() {
        return Err(mlua::Error::runtime(format!(
            "host: useConfiguration: {} is not a directory of the repository",
            directory.display()
        )));
    }
    let mut sources = lua
        .app_data_mut::<Sources>()
        .ok_or_else(|| mlua::Error::runtime("the module sources are missing"))?;
    sources.configuration = Some(directory);
    Ok(())
}

/// Shuts down plugin runtimes and returns uncollected reports and shutdown failures.
pub fn shutdown(lua: &Lua) -> Vec<String> {
    let failures = attachment::shutdown_all(lua);
    let mut reports = take_reports(lua);
    reports.extend(failures.iter().map(ToString::to_string));
    reports
}

fn native(lua: &Lua) -> mlua::Result<Table> {
    let native = lua.create_table()?;
    declarations::install(lua, &native)?;
    native.set("keyCodes", lua.create_function(|_, ()| Ok(KeyCodes))?)?;
    native.set(
        "lockingModifierNames",
        lua.create_function(|_, ()| Ok(locking_modifier_names()))?,
    )?;
    native.set(
        "modifierNames",
        lua.create_function(|_, ()| Ok(modifier_names()))?,
    )?;
    native.set(
        "textBoundaries",
        lua.create_function(|_, text| text_boundaries(text))?,
    )?;
    native.set(
        "newLayoutTree",
        lua.create_function(|lua, ()| new_layout_tree(lua))?,
    )?;
    native.set(
        "loadLayoutFont",
        lua.create_function(|lua, data: mlua::LuaString| load_layout_font(lua, &data))?,
    )?;
    native.set(
        "rasterizeSvg",
        lua.create_function(|lua, (svg, width, height): (mlua::LuaString, f64, f64)| {
            rasterize_svg(lua, &svg, width, height)
        })?,
    )?;
    native.set(
        "glyphAtlas",
        lua.create_function(|lua, ()| Ok(glyph_atlas(lua)))?,
    )?;
    native.set(
        "scaleSteps",
        lua.create_function(|_, ()| Ok(scale::ladder()))?,
    )?;
    Ok(native)
}

/// The `@testing/host` module.
fn host(lua: &Lua) -> mlua::Result<Table> {
    let host = lua.create_table()?;
    host.set(
        "takeReports",
        lua.create_function(|lua, ()| Ok(take_reports(lua)))?,
    )?;
    host.set(
        "shutdown",
        lua.create_function(|lua, ()| Ok(shutdown(lua)))?,
    )?;
    host.set(
        "reload",
        lua.create_function(|lua, clear: Function| {
            // The reload cannot be stopped from inside the clearing, so a
            // clearing that raised is raised once the reload has returned.
            let failure = std::cell::RefCell::new(None);
            let outcome =
                reload::reload_from_lua(lua, &NoMonitors, &reload::NothingRetained, &|| {
                    if let Err(error) = clear.call::<()>(()) {
                        failure.borrow_mut().replace(error);
                    }
                });
            if let Some(error) = failure.into_inner() {
                return Err(error);
            }
            Ok(outcome)
        })?,
    )?;
    host.set(
        "reportTraced",
        lua.create_function(
            |lua, (listeners, message, traceback): (Vec<Function>, String, String)| {
                report_through_boundary(lua, &listeners, TracedError { message, traceback })
            },
        )?,
    )?;
    host.set("collect", lua.create_function(|lua, ()| lua.gc_collect())?)?;
    host.set(
        "readFile",
        lua.create_function(|lua, path: String| {
            let sources = lua
                .app_data_ref::<Sources>()
                .ok_or_else(|| mlua::Error::runtime("the module sources are missing"))?;
            let resolved = resolve_alias_path(&sources.roots, &path)?;
            let data = fs::read(&resolved).map_err(|error| {
                mlua::Error::runtime(format!("{}: {error}", resolved.display()))
            })?;
            lua.create_string(data)
        })?,
    )?;
    host.set(
        "writeSnapshot",
        lua.create_function(|_, (name, data): (String, mlua::LuaString)| {
            write_snapshot(&name, &data.as_bytes())
        })?,
    )?;
    host.set(
        "useConfiguration",
        lua.create_function(|lua, directory: String| {
            let path = lua
                .app_data_ref::<Sources>()
                .ok_or_else(|| mlua::Error::runtime("the module sources are missing"))?
                .roots
                .repository
                .join(directory);
            use_configuration(lua, path)
        })?,
    )?;
    Ok(host)
}

/// Resolves an alias path such as `@lunette-plugins/ui/standard/fonts/a.ttf` under the `lua/`
/// directory, for fixtures that stand in for `lovr.filesystem`.
fn resolve_alias_path(roots: &Roots, path: &str) -> mlua::Result<PathBuf> {
    let relative = path
        .strip_prefix('@')
        .ok_or_else(|| mlua::Error::runtime(format!("readFile: '{path}' is not an alias path")))?;
    if relative
        .split('/')
        .any(|segment| segment == ".." || segment.is_empty())
    {
        return Err(mlua::Error::runtime(format!(
            "readFile: '{path}' leaves the module roots"
        )));
    }
    Ok(roots.lua.join(relative))
}

/// Writes a rendered image for review to the integration tests' temporary directory.
fn write_snapshot(name: &str, data: &[u8]) -> mlua::Result<()> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(mlua::Error::runtime(format!(
            "writeSnapshot: '{name}' is not a lowercase hyphenated name"
        )));
    }
    let directory = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("ui-snapshots");
    fs::create_dir_all(&directory)
        .and_then(|()| fs::write(directory.join(format!("{name}.png")), data))
        .map_err(|error| mlua::Error::runtime(format!("writeSnapshot: {name}: {error}")))
}

/// Reports `traced` through the session's error boundary, `report_traced`, to
/// `listeners`, and answers what the boundary logged.
fn report_through_boundary(
    lua: &Lua,
    listeners: &[Function],
    traced: TracedError,
) -> mlua::Result<String> {
    let captured = Captured::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(captured.clone())
        .with_ansi(false)
        .finish();
    tracing::subscriber::with_default(subscriber, || report_traced(lua, listeners, &traced));
    let logged = captured
        .0
        .lock()
        .map_err(|_| mlua::Error::runtime("host: reportTraced: the captured log is poisoned"))?
        .clone();
    Ok(String::from_utf8_lossy(&logged).into_owned())
}

/// A log sink the boundary's `tracing` output is captured into.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl io::Write for Captured {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .map_err(|_| io::Error::other("the captured log is poisoned"))?
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'writer> MakeWriter<'writer> for Captured {
    type Writer = Captured;

    fn make_writer(&'writer self) -> Self::Writer {
        self.clone()
    }
}

/// A module that returns nothing is cached as `true`, as LÖVR's loader caches it.
/// `require::install` wraps this so relative paths resolve as they do in a session.
fn require_module(lua: &Lua, name: String) -> mlua::Result<Value> {
    let package: Table = lua.globals().get("package")?;
    let loaded: Table = package.get("loaded")?;
    let cached: Value = loaded.get(name.as_str())?;
    if !cached.is_nil() {
        return Ok(cached);
    }
    let preload: Table = package.get("preload")?;
    let loader = match preload.get::<Option<Function>>(name.as_str())? {
        Some(loader) => loader,
        None => load_file(lua, &name)?,
    };
    let value = match loader.call(name.as_str())? {
        Value::Nil => Value::Boolean(true),
        value => value,
    };
    loaded.set(name, value.clone())?;
    Ok(value)
}

/// Loads the file a module name names, under the chunk name LÖVR's loader
/// gives it: `@` and the file's path in the virtual filesystem.
fn load_file(lua: &Lua, name: &str) -> mlua::Result<Function> {
    let (path, virtual_path) = {
        let sources = lua
            .app_data_ref::<Sources>()
            .ok_or_else(|| mlua::Error::runtime("the module sources are missing"))?;
        locate(&sources, name)?
    };
    let source = fs::read_to_string(&path)
        .map_err(|error| mlua::Error::runtime(format!("require: {}: {error}", path.display())))?;
    let function = lua
        .load(source)
        .set_name(format!("@{virtual_path}"))
        .into_function()?;
    lunette::execution::compile(lua, &function)?;
    Ok(function)
}

/// The file `name` resolves to, and its path in the virtual filesystem.
fn locate(sources: &Sources, name: &str) -> mlua::Result<(PathBuf, String)> {
    let (directory, virtual_prefix, rest) = match name.strip_prefix('@') {
        Some(aliased) => {
            let (alias, rest) = aliased.split_once('/').unwrap_or((aliased, ""));
            let root = DEVELOPMENT_ALIASES
                .iter()
                .find(|root| root.name == alias && root.resolution == Resolution::Mounted)
                .ok_or_else(|| {
                    mlua::Error::runtime(format!("require: module '{name}' names no module root"))
                })?;
            (
                sources.roots.lua.join(root.name),
                format!("@{alias}/"),
                rest.to_owned(),
            )
        }
        None => {
            let configuration = sources.configuration.clone().ok_or_else(|| {
                mlua::Error::runtime(format!(
                    "require: module '{name}' not found; no configuration was chosen with \
                     host.useConfiguration"
                ))
            })?;
            (configuration, String::new(), name.to_owned())
        }
    };
    let candidates = if rest.is_empty() {
        vec!["init.luau".to_owned()]
    } else {
        vec![format!("{rest}.luau"), format!("{rest}/init.luau")]
    };
    for candidate in &candidates {
        let path = directory.join(candidate);
        if path.is_file() {
            return Ok((path, format!("{virtual_prefix}{candidate}")));
        }
    }
    Err(mlua::Error::runtime(format!(
        "require: module '{name}' not found under {}",
        directory.display()
    )))
}
