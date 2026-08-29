//! Linux-only: whether lunette renders a scene of its own, and what it costs
//! not to.
//!
//! An overlay whose panels are all on composition layers has nothing left to
//! put in a projection layer. `docs/rendering.md` calls that skipping the
//! projection layer, and the name understates what is skipped.
//!
//! # What `setLayers{ main = false }` saves
//!
//! `lovrHeadsetSetLayers`'s third argument becomes `state.showMainLayer`,
//! and all that does at submit is leave the `XrCompositionLayerProjection`
//! out of `XrFrameEndInfo::layers` (`headset.c`). The render pass, the
//! multisample resolve, and the swapchain wait have all already happened by
//! then.
//!
//! The saving is in not asking for the pass. The colour swapchain is acquired
//! lazily, inside `lovrHeadsetGetTexture` and `lovrHeadsetGetPass`, so a
//! frame that calls neither skips the acquire, the `xrWaitSwapchainImage`,
//! the pass, and the resolve. A frame that calls one of them and then sets
//! `main = false` performs the acquire and the wait, then discards the
//! result.
//!
//! # The two calls, not the flag
//!
//! `vendor/lovr/etc/boot.lua` calls `lovr.headset.getPass()` unconditionally,
//! before it has looked at whether `lovr.draw` exists, and `lovr.mirror`
//! calls `lovr.headset.getTexture()` for the desktop window. lunette runs
//! that loop unmodified; `docs/lovr-integration.md` records keeping LÖVR's
//! `lovr.run`. The two calls are wrapped: while the scene is skipped each
//! answers nothing, `boot.lua` then gets no headset pass, and `lovr.draw` is
//! not called.
//!
//! The XR frame is submitted either way. `lovr.headset.submit()` is outside the
//! branch, and `docs/rendering.md` is explicit that an overlay submits every
//! cycle. Leaving the runtime's frame loop would also leave the composition
//! layers unsubmitted.
//!
//! # The flush
//!
//! `if headset or window then lovr.graphics.submit(headset, window) end`
//! (`boot.lua`) is the only thing that submits `state.stream`, and the
//! frame's layer copies are recorded into it (`lovrGraphicsSubmit`,
//! `graphics.c`; `lovrGraphicsPresent` does not touch it). With no window
//! open and no headset pass, that line does not run, and
//! `lovr.headset.submit()` still releases every layer's swapchain image, so
//! the runtime would composite from an image whose copy is still unsubmitted.
//! The gate submits the stream itself on a skipped frame that recorded
//! copies, before answering nothing.

use mlua::{Function, Lua, Table, Value};
use tracing::debug;

/// Whether lunette renders its own scene this frame.
///
/// Latched at the frame boundary, not read live. The `setLayers` call at the
/// start of a frame and the gate that runs in the middle of it read the same
/// value. Reading live would leave a projection layer that nothing drew into
/// presenting stale content for half a frame.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SceneRendering {
    /// `lovr.draw` runs, the projection layer is submitted, and the frame
    /// costs what it always did.
    #[default]
    Drawn,
    /// No pass is acquired, `lovr.draw` is not called, and the projection
    /// layer is left out of `xrEndFrame`.
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
    /// Call LÖVR. This is every frame that draws a scene.
    Through,
    /// Answer nothing.
    Skip,
    /// Answer nothing, having first submitted LÖVR's stream: this frame
    /// recorded layer copies that nothing else will submit. The module note
    /// explains why the flush is needed.
    SkipAfterFlush,
}

impl Gate {
    /// Whether the call is answered or passed through.
    const fn skips(self) -> bool {
        matches!(self, Self::Skip | Self::SkipAfterFlush)
    }

    /// Whether LÖVR's stream is submitted before answering.
    const fn flushes(self) -> bool {
        matches!(self, Self::SkipAfterFlush)
    }
}

/// Wraps `lovr.headset`'s two swapchain-acquiring entry points with `decide`.
///
/// Called once per Lua state, before `boot.lua` runs. The wrap is of the
/// `package.preload` loader, not of the module: the module does not exist
/// until `lovr.boot` requires it, which happens inside the same resume that
/// goes on to run `main.lua`.
///
/// A state with no LÖVR in it, such as every test state and any state where
/// the headset module was not preloaded, is left alone. There is nothing to
/// gate there and nothing to report.
///
/// # Rust holds no reference into Lua
///
/// The wrapper is a Lua closure over the original loader, built by the chunk
/// below; `decide` is a Rust closure that captures no Lua value. This is the
/// same prohibition [`crate::lua`] states, for the same reason: a soft reload
/// discards the Lua state, and a `Function` cached on the Rust side would
/// outlive the state that owned it.
///
/// # Errors
///
/// If `package.preload` cannot be reached, or the chunk cannot be loaded.
pub fn install_gate(lua: &Lua, decide: impl Fn() -> Gate + 'static) -> mlua::Result<()> {
    let preload: Table = lua.globals().get::<Table>("package")?.get("preload")?;

    let Value::Function(loader) = preload.get::<Value>(HEADSET_MODULE)? else {
        debug!(
            "lua: {HEADSET_MODULE} is not preloaded, so nothing gates lunette's scene rendering"
        );
        return Ok(());
    };

    // The two booleans are the shape the chunk consumes. `Gate` is the type
    // the rest of the codebase uses; the translation happens once, here.
    let decide = lua.create_function(move |_, ()| {
        let gate = decide();
        Ok((gate.skips(), gate.flushes()))
    })?;

    let wrap: Function = lua.load(GATE_CHUNK).set_name("@lunette:scene").call(())?;
    preload.set(HEADSET_MODULE, wrap.call::<Function>((loader, decide))?)
}

/// The `package.preload` key LÖVR's headset module is registered under.
const HEADSET_MODULE: &str = "lovr.headset";

/// Builds the loader that gates the module the original loader answers with.
///
/// Built in Lua. The original loader and the original methods stay as
/// upvalues of a Lua closure, which the state collects when it is discarded.
/// Registry references on the Rust side would outlive the discarded state.
///
/// `getPass` and `getTexture` are the two entry points that acquire the colour
/// swapchain (`headset.c`); every other function on the module is untouched.
/// `lovr.headset.submit` keeps its original behaviour: the XR frame is
/// submitted whether or not lunette drew into it.
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
            // Reads the gate once and clears the flush, as `Session::scene_gate`
            // does, so a frame flushes once however many gated calls it makes.
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
        // Otherwise `lovr.headset.submit` releases each layer's swapchain image
        // while the copy into it is still queued in LÖVR's stream.
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
        // The gate flushes only when instructed. `Session::scene_gate`
        // provides the instruction.
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
