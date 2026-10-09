//! Linux-specific reload of configuration modules and callbacks in the running session.
//!
//! Reload retires the plugin runtime, starts a new plugin epoch, clears user and
//! standard-library modules, clears configuration callbacks, and runs `main.luau`.
//! The Lua state, XR session, graphics device, compositor thread, and clients remain
//! active. See [the Lua API](../../../docs/dev/lua-api.md#reload).
//!
//! Reload keeps Lua globals and protected modules. It clears user modules by default.
//! Protected roots include LÖVR modules and standard libraries initialized once per
//! Lua state. [`USER_CALLBACKS`] lists configuration callbacks that reload clears;
//! defaults defined by `boot.lua` remain installed. A failed reload returns its error
//! and leaves the session running. See [reload errors](../../../docs/dev/lua-api.md#errors).

use std::{cell::Cell, error::Error, fmt};

use mlua::{Function, Lua, Table, Value};
use tracing::{info, warn};

use crate::{
    mirrors::MirrorRegistry,
    plugin::{attachment, host},
};

/// Applies the configuration on disk to the running session.
///
/// Plugin shutdown failures are reported, and shutdown continues. Errors while clearing
/// callbacks or loaded modules stop the reload. Mirrors stay acquired while the
/// replacement configuration runs, so it can reuse them; the rest are released after.
///
/// # Errors
///
/// The reload errors when `main.luau` or `lovr.load` raises, or when the Lua
/// state cannot be reached for the clearing. A reload that already reached
/// `main.luau` has torn the previous configuration down. The session
/// continues with whatever the failed run installed, not the previous
/// configuration.
pub fn reload(
    lua: &Lua,
    mirrors: &dyn MirrorRegistry,
    forget_subscriptions: &dyn Fn(),
) -> Result<(), ReloadError> {
    // Prevent recursive reloads from exhausting the Lua stack.
    let _guard = ReloadGuard::acquire().ok_or(ReloadError::Reentered)?;
    if attachment::callback_active(lua) {
        return Err(ReloadError::CallbackActive);
    }
    let owns_reload = mirrors.begin_reload();
    let result = replace_configuration(lua, forget_subscriptions);
    if owns_reload {
        mirrors.finish_reload();
    }
    result
}

/// Returns success and an optional error message without raising.
pub fn reload_from_lua(
    lua: &Lua,
    mirrors: &dyn MirrorRegistry,
    forget_subscriptions: &dyn Fn(),
) -> mlua::Result<(bool, Option<String>)> {
    match reload(lua, mirrors, forget_subscriptions) {
        Ok(()) => Ok((true, None)),
        Err(error) => {
            warn!("{error}");
            Ok((false, Some(error.to_string())))
        }
    }
}

fn replace_configuration(lua: &Lua, forget_subscriptions: &dyn Fn()) -> Result<(), ReloadError> {
    host::shutdown(lua, "reload");

    let globals = lua.globals();
    // Remove listeners owned by the configuration being replaced.
    forget_subscriptions();
    clear_user_callbacks(&globals).map_err(ReloadError::State)?;
    clear_loaded_modules(&globals).map_err(ReloadError::State)?;
    run_configuration(&globals)?;

    info!("the configuration was reloaded");
    Ok(())
}

/// The reason a reload fails.
#[derive(Debug)]
pub enum ReloadError {
    /// A reload request arrived during another reload.
    Reentered,
    /// A reload request arrived from a plugin callback.
    CallbackActive,
    /// The Lua state could not be read or written where the clearing needs it.
    State(mlua::Error),
    /// `main.luau` raised.
    Configuration(mlua::Error),
    /// `lovr.load` raised.
    Load(mlua::Error),
}

impl fmt::Display for ReloadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Reentered => formatter.write_str(
                "reload: a reload cannot be asked for from inside one; a configuration that \
                 reloads as it loads would never finish loading",
            ),
            Self::CallbackActive => formatter
                .write_str("reload: a reload cannot be asked for from inside a plugin callback"),
            Self::State(error) => write!(
                formatter,
                "reload: the lua state could not be cleared: {error}"
            ),
            Self::Configuration(error) => write!(
                formatter,
                "reload: the {MAIN_MODULE} module could not be run, and the session is left with whatever \
                 it installed before it failed: {error}"
            ),
            Self::Load(error) => write!(formatter, "reload: lovr.load raised: {error}"),
        }
    }
}

impl Error for ReloadError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Reentered | Self::CallbackActive => None,
            Self::State(error) | Self::Configuration(error) | Self::Load(error) => Some(error),
        }
    }
}

/// The module name LÖVR uses for the configuration entry point.
const MAIN_MODULE: &str = "main";

/// The `package.loaded` roots preserved across reload.
const PROTECTED_ROOTS: &[&str] = &[
    "_G",
    "bit32",
    "buffer",
    "class",
    "coroutine",
    "debug",
    "integer",
    "lovr",
    "math",
    "os",
    "package",
    "quaternion",
    "string",
    "table",
    "utf8",
    "vector",
];

/// Configuration callbacks cleared during reload.
///
/// The list excludes callbacks and configuration fields initialized once by `boot.lua`.
const USER_CALLBACKS: &[&str] = &[
    "draw",
    "errhand",
    "focus",
    "keypressed",
    "keyreleased",
    "load",
    "modelschanged",
    "mount",
    "mousemoved",
    "mousepressed",
    "mousereleased",
    "permission",
    "quit",
    "recenter",
    "resize",
    "restart",
    "textinput",
    "update",
    "visible",
    "wheelmoved",
];

/// The reserved prefix for configuration event handlers cleared during reload.
///
/// Event dispatchers are stored under `lovr.handlers`, not on `lovr`.
/// See [events](../../../docs/dev/lua-api.md#events).
const EVENT_PREFIX: &str = "lun";

/// Clears configuration callbacks from the `lovr` table.
///
/// Safe mode clears callbacks left by a configuration that fails during startup. A missing
/// `lovr` table has no callbacks to clear.
pub(crate) fn clear_user_callbacks(globals: &Table) -> mlua::Result<()> {
    let Some(lovr) = globals.get::<Option<Table>>("lovr")? else {
        return Ok(());
    };

    for name in USER_CALLBACKS {
        lovr.set(*name, Value::Nil)?;
    }

    let mut handlers = Vec::new();
    for pair in lovr.pairs::<Value, Value>() {
        let (key, _) = pair?;
        if let Value::String(name) = &key
            && name.to_string_lossy().starts_with(EVENT_PREFIX)
        {
            handlers.push(key);
        }
    }
    for key in handlers {
        lovr.set(key, Value::Nil)?;
    }

    Ok(())
}

fn clear_loaded_modules(globals: &Table) -> mlua::Result<()> {
    let loaded: Table = globals.get::<Table>("package")?.get("loaded")?;

    let mut discarded = Vec::new();
    for pair in loaded.pairs::<Value, Value>() {
        let (key, _) = pair?;
        let Value::String(name) = &key else {
            continue;
        };
        if !is_protected(&name.to_string_lossy()) {
            discarded.push(key);
        }
    }

    for key in discarded {
        loaded.set(key, Value::Nil)?;
    }

    Ok(())
}

/// Tests whether a module belongs to a protected root.
fn is_protected(name: &str) -> bool {
    let root = name.split(['.', '/']).next().unwrap_or(name);
    PROTECTED_ROOTS.contains(&root)
}

/// Runs `main.luau` and then `lovr.load` with the global `arg` table.
fn run_configuration(globals: &Table) -> Result<(), ReloadError> {
    let require: Function = globals.get("require").map_err(ReloadError::State)?;
    require
        .call::<Value>(MAIN_MODULE)
        .map_err(ReloadError::Configuration)?;

    let lovr = globals
        .get::<Option<Table>>("lovr")
        .map_err(ReloadError::State)?;
    let Some(lovr) = lovr else {
        return Ok(());
    };
    let Some(load) = lovr
        .get::<Option<Function>>("load")
        .map_err(ReloadError::State)?
    else {
        return Ok(());
    };

    let arguments: Value = globals.get("arg").map_err(ReloadError::State)?;
    load.call::<()>(arguments).map_err(ReloadError::Load)
}

/// Holds a thread-local reentrancy flag for one reload.
struct ReloadGuard;

impl ReloadGuard {
    fn acquire() -> Option<Self> {
        RELOADING.with(|reloading| (!reloading.replace(true)).then_some(Self))
    }
}

impl Drop for ReloadGuard {
    fn drop(&mut self) {
        RELOADING.with(|reloading| reloading.set(false));
    }
}

thread_local! {
    static RELOADING: Cell<bool> = const { Cell::new(false) };
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::mirrors::NoMonitors;

    /// A Lua state carrying what `boot.lua` leaves behind and a `main` module
    /// whose source the test chooses.
    ///
    /// `main` arrives through `package.preload`, not through a file, so nothing
    /// here reads the filesystem. `require` resolves it exactly as it resolves
    /// the file in a session, which is the module the reload calls.
    fn state(main: &str) -> Lua {
        let lua = crate::test_lua::session_lua();
        lua.load(
            r"
              lovr = {}
              lovr.handlers = setmetatable({}, { __index = lovr })
              -- Two of boot.lua's own defaults, which a reload must not clear.
              function lovr.log(message) end
              function lovr.run() end
              arg = { [0] = 'lunette', [1] = '/config' }
              -- A live LOVR module occupies `lovr.graphics`: a reload that dropped
              -- it would re-run its initialisation against the running graphics device.
              package.loaded['lovr.graphics'] = { name = 'graphics' }
              runs = { main = 0, load = 0 }
            ",
        )
        .exec()
        .expect("the boot scaffolding loads");
        set_main(&lua, main);
        lua
    }

    /// Installs `source` as the `main` module, as an edit to `main.luau` would.
    fn set_main(lua: &Lua, source: &str) {
        let chunk: Function = lua
            .load(source)
            .set_name("@main.luau")
            .into_function()
            .expect("the fixture configuration compiles");
        let preload: Table = lua
            .globals()
            .get::<Table>("package")
            .expect("package exists")
            .get("preload")
            .expect("package.preload exists");
        preload
            .set(MAIN_MODULE, chunk)
            .expect("the configuration is reachable");
    }

    fn run(lua: &Lua, chunk: &str) {
        lua.load(chunk).exec().expect("the chunk runs");
    }

    fn number(lua: &Lua, expression: &str) -> i64 {
        lua.load(format!("return {expression}"))
            .eval()
            .expect("the expression evaluates")
    }

    #[test]
    fn the_configuration_runs_again_and_so_does_lovr_load() {
        let lua =
            state("runs.main = runs.main + 1 function lovr.load() runs.load = runs.load + 1 end");
        run(&lua, "require 'main' lovr.load()");

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        assert_eq!(
            number(&lua, "runs.main"),
            2,
            "main.luau should have run again"
        );
        assert_eq!(
            number(&lua, "runs.load"),
            2,
            "lovr.load should have run again"
        );
    }

    /// `lovr.load` is what a configuration does its setup in, and it is given
    /// the same `arg` at a reload as it is at startup.
    #[test]
    fn lovr_load_is_given_the_argument_table() {
        let lua = state("function lovr.load(arguments) received = arguments end");
        run(&lua, "require 'main'");

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        assert_eq!(
            lua.load("return received[1]")
                .eval::<String>()
                .expect("the argument table arrived"),
            "/config"
        );
    }

    #[test]
    fn a_configuration_without_plugin_runtime_reloads() {
        let lua = state("runs.main = runs.main + 1");

        reload(&lua, &NoMonitors, &|| ()).expect("a session without a plugin runtime reloads");

        assert_eq!(number(&lua, "runs.main"), 1);
    }

    #[test]
    fn lovr_modules_are_never_cleared() {
        let lua = state("");
        run(
            &lua,
            "package.loaded['lovr.headset'] = { name = 'headset' }",
        );

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        assert_eq!(
            lua.load("return package.loaded['lovr.graphics'].name")
                .eval::<String>()
                .expect("lovr.graphics survived"),
            "graphics"
        );
        assert_eq!(
            lua.load("return package.loaded['lovr.headset'].name")
                .eval::<String>()
                .expect("lovr.headset survived"),
            "headset"
        );
    }

    /// Every library registered by `luaL_openlibs` survives, including libraries
    /// enabled by fork-specific flags. A fresh state supplies the names, so new
    /// interpreter libraries are covered automatically.
    #[test]
    fn the_interpreters_own_modules_are_never_cleared() {
        let libraries: Vec<String> = crate::test_lua::session_lua()
            .load(
                "local names = {}
                 for name in package.loaded do table.insert(names, name) end
                 return names",
            )
            .eval()
            .expect("package.loaded is readable");
        assert!(
            libraries.iter().any(|name| name == "string"),
            "the fresh state should have registered its libraries: {libraries:?}"
        );
        let lua = state("");

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        for name in &libraries {
            assert!(
                lua.load(format!("return package.loaded['{name}'] ~= nil"))
                    .eval::<bool>()
                    .expect("readable"),
                "package.loaded['{name}'] should have survived the reload"
            );
        }
    }

    #[test]
    fn user_and_standard_library_modules_are_cleared() {
        let lua = state("");
        run(
            &lua,
            "package.loaded['@lunette-plugins/arrangement'] = { n = 1 }
             package.loaded['@lunette-plugins/arrangement/format'] = { n = 1 }
             package.loaded.mylayout = { n = 1 }
             package.loaded['@lunette'] = { n = 1 }",
        );

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        for name in [
            "@lunette-plugins/arrangement",
            "@lunette-plugins/arrangement/format",
            "mylayout",
            "@lunette",
        ] {
            assert!(
                lua.load(format!("return package.loaded['{name}'] == nil"))
                    .eval::<bool>()
                    .expect("readable"),
                "package.loaded['{name}'] should have been cleared"
            );
        }
    }

    /// The hazard the specification does not name: a callback the user deleted
    /// from the configuration would stay bound to the old function.
    #[test]
    fn a_callback_the_new_configuration_does_not_define_stops_being_called() {
        let lua = state(
            "function lovr.keypressed() end
             function lovr.lunwindowopened() end
             function lovr.draw() end",
        );
        run(&lua, "require 'main'");

        set_main(&lua, "function lovr.draw() end");
        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        assert!(
            lua.load("return lovr.keypressed == nil and lovr.lunwindowopened == nil")
                .eval::<bool>()
                .expect("readable"),
            "a callback the new configuration does not define should be gone"
        );
        assert!(
            lua.load("return lovr.draw ~= nil")
                .eval::<bool>()
                .expect("readable"),
            "a callback the new configuration still defines should be there"
        );
    }

    /// `boot.lua` runs once per Lua state. A default it installed and a reload
    /// cleared would be gone for the rest of the session.
    #[test]
    fn boot_lua_s_own_defaults_survive() {
        let lua = state("");

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        assert!(
            lua.load("return lovr.log ~= nil and lovr.run ~= nil")
                .eval::<bool>()
                .expect("readable"),
            "boot.lua's defaults should have survived, because nothing would put them back"
        );
    }

    /// The dispatchers sit on `lovr.handlers`. Clearing the configuration's
    /// `lovr.lun*` handlers must not remove them.
    #[test]
    fn the_event_dispatchers_are_not_cleared() {
        let lua = state("");
        run(&lua, "lovr.handlers.lunwindowopened = function() end");

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        assert!(
            lua.load("return rawget(lovr.handlers, 'lunwindowopened') ~= nil")
                .eval::<bool>()
                .expect("readable"),
            "a dispatcher is the module's, not the configuration's"
        );
    }

    #[test]
    fn a_configuration_that_raises_is_reported_and_the_session_continues() {
        let lua = state("runs.main = runs.main + 1");
        run(&lua, "require 'main'");

        set_main(&lua, "error('a deliberate defect')");
        let error = reload(&lua, &NoMonitors, &|| ())
            .expect_err("a configuration that raises fails the reload");

        assert!(
            error.to_string().contains("a deliberate defect"),
            "the message should name what went wrong: {error}"
        );
        // The session is still usable, which is the difference between this
        // and safe mode: the Lua state runs, and the next reload works.
        set_main(&lua, "runs.main = runs.main + 1");
        reload(&lua, &NoMonitors, &|| ())
            .expect("the session can be reloaded again after a failure");
        assert_eq!(number(&lua, "runs.main"), 2);
    }

    #[test]
    fn a_lovr_load_that_raises_is_reported_separately() {
        let lua = state("function lovr.load() error('a deliberate defect') end");

        let error =
            reload(&lua, &NoMonitors, &|| ()).expect_err("lovr.load raising fails the reload");

        assert!(
            matches!(error, ReloadError::Load(_)),
            "a failure in lovr.load is not a failure to load the configuration: {error}"
        );
    }

    /// A configuration that reloads as it loads would recurse until the stack
    /// runs out, taking every connected client with the process.
    #[test]
    fn a_reload_from_inside_a_reload_is_refused() {
        let lua = state(
            "runs.main = runs.main + 1
             local lunette = require '@lunette'
             ok, message = lunette.reload()",
        );
        lua.globals()
            .get::<Table>("package")
            .expect("package exists")
            .get::<Table>("preload")
            .expect("preload exists")
            .set(
                "@lunette",
                lua.create_function(|lua, ()| {
                    let module = lua.create_table()?;
                    module.set(
                        "reload",
                        lua.create_function(|lua, ()| reload_from_lua(lua, &NoMonitors, &|| ()))?,
                    )?;
                    Ok(module)
                })
                .expect("the loader is created"),
            )
            .expect("the module is reachable");

        reload(&lua, &NoMonitors, &|| ()).expect("the outer reload succeeds");

        assert!(
            !lua.load("return ok").eval::<bool>().expect("readable"),
            "the inner reload should have been refused"
        );
        assert_eq!(
            number(&lua, "runs.main"),
            1,
            "the configuration should have run once, not once per nested reload"
        );
    }

    #[test]
    fn a_module_named_for_a_protected_root_is_kept_with_it() {
        assert!(is_protected("lovr"));
        assert!(is_protected("lovr.graphics"));
        assert!(is_protected("string/extra"));
        assert!(is_protected("utf8.extra"));
        assert!(!is_protected("lovrly"));
        assert!(!is_protected("lunette-plugins.scale"));
        assert!(!is_protected(MAIN_MODULE));
    }
}
