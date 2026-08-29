//! A `Layer` fixes its key at creation, and the free list is keyed by that
//! key.

use std::fmt;

use lunette_compositor::protocol::PixelSize;

use crate::scale::quantize_dimension;

/// A layer size on the ladder [`crate::scale`] defines.
///
/// The field is private, and the sole constructor quantises. A size that has
/// not passed through [`LayerSize::quantized`] cannot become a key.
///
/// In the absence of quantisation, two panels a pixel apart take two `Layer`s.
/// Neither ever matches the other's free-list entry, and a drag resize
/// allocates a layer every frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LayerSize(PixelSize);

impl LayerSize {
    /// Rounds a requested size up to the ladder.
    ///
    /// `None` if either dimension is zero; see [`quantize_dimension`].
    #[must_use]
    pub fn quantized(requested: PixelSize) -> Option<Self> {
        Some(Self(PixelSize::new(
            quantize_dimension(requested.width)?,
            quantize_dimension(requested.height)?,
        )))
    }

    #[must_use]
    pub const fn get(self) -> PixelSize {
        self.0
    }
}

impl fmt::Display for LayerSize {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// The four booleans `LayerInfo` freezes alongside the size.
///
/// The fields are named. Four positional booleans are easy to pass in the
/// wrong order, and each of the four changes what the runtime does with the
/// layer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LayerProperties {
    /// The layer shows two views. It costs two slots of the budget, because
    /// `lovrHeadsetSetLayers` counts the stereo layer that way.
    pub stereo: bool,
    /// The layer is written once and never rewritten. The pool never sets
    /// this flag, because a pooled layer is reused and LÖVR raises on the
    /// second acquire of an immutable layer.
    pub immutable: bool,
    /// Whether the runtime reads the layer's alpha channel. LÖVR maps this to
    /// `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT`; without it the
    /// layer composites as opaque and the alpha channel is ignored.
    pub transparent: bool,
    /// The runtime samples the layer with filtering. Sampling is
    /// nearest-neighbour when the flag is clear.
    pub filter: bool,
}

impl LayerProperties {
    /// The defaults for a panel layer: one view, a reusable layer, opaque
    /// composition, and filtered sampling.
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
    /// renegotiating the format does not change that.
    ///
    /// The cost is that a translucent client is composited opaque while it
    /// holds a layer. A translucent panel renders as an in-scene quad, where
    /// the shader path resolves alpha. Lua chooses between sharpness and
    /// translucency by claiming a layer or not. `docs/rendering.md` records
    /// this.
    pub const PANEL: Self = Self {
        stereo: false,
        immutable: false,
        transparent: false,
        filter: true,
    };
}

/// Everything a `Layer` fixes at creation, and everything a free-list entry
/// must match for a claim to reuse it.
///
/// A named type: it is a domain type, it appears in several signatures, and a
/// bare `(u32, u32, bool, bool, bool, bool)` is unreadable at each of them.
///
/// `format` is absent. There is exactly one format: `lovrSwapchainInit`
/// hard-codes `VK_FORMAT_R8G8B8A8_SRGB`, and session start aborts outright if
/// the runtime refuses it. A format field would imply a choice that does not
/// exist.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct LayerKey {
    size: LayerSize,
    properties: LayerProperties,
}

impl LayerKey {
    #[must_use]
    pub const fn new(size: LayerSize, properties: LayerProperties) -> Self {
        Self { size, properties }
    }

    #[must_use]
    pub const fn size(self) -> LayerSize {
        self.size
    }

    #[must_use]
    pub const fn properties(self) -> LayerProperties {
        self.properties
    }

    /// How much of the runtime's layer budget one of these spends.
    ///
    /// A stereo layer spends two, because `lovrHeadsetSetLayers` inserts the
    /// right-eye copy as its own entry and checks the doubled total. The Lua
    /// wrapper checks the object count; the two disagree, and the native
    /// check is the binding one.
    #[must_use]
    pub const fn slots(self) -> u32 {
        if self.properties.stereo { 2 } else { 1 }
    }
}

impl fmt::Display for LayerKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.size)?;
        for (name, set) in [
            ("stereo", self.properties.stereo),
            ("immutable", self.properties.immutable),
            ("transparent", self.properties.transparent),
            ("filter", self.properties.filter),
        ] {
            if set {
                write!(f, " {name}")?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn size(width: u32, height: u32) -> LayerSize {
        LayerSize::quantized(PixelSize::new(width, height)).expect("a positive size has a rung")
    }

    #[test]
    fn two_sizes_a_pixel_apart_share_a_key() {
        assert_eq!(size(1000, 1000), size(1001, 1000));
    }

    #[test]
    fn a_quantised_size_is_at_least_the_size_asked_for() {
        let quantised = size(1920, 1080).get();

        assert!(quantised.width >= 1920 && quantised.height >= 1080);
    }

    #[test]
    fn a_size_with_no_extent_has_no_key() {
        assert_eq!(LayerSize::quantized(PixelSize::new(0, 512)), None);
        assert_eq!(LayerSize::quantized(PixelSize::new(512, 0)), None);
    }

    #[test]
    fn keys_differing_only_in_a_property_are_different_keys() {
        let mono = LayerKey::new(size(512, 512), LayerProperties::PANEL);
        let stereo = LayerKey::new(
            size(512, 512),
            LayerProperties {
                stereo: true,
                ..LayerProperties::PANEL
            },
        );

        assert_ne!(mono, stereo);
    }

    #[test]
    fn a_stereo_layer_spends_two_slots_of_the_budget() {
        let mono = LayerKey::new(size(512, 512), LayerProperties::PANEL);
        let stereo = LayerKey::new(
            size(512, 512),
            LayerProperties {
                stereo: true,
                ..LayerProperties::PANEL
            },
        );

        assert_eq!(mono.slots(), 1);
        assert_eq!(stereo.slots(), 2);
    }
}
