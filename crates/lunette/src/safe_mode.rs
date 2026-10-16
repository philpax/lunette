//! Linux-specific embedded fallback configuration for startup failures and requested recovery.
//!
//! Safe mode runs when `lovr.boot` or `lovr.load` fails, and on the boot after a
//! session asks for it with `lunette.restartIntoSafeMode`. It uses no file-backed
//! module roots, so it can run when the standard library or installation is
//! unavailable. Other callback failures use [`crate::callback_error`]. A failed
//! reload leaves the current session running. See
//! [error handling](../../../docs/development/native/lua-api.md#errors).

use std::{cell::Cell, error::Error, fmt, rc::Rc};

use mlua::{Function, Lua, MultiValue, Table, Value};
use tracing::{error, info, warn};

use crate::reload;

/// The safe-mode Lua source embedded in the binary.
const SOURCE: &str = include_str!("safe_mode.luau");

/// The chunk name used in safe-mode tracebacks.
const CHUNK_NAME: &str = "@safe-mode.luau";

/// The module `boot.lua` requires for the configuration. lunette passes a
/// configuration directory as LÖVR's source, so the entry is `main.luau` or
/// `main.lua`, which LÖVR requires as `main`.
const MAIN_MODULE: &[u8] = b"main";

/// What the next boot runs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BootEntry {
    /// The configuration, with safe mode as the fallback when it does not load.
    #[default]
    Configuration,
    /// Safe mode, without running the configuration.
    SafeMode,
}

/// A request, made from one Lua state, that the next boot run safe mode.
///
/// It lives on the session, which outlives each Lua state, so a request
/// crosses the restart that follows it. One request covers one boot: taking it
/// resets it.
#[derive(Debug, Default)]
pub struct SafeModeRequest(Cell<BootEntry>);

impl SafeModeRequest {
    /// Asks for safe mode on the next boot.
    pub fn request(&self) {
        self.0.set(BootEntry::SafeMode);
    }

    /// Withdraws a request whose restart could not be queued.
    pub fn withdraw(&self) {
        self.0.set(BootEntry::Configuration);
    }

    /// Answers what this boot runs, and resets the request so that the boot
    /// after it runs the configuration again.
    pub fn take(&self) -> BootEntry {
        self.0.replace(BootEntry::Configuration)
    }
}

/// Asks for safe mode on the next boot, then queues a hard restart through
/// `lovr.event.restart`.
///
/// The restart happens once the frame's callbacks return, as [`crate::restart`]
/// describes. A request whose restart cannot be queued is withdrawn, so a later
/// restart for another reason runs the configuration.
///
/// # Errors
///
/// Returns an error if `lovr.event` is not loaded or its `restart` raises.
pub fn restart_into_safe_mode(lua: &Lua, request: &SafeModeRequest) -> Result<(), SafeModeError> {
    request.request();
    let queued = queue_restart(lua);
    if queued.is_err() {
        request.withdraw();
    }
    queued
}

fn queue_restart(lua: &Lua) -> Result<(), SafeModeError> {
    let lovr: Table = lua.globals().get("lovr").map_err(SafeModeError::Lua)?;
    let event: Option<Table> = lovr.get("event").map_err(SafeModeError::Lua)?;
    let event = event.ok_or(SafeModeError::EventModuleMissing)?;
    let restart: Function = event.get("restart").map_err(SafeModeError::Lua)?;
    restart.call::<()>(()).map_err(SafeModeError::Lua)
}

/// Why a restart into safe mode could not be queued.
#[derive(Debug)]
pub enum SafeModeError {
    /// The configuration disabled LÖVR's event module, which carries the restart.
    EventModuleMissing,
    /// Reading `lovr.event.restart`, or calling it, raised.
    Lua(mlua::Error),
}

impl fmt::Display for SafeModeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("safe mode: the restart could not be queued: ")?;
        match self {
            Self::EventModuleMissing => formatter.write_str("lovr.event is not loaded"),
            Self::Lua(error) => write!(formatter, "{error}"),
        }
    }
}

impl Error for SafeModeError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::EventModuleMissing => None,
            Self::Lua(error) => Some(error),
        }
    }
}

/// Compiles [`SOURCE`] without running it.
///
/// # Errors
///
/// Returns a compilation error if [`SOURCE`] is invalid.
pub fn load(lua: &Lua) -> mlua::Result<Function> {
    lua.load(SOURCE).set_name(CHUNK_NAME).into_function()
}

/// Installs a `lovr.boot` wrapper that starts safe mode when startup fails,
/// or, for [`BootEntry::SafeMode`], in place of the configuration.
///
/// Call after `boot.lua` creates `lovr` and before its coroutine resumes. The
/// wrapper covers `lovr.load`; later callback failures remain outside this boundary.
///
/// # Errors
///
/// Returns an error if `lovr.boot` cannot be read or replaced.
pub fn install_trigger(lua: &Lua, entry: BootEntry) -> mlua::Result<()> {
    let lovr: Table = lua.globals().get("lovr")?;
    let boot: Function = lovr.get("boot")?;

    let wrapper = match entry {
        BootEntry::Configuration => {
            lua.create_function(move |lua, ()| match boot.call::<Value>(()) {
                Ok(loop_function) => Ok(loop_function),
                Err(failure) => start(lua, &Reason::LoadFailed(failure.to_string())),
            })?
        }
        BootEntry::SafeMode => {
            lua.create_function(move |lua, ()| boot_without_configuration(lua, &boot))?
        }
    };
    lovr.set("boot", wrapper)
}

/// Why safe mode is running.
#[derive(Debug)]
enum Reason {
    /// The configuration did not load, with the error it raised.
    LoadFailed(String),
    /// The previous session asked for safe mode.
    Requested,
}

/// Runs LÖVR's boot with a `require` that refuses the configuration's entry
/// module, then starts safe mode in its place.
///
/// The boot loads `conf.luau` and starts the modules before it requires the
/// entry, so safe mode starts with graphics and the headset running, as it does
/// after a configuration that does not load.
fn boot_without_configuration(lua: &Lua, boot: &Function) -> mlua::Result<Value> {
    let globals = lua.globals();
    let require: Function = globals.get("require")?;
    let refused = Rc::new(Cell::new(false));
    let guard = {
        let refused = Rc::clone(&refused);
        let require = require.clone();
        lua.create_function(move |_, arguments: MultiValue| {
            if let Some(Value::String(name)) = arguments.front()
                && name.as_bytes().as_ref() == MAIN_MODULE
            {
                refused.set(true);
                return Err(mlua::Error::runtime(
                    "safe mode: the configuration is not loaded, because safe mode was requested",
                ));
            }
            require.call::<MultiValue>(arguments)
        })?
    };
    globals.set("require", guard)?;
    let booted = boot.call::<Value>(());
    globals.set("require", require)?;

    match booted {
        Err(_) if refused.get() => start(lua, &Reason::Requested),
        Err(failure) => start(lua, &Reason::LoadFailed(failure.to_string())),
        Ok(loop_function) => {
            warn!("safe mode was requested, but the boot did not require the configuration");
            Ok(loop_function)
        }
    }
}

/// Runs safe mode and returns its frame loop.
///
/// The host logs the reason and passes it to the safe-mode chunk.
///
/// # Errors
///
/// Returns an error if safe mode does not load or run.
fn start(lua: &Lua, reason: &Reason) -> mlua::Result<Value> {
    let (reported, requested) = match reason {
        Reason::LoadFailed(reported) => {
            error!(
                "lua: the configuration could not be loaded, so safe mode is running: {reported}"
            );
            (reported.as_str(), false)
        }
        Reason::Requested => {
            info!("safe mode is running because the previous session requested it");
            ("the previous session requested safe mode", true)
        }
    };

    if let Err(error) = reload::clear_user_callbacks(&lua.globals()) {
        error!("lua: the failed configuration's callbacks could not be cleared: {error}");
    }

    load(lua)?.call::<()>((reported, requested))?;
    info!("safe mode is running; press the reload key to load the configuration");

    let run: Function = lua.globals().get::<Table>("lovr")?.get("run")?;
    run.call(())
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a failed expectation is how a test reports a failure; the ban is on production code"
    )]

    use mlua::{Function, Lua, Table, Value};
    use pretty_assertions::assert_eq;

    use crate::safe_mode::{
        BootEntry, SafeModeRequest, install_trigger, load, restart_into_safe_mode,
    };

    /// The fake `lunette` module, `lovr`, and recording pass that each case runs
    /// the chunk against. They are written in Lua because the real API is
    /// method-shaped: `self` is the window's sink.
    const ENVIRONMENT: &str = r#"
      local recorded = { spawns = {}, calls = {}, planes = 0, texts = 0 }

      local sink = {}
      sink.__index = sink
      function sink:pointer(x, y)
        recorded.calls[#recorded.calls + 1] = { name = 'pointer', x = x, y = y }
      end
      function sink:button(button, down)
        recorded.calls[#recorded.calls + 1] = { name = 'button', button = button, down = down }
      end

      recorded.window = {
        dead = false,
        width = 800,
        height = 600,
        opaque = false,
        title = 'a terminal',
        sink = setmetatable({}, sink),
        texture = false,
      }
      function recorded.window:getTexture()
        return self.texture
      end

      package.preload['@lunette'] = function()
        return {
          windows = function()
            return recorded.showWindow and { recorded.window } or {}
          end,
          onProcessExited = function(handler)
            recorded.processExited = handler
            return function() recorded.processExited = nil end
          end,
          spawn = function(options)
            recorded.spawns[#recorded.spawns + 1] = options.argv[1]
            return { id = #recorded.spawns }
          end,
          -- Faked rather than real: the real one re-runs `main.luau`, and the
          -- `main.luau` that would not load is why safe mode is running.
          reload = function()
            recorded.reloads = recorded.reloads + 1
            return recorded.reloaded, recorded.reloadMessage
          end,
        }
      end

      -- No graphics module and no headset until a case installs one, which is
      -- the state a session that failed early is in.
      lovr = {}

      recorded.pass = {}
      function recorded.pass:text()
        recorded.texts = recorded.texts + 1
      end
      function recorded.pass:plane()
        recorded.planes = recorded.planes + 1
      end
      function recorded.pass:line() end
      function recorded.pass:setMaterial() end
      function recorded.pass:setShader() end
      function recorded.pass:setBlendMode() end

      -- The tracked hands are the keys of `recorded.tracked`. The left hand is
      -- the only one by default.
      function recorded.installHeadset()
        lovr.headset = {
          isTracked = function(device)
            return recorded.tracked[device] == true
          end,
          getPosition = function()
            return recorded.origin[1], recorded.origin[2], recorded.origin[3]
          end,
          getDirection = function()
            return recorded.direction[1], recorded.direction[2], recorded.direction[3]
          end,
          isDown = function()
            return recorded.trigger
          end,
        }
      end

      recorded.tracked = { ['hand/left/point'] = true }
      recorded.origin = { 0, 1.5, 0 }
      recorded.direction = { 0, 0, -1 }
      recorded.trigger = false
      recorded.showWindow = false
      recorded.reloads = 0
      recorded.reloaded = true
      recorded.reloadMessage = nil
      return recorded
    "#;

    /// A state carrying the fakes, with the recorder in the global `recorded`.
    fn environment() -> Lua {
        let lua = crate::test_lua::session_lua();
        let recorded: Table = lua
            .load(ENVIRONMENT)
            .set_name("environment")
            .call(())
            .expect("the fake environment should run");
        lua.globals()
            .set("recorded", recorded)
            .expect("the recorder should be reachable");
        lua
    }

    /// The recorder, and the `lovr` table that carries the chunk's callbacks.
    fn recorder(lua: &Lua) -> Table {
        lua.globals()
            .get("recorded")
            .expect("recorded should exist")
    }

    fn lovr(lua: &Lua) -> Table {
        lua.globals().get("lovr").expect("lovr should exist")
    }

    /// Calls `lovr.<name>` with `arguments`, failing the test if it raises.
    fn call(lua: &Lua, name: &str, arguments: impl mlua::IntoLuaMulti) {
        let callback: mlua::Function = lovr(lua)
            .get(name)
            .unwrap_or_else(|error| panic!("lovr.{name} should be readable: {error}"));
        if let Err(error) = callback.call::<()>(arguments) {
            panic!("lovr.{name} raised: {error}");
        }
    }

    /// Runs the chunk against the fakes and returns the state it ran on.
    fn started() -> Lua {
        let lua = environment();
        let chunk = load(&lua).expect("the safe-mode chunk should compile");
        chunk.call::<()>(()).expect("the chunk should run");
        lua
    }

    /// Everything drawn on one frame, joined. A case can ask whether something
    /// reached the panel without asking where on it.
    fn drawn(lua: &Lua) -> String {
        let recorded = recorder(lua);
        recorded
            .set("drawn", lua.create_table().expect("a table can be made"))
            .expect("the sink is reachable");
        lua.load(
            "function recorded.pass:text(text) recorded.drawn[#recorded.drawn + 1] = text end",
        )
        .exec()
        .expect("the text sink is replaced");

        let pass: Table = recorded.get("pass").expect("the pass should exist");
        call(lua, "draw", pass);

        recorded
            .get::<Table>("drawn")
            .expect("the drawn text is recorded")
            .sequence_values::<String>()
            .filter_map(Result::ok)
            .collect::<Vec<String>>()
            .join("\n")
    }

    /// Safe mode runs when the standard library may be the reason the
    /// configuration failed, so it must not depend on one.
    #[test]
    fn it_runs_with_no_standard_library_anywhere() {
        let lua = environment();
        lua.load("package.path = '' package.cpath = ''")
            .exec()
            .expect("the search path should be emptied");
        let before: Vec<String> = loaded_modules(&lua);

        let chunk = load(&lua).expect("the safe-mode chunk should compile");
        chunk
            .call::<()>(())
            .expect("the chunk should run with no standard library present");
        call(&lua, "load", ());

        let mut added: Vec<String> = loaded_modules(&lua)
            .into_iter()
            .filter(|name| !before.contains(name))
            .collect();
        added.sort();
        assert_eq!(
            added,
            vec!["@lunette".to_owned()],
            "safe mode should require lunette and nothing else"
        );
    }

    /// The frame runs with no graphics module, no headset, and no window,
    /// matching a session that failed during startup.
    #[test]
    fn a_frame_runs_with_no_headset_no_graphics_and_no_window() {
        let lua = started();

        call(&lua, "load", ());
        call(&lua, "update", ());
        let pass: Table = recorder(&lua).get("pass").expect("the pass should exist");
        call(&lua, "draw", pass);

        let recorded = recorder(&lua);
        let texts: i64 = recorded.get("texts").expect("texts should be counted");
        assert!(
            texts >= 2,
            "safe mode should say what it is and what it is waiting for"
        );
        let planes: i64 = recorded.get("planes").expect("planes should be counted");
        assert_eq!(planes, 0, "there is no window to draw");
    }

    /// A hand aimed at the middle of the panel puts the pointer at the middle of
    /// the window, and a trigger press reaches the sink as a button.
    ///
    /// The panel is at eye height, 1.5 metres ahead, and the window is 800x600,
    /// so the centre is (400, 300).
    #[test]
    fn a_hand_aimed_at_the_panel_clicks_it() {
        let lua = started();
        lua.load("recorded.showWindow = true recorded.installHeadset()")
            .exec()
            .expect("the headset should install");

        call(&lua, "load", ());
        call(&lua, "update", ());
        lua.load("recorded.trigger = true")
            .exec()
            .expect("the trigger should go down");
        call(&lua, "update", ());
        lua.load("recorded.trigger = false")
            .exec()
            .expect("the trigger should come up");
        call(&lua, "update", ());

        let calls = recorded_calls(&lua);
        let pointers: Vec<&(String, f64, f64, bool)> =
            calls.iter().filter(|call| call.0 == "pointer").collect();
        assert!(!pointers.is_empty(), "the ray should have reached the sink");
        assert_eq!(
            (pointers[0].1, pointers[0].2),
            (400.0, 300.0),
            "a ray through the centre should land on the centre pixel"
        );

        let buttons: Vec<&(String, f64, f64, bool)> =
            calls.iter().filter(|call| call.0 == "button").collect();
        assert_eq!(buttons.len(), 2, "one press and one release");
        assert!(buttons[0].3, "the first is the press");
        assert!(!buttons[1].3, "the second is the release");
    }

    /// A hand pointing away from the panel neither moves the pointer nor
    /// delivers a click. That behaviour stops safe mode clicking a client the
    /// user is not looking at.
    #[test]
    fn a_hand_aimed_away_from_the_panel_delivers_nothing() {
        let lua = started();
        lua.load(
            "recorded.showWindow = true recorded.installHeadset() recorded.direction = { 0, 0, 1 }",
        )
        .exec()
        .expect("the headset should install");

        call(&lua, "load", ());
        lua.load("recorded.trigger = true")
            .exec()
            .expect("the trigger should go down");
        call(&lua, "update", ());

        assert!(
            recorded_calls(&lua).is_empty(),
            "a ray pointing behind the user should reach no sink"
        );
    }

    /// A trigger held while the hand stops being tracked is released, not left
    /// down. A press nothing releases leaves the client holding a button for
    /// the rest of the session.
    #[test]
    fn a_hand_that_stops_being_tracked_releases_what_it_was_holding() {
        let lua = started();
        lua.load("recorded.showWindow = true recorded.installHeadset()")
            .exec()
            .expect("the headset should install");

        call(&lua, "load", ());
        lua.load("recorded.trigger = true")
            .exec()
            .expect("the trigger should go down");
        call(&lua, "update", ());
        lua.load("recorded.tracked['hand/left/point'] = false")
            .exec()
            .expect("the hand should stop being tracked");
        call(&lua, "update", ());

        let calls = recorded_calls(&lua);
        let buttons: Vec<&(String, f64, f64, bool)> =
            calls.iter().filter(|call| call.0 == "button").collect();
        assert_eq!(buttons.len(), 2, "one press and one release");
        assert!(!buttons[1].3, "losing tracking should release the button");
    }

    /// The reload key is how a user leaves safe mode without taking the headset
    /// off, and safe mode binds no other key.
    #[test]
    fn the_reload_key_reloads_and_no_other_key_does() {
        let lua = started();

        call(&lua, "keypressed", "f5");
        call(&lua, "keypressed", "a");

        let reloads: i64 = recorder(&lua)
            .get("reloads")
            .expect("reloads should be counted");
        assert_eq!(reloads, 1, "only the reload key should reload");
    }

    /// Holding both triggers is the controller path to the reload key, so a
    /// user in a headset can leave safe mode without a keyboard. One hold
    /// reloads once, and a short hold does not reload.
    #[test]
    fn holding_both_triggers_reloads_once() {
        let lua = started();
        lua.load("recorded.installHeadset() recorded.tracked['hand/right/point'] = true")
            .exec()
            .expect("the headset should install");
        call(&lua, "load", ());

        lua.load("recorded.trigger = true")
            .exec()
            .expect("the triggers should go down");
        call(&lua, "update", 1.0);
        let reloads = |lua: &Lua| -> i64 {
            recorder(lua)
                .get("reloads")
                .expect("reloads should be counted")
        };
        assert_eq!(reloads(&lua), 0, "a short hold does not reload");
        call(&lua, "update", 1.5);
        assert_eq!(reloads(&lua), 1, "a long hold reloads");
        call(&lua, "update", 5.0);
        assert_eq!(reloads(&lua), 1, "the same hold reloads once");

        lua.load("recorded.trigger = false")
            .exec()
            .expect("the triggers should come up");
        call(&lua, "update", 0.1);
        lua.load("recorded.trigger = true")
            .exec()
            .expect("the triggers should go down again");
        call(&lua, "update", 2.5);
        assert_eq!(reloads(&lua), 2, "a new hold reloads again");
    }

    /// Safe mode must survive a failed reload, because it is the last
    /// configuration left running.
    #[test]
    fn a_reload_that_fails_leaves_safe_mode_running() {
        let lua = started();
        lua.load("recorded.reloaded = false recorded.reloadMessage = 'a deliberate defect'")
            .exec()
            .expect("the reload should be made to fail");

        call(&lua, "keypressed", "f5");

        call(&lua, "update", ());
        let pass: Table = recorder(&lua).get("pass").expect("the pass should exist");
        call(&lua, "draw", pass);
    }

    /// A state with the `lovr.boot` and `lovr.run` that `boot.lua` leaves in
    /// place. The case supplies the body of `lovr.boot`.
    fn booting(boot: &str) -> Lua {
        let lua = environment();
        lua.load(format!(
            "booted = 0
             function lovr.boot()
                 booted = booted + 1
                 {boot}
                 return function() return \"the configuration's own loop\" end
             end
             function lovr.run()
                 if lovr.load then lovr.load(arg) end
                 return function() return \"safe mode's loop\" end
             end
             arg = {{ [0] = 'lunette', [1] = '/config' }}"
        ))
        .exec()
        .expect("the boot scaffolding should load");
        lua
    }

    /// Calls `lovr.boot` the way `vendor/lovr/etc/boot.lua` does, then calls
    /// the frame loop it returns and answers the result.
    fn boot(lua: &Lua) -> String {
        let boot: Function = lovr(lua).get("boot").expect("lovr.boot should be readable");
        boot.call::<Function>(())
            .expect("the wrapper should answer a frame loop rather than raising")
            .call::<String>(())
            .expect("the frame loop should run")
    }

    /// A configuration that will not load produces safe mode, not a black
    /// headset. A user in a headset should not have to take it off to find out
    /// what happened, so the panel shows the load error and how to leave.
    #[test]
    fn a_configuration_that_does_not_load_produces_safe_mode() {
        let lua = booting("error('main.luau:1: a deliberate defect')");
        install_trigger(&lua, BootEntry::Configuration).expect("the trigger should install");

        assert_eq!(boot(&lua), "safe mode's loop");

        let drawn = drawn(&lua);
        assert!(drawn.contains("safe mode"), "{drawn}");
        assert!(
            drawn.contains("main.luau:1"),
            "the load error should have reached safe mode: {drawn}"
        );
        assert!(
            drawn.contains("f5") && drawn.contains("both triggers"),
            "the panel should say how to leave safe mode: {drawn}"
        );
    }

    /// Safe mode replaces the configuration; it does not join it. A
    /// `main.luau` that raised halfway has already installed some of its
    /// callbacks, and `lovr.run` would keep calling them.
    #[test]
    fn a_half_installed_configuration_stops_being_called() {
        let lua = booting(
            "function lovr.mousepressed() end
             function lovr.lunwindowopened() end
             error('main.luau:3: a deliberate defect')",
        );
        install_trigger(&lua, BootEntry::Configuration).expect("the trigger should install");

        boot(&lua);

        assert!(
            lua.load("return lovr.mousepressed == nil and lovr.lunwindowopened == nil")
                .eval::<bool>()
                .expect("readable"),
            "a callback the failed configuration installed should be gone"
        );
    }

    /// Safe mode is for a configuration that will not load, and for nothing else.
    /// Treating a runtime error as a load failure would replace a working session
    /// with the fallback over one bad frame.
    #[test]
    fn a_configuration_that_loads_is_left_alone() {
        let lua = booting("");
        install_trigger(&lua, BootEntry::Configuration).expect("the trigger should install");

        assert_eq!(boot(&lua), "the configuration's own loop");

        assert_eq!(
            lua.load("return booted").eval::<i64>().expect("readable"),
            1,
            "the wrapper should call the real boot exactly once"
        );
        assert!(
            lua.load("return lovr.keypressed == nil")
                .eval::<bool>()
                .expect("readable"),
            "safe mode should not have installed anything over a session that loaded"
        );
    }

    /// A request covers the one boot that follows it. A second restart for
    /// another reason runs the configuration again.
    #[test]
    fn a_request_is_taken_once() {
        let request = SafeModeRequest::default();
        assert_eq!(request.take(), BootEntry::Configuration);

        request.request();
        assert_eq!(request.take(), BootEntry::SafeMode);
        assert_eq!(
            request.take(),
            BootEntry::Configuration,
            "taking the request resets it"
        );
    }

    /// Asking for safe mode queues LÖVR's own restart, and leaves the request
    /// for the next boot to take.
    #[test]
    fn a_restart_into_safe_mode_queues_a_restart() {
        let lua = environment();
        lua.load("restarts = 0 lovr.event = { restart = function() restarts = restarts + 1 end }")
            .exec()
            .expect("the event module should install");
        let request = SafeModeRequest::default();

        restart_into_safe_mode(&lua, &request).expect("the restart is queued");

        assert_eq!(
            lua.load("return restarts").eval::<i64>().expect("readable"),
            1
        );
        assert_eq!(request.take(), BootEntry::SafeMode);
    }

    /// A configuration that disabled the event module cannot restart, and the
    /// request is withdrawn so it does not surprise a later restart.
    #[test]
    fn a_restart_that_cannot_be_queued_withdraws_the_request() {
        let lua = environment();
        let request = SafeModeRequest::default();

        let error =
            restart_into_safe_mode(&lua, &request).expect_err("no event module means no restart");

        assert!(
            error.to_string().starts_with("safe mode: "),
            "an error's context prefix names the subsystem: {error}"
        );
        assert_eq!(request.take(), BootEntry::Configuration);
    }

    /// A requested safe mode starts the modules through LÖVR's boot but does
    /// not run the configuration, and says why it is running.
    #[test]
    fn a_requested_safe_mode_skips_the_configuration() {
        let lua = booting("require('conf') require('main')");
        lua.load(
            "mainRan = false confRan = false
             package.preload.conf = function() confRan = true end
             package.preload.main = function() mainRan = true end
             originalRequire = require",
        )
        .exec()
        .expect("the modules should be preloaded");
        install_trigger(&lua, BootEntry::SafeMode).expect("the trigger should install");

        assert_eq!(boot(&lua), "safe mode's loop");

        let (main_ran, conf_ran, restored) = lua
            .load("return mainRan, confRan, require == originalRequire")
            .eval::<(bool, bool, bool)>()
            .expect("readable");
        assert!(!main_ran, "the configuration's entry should not run");
        assert!(conf_ran, "other modules should still load");
        assert!(restored, "require should be restored after the boot");
        let drawn = drawn(&lua);
        assert!(drawn.contains("requested"), "{drawn}");
    }

    /// A requested safe mode whose boot fails before the configuration still
    /// reaches safe mode, reporting that failure.
    #[test]
    fn a_requested_safe_mode_reports_an_earlier_failure() {
        let lua = booting("error('conf.luau:1: a deliberate defect')");
        install_trigger(&lua, BootEntry::SafeMode).expect("the trigger should install");

        assert_eq!(boot(&lua), "safe mode's loop");

        let drawn = drawn(&lua);
        assert!(drawn.contains("conf.luau:1"), "{drawn}");
    }

    /// Every module `package.loaded` holds, by name.
    fn loaded_modules(lua: &Lua) -> Vec<String> {
        let package: Table = lua
            .globals()
            .get("package")
            .expect("package should be reachable");
        let loaded: Table = package.get("loaded").expect("package.loaded should exist");
        loaded
            .pairs::<String, Value>()
            .filter_map(Result::ok)
            .map(|(name, _)| name)
            .collect()
    }

    /// The sink calls, as `(name, x, y, down)`. A pointer leaves `down` false
    /// and a button leaves the coordinates at zero; each case reads the fields
    /// that its own kind of call carries.
    fn recorded_calls(lua: &Lua) -> Vec<(String, f64, f64, bool)> {
        recorder(lua)
            .get::<Table>("calls")
            .expect("calls should be recorded")
            .sequence_values::<Table>()
            .filter_map(Result::ok)
            .map(|call| {
                (
                    call.get("name").unwrap_or_default(),
                    call.get("x").unwrap_or_default(),
                    call.get("y").unwrap_or_default(),
                    call.get("down").unwrap_or_default(),
                )
            })
            .collect()
    }
}
