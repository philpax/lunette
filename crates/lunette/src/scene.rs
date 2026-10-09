//! Linux-only: controls whether LÖVR acquires and renders the projection layer.
//!
//! A skipped frame still submits an XR frame so composition layers reach the runtime.

use mlua::{Function, Lua, Table, Value};
use tracing::debug;

/// Whether lunette renders its own scene this frame.
///
/// The value is latched at the frame boundary so layer submission and the gate use the same state.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SceneRendering {
    /// `lovr.draw` runs and the projection layer is submitted.
    #[default]
    Drawn,
    /// Skips pass acquisition, `lovr.draw`, and projection-layer submission.
    Skipped,
}

impl SceneRendering {
    /// What the configuration means by `lunette.setSceneEnabled(enabled)`.
    #[must_use]
    pub const fn from_enabled(enabled: bool) -> Self {
        if enabled { Self::Drawn } else { Self::Skipped }
    }

    /// Whether the scene is drawn, which is also the `main` argument
    /// `lovrHeadsetSetLayers` takes.
    #[must_use]
    pub const fn drawn(self) -> bool {
        matches!(self, Self::Drawn)
    }
}

/// What the gate does about one call to `getPass` or `getTexture`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    /// Call LÖVR.
    Through,
    /// Answer nothing.
    Skip,
    /// Submits LÖVR's stream first, because this frame recorded layer copies.
    SkipAfterFlush,
}

impl Gate {
    const fn skips(self) -> bool {
        matches!(self, Self::Skip | Self::SkipAfterFlush)
    }

    const fn flushes(self) -> bool {
        matches!(self, Self::SkipAfterFlush)
    }
}

/// Wraps `lovr.headset`'s swapchain-acquiring methods with `decide`.
///
/// The `package.preload` loader is wrapped because the headset module is created during boot.
/// Lua owns the wrapper, so no reference outlives a state during reload.
///
/// # Errors
///
/// Returns an error if `package.preload` is unavailable or the wrapper chunk fails to load.
pub fn install_gate(lua: &Lua, decide: impl Fn() -> Gate + 'static) -> mlua::Result<()> {
    let preload: Table = lua.globals().get::<Table>("package")?.get("preload")?;

    let Value::Function(loader) = preload.get::<Value>(HEADSET_MODULE)? else {
        debug!(
            "lua: {HEADSET_MODULE} is not preloaded, so nothing gates lunette's scene rendering"
        );
        return Ok(());
    };

    let decide = lua.create_function(move |_, ()| {
        let gate = decide();
        Ok((gate.skips(), gate.flushes()))
    })?;

    let wrap: Function = lua.load(GATE_CHUNK).set_name("@lunette:scene").call(())?;
    preload.set(HEADSET_MODULE, wrap.call::<Function>((loader, decide))?)
}

/// The `package.preload` key LÖVR's headset module is registered under.
const HEADSET_MODULE: &str = "lovr.headset";

/// Wraps `getPass` and `getTexture`, the methods that acquire the colour swapchain.
///
/// `lovr.headset.submit` is not wrapped, because every XR frame must be submitted.
const GATE_CHUNK: &str = r"
local wrap = function(loader, decide)
  local gate = function(original)
    return function(...)
      local skip, flush = decide()
      if not skip then
        return original(...)
      end
      -- Nothing else will submit this frame's layer copies: boot.lua submits
      -- the stream only when it has a pass to submit alongside it, and
      -- lovr.headset.submit releases each layer's swapchain image regardless.
      if flush and lovr and lovr.graphics then
        lovr.graphics.submit()
      end
      return nil
    end
  end

  return function(...)
    local headset = loader(...)
    if type(headset) == 'table' then
      if headset.getPass then
        headset.getPass = gate(headset.getPass)
      end
      if headset.getTexture then
        headset.getTexture = gate(headset.getTexture)
      end
    end
    return headset
  end
end

return wrap
";

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::{cell::Cell, rc::Rc};

    use pretty_assertions::assert_eq;

    use super::*;

    /// A state carrying a `lovr.headset` module that counts what it was asked
    /// for, and a `lovr.graphics` that counts submits.
    struct Fake {
        lua: Lua,
        gate: Rc<Cell<Gate>>,
    }

    impl Fake {
        fn new() -> Self {
            let lua = crate::test_lua::session_lua();
            lua.load(
                r"
                lovr = { graphics = { submits = 0 } }
                lovr.graphics.submit = function()
                  lovr.graphics.submits = lovr.graphics.submits + 1
                end

                headset = { passes = 0, textures = 0, submits = 0 }
                headset.getPass = function()
                  headset.passes = headset.passes + 1
                  return 'pass'
                end
                headset.getTexture = function()
                  headset.textures = headset.textures + 1
                  return 'texture'
                end
                headset.submit = function()
                  headset.submits = headset.submits + 1
                end

                package.preload['lovr.headset'] = function() return headset end
                ",
            )
            .exec()
            .expect("the fake state loads");

            let gate = Rc::new(Cell::new(Gate::Through));
            let reader = Rc::clone(&gate);
            // Clears the flush as `Session::scene_gate` does, so a frame flushes once.
            install_gate(&lua, move || {
                let gate = reader.get();
                if gate == Gate::SkipAfterFlush {
                    reader.set(Gate::Skip);
                }
                gate
            })
            .expect("the gate installs");

            Self { lua, gate }
        }

        /// One frame of `boot.lua`'s loop, with the gated headset calls
        /// included and the rest of the loop left out.
        fn frame(&self) -> Option<String> {
            self.lua
                .load(
                    r"
                    local headset = require('lovr.headset')
                    local pass = headset.getPass()
                    headset.getTexture()
                    headset.submit()
                    return pass
                    ",
                )
                .eval()
                .expect("the frame runs")
        }

        fn count(&self, name: &str) -> u32 {
            self.lua
                .load(format!("return {name}"))
                .eval()
                .expect("the counter is readable")
        }
    }

    #[test]
    fn a_drawn_frame_reaches_lovr_unchanged() {
        let fake = Fake::new();

        assert_eq!(fake.frame(), Some("pass".to_owned()));

        assert_eq!(fake.count("headset.passes"), 1);
        assert_eq!(fake.count("headset.textures"), 1);
        assert_eq!(fake.count("lovr.graphics.submits"), 0);
    }

    #[test]
    fn a_skipped_frame_acquires_nothing_and_still_submits_the_xr_frame() {
        let fake = Fake::new();
        fake.gate.set(Gate::Skip);

        assert_eq!(fake.frame(), None);

        assert_eq!(
            fake.count("headset.passes"),
            0,
            "the acquire and its swapchain wait are what the skip is for"
        );
        assert_eq!(fake.count("headset.textures"), 0);
        assert_eq!(
            fake.count("headset.submits"),
            1,
            "an overlay submits an XR frame every cycle whether or not it drew"
        );
        assert_eq!(fake.count("lovr.graphics.submits"), 0);
    }

    #[test]
    fn a_skipped_frame_that_recorded_copies_submits_the_stream_itself() {
        let fake = Fake::new();
        fake.gate.set(Gate::SkipAfterFlush);

        assert_eq!(fake.frame(), None);

        assert_eq!(
            fake.count("lovr.graphics.submits"),
            1,
            "once for the frame, although the frame made two gated calls"
        );
    }

    #[test]
    fn a_later_skipped_frame_flushes_nothing_of_its_own() {
        let fake = Fake::new();
        fake.gate.set(Gate::SkipAfterFlush);
        fake.frame();

        fake.frame();
        fake.frame();

        assert_eq!(fake.count("lovr.graphics.submits"), 1);
    }

    #[test]
    fn a_state_without_lovr_is_left_alone() {
        let lua = crate::test_lua::session_lua();
        lua.load("package.preload['lovr.headset'] = nil")
            .exec()
            .expect("the state loads");

        install_gate(&lua, || Gate::Skip).expect("a state with no headset module is not an error");
    }

    #[test]
    fn the_gate_translates_to_the_two_answers_the_chunk_reads() {
        assert!(!Gate::Through.skips());
        assert!(!Gate::Through.flushes());
        assert!(Gate::Skip.skips());
        assert!(!Gate::Skip.flushes());
        assert!(Gate::SkipAfterFlush.skips());
        assert!(Gate::SkipAfterFlush.flushes());
    }

    #[test]
    fn the_scene_is_drawn_unless_a_configuration_says_otherwise() {
        assert_eq!(SceneRendering::default(), SceneRendering::Drawn);
        assert_eq!(SceneRendering::from_enabled(true), SceneRendering::Drawn);
        assert_eq!(SceneRendering::from_enabled(false), SceneRendering::Skipped);
        assert!(SceneRendering::Drawn.drawn());
        assert!(!SceneRendering::Skipped.drawn());
    }
}
