//! A `Layer` fixes its size at creation, and the free list is keyed by that
//! size.

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
///
/// The size is the whole key. Every layer is created with the same flags,
/// which [`crate::layers::LovrLayers`] sets, and there is exactly one format:
/// `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB`, and session start
/// aborts outright if the runtime refuses it.
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
}
