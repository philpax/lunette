//! Linux-only: the soft reload.
//!
//! `lunette.reload()` applies an edited configuration without disturbing
//! anything native. It runs the standard library's teardown hooks, drops
//! `package.loaded` for the user's and the standard library's namespaces,
//! clears the callbacks `main.lua` owns, and runs `main.lua` again
//! ([the Lua API](../../../docs/lua-api.md#reload)).
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
//! ([the Lua API](../../../docs/lua-api.md#errors)). A reload that fails does
//! not: the user has a working session in front of them. Replacing it with
//! the fallback over a typo they can fix and reload again is worse than
//! reporting the error. [`reload`] returns the error, the session keeps
//! running, and the clients stay where they are.

use std::{cell::Cell, error::Error, fmt};

use mlua::{Function, Lua, Table, Value};
use tracing::{info, warn};

/// Applies the configuration on disk to the running session.
///
/// The steps run in the order the module documentation gives them. The first
/// three are best-effort: a hook raising does not stop the rest, and that is
/// the teardown registry's own contract.
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

    run_teardown_hooks(lua, "reload");

    let globals = lua.globals();
    // Subscriptions go with the callbacks: a listener the previous
    // configuration registered would keep being called after the
    // configuration that registered it is gone.
    forget_subscriptions();
    clear_user_callbacks(&globals).map_err(ReloadError::State)?;
    clear_loaded_modules(&globals).map_err(ReloadError::State)?;
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
            Self::Reentered => None,
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
/// lunette (`docs/lua-api.md#events`), and a handler for an event a later
/// phase delivers is as much the configuration's as `lovr.lunwindowopened`
/// is. The dispatchers sit on `lovr.handlers`, not on `lovr`, so the prefix
/// match reaches the configuration's handlers and not the module's own.
const EVENT_PREFIX: &str = "lun";

/// The module the teardown registry sits in.
///
/// Reached through `package.loaded`; it is not `require`d. A configuration
/// that never mentions `mullion` is supported, and requiring the module here
/// would load the standard library into a session that had gone without it.
const TEARDOWN_MODULE: &str = "@mullion/teardown";

/// Runs the standard library's teardown hooks, reporting failures and
/// continuing.
///
/// Timers, signal connections, coroutines, and stashed handles from the
/// configuration being discarded outlive it unless something takes them down.
/// The registry is `mullion`'s, and its contract is that one hook's failure
/// does not stop the next: reload has to complete either way, and a
/// half-torn-down state is worse than a reported failure.
///
/// A restart runs it for a different reason. A reload keeps the Lua state, so
/// a handle the configuration holds survives and the hooks release what would
/// otherwise be held twice. A restart closes the state, so every handle in it
/// goes at once while the compositor object each one named stays; the next
/// configuration finds the names taken. `crate::boot` is the other caller,
/// and `context` is what its warnings say.
pub fn run_teardown_hooks(lua: &Lua, context: &str) {
    match teardown_failures(lua) {
        Ok(failures) if failures.is_empty() => (),
        Ok(failures) => warn!(
            "{context}: {} teardown hook(s) failed and the {context} continued: {}",
            failures.len(),
            failures.join(", ")
        ),
        Err(error) => warn!("{context}: the teardown registry could not be run: {error}"),
    }
}

/// The names of the hooks that raised, or an empty list.
fn teardown_failures(lua: &Lua) -> mlua::Result<Vec<String>> {
    let loaded: Table = lua.globals().get::<Table>("package")?.get("loaded")?;
    let Some(module) = loaded.get::<Option<Table>>(TEARDOWN_MODULE)? else {
        return Ok(Vec::new());
    };
    let Some(run) = module.get::<Option<Function>>("run")? else {
        return Ok(Vec::new());
    };

    let mut names = Vec::new();
    for failure in run.call::<Table>(())?.sequence_values::<Table>() {
        names.push(failure?.get::<Option<String>>("name")?.unwrap_or_default());
    }
    Ok(names)
}

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

    /// A teardown registry with the contract `@mullion/teardown` has: hooks keyed
    /// by name, run in reverse registration order, emptied by a run, and rebuilt
    /// empty when the module body runs again.
    ///
    /// The real one is Lua in `lua/mullion/teardown.lua` and is exercised by its
    /// own spec. What these cases need is a record of when a hook ran relative
    /// to the clearing, and a count that outlives the module the reload
    /// discards. `hooksRun` is a global for that second reason, and a reload
    /// does not clear globals.
    const TEARDOWN: &str = r"
      hooksRun = {}
      package.preload['@mullion/teardown'] = function()
        local teardown = { hooks = {}, order = {} }
        function teardown.register(name, run)
          if teardown.hooks[name] == nil then
            teardown.order[#teardown.order + 1] = name
          end
          teardown.hooks[name] = run
        end
        function teardown.pending()
          local names = {}
          for index = #teardown.order, 1, -1 do
            names[#names + 1] = teardown.order[index]
          end
          return names
        end
        function teardown.run()
          local names, hooks = teardown.pending(), teardown.hooks
          teardown.hooks, teardown.order = {}, {}
          local failures = {}
          for _, name in ipairs(names) do
            local ok, message = pcall(hooks[name])
            hooksRun[#hooksRun + 1] = name
            if not ok then
              failures[#failures + 1] = { name = name, message = message }
            end
          end
          return failures
        end
        return teardown
      end
    ";

    fn install_teardown(lua: &Lua) {
        lua.load(TEARDOWN)
            .exec()
            .expect("the teardown registry loads");
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
    fn teardown_hooks_run_before_anything_is_cleared() {
        let lua = state(
            r"
              local teardown = require '@mullion/teardown'
              teardown.register('a.module', function()
                -- What the hook can still see is the point: a hook that ran
                -- after the clearing would tear down a state that had already been
                -- dismantled.
                sawModule = package.loaded['a.module'] ~= nil
                sawCallback = lovr.update ~= nil
              end)
              function lovr.update() end
            ",
        );
        install_teardown(&lua);
        run(
            &lua,
            "require 'main' package.loaded['a.module'] = { name = 'a' }",
        );

        reload(&lua, &|| ()).expect("the reload succeeds");

        assert!(
            lua.load("return sawModule and sawCallback")
                .eval::<bool>()
                .expect("the hook ran"),
            "the hook should have run before the modules and callbacks were cleared"
        );
        assert_eq!(
            number(&lua, "#hooksRun"),
            1,
            "the hook should have run exactly once"
        );
    }

    /// The registry's contract is that one hook raising does not stop the rest.
    /// This is its only caller.
    #[test]
    fn a_hook_that_raises_does_not_stop_the_reload() {
        let lua = state("runs.main = runs.main + 1");
        install_teardown(&lua);
        run(
            &lua,
            r"
              local teardown = require '@mullion/teardown'
              teardown.register('second', function() secondRan = true end)
              teardown.register('first', function() error('deliberate') end)
            ",
        );

        reload(&lua, &|| ()).expect("a failing hook does not fail the reload");

        assert!(
            lua.load("return secondRan")
                .eval::<bool>()
                .expect("readable"),
            "the hook that ran after the one that raised should still have run"
        );
        assert_eq!(number(&lua, "runs.main"), 1, "main.lua should have run");
    }

    /// The restart's half of the registry. `crate::boot` runs the hooks and
    /// nothing else: the state it would clear is about to be closed, and the
    /// hooks release something native that has to be released before the
    /// handles holding it go.
    #[test]
    fn a_restart_runs_the_hooks_without_clearing_the_state() {
        let lua = state(
            r"
              local teardown = require '@mullion/teardown'
              teardown.register('a.module', function() released = true end)
              function lovr.update() end
            ",
        );
        install_teardown(&lua);
        run(
            &lua,
            "require 'main' package.loaded['a.module'] = { name = 'a' }",
        );

        run_teardown_hooks(&lua, "restart");

        assert!(
            lua.load("return released")
                .eval::<bool>()
                .expect("the hook ran"),
            "the hook should have run, because a restart is the case where nothing else releases what it holds"
        );
        assert!(
            lua.load("return lovr.update ~= nil and package.loaded['a.module'] ~= nil")
                .eval::<bool>()
                .expect("the state is readable"),
            "a restart should not clear the callbacks or the modules a reload clears: the state is \
             closed a moment later, so clearing them is work with no observer"
        );
    }

    /// The same tolerance a reload has, at the other entry point. Both
    /// `lovr.filechanged` and `lunette.restart` ask for a restart, and neither
    /// is refusable by a configuration that never loaded the standard library.
    #[test]
    fn a_restart_with_no_teardown_registry_runs_the_hooks_it_has() {
        let lua = state("runs.main = runs.main + 1");

        run_teardown_hooks(&lua, "restart");
    }

    #[test]
    fn a_configuration_with_no_teardown_registry_reloads() {
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
            "package.loaded['@mullion/panel'] = { n = 1 }
             package.loaded['@mullion/layout/arc'] = { n = 1 }
             package.loaded.mylayout = { n = 1 }
             package.loaded['@lunette'] = { n = 1 }",
        );

        reload(&lua, &|| ()).expect("the reload succeeds");

        for name in [
            "@mullion/panel",
            "@mullion/layout/arc",
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

    /// Ten reloads leave the registry the size one reload leaves it. Hooks and
    /// the connections they stand for do not accumulate.
    #[test]
    fn ten_reloads_accumulate_no_teardown_hooks() {
        let lua = state(
            "local teardown = require '@mullion/teardown'
             teardown.register('@mullion/panel', function() end)
             teardown.register('@mullion/signal', function() end)",
        );
        install_teardown(&lua);

        run(&lua, "require 'main'");

        for _ in 0..10 {
            reload(&lua, &|| ()).expect("the reload succeeds");
            assert_eq!(
                number(&lua, "#require('@mullion/teardown').pending()"),
                2,
                "the registry should hold one hook per module, however many reloads have run"
            );
        }

        assert_eq!(
            number(&lua, "#hooksRun"),
            20,
            "each reload should have run each of the two hooks once"
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
        assert!(!is_protected("mullion.panel"));
        assert!(!is_protected(MAIN_MODULE));
    }
}
