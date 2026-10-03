//! The Lua state a test file runs in.
//!
//! The module roots resolve from the working tree under the names a session
//! gives them, so a test requires `@lunette-plugins/panels` and gets the file
//! a session would. `@lunette` is a native table with the real plugin runtime
//! and the real key and scale vocabularies; the rest of the native API is
//! installed by `@testing/native`, the fake. `lovr.math` is LÖVR's own, opened
//! from `liblovr.so`, so a pose is a real `Mat4` and a test asserts real
//! rotations. `@testing/host` is native too, and carries what only the host can
//! do: the plugin failures it collected, the plugin shutdown, the production
//! reload, and the native error boundary with the log it writes.

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
    lua::keys::{KeyCodes, locking_modifier_names, modifier_names},
    plugin::{
        attachment::{self, PluginFailure},
        declarations,
    },
    reload, require,
    scale::{STEPS, ScaleStep},
};
use mlua::{Function, Lua, Table, Value, ffi::lua_State};
use tracing_subscriber::fmt::MakeWriter;

unsafe extern "C-unwind" {
    /// LÖVR's opener for `lovr.math`, exported by `liblovr.so`. It registers
    /// the math types in the state it is given and needs no window, device, or
    /// other module.
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

/// Where bare module names, such as `main`, resolve: the configuration a test
/// chose with `host.useConfiguration`, if any.
struct Sources {
    roots: Roots,
    configuration: Option<PathBuf>,
}

/// The plugin failures reported and not yet taken.
#[derive(Default)]
struct Reports(Vec<String>);

/// Builds a fresh state for one test file.
pub fn new(roots: &Roots) -> mlua::Result<Lua> {
    let lua = Lua::new();
    lua.set_app_data(Sources {
        roots: roots.clone(),
        configuration: None,
    });
    lua.set_app_data(Reports::default());
    attachment::set_reporter(
        &lua,
        Rc::new(|lua: &Lua, failure: &PluginFailure| {
            if let Some(mut reports) = lua.app_data_mut::<Reports>() {
                reports.0.push(failure.to_string());
            }
        }),
    )?;

    let lovr = lua.create_table()?;
    // SAFETY: the opener follows the Lua C function protocol, and the state
    // shares the Luau build `liblovr.so` exports.
    let open = unsafe { lua.create_c_function(luaopen_lovr_math)? };
    lovr.set("math", open.call::<Table>(())?)?;
    lua.globals().set("lovr", lovr)?;

    let package = lua.create_table()?;
    let preload = lua.create_table()?;
    package.set("loaded", lua.create_table()?)?;
    package.set("preload", preload.clone())?;
    lua.globals().set("package", package)?;
    lua.globals()
        .set("require", lua.create_function(require_module)?)?;
    require::install(&lua)?;

    let native = native(&lua)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, ()| Ok(native.clone()))?,
    )?;
    let host = host(&lua)?;
    preload.set(
        "@testing/host",
        lua.create_function(move |_, ()| Ok(host.clone()))?,
    )?;
    Ok(lua)
}

/// Takes every plugin failure reported since the last take.
pub fn take_reports(lua: &Lua) -> Vec<String> {
    lua.app_data_mut::<Reports>()
        .map(|mut reports| mem::take(&mut reports.0))
        .unwrap_or_default()
}

/// Shuts every plugin runtime down and answers the failures reported and not
/// taken, followed by the shutdown's own.
pub fn shutdown(lua: &Lua) -> Vec<String> {
    let failures = attachment::shutdown_all(lua);
    let mut reports = take_reports(lua);
    reports.extend(failures.iter().map(ToString::to_string));
    reports
}

/// The native table `@lunette` resolves to, before the fake adds to it.
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
        "scaleSteps",
        lua.create_function(|_, ()| {
            Ok(STEPS
                .iter()
                .map(|step| f64::from(step.in_120ths()) / f64::from(ScaleStep::DENOMINATOR))
                .collect::<Vec<_>>())
        })?,
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
            let outcome = reload::reload(lua, &|| {
                if let Err(error) = clear.call::<()>(()) {
                    failure.borrow_mut().replace(error);
                }
            });
            if let Some(error) = failure.into_inner() {
                return Err(error);
            }
            match outcome {
                Ok(()) => Ok((true, None)),
                Err(error) => Ok((false, Some(error.to_string()))),
            }
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
        "setReadonly",
        lua.create_function(|_, (table, readonly): (Table, bool)| {
            table.set_readonly(readonly);
            Ok(())
        })?,
    )?;
    host.set(
        "useConfiguration",
        lua.create_function(|lua, directory: String| {
            let mut sources = lua
                .app_data_mut::<Sources>()
                .ok_or_else(|| mlua::Error::runtime("the module sources are missing"))?;
            let path = sources.roots.repository.join(&directory);
            if !path.is_dir() {
                return Err(mlua::Error::runtime(format!(
                    "host: useConfiguration: {directory} is not a directory of the repository"
                )));
            }
            sources.configuration = Some(path);
            Ok(())
        })?,
    )?;
    Ok(host)
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

/// The state's `require`: `package.loaded`, then `package.preload`, then a
/// file under a module root or the chosen configuration. A module that
/// returns nothing is cached as `true`, as LÖVR's loader caches it.
///
/// `require::install` wraps this so relative paths resolve against the
/// requiring file, as they do in a session.
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
    lua.load(source)
        .set_name(format!("@{virtual_path}"))
        .into_function()
}

/// The file `name` resolves to, and its path in the virtual filesystem.
fn locate(sources: &Sources, name: &str) -> mlua::Result<(PathBuf, String)> {
    // LÖVR's loader reads a dot as a directory separator.
    let normalised = name.replace('.', "/");
    let (directory, virtual_prefix, rest) = match normalised.strip_prefix('@') {
        Some(aliased) => {
            let (alias, rest) = aliased.split_once('/').unwrap_or((aliased, ""));
            let root = DEVELOPMENT_ALIASES
                .iter()
                .find(|root| root.name == alias && root.resolution == Resolution::Mounted)
                .ok_or_else(|| {
                    mlua::Error::runtime(format!("require: module '{name}' names no module root"))
                })?;
            (
                sources.roots.lua.join(root.directory),
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
            (configuration, String::new(), normalised.clone())
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
