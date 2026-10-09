//! Linux-only: the LÖVR side of the layer seam.
//!
//! The LÖVR side applies no policy. [`crate::layers::LayerPool`] applies
//! every policy through the [`LayerBackend`] and [`LayerBlitter`] calls.

use std::{ffi::c_void, ptr::NonNull};

use lunette_lovr::raw::{
    Layer, LayerInfo, lovrHeadsetGetLayerLimit, lovrHeadsetGetSessionGeneration,
    lovrHeadsetSetLayers, lovrLayerCreate, lovrLayerDestroy, lovrLayerGetTexture, lovrRelease,
};

use crate::{
    layers::{
        backend::{LayerBackend, SessionId, SessionPresence},
        blit::LayerBlitter,
        key::LayerKey,
    },
    scene::SceneRendering,
    texture::{CopyableTexture, LovrTexture},
};

/// A LÖVR `Layer` lunette owns a reference to.
///
/// The reference is independent of the one `lovrHeadsetSetLayers` takes
/// while the layer is submitted. It is handed back through
/// [`LayerBackend::destroy`] or [`LayerBackend::abandon`]; dropping it leaks
/// the reference.
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
/// The type is a token. The thread and session guarantee is stated once, at
/// construction; stating it on every method of the trait would make the trait
/// unsafe, and a test fake could not implement it.
#[derive(Debug)]
pub struct LovrLayers(());

impl LovrLayers {
    /// # Safety
    ///
    /// The caller must be the thread that owns LÖVR's headset module, and
    /// must stay that thread for the value's lifetime. LÖVR's headset state is
    /// global and unsynchronised; a second thread holding one of these is a
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
        // and returns zero when there is no system.
        unsafe { lovrHeadsetGetLayerLimit() }
    }

    /// Uses the session generation, not `lovrHeadsetIsActive`. The boolean is the same
    /// before and after a `lovr.headset.stop()` and
    /// `lovr.headset.start()` pair inside one callback,
    /// while the stop destroys every swapchain the pool holds.
    fn session(&self) -> SessionPresence {
        // SAFETY: the thread guarantee above. The call reads two fields of the
        // headset module's state and allocates nothing.
        let generation = unsafe { lovrHeadsetGetSessionGeneration() };
        SessionId::new(generation).map_or(SessionPresence::Absent, SessionPresence::Present)
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

    /// `main` is `scene`. It is false only on a frame where lunette draws nothing:
    /// the projection layer carries everything lunette draws itself, and
    /// submitting it on such a frame composites an image nothing drew into.
    /// [`crate::scene`] has the rest, including why the flag alone saves almost nothing.
    ///
    /// The pointers are gathered into a contiguous array because
    /// `lovrHeadsetSetLayers` takes one. It copies what it keeps out of the
    /// array and retains each layer, so the array does not outlive the call.
    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool {
        let mut pointers: Vec<*mut Layer> = layers.iter().map(|layer| layer.as_ptr()).collect();
        let Ok(count) = u32::try_from(pointers.len()) else {
            return false;
        };

        // SAFETY: the thread guarantee above. Every pointer names a layer this
        // pool holds a reference to. LÖVR validates and retains the replacement
        // list before releasing the previous list.
        unsafe { lovrHeadsetSetLayers(pointers.as_mut_ptr(), count, scene.drawn()) }
    }

    fn destroy(&mut self, layer: Self::Layer) {
        // SAFETY: the thread guarantee above, and the reference being dropped
        // is the one this type holds. LÖVR's own counting determines whether
        // that is the last one; a layer still in the list
        // `lovrHeadsetSetLayers` holds survives this, and is destroyed
        // when that list is replaced.
        unsafe { lovrRelease(layer.0.as_ptr().cast::<c_void>(), Some(lovrLayerDestroy)) };
    }

    fn abandon(&mut self, layer: Self::Layer) {
        self.destroy(layer);
    }
}

/// LÖVR's side of the blit seam.
///
/// A token for the same reason [`LovrLayers`] is one: the guarantee is about
/// the thread, and stating it once at construction keeps the trait
/// implementable by a fake.
#[derive(Debug)]
pub struct LovrBlits(());

impl LovrBlits {
    /// # Safety
    ///
    /// The caller must be the thread that owns LÖVR's graphics and headset modules,
    /// and must stay that thread for the value's lifetime.
    #[must_use]
    pub const unsafe fn new() -> Self {
        Self(())
    }
}

impl LayerBlitter for LovrBlits {
    type Layer = LovrLayer;
    type Texture = LovrTexture;

    fn acquire(&mut self, layer: &Self::Layer) -> Option<Self::Texture> {
        // SAFETY: the thread guarantee above. The layer is one the pool holds a
        // reference to, so its swapchain is live.
        let raw = unsafe { lovrLayerGetTexture(layer.as_ptr()) };
        let raw = NonNull::new(raw)?;

        // SAFETY: the swapchain owns the texture and outlives the returned
        // value. The blit ledger drops the value without releasing it;
        // `LovrTexture` has no destructor, so dropping one takes no reference
        // away.
        Some(unsafe { LovrTexture::borrowed(raw) })
    }

    fn can_copy(&self, source: &Self::Texture, destination: &Self::Texture) -> bool {
        source.can_copy_to(destination)
    }

    /// Delegates to the one copy mechanism in the codebase, so no second
    /// `lovrTextureCopy` call site exists. `window:stabilize()` uses the same
    /// mechanism, so the `syncStream` barriers that order a copy against
    /// LÖVR's own rendering are emitted from one place.
    fn copy(&mut self, source: &Self::Texture, destination: &Self::Texture) -> bool {
        source.copy_to(destination)
    }
}
