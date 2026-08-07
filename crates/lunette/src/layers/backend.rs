//! The seam between the pool's decisions and LÖVR.
//!
//! Everything the pool does is arithmetic over plain data, and everything that
//! is not — creating a `Layer`, destroying one, asking the runtime what it will
//! accept — is behind this trait. The production implementation is
//! [`crate::layers::LovrLayers`]; the tests answer with a counter, and so run
//! with no XR runtime and no device.

use std::fmt;

use crate::{layers::key::LayerKey, scene::SceneRendering};

/// Whether the XR session that owns the pool's swapchains exists.
///
/// Not derivable from [`LayerBackend::layer_limit`], which is why it is asked
/// separately. LÖVR reads the limit off the *system* rather than off the
/// session (`headset.c:980-982`), and the system survives a session being
/// stopped — so a pool that inferred loss from a zero limit would miss the one
/// case that matters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPresence {
    /// A session exists. Layers can be created, submitted, and destroyed.
    Present,
    /// There is no session. Every layer the pool holds names a swapchain
    /// `xrDestroySession` invalidated, so they are given up through
    /// [`LayerBackend::abandon`] rather than destroyed, and no new one can be
    /// created until a session comes back.
    Absent,
}

/// What the pool needs of LÖVR.
pub trait LayerBackend {
    /// A reference to a live `Layer`.
    ///
    /// The pool holds one for every layer it owns, granted or free, and hands
    /// it back through exactly one of [`LayerBackend::destroy`] and
    /// [`LayerBackend::abandon`].
    type Layer: fmt::Debug;

    /// The most composition layers the runtime accepts in one `xrEndFrame`.
    ///
    /// Zero before a system has been found, which is why the pool reads it
    /// every frame rather than once. It is not an answer about the session:
    /// [`LayerBackend::session`] is the one that reports whether the swapchains
    /// the pool holds still name anything.
    fn layer_limit(&self) -> u32;

    /// Whether the session that owns the pool's layers exists.
    ///
    /// Read at every frame boundary. A session can go away underneath a live
    /// Lua state — `lovr.headset.stop()` releases every layer and calls
    /// `xrDestroySession` (`headset.c:1248-1297`) — and the pool answers a
    /// transition to [`SessionPresence::Absent`] by giving up everything it
    /// holds, because a layer that outlived its session names an invalidated
    /// swapchain.
    fn session(&self) -> SessionPresence;

    /// Creates a layer with the properties `key` fixes.
    ///
    /// Blocking, and unboundedly so: `lovrLayerCreate` ends in
    /// `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop
    /// with no escape. The pool caps how often it calls this for that reason,
    /// and calls it only at a frame boundary.
    ///
    /// `None` when the runtime refused.
    fn create(&mut self, key: LayerKey) -> Option<Self::Layer>;

    /// Hands the runtime the layers to composite, in submit order.
    ///
    /// Called every frame with every grantable layer, copied into this frame or
    /// not. `xrEndFrame` re-composites from the most recently released image,
    /// so a layer left out of this list does not hold still — its panel
    /// disappears.
    ///
    /// `scene` is whether lunette's own projection layer belongs in the same
    /// `xrEndFrame`. It rides with the list because `lovrHeadsetSetLayers` is
    /// the one call that carries it, and [`crate::scene`] records why that flag
    /// is the smaller half of skipping the scene.
    ///
    /// Reports whether the runtime accepted the list.
    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool;

    /// Drops the pool's reference to a layer, destroying it if it was the last.
    ///
    /// Only sound while the session that owns the layer's swapchain is alive,
    /// because destruction calls `xrDestroySwapchain` inline.
    fn destroy(&mut self, layer: Self::Layer);

    /// Gives up a layer whose session is already gone.
    ///
    /// Separate from [`LayerBackend::destroy`] because destroying is the wrong
    /// call after session loss rather than merely a wasted one: the swapchain
    /// handle inside the layer was invalidated by `xrDestroySession`, and
    /// `lovrLayerDestroy` calls `xrDestroySwapchain` on it unconditionally and
    /// inline, which is a use-after-free in the runtime.
    fn abandon(&mut self, layer: Self::Layer);
}
