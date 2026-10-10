//! Linux-only: the LÖVR side of the layer seam, which applies no policy of its
//! own.

use std::{ffi::c_void, ptr::NonNull};

use lunette_lovr::raw::{
    Layer, LayerInfo, lovrHeadsetGetLayerLimit, lovrHeadsetGetSessionGeneration,
    lovrHeadsetSetLayers, lovrLayerCreate, lovrLayerDestroy, lovrLayerGetTexture, lovrRelease,
};

use crate::{
    layers::{
        backend::{LayerBackend, SessionId, SessionPresence},
        blit::LayerBlitter,
        key::LayerSize,
    },
    scene::SceneRendering,
    texture::{CopyableTexture, LovrTexture},
};

/// A LÖVR `Layer` lunette owns a reference to.
///
/// The reference is independent of the one `lovrHeadsetSetLayers` takes. It is
/// handed back through [`LayerBackend::destroy`], and dropping it leaks the
/// reference.
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
/// The thread guarantee is stated once, at construction, because stating it on
/// each trait method would make the trait unsafe and unimplementable by a test
/// fake.
#[derive(Debug)]
pub struct LovrLayers(());

impl LovrLayers {
    /// # Safety
    ///
    /// The caller must be the thread that owns LÖVR's headset module, and must
    /// stay that thread for the value's lifetime. LÖVR's headset state is
    /// global and unsynchronised.
    #[must_use]
    pub const unsafe fn new() -> Self {
        Self(())
    }
}

impl LayerBackend for LovrLayers {
    type Layer = LovrLayer;

    fn layer_limit(&self) -> u32 {
        // SAFETY: holding a `LovrLayers` guarantees this is the thread that
        // owns the headset module.
        unsafe { lovrHeadsetGetLayerLimit() }
    }

    /// Uses the session generation, not `lovrHeadsetIsActive`, because a stop
    /// and start inside one callback leaves the boolean unchanged while
    /// destroying every swapchain.
    fn session(&self) -> SessionPresence {
        // SAFETY: the thread guarantee above.
        let generation = unsafe { lovrHeadsetGetSessionGeneration() };
        SessionId::new(generation).map_or(SessionPresence::Absent, SessionPresence::Present)
    }

    /// Every layer is mono, mutable, opaque, and filtered. Nothing produces
    /// stereo content, and a pooled layer is reused, so it cannot be
    /// immutable: LÖVR raises on the second acquire of an immutable layer.
    ///
    /// Opaque composition resolves the X-variant alpha problem, and no other
    /// resolution exists on this path. `Xrgb8888` and `Xbgr8888` have no alpha
    /// channel, so they are imported as the alpha-carrying format with the
    /// same component order, and whatever the client left in the padding byte
    /// arrives as alpha. The in-scene quad forces alpha to one in a fragment
    /// stage. A composition layer reaches the runtime with no shader and no
    /// Lua consumer. A copy cannot fix the alpha either: `lovrTextureCopy`
    /// and `lovrTextureBlit` are `vkCmdCopyImage` and `vkCmdBlitImage`, which
    /// read the image, not a view, so an image-view swizzle does not reach
    /// them. The layer's blend flag is the remaining control, and turning it
    /// off makes the padding byte unreachable for every source format;
    /// renegotiating the format does not change that. LÖVR maps the flag to
    /// `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT`.
    ///
    /// The cost is that a translucent client is composited opaque while it
    /// holds a layer. A translucent panel renders as an in-scene quad, where
    /// the shader path resolves alpha. Lua chooses between sharpness and
    /// translucency by claiming a layer or not. `docs/dev/rendering.md` records
    /// this.
    fn create(&mut self, size: LayerSize) -> Option<Self::Layer> {
        let size = size.get();
        let info = LayerInfo {
            width: size.width,
            height: size.height,
            stereo: false,
            immutable: false,
            transparent: false,
            filter: true,
        };

        // SAFETY: the thread guarantee above. `info` is a live local for the
        // duration of the call, and LÖVR copies what it keeps out of it.
        let raw = unsafe { lovrLayerCreate(&raw const info) };
        NonNull::new(raw).map(LovrLayer)
    }

    /// `main` is false only on a frame where lunette draws nothing, because
    /// submitting the projection layer then composites an image nothing drew
    /// into. [`crate::scene`] explains the rest.
    ///
    /// `lovrHeadsetSetLayers` copies what it keeps out of the array, so the
    /// array does not outlive the call.
    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool {
        let mut pointers: Vec<*mut Layer> = layers.iter().map(|layer| layer.as_ptr()).collect();
        let Ok(count) = u32::try_from(pointers.len()) else {
            return false;
        };

        // SAFETY: the thread guarantee above. Every pointer names a layer this
        // pool holds a reference to.
        unsafe { lovrHeadsetSetLayers(pointers.as_mut_ptr(), count, scene.drawn()) }
    }

    fn destroy(&mut self, layer: Self::Layer) {
        // SAFETY: the thread guarantee above, and the reference dropped is the
        // one this type holds. A layer still in the submitted list survives
        // until that list is replaced.
        unsafe { lovrRelease(layer.0.as_ptr().cast::<c_void>(), Some(lovrLayerDestroy)) };
    }
}

/// LÖVR's side of the blit seam.
///
/// A token for the same reason [`LovrLayers`] is one.
#[derive(Debug)]
pub struct LovrBlits(());

impl LovrBlits {
    /// # Safety
    ///
    /// The caller must be the thread that owns LÖVR's graphics and headset
    /// modules,
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
        // value. `LovrTexture` has no destructor, so dropping one takes no
        // reference away.
        Some(unsafe { LovrTexture::borrowed(raw) })
    }

    fn can_copy(&self, source: &Self::Texture, destination: &Self::Texture) -> bool {
        source.can_copy_to(destination)
    }

    /// Delegates to the one copy mechanism `window:stabilize()` also uses, so
    /// the `syncStream` barriers come from one place.
    fn copy(&mut self, source: &Self::Texture, destination: &Self::Texture) -> bool {
        source.copy_to(destination)
    }
}
