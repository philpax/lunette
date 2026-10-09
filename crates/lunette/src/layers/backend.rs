//! The seam between the pool's decisions and LÖVR.
//!
//! The pool's decisions are arithmetic over plain data. Everything with a
//! side effect, creating a `Layer`, destroying one, and reading what the
//! runtime accepts, happens through this trait. The production implementation
//! is [`crate::layers::LovrLayers`]; the tests use a fake counter and run
//! with no XR runtime and no device.

use std::{fmt, num::NonZeroU32};

use crate::{layers::key::LayerKey, scene::SceneRendering};

/// Which XR session exists, distinguishing one session from the session that
/// replaces it.
///
/// An identity carries more than a boolean. A boolean holds presence, and
/// presence is the same on both frame boundaries around the transition.
/// `lovr.headset.stop()` followed by `lovr.headset.start()` inside one Lua
/// callback destroys every swapchain the pool holds and builds a session
/// that has none of them. A pool reading presence sees no transition and
/// continues submitting handles the first `xrDestroySession` invalidated.
///
/// The identity is not derivable from [`LayerBackend::layer_limit`] either.
/// LÖVR takes the limit from the system, not from the session (`headset.c`),
/// and the system remains when a session stops.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPresence {
    /// A session exists. Layers can be created, submitted, and destroyed.
    Present(SessionId),
    /// There is no usable session. Every layer the pool holds has retired
    /// backing, and each one goes to [`LayerBackend::destroy`]. No new layer
    /// can be created until a session exists again.
    Absent,
}

/// Which session, among the sessions this process has created.
///
/// LÖVR's `lovrHeadsetGetSessionGeneration` counts the sessions created and
/// returns zero while there is none. A non-zero value names exactly one of
/// those sessions, and comparing two values shows whether they name the
/// same session. The pool compares values for equality and does nothing
/// else with them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionId(NonZeroU32);

impl SessionId {
    /// `None` for the zero LÖVR returns when there is no session. The zero
    /// maps to [`SessionPresence::Absent`], not to a session with a number.
    #[must_use]
    pub const fn new(generation: u32) -> Option<Self> {
        match NonZeroU32::new(generation) {
            Some(generation) => Some(Self(generation)),
            None => None,
        }
    }
}

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "session {}", self.0)
    }
}

/// What the pool needs of LÖVR.
pub trait LayerBackend {
    /// A reference to a live `Layer`.
    ///
    /// The pool holds one for every layer it owns, granted or free, and hands
    /// it back through [`LayerBackend::destroy`].
    type Layer: fmt::Debug;

    /// The most composition layers the runtime accepts in one `xrEndFrame`.
    ///
    /// Zero while there is no system. The pool reads it every frame, not
    /// once, because the value stays zero until a system appears. It is not
    /// an answer about the session:
    /// [`LayerBackend::session`] reports whether the swapchains the pool holds
    /// still name anything.
    fn layer_limit(&self) -> u32;

    /// Which session owns the pool's layers, if one does.
    ///
    /// Read at every frame boundary. A session can end while a live
    /// Lua state runs: `lovr.headset.stop()` releases every layer and calls
    /// `xrDestroySession` (`headset.c`). Another session can replace it
    /// within the same callback, because `lovr.headset.start()` is callable
    /// there. The pool gives up everything it holds for either. The answer
    /// names the session: a layer from a destroyed session names an
    /// invalidated swapchain whether or not another session has replaced the
    /// destroyed one.
    fn session(&self) -> SessionPresence;

    /// Creates a layer with the properties `key` fixes.
    ///
    /// Blocking: `lovrLayerCreate` waits for a swapchain image with
    /// `XR_INFINITE_DURATION`. Runtime errors return without an endless retry
    /// loop. The pool caps how often it calls this and calls it at a frame
    /// boundary.
    ///
    /// `None` when the runtime refused.
    fn create(&mut self, key: LayerKey) -> Option<Self::Layer>;

    /// Hands the runtime the layers to composite, in submit order.
    ///
    /// Called every frame with every grantable layer, copied into this frame or
    /// not. `xrEndFrame` re-composites from the most recently released image,
    /// so a layer left out of this list becomes invisible: its panel
    /// disappears.
    ///
    /// `scene` is whether lunette's own projection layer belongs in the same
    /// `xrEndFrame`. It goes with the list because `lovrHeadsetSetLayers` is
    /// the call that carries it, and [`crate::scene`] records what else
    /// skipping the scene involves.
    ///
    /// Reports whether the runtime accepted the list.
    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool;

    /// Drops the pool's reference to a layer, destroying the layer if no
    /// other reference remains.
    ///
    /// Native retirement makes this safe after the owning session ends too.
    fn destroy(&mut self, layer: Self::Layer);
}
