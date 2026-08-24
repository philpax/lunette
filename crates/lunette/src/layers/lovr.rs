//! Linux-only: the LÖVR side of the layer seam.
//!
//! Nothing here decides anything. Every policy the pool applies is in
//! [`crate::layers::LayerPool`], and this is only the four calls that policy is
//! expressed in terms of.

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
        // and is answered with zero when there is no system.
        unsafe { lovrHeadsetGetLayerLimit() }
    }

    /// The generation rather than `lovrHeadsetIsActive`, because the boolean is
    /// the same on both sides of a `lovr.headset.stop()` and
    /// `lovr.headset.start()` in one callback, while every swapchain the pool
    /// held died in between.
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

    /// `main` is `scene`, which is false only for a frame lunette drew nothing
    /// into: the projection layer carries everything lunette draws itself, so
    /// submitting it on such a frame would composite an image nothing was
    /// rendered into. [`crate::scene`] has the rest, including why the flag on
    /// its own saves almost nothing.
    ///
    /// The pointers are gathered into a contiguous array because
    /// `lovrHeadsetSetLayers` takes one; it copies what it keeps out of it
    /// (`headset.c`) and retains each layer, so the array itself does
    /// not outlive the call.
    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool {
        let mut pointers: Vec<*mut Layer> = layers.iter().map(|layer| layer.as_ptr()).collect();
        let Ok(count) = u32::try_from(pointers.len()) else {
            return false;
        };

        // SAFETY: the thread guarantee above. Every pointer names a layer this
        // pool holds a reference to, so none can be destroyed by the release of
        // the previous list that this call performs before retaining the new
        // one.
        unsafe { lovrHeadsetSetLayers(pointers.as_mut_ptr(), count, scene.drawn()) }
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

/// LÖVR's side of the blit seam.
///
/// A token for the same reason [`LovrLayers`] is one: the guarantee is about the
/// thread, and stating it once at construction keeps the trait implementable by
/// a fake.
#[derive(Debug)]
pub struct LovrBlits(());

impl LovrBlits {
    /// # Safety
    ///
    /// This must be the thread that owns LÖVR's graphics and headset modules,
    /// and it must stay that way for as long as the value lives.
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
        // value, which the blit ledger drops without releasing — `LovrTexture`
        // has no destructor, so dropping one takes no reference away.
        Some(unsafe { LovrTexture::borrowed(raw) })
    }

    fn can_copy(&self, source: &Self::Texture, destination: &Self::Texture) -> bool {
        source.can_copy_to(destination)
    }

    /// Through the one copy mechanism in the codebase, which is why this is a
    /// delegation rather than a second `lovrTextureCopy` call site.
    /// `window:stabilize()` uses the same one, so the `syncStream` barriers that
    /// order a copy against LÖVR's own rendering are emitted from one place.
    fn copy(&mut self, source: &Self::Texture, destination: &Self::Texture) -> bool {
        source.copy_to(destination)
    }
}
