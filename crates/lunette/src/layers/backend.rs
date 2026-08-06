//! The seam between the pool's decisions and LÖVR.
//!
//! Everything the pool does is arithmetic over plain data, and everything that
//! is not — creating a `Layer`, destroying one, asking the runtime what it will
//! accept — is behind this trait. The production implementation is
//! [`crate::layers::LovrLayers`]; the tests answer with a counter, and so run
//! with no XR runtime and no device.

use std::fmt;

use crate::layers::key::LayerKey;

/// What the pool needs of LÖVR.
pub trait LayerBackend {
    /// A reference to a live `Layer`.
    ///
    /// The pool holds one for every layer it owns, granted or free, and hands
    /// it back through [`LayerBackend::destroy`].
    type Layer: fmt::Debug;

    /// The most composition layers the runtime accepts in one `xrEndFrame`.
    ///
    /// Zero before a session exists, which is why the pool reads it every frame
    /// rather than once: a session that has not started yet and a session that
    /// was lost look the same from here, and both mean no layer can be held.
    fn layer_limit(&self) -> u32;

    /// Creates a layer with the properties `key` fixes.
    ///
    /// Blocking, and unboundedly so: `lovrLayerCreate` ends in
    /// `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop
    /// with no escape. The pool caps how often it calls this for that reason,
    /// and calls it only at a frame boundary.
    ///
    /// `None` when the runtime refused.
    fn create(&mut self, key: LayerKey) -> Option<Self::Layer>;

    /// Drops the pool's reference to a layer, destroying it if it was the last.
    ///
    /// Only sound while the session that owns the layer's swapchain is alive,
    /// because destruction calls `xrDestroySwapchain` inline.
    fn destroy(&mut self, layer: Self::Layer);
}
