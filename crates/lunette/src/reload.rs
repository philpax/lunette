//! Linux-only: reloads configuration modules and callbacks in the running session.
//!
//! The Lua state, XR session, graphics device, compositor thread, and clients stay active.
//! See [the Lua API](../../../docs/dev/lua-api.md#reload).

use std::{cell::Cell, error::Error, fmt};

use mlua::{Function, Lua, Table, Value};
use tracing::{info, warn};

use crate::{mirrors::MirrorRegistry, plugin::attachment};

/// Applies the configuration on disk to the running session.
///
/// Mirrors stay acquired while the replacement configuration runs, so it can reuse them.
///
/// # Errors
///
/// Errors when `main.luau` or `lovr.load` raises, or when the Lua state cannot be cleared.
/// A failure after `main.luau` starts leaves whatever the failed run installed.
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
) -> (bool, Option<String>) {
    match reload(lua, mirrors, forget_subscriptions) {
        Ok(()) => (true, None),
        Err(error) => {
            warn!("{error}");
            (false, Some(error.to_string()))
        }
    }
}

fn replace_configuration(lua: &Lua, forget_subscriptions: &dyn Fn()) -> Result<(), ReloadError> {
    attachment::shutdown(lua, "reload");

    let globals = lua.globals();
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
/// The list excludes defaults `boot.lua` installs once per state.
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
/// Event dispatchers live under `lovr.handlers`, so clearing `lovr.lun*` leaves them.
const EVENT_PREFIX: &str = "lun";

/// Clears configuration callbacks from the `lovr` table.
///
/// Safe mode also uses this to clear what a configuration that failed at startup left.
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

    /// A state carrying what `boot.lua` leaves behind, with `main` supplied
    /// through `package.preload` so no test reads the filesystem.
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
              -- Dropping a live LÖVR module would rerun its initialisation against the running device.
              package.loaded['lovr.graphics'] = { name = 'graphics' }
              runs = { main = 0, load = 0 }
            ",
        )
        .exec()
        .expect("the boot scaffolding loads");
        set_main(&lua, main);
        lua
    }

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
    fn the_configuration_and_lovr_load_run_again_with_the_argument_table() {
        let lua = state(
            "runs.main = runs.main + 1 \
             function lovr.load(arguments) runs.load = runs.load + 1 received = arguments end",
        );
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
        assert_eq!(
            lua.load("return received[1]")
                .eval::<String>()
                .expect("the argument table arrived"),
            "/config"
        );
    }

    /// A fresh state supplies the interpreter's library names, so a new library is covered.
    #[test]
    fn protected_roots_are_kept_and_other_modules_are_cleared() {
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
        run(
            &lua,
            "package.loaded['lovr.headset'] = { name = 'headset' }
             package.loaded['@lunette-plugins/arrangement'] = { n = 1 }
             package.loaded['@lunette-plugins/arrangement/format'] = { n = 1 }
             package.loaded.mylayout = { n = 1 }
             package.loaded['@lunette'] = { n = 1 }",
        );

        reload(&lua, &NoMonitors, &|| ()).expect("the reload succeeds");

        let kept = libraries
            .iter()
            .map(String::as_str)
            .chain(["lovr.graphics", "lovr.headset"]);
        for name in kept {
            assert!(
                lua.load(format!("return package.loaded['{name}'] ~= nil"))
                    .eval::<bool>()
                    .expect("readable"),
                "package.loaded['{name}'] should have survived the reload"
            );
        }
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
        assert!(is_protected("string/extra"));
        assert!(is_protected("utf8.extra"));
        assert!(!is_protected("lovrly"));
        assert!(!is_protected("lunette-plugins.scale"));
        assert!(!is_protected(MAIN_MODULE));
    }

    /// `boot.lua` runs once per Lua state, so nothing reinstalls a default a reload clears.
    #[test]
    fn configuration_callbacks_are_cleared_and_boot_defaults_and_dispatchers_survive() {
        let lua = state(
            "function lovr.keypressed() end
             function lovr.lunwindowopened() end
             function lovr.draw() end",
        );
        run(
            &lua,
            "require 'main' lovr.handlers.lunwindowopened = function() end",
        );

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
        assert!(
            lua.load("return lovr.log ~= nil and lovr.run ~= nil")
                .eval::<bool>()
                .expect("readable"),
            "boot.lua's defaults should have survived"
        );
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
        // Unlike safe mode, the session stays usable and the next reload works.
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

    /// A configuration that reloads as it loads would otherwise exhaust the stack.
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
                        lua.create_function(|lua, ()| {
                            Ok(reload_from_lua(lua, &NoMonitors, &|| ()))
                        })?,
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
}
