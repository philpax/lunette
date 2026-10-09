//! Linux-specific embedded fallback configuration for startup failures.
//!
//! Safe mode runs when `lovr.boot` or `lovr.load` fails. It uses no file-backed
//! module roots, so it can run when the standard library or installation is
//! unavailable. Other callback failures use [`crate::callback_error`]. A failed
//! reload leaves the current session running. See
//! [error handling](../../../docs/dev/lua-api.md#errors).

use mlua::{Function, Lua, Table, Value};
use tracing::{error, info};

use crate::reload;

/// The safe-mode Lua source embedded in the binary.
pub const SOURCE: &str = include_str!("safe_mode.luau");

/// The chunk name used in safe-mode tracebacks.
pub const CHUNK_NAME: &str = "@safe-mode.luau";

/// Compiles [`SOURCE`] without running it.
///
/// # Errors
///
/// Returns a compilation error if [`SOURCE`] is invalid.
pub fn load(lua: &Lua) -> mlua::Result<Function> {
    lua.load(SOURCE).set_name(CHUNK_NAME).into_function()
}

/// Installs a `lovr.boot` wrapper that starts safe mode when startup fails.
///
/// Call after `boot.lua` creates `lovr` and before its coroutine resumes. The
/// wrapper covers `lovr.load`; later callback failures remain outside this boundary.
///
/// # Errors
///
/// Returns an error if `lovr.boot` cannot be read or replaced.
pub fn install_trigger(lua: &Lua) -> mlua::Result<()> {
    let lovr: Table = lua.globals().get("lovr")?;
    let boot: Function = lovr.get("boot")?;

    let wrapper = lua.create_function(move |lua, ()| match boot.call::<Value>(()) {
        Ok(loop_function) => Ok(loop_function),
        Err(failure) => start(lua, &failure),
    })?;
    lovr.set("boot", wrapper)
}

/// Runs safe mode and returns its frame loop.
///
/// The host logs the load error and passes it to the safe-mode chunk.
///
/// # Errors
///
/// Returns an error if safe mode does not load or run.
fn start(lua: &Lua, failure: &mlua::Error) -> mlua::Result<Value> {
    let reported = failure.to_string();
    error!("lua: the configuration could not be loaded, so safe mode is running: {reported}");

    if let Err(error) = reload::clear_user_callbacks(&lua.globals()) {
        error!("lua: the failed configuration's callbacks could not be cleared: {error}");
    }

    load(lua)?.call::<()>(reported)?;
    info!("safe mode is running; fix the configuration and press the reload key");

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

    use crate::safe_mode::{CHUNK_NAME, install_trigger, load};

    /// The fake `lunette` module, the fake `lovr`, and the recording pass every
    /// case below runs the chunk against.
    ///
    /// The fakes are written in Lua, not assembled through `mlua`, because they
    /// must be a Lua-shaped API: a window with a `sink` whose methods take
    /// `self`, a `windows()` that answers a fresh table, a headset that reports
    /// a pose. Writing them in Rust means writing Lua one `create_function` at
    /// a time.
    const ENVIRONMENT: &str = r#"
      local recorded = { spawns = {}, calls = {}, planes = 0, texts = 0, lines = {} }

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
      function recorded.pass:line(...)
        recorded.lines[#recorded.lines + 1] = { ... }
      end
      function recorded.pass:setMaterial() end
      function recorded.pass:setShader() end
      function recorded.pass:setBlendMode() end

      -- A headset whose tracked hands are the keys of `recorded.tracked`, aimed
      -- by `recorded.direction` from `recorded.origin`, with the trigger in
      -- `recorded.trigger`. The left hand alone by default, so that a case
      -- about one hand counts one hand's calls.
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
        started_after(())
    }

    /// As [`started`], with the load error passed to safe mode.
    fn started_after(load_error: impl mlua::IntoLuaMulti) -> Lua {
        let lua = environment();
        let chunk = load(&lua).expect("the safe-mode chunk should compile");
        chunk.call::<()>(load_error).expect("the chunk should run");
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

    #[test]
    fn the_chunk_compiles_and_is_named_for_a_traceback() {
        let lua = environment();

        load(&lua).expect("the safe-mode chunk should compile");

        assert!(
            CHUNK_NAME.starts_with('@'),
            "a chunk name without the leading @ is quoted into every traceback"
        );
    }

    /// Safe mode runs when the standard library may be the reason the
    /// configuration failed, so it must not depend on one. `package.path` is
    /// emptied and `package.preload` holds `lunette` alone, the state a
    /// session with no standard library mounted is in.
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

    #[test]
    fn it_defines_the_callbacks_the_session_calls() {
        let lua = started();
        let lovr = lovr(&lua);

        for name in ["load", "update", "draw", "keypressed"] {
            let defined: Option<mlua::Function> =
                lovr.get(name).expect("the callback should be readable");
            assert!(defined.is_some(), "safe mode should define lovr.{name}");
        }
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

    /// Safe mode exposes one seat, so both hands use the same cursor.
    #[test]
    fn both_hands_reach_the_panel() {
        let lua = started();
        lua.load(
            "recorded.showWindow = true recorded.installHeadset() \
             recorded.tracked['hand/right/point'] = true",
        )
        .exec()
        .expect("the headset should install");

        call(&lua, "load", ());
        call(&lua, "update", ());

        let pointers = recorded_calls(&lua)
            .into_iter()
            .filter(|call| call.0 == "pointer")
            .count();
        assert_eq!(
            pointers, 2,
            "each tracked hand should deliver its own pointer"
        );
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

    /// A second broken configuration leaves safe mode running and shows why.
    /// Safe mode is the configuration that must survive everything else
    /// being broken. A reload that failed must not stop it.
    #[test]
    fn a_reload_that_fails_leaves_safe_mode_running() {
        let lua = started();
        lua.load("recorded.reloaded = false recorded.reloadMessage = 'a deliberate defect'")
            .exec()
            .expect("the reload should be made to fail");

        call(&lua, "keypressed", "f5");

        // A frame after the failed reload still runs; the update and draw
        // calls below check that it does.
        call(&lua, "update", ());
        let pass: Table = recorder(&lua).get("pass").expect("the pass should exist");
        call(&lua, "draw", pass);
    }

    /// A user in a headset should not have to take it off to find out what
    /// happened. That requirement is the reason the safe mode loop exists.
    #[test]
    fn the_load_error_is_shown_rather_than_only_logged() {
        let lua = started_after("main.luau:12: '=' expected near 'panel'");

        let drawn = drawn(&lua);

        assert!(drawn.contains("safe mode"), "{drawn}");
        assert!(
            drawn.contains("main.luau:12") && drawn.contains("expected near"),
            "the panel should say why the configuration did not load: {drawn}"
        );
        assert!(
            drawn.contains("f5"),
            "the panel should say how to leave safe mode: {drawn}"
        );
    }

    #[test]
    fn a_load_error_too_long_for_the_panel_is_truncated() {
        let lua = started_after("x".repeat(10_000));

        let drawn = drawn(&lua);

        assert!(
            drawn.contains('…'),
            "a traceback is long and a headset is not a terminal: {drawn}"
        );
        assert!(
            drawn.lines().count() < 20,
            "the panel should not be a scrollback: {drawn}"
        );
    }

    #[test]
    fn a_frame_runs_with_no_load_error_at_all() {
        let lua = started_after(mlua::Value::Nil);

        let drawn = drawn(&lua);

        assert!(drawn.contains("safe mode"), "{drawn}");
    }

    /// A Lua state shaped like the one `boot.lua`'s chunk leaves: a `lovr.boot`
    /// that the coroutine calls, and a `lovr.run` that answers a frame loop.
    ///
    /// The case supplies the `boot` body. The rest of the scaffolding
    /// reproduces what `boot.lua` leaves in place.
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
    /// headset.
    #[test]
    fn a_configuration_that_does_not_load_produces_safe_mode() {
        let lua = booting("error('main.luau:1: a deliberate defect')");
        install_trigger(&lua).expect("the trigger should install");

        assert_eq!(boot(&lua), "safe mode's loop");

        let drawn = drawn(&lua);
        assert!(drawn.contains("safe mode"), "{drawn}");
        assert!(
            drawn.contains("main.luau:1"),
            "the load error should have reached safe mode: {drawn}"
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
        install_trigger(&lua).expect("the trigger should install");

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
        install_trigger(&lua).expect("the trigger should install");

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

    /// The trigger works when the standard library is broken, so it must not need
    /// one either.
    #[test]
    fn the_trigger_works_with_no_standard_library_anywhere() {
        let lua = booting("error('main.luau:1: a deliberate defect')");
        lua.load("package.path = '' package.cpath = ''")
            .exec()
            .expect("the search path should be emptied");
        install_trigger(&lua).expect("the trigger should install");

        assert_eq!(boot(&lua), "safe mode's loop");
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
