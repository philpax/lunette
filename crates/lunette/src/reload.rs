//! Linux-only: the soft reload.
//!
//! `lunette.reload()` applies an edited configuration without disturbing
//! anything native. It retires the plugin runtime, drops `package.loaded` for
//! the user's and the standard library's namespaces, clears the callbacks
//! `main.lua` owns, resets the plugin epoch, and runs `main.lua` again
//! ([the Lua API](../../../docs/dev/lua-api.md#reload)).
//!
//! LÖVR's modules, the XR session, the graphics device, the compositor thread,
//! and every connected client keep running throughout. The reload touches
//! none of them. The whole operation is confined to one Lua state, it is
//! instant, and a client cannot notice it happened.
//!
//! # Cleared state and surviving state
//!
//! `package.loaded` keeps the roots that [`PROTECTED_ROOTS`] names and drops
//! everything else. A module added to the standard library later, or a user
//! module under any name, is cleared by default. Clearing `lovr.*` would make
//! the next `require 'lovr.graphics'` re-run a live module's initialisation.
//! The retained set is stated as roots; a list of what goes would need
//! updating as modules are added.
//!
//! The Lua state itself is not closed. Globals survive; nothing documents
//! them as going away, and a configuration may keep its own state in one. A
//! reload removes `main.lua`'s modules and callbacks. `lunette.restart()` is
//! the operation that discards everything.
//!
//! # Clearing the callbacks
//!
//! `main.lua` defines `lovr.draw`, `lovr.update`, and the `lovr.lun*` handlers.
//! Re-running it redefines the callbacks it still defines. A callback the user
//! deleted from the configuration would stay bound to the old function and
//! keep being called, and the reload would keep executing code that is no
//! longer in the file.
//!
//! [`USER_CALLBACKS`] is a closed list. It excludes the callbacks
//! `vendor/lovr/etc/boot.lua` defines defaults for. Clearing `lovr.log` would
//! remove a default and nothing would put it back. `boot.lua` runs once per
//! Lua state, and a soft reload does not make a new one.
//!
//! # Reload failure
//!
//! A `main.lua` that fails to load at startup produces safe mode
//! ([the Lua API](../../../docs/dev/lua-api.md#errors)). A reload that fails does
//! not: the user has a working session in front of them. Replacing it with
//! the fallback over a typo they can fix and reload again is worse than
//! reporting the error. [`reload`] returns the error, the session keeps
//! running, and the clients stay where they are.

use std::{cell::Cell, error::Error, fmt};

use mlua::{Function, Lua, Table, Value};
use tracing::{info, warn};

use crate::plugin::host;

/// Applies the configuration on disk to the running session.
///
/// The steps run in the order the module documentation gives them. Plugin
/// shutdown callback failures are reported, and cleanup continues. Errors
/// clearing callbacks or loaded modules stop the reload.
///
/// # Errors
///
/// The reload errors when `main.lua` or `lovr.load` raises, or when the Lua
/// state cannot be reached for the clearing. A reload that already reached
/// `main.lua` has torn the previous configuration down. The session
/// continues with whatever the failed run installed, not the previous
/// configuration.
pub fn reload(lua: &Lua, forget_subscriptions: &dyn Fn()) -> Result<(), ReloadError> {
    // A configuration that reloads from the top of `main.lua` would otherwise
    // recurse until the stack runs out. A stack overflow takes every connected
    // client down with the process.
    let _guard = ReloadGuard::acquire().ok_or(ReloadError::Reentered)?;
    if host::callback_active(lua) {
        return Err(ReloadError::CallbackActive);
    }

    host::shutdown(lua, "reload");

    let globals = lua.globals();
    // Subscriptions go with the callbacks: a listener the previous
    // configuration registered would keep being called after the
    // configuration that registered it is gone.
    forget_subscriptions();
    clear_user_callbacks(&globals).map_err(ReloadError::State)?;
    clear_loaded_modules(&globals).map_err(ReloadError::State)?;
    host::reset_epoch(lua).map_err(ReloadError::State)?;
    run_configuration(&globals)?;

    info!("the configuration was reloaded");
    Ok(())
}

/// `lunette.reload()`: the reload, as Lua sees it.
///
/// Answers `true`, or `false` and the message; it does not raise. The caller
/// is usually a key binding. The failure the reload avoids is a session that
/// stops drawing over a typo in the configuration it was asked to load. A
/// caller that raises can include the message.
pub(crate) fn reload_from_lua(
    lua: &Lua,
    forget_subscriptions: &dyn Fn(),
) -> mlua::Result<(bool, Option<String>)> {
    match reload(lua, forget_subscriptions) {
        Ok(()) => Ok((true, None)),
        Err(error) => {
            warn!("{error}");
            Ok((false, Some(error.to_string())))
        }
    }
}

/// The reason a reload fails.
#[derive(Debug)]
pub enum ReloadError {
    /// A reload was asked for while one was running.
    Reentered,
    /// A reload was asked for from inside a plugin callback.
    CallbackActive,
    /// The Lua state could not be read or written where the clearing needs it.
    State(mlua::Error),
    /// `main.lua` raised.
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
                "reload: {MAIN_MODULE}.lua could not be run, and the session is left with whatever \
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

/// The module `require` resolves the user's configuration through.
///
/// `vendor/lovr/etc/boot.lua` runs `require(main:sub(1, -5))`, and `main` is
/// `main.lua` for a source that is a directory. lunette always points LÖVR at
/// the configuration directory, so the module is always this.
const MAIN_MODULE: &str = "main";

/// The `package.loaded` roots a reload keeps.
///
/// The set is stated as what survives; the list of what goes would need
/// updating as modules are added. A name is matched on its first dotted
/// segment. `lovr.graphics`, `jit.util`, and `string.buffer` stay with their
/// roots, and `lovr.*` cannot be cleared by accident.
///
/// LÖVR's modules are here because clearing them would make the next
/// `require 'lovr.graphics'` re-run module initialisation against a live
/// graphics module. The rest are the interpreter's own, and no reload rebuilds
/// them.
const PROTECTED_ROOTS: &[&str] = &[
    "_G",
    "bit",
    "coroutine",
    "debug",
    "ffi",
    "io",
    "jit",
    "lovr",
    "math",
    "os",
    "package",
    "string",
    "table",
];

/// The `lovr` fields `main.lua` owns, cleared before it is re-run.
///
/// These are every LÖVR callback that `vendor/lovr/etc/boot.lua` leaves
/// undefined. A configuration is the only possible author of them.
///
/// `boot`, `run`, `mirror`, `simulate`, `threaderror`, `taskready`,
/// `filechanged`, and `log` are absent; `boot.lua` defines a default for each.
/// `boot.lua` runs once per Lua state, and a soft reload does not make a new
/// one. Clearing one of those would remove a default that nothing would put
/// back. `conf` is absent for the same reason: `conf.lua` wrote it, `conf.lua`
/// is not re-run, and the configuration has already been applied to a session
/// that is running.
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

/// What lunette's own callbacks are named with.
///
/// Handlers are cleared by prefix, not by name. The prefix is reserved for
/// lunette (`docs/dev/lua-api.md#events`), and a handler for an event a later
/// phase delivers is as much the configuration's as `lovr.lunwindowopened`
/// is. The dispatchers sit on `lovr.handlers`, not on `lovr`, so the prefix
/// match reaches the configuration's handlers and not the module's own.
const EVENT_PREFIX: &str = "lun";

/// Clears the `lovr` fields `main.lua` owns.
///
/// A state with no `lovr` table is not an error: the module is reachable from
/// a Lua state that never ran `boot.lua`, and a reload there has nothing to
/// clear.
///
/// [`crate::safe_mode`] calls it for the same reason a reload does. A
/// `main.lua` that raised halfway through has installed some of its callbacks.
/// Safe mode running with the broken configuration's `lovr.draw` still bound
/// would not be safe mode.
pub(crate) fn clear_user_callbacks(globals: &Table) -> mlua::Result<()> {
    let Some(lovr) = globals.get::<Option<Table>>("lovr")? else {
        return Ok(());
    };

    for name in USER_CALLBACKS {
        lovr.set(*name, Value::Nil)?;
    }

    // Collected before anything is removed. Assigning nil to a field during a
    // `next` traversal is legal, but a second pass costs nothing.
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

/// Drops every loaded module a reload does not keep.
fn clear_loaded_modules(globals: &Table) -> mlua::Result<()> {
    let loaded: Table = globals.get::<Table>("package")?.get("loaded")?;

    let mut discarded = Vec::new();
    for pair in loaded.pairs::<Value, Value>() {
        let (key, _) = pair?;
        let Value::String(name) = &key else {
            // A module cannot be required under a key that is not a string.
            // Whatever this is, `require` did not put it there.
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

/// Whether a module survives a reload.
///
/// A name survives when its first dotted or slashed segment is in
/// [`PROTECTED_ROOTS`].
fn is_protected(name: &str) -> bool {
    let root = name.split(['.', '/']).next().unwrap_or(name);
    PROTECTED_ROOTS.contains(&root)
}

/// Runs `main.lua`, then `lovr.load`.
///
/// `vendor/lovr/etc/boot.lua` calls `lovr.load` at startup, and a reload calls
/// it for the same reason: `main.lua` conventionally defines callbacks and
/// does its setup in `lovr.load`, so a reload that ran only the file would
/// install the new callbacks and never run the new setup. `lovr.load` receives
/// the global `arg`, the same value it receives at startup.
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

/// Holds the reentrancy flag for the length of one reload.
///
/// The flag is thread-local, not global. The Lua API is available only in the
/// main state, and a `lovr.thread` state never receives it. The flag belongs
/// to the thread that owns the state, not to the process.
struct ReloadGuard;

impl ReloadGuard {
    /// Takes the flag, or `None` if a reload is already running.
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

    /// Installs `source` as the `main` module, as an edit to `main.lua` would.
    fn set_main(lua: &Lua, source: &str) {
        let chunk: Function = lua
            .load(source)
            .set_name("@main.lua")
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

        reload(&lua, &|| ()).expect("the reload succeeds");

        assert_eq!(
            number(&lua, "runs.main"),
            2,
            "main.lua should have run again"
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

        reload(&lua, &|| ()).expect("the reload succeeds");

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

        reload(&lua, &|| ()).expect("a session without mullion reloads");

        assert_eq!(number(&lua, "runs.main"), 1);
    }

    #[test]
    fn lovr_modules_are_never_cleared() {
        let lua = state("");
        run(
            &lua,
            "package.loaded['lovr.headset'] = { name = 'headset' }",
        );

        reload(&lua, &|| ()).expect("the reload succeeds");

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

    #[test]
    fn the_interpreters_own_modules_are_never_cleared() {
        let lua = state("");

        reload(&lua, &|| ()).expect("the reload succeeds");

        // `package` itself is excluded: the fork's Luau `package` library keeps
        // its loaded table under the registry `_LOADED` and does not register
        // itself in `package.loaded` (LuaJIT did). The interpreter-owned
        // modules that do appear there are the ones the reload must preserve.
        for name in ["string", "table", "math", "os", "coroutine"] {
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
            "package.loaded['@lunette-desktop/persist'] = { n = 1 }
             package.loaded['@lunette-desktop/persist/format'] = { n = 1 }
             package.loaded.mylayout = { n = 1 }
             package.loaded['@lunette'] = { n = 1 }",
        );

        reload(&lua, &|| ()).expect("the reload succeeds");

        for name in [
            "@lunette-desktop/persist",
            "@lunette-desktop/persist/format",
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
        reload(&lua, &|| ()).expect("the reload succeeds");

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

        reload(&lua, &|| ()).expect("the reload succeeds");

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

        reload(&lua, &|| ()).expect("the reload succeeds");

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
        let error = reload(&lua, &|| ()).expect_err("a configuration that raises fails the reload");

        assert!(
            error.to_string().contains("a deliberate defect"),
            "the message should name what went wrong: {error}"
        );
        // The session is still usable, which is the difference between this
        // and safe mode: the Lua state runs, and the next reload works.
        set_main(&lua, "runs.main = runs.main + 1");
        reload(&lua, &|| ()).expect("the session can be reloaded again after a failure");
        assert_eq!(number(&lua, "runs.main"), 2);
    }

    #[test]
    fn a_lovr_load_that_raises_is_reported_separately() {
        let lua = state("function lovr.load() error('a deliberate defect') end");

        let error = reload(&lua, &|| ()).expect_err("lovr.load raising fails the reload");

        assert!(
            matches!(error, ReloadError::Load(_)),
            "a failure in lovr.load is not a failure to load the configuration: {error}"
        );
    }

    /// Repeated reloads rebuild the configuration without retaining the old
    /// module callbacks or package entries.
    #[test]
    fn ten_reloads_rebuild_the_configuration() {
        let lua = state("runs.main = runs.main + 1");
        run(&lua, "require 'main'");

        for _ in 0..10 {
            reload(&lua, &|| ()).expect("the reload succeeds");
        }

        assert_eq!(number(&lua, "runs.main"), 11);
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
                        lua.create_function(|lua, ()| reload_from_lua(lua, &|| ()))?,
                    )?;
                    Ok(module)
                })
                .expect("the loader is created"),
            )
            .expect("the module is reachable");

        reload(&lua, &|| ()).expect("the outer reload succeeds");

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
    fn the_reload_is_available_again_after_one_that_failed() {
        let lua = state("error('a deliberate defect')");

        reload(&lua, &|| ()).expect_err("the first reload fails");
        set_main(&lua, "runs.main = runs.main + 1");

        reload(&lua, &|| ()).expect("the guard is released by the failure");
    }

    #[test]
    fn a_module_named_for_a_protected_root_is_kept_with_it() {
        assert!(is_protected("lovr"));
        assert!(is_protected("lovr.graphics"));
        assert!(is_protected("jit.util"));
        assert!(is_protected("string.buffer"));
        assert!(!is_protected("lovrly"));
        assert!(!is_protected("mullion.scale"));
        assert!(!is_protected(MAIN_MODULE));
    }
}
