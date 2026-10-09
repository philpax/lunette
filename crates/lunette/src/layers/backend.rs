//! The seam between the pool's decisions and LÖVR.
//!
//! Every side effect goes through this trait, so the tests run with no XR runtime and no device.

use std::{fmt, num::NonZeroU32};

use crate::{layers::key::LayerKey, scene::SceneRendering};

/// Which XR session exists, distinguishing one session from the session that replaces it.
///
/// A boolean is not enough, because `lovr.headset.stop()` then `lovr.headset.start()` inside one callback replaces the session without changing presence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPresence {
    /// A session exists. Layers can be created, submitted, and destroyed.
    Present(SessionId),
    /// There is no usable session. Every layer the pool holds goes to [`LayerBackend::destroy`], and no new layer can be created.
    Absent,
}

/// Which session, among the sessions this process has created.
///
/// LÖVR's `lovrHeadsetGetSessionGeneration` counts created sessions and returns zero while there is none.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionId(NonZeroU32);

impl SessionId {
    /// `None` for the zero LÖVR returns when there is no session.
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
    /// A reference to a live `Layer`, held for every layer the pool owns.
    type Layer: fmt::Debug;

    /// The most composition layers the runtime accepts in one `xrEndFrame`.
    ///
    /// Zero while there is no system, so the pool reads it every frame. It says nothing about the session.
    fn layer_limit(&self) -> u32;

    /// Which session owns the pool's layers, if one does.
    ///
    /// Read at every frame boundary, because a session can end or be replaced within one Lua callback. A layer from a destroyed session names an invalidated swapchain.
    fn session(&self) -> SessionPresence;

    /// Creates a layer with the properties `key` fixes, or `None` when the runtime refuses.
    ///
    /// Blocking, because `lovrLayerCreate` waits for a swapchain image, so the pool rate-limits calls at a frame boundary.
    fn create(&mut self, key: LayerKey) -> Option<Self::Layer>;

    /// Hands the runtime the layers to composite, in submit order, and reports whether it accepted them.
    ///
    /// Called every frame with every grantable layer, because a layer left out of the list becomes invisible. `scene` says whether lunette's projection layer belongs in the same `xrEndFrame`.
    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool;

    /// Drops the pool's reference to a layer, destroying it if no other reference remains.
    ///
    /// Native retirement makes this safe after the owning session ends.
    fn destroy(&mut self, layer: Self::Layer);
}
