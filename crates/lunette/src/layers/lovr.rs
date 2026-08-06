//! Linux-only: the LÖVR side of the layer seam.
//!
//! Nothing here decides anything. Every policy the pool applies is in
//! [`crate::layers::LayerPool`], and this is only the four calls that policy is
//! expressed in terms of.

use std::{ffi::c_void, ptr::NonNull};

use lunette_lovr::raw::{
    Layer, LayerInfo, lovrHeadsetGetLayerLimit, lovrLayerCreate, lovrLayerDestroy, lovrRelease,
};

use crate::layers::{backend::LayerBackend, key::LayerKey};

/// A LÖVR `Layer` lunette owns a reference to.
///
/// A reference rather than the object: `lovrHeadsetSetLayers` takes its own
/// while the layer is submitted, and the whole point of this one is that it is
/// independent of that. It is handed back through [`LayerBackend::destroy`] or
/// [`LayerBackend::abandon`]; dropping it instead leaks the reference.
#[derive(Debug)]
pub struct LovrLayer(NonNull<Layer>);

impl LovrLayer {
    /// The pointer to give LÖVR, for the blit and the submit.
    #[must_use]
    pub const fn as_ptr(&self) -> *mut Layer {
        self.0.as_ptr()
    }
}

/// The frame thread's authority to create and destroy layers.
///
/// A token rather than a unit struct so that the thread and session guarantee
/// is stated once, at construction, instead of on every method of the trait —
/// which would make the trait unsafe and unimplementable by a test fake.
#[derive(Debug)]
pub struct LovrLayers(());

impl LovrLayers {
    /// # Safety
    ///
    /// This must be the thread that owns LÖVR's headset module, and it must
    /// stay that way for as long as the value lives. LÖVR's headset state is
    /// global and unsynchronised, so a second thread holding one of these is a
    /// data race in C.
    #[must_use]
    pub const unsafe fn new() -> Self {
        Self(())
    }
}

impl LayerBackend for LovrLayers {
    type Layer = LovrLayer;

    fn layer_limit(&self) -> u32 {
        // SAFETY: holding a `LovrLayers` is the guarantee that this is the
        // thread that owns the headset module. The call reads one field of it
        // and is answered with zero when there is no session.
        unsafe { lovrHeadsetGetLayerLimit() }
    }

    fn create(&mut self, key: LayerKey) -> Option<Self::Layer> {
        let properties = key.properties();
        let size = key.size().get();
        let info = LayerInfo {
            width: size.width,
            height: size.height,
            stereo: properties.stereo,
            immutable: properties.immutable,
            transparent: properties.transparent,
            filter: properties.filter,
        };

        // SAFETY: the thread guarantee above. `info` is a live local for the
        // duration of the call, and LÖVR copies what it keeps out of it.
        let raw = unsafe { lovrLayerCreate(&raw const info) };
        NonNull::new(raw).map(LovrLayer)
    }

    fn destroy(&mut self, layer: Self::Layer) {
        // SAFETY: the thread guarantee above, and the reference being dropped
        // is the one this type holds. LÖVR's own counting decides whether that
        // is the last one — so a layer still in the list `lovrHeadsetSetLayers`
        // holds survives this, and is destroyed when that list is replaced.
        unsafe { lovrRelease(layer.0.as_ptr().cast::<c_void>(), Some(lovrLayerDestroy)) };
    }

    /// The layer is deliberately not released, which leaks it. Releasing the
    /// reference here would run `lovrLayerDestroy`, and that calls
    /// `xrDestroySwapchain` on a handle `xrDestroySession` has already
    /// invalidated. A few hundred bytes, on a path taken once per lost session,
    /// is the cheaper of the two.
    fn abandon(&mut self, _layer: Self::Layer) {}
}
