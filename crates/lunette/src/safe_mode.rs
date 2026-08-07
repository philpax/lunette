//! Linux-only: the configuration lunette runs when the user's will not load.
//!
//! The native layer owns exactly one failure path ([the Lua
//! API](../../../docs/lua-api.md#errors)), and this is its payload: a laser, one
//! panel, a terminal, and a reload key. Enough to see something and recover from
//! inside the headset rather than by taking it off to edit a file.
//!
//! It is embedded rather than installed. Safe mode exists for the moment
//! `main.lua` fails to load, and a broken standard library, a missing install,
//! or a bad `LUNETTE_STDLIB_PATH` is one of the reasons it might have — so the
//! fallback must not depend on anything on disk. [`SOURCE`] therefore requires
//! `lunette` and nothing else, and in particular never `mullion`.
//!
//! Phase 7 wires the trigger. This is the payload, kept next to the default
//! configuration it deliberately resembles so the two stay in step.

use mlua::{Function, Lua};

/// The chunk, compiled into the binary.
///
/// `include_str!` rather than a string literal, so the Lua is a Lua file: it is
/// syntax-highlighted, it is diffable against the default configuration it
/// resembles, and the tests below read the same bytes the session runs.
pub const SOURCE: &str = include_str!("safe_mode.lua");

/// What a traceback names the chunk.
///
/// The leading `@` is LuaJIT's marker for a chunk named after a file, which is
/// what makes an error inside safe mode read as `safe-mode.lua:12:` rather than
/// as the first line of the source quoted back.
pub const CHUNK_NAME: &str = "@safe-mode.lua";

/// Compiles [`SOURCE`] against `lua`, without running it.
///
/// The caller runs it, because when it runs is the caller's decision: safe mode
/// replaces `main.lua`, so the chunk is executed at the point in the boot
/// sequence the configuration would have been.
///
/// # Errors
///
/// If the chunk does not compile, which is a defect in [`SOURCE`] rather than
/// anything the session did.
pub fn load(lua: &Lua) -> mlua::Result<Function> {
    lua.load(SOURCE).set_name(CHUNK_NAME).into_function()
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a failed expectation is how a test reports a failure; the ban is on production code"
    )]

    use mlua::{Lua, Table, Value};
    use pretty_assertions::assert_eq;

    use crate::safe_mode::{CHUNK_NAME, load};

    /// The fake `lunette` module, the fake `lovr`, and the recording pass every
    /// case below runs the chunk against.
    ///
    /// In Lua rather than assembled through `mlua`, because what these fakes
    /// have to be is a Lua-shaped API: a window with a `sink` whose methods take
    /// `self`, a `windows()` that answers a fresh table, a headset that reports
    /// a pose. Writing that in Rust would be writing Lua one `create_function`
    /// at a time.
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

      package.preload.lunette = function()
        return {
          windows = function()
            return recorded.showWindow and { recorded.window } or {}
          end,
          spawn = function(options)
            recorded.spawns[#recorded.spawns + 1] = options.argv[1]
            return { id = #recorded.spawns }
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
      return recorded
    "#;

    /// A state carrying the fakes, with the recorder in the global `recorded`.
    fn environment() -> Lua {
        let lua = Lua::new();
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

    /// The recorder, and the `lovr` table the chunk left its callbacks on.
    fn recorder(lua: &Lua) -> Table {
        lua.globals()
            .get("recorded")
            .expect("recorded should exist")
    }

    fn lovr(lua: &Lua) -> Table {
        lua.globals().get("lovr").expect("lovr should exist")
    }

    /// Calls `lovr.<name>` with `arguments`, failing the test if it raised.
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
    /// configuration failed, so it must not reach for one. `package.path` is
    /// emptied and `package.preload` holds `lunette` alone, which is the state a
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
            vec!["lunette".to_owned()],
            "safe mode should require lunette and nothing else"
        );
    }

    #[test]
    fn it_defines_the_callbacks_the_session_calls() {
        let lua = started();
        let lovr = lovr(&lua);

        for name in ["load", "update", "draw", "keypressed", "lunprocessexited"] {
            let defined: Option<mlua::Function> =
                lovr.get(name).expect("the callback should be readable");
            assert!(defined.is_some(), "safe mode should define lovr.{name}");
        }
    }

    /// The frame runs with no graphics module, no headset, and no window, which
    /// is what a session that failed before any of them existed looks like.
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

    #[test]
    fn it_spawns_a_terminal_and_falls_through_to_the_next_when_one_will_not_start() {
        let lua = started();

        call(&lua, "load", ());
        let first = spawns(&lua);
        assert_eq!(first.len(), 1, "load should spawn one candidate");

        let event = lua
            .load("return { process = { id = 1 }, outcome = 'spawnFailed' }")
            .eval::<Table>()
            .expect("the event should build");
        call(&lua, "lunprocessexited", event);

        let second = spawns(&lua);
        assert_eq!(
            second.len(),
            2,
            "a failed spawn should try the next candidate"
        );
        assert_ne!(
            second[0], second[1],
            "the next candidate is a different program"
        );
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

    /// Both hands point, and both deliver. Safe mode has one seat rather than
    /// one per hand, so the two share a cursor — but a session where only the
    /// hand the list happens to name first works would be worse, and is what
    /// this catches.
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
    /// delivers a click, which is what stops safe mode clicking a client the
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

    /// A trigger held while the hand stops being tracked is released rather than
    /// left down. A press nothing releases leaves the client holding a button
    /// for the rest of the session.
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

    /// The reload key does not stop the session on a build whose reload
    /// mechanism is not there yet, and safe mode is the one configuration that
    /// has to survive everything else being broken.
    #[test]
    fn the_reload_key_does_not_raise_without_a_reload_mechanism() {
        let lua = started();

        call(&lua, "keypressed", "f5");
        call(&lua, "keypressed", "a");
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

    /// The programs the fake `lunette.spawn` was asked for, in order.
    fn spawns(lua: &Lua) -> Vec<String> {
        recorder(lua)
            .get::<Table>("spawns")
            .expect("spawns should be recorded")
            .sequence_values::<String>()
            .filter_map(Result::ok)
            .collect()
    }

    /// The sink calls, as `(name, x, y, down)`. A pointer leaves `down` false
    /// and a button leaves the coordinates at zero; each case reads the fields
    /// its own kind of call carries.
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
