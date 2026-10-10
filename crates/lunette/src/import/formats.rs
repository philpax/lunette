//! Which client pixel formats lunette can import, and how each is spelled.
//!
//! Three vocabularies describe a client buffer. The client names its buffer
//! with a DRM fourcc, Vulkan creates the image with a `VkFormat`, and LÖVR
//! attaches a `TextureFormat` to the image. The module is the single place
//! the three are related, so a mismatch between them is one edit to correct.
//!
//! Each function in this module is pure: it takes data in, returns data out,
//! and performs no I/O. The `format_properties` queries that narrow the table
//! to what the hardware accepts are in [`crate::import::device`], because
//! they need a device and these do not.
//!
//! # The X variants
//!
//! `Xrgb8888`, `Xbgr8888`, and `Xbgr2101010` have no alpha channel; the fourth
//! component is undefined padding. Vulkan has no matching format for these
//! fourccs, so each maps to the alpha-carrying format with the same component
//! order, and the value a client leaves in the padding byte arrives as alpha.
//! [`Alpha::Opaque`] records the distinction. WayVR's `fourcc_to_vk`
//! (`graphics/dmabuf.rs`) maps the same six fourccs without recording the
//! distinction, so its X-format content renders with arbitrary transparency.

use ash::vk;
use lunette_lovr::raw::{TextureFormat, TextureFormat_FORMAT_BGRA8, TextureFormat_FORMAT_RGBA8};
use smithay::backend::allocator::{Format, Fourcc, Modifier};

/// Whether a format's fourth component carries alpha or padding.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Alpha {
    /// The fourth component is alpha, and a consumer samples it.
    Present,
    /// The fourth component is undefined padding, and a consumer forces it to
    /// one. Sampling it renders the surface with arbitrary transparency.
    Opaque,
}

/// How one client format is spelled in Vulkan and in LÖVR.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FormatMapping {
    pub fourcc: Fourcc,
    pub vulkan: vk::Format,
    /// LÖVR's `TextureFormat`, which `convertFormat` (`gpu_vk.c`) maps back to
    /// [`FormatMapping::vulkan`]. The two must agree. LÖVR accepts the
    /// imported image's format without checking it against the image's Vulkan
    /// format, so a mismatch goes undetected.
    pub texture: TextureFormat,
    pub alpha: Alpha,
}

/// The formats lunette imports, in the order they are advertised.
///
/// WayVR imports the same six fourccs. Multi-plane YUV is not imported,
/// because importing it needs a per-plane binding path the design does not
/// have.
pub const SUPPORTED: [FormatMapping; 6] = [
    FormatMapping {
        fourcc: Fourcc::Argb8888,
        vulkan: vk::Format::B8G8R8A8_UNORM,
        texture: TextureFormat_FORMAT_BGRA8,
        alpha: Alpha::Present,
    },
    FormatMapping {
        fourcc: Fourcc::Xrgb8888,
        vulkan: vk::Format::B8G8R8A8_UNORM,
        texture: TextureFormat_FORMAT_BGRA8,
        alpha: Alpha::Opaque,
    },
    FormatMapping {
        fourcc: Fourcc::Abgr8888,
        vulkan: vk::Format::R8G8B8A8_UNORM,
        texture: TextureFormat_FORMAT_RGBA8,
        alpha: Alpha::Present,
    },
    FormatMapping {
        fourcc: Fourcc::Xbgr8888,
        vulkan: vk::Format::R8G8B8A8_UNORM,
        texture: TextureFormat_FORMAT_RGBA8,
        alpha: Alpha::Opaque,
    },
    FormatMapping {
        fourcc: Fourcc::Abgr2101010,
        vulkan: vk::Format::A2B10G10R10_UNORM_PACK32,
        texture: RGB10A2,
        alpha: Alpha::Present,
    },
    FormatMapping {
        fourcc: Fourcc::Xbgr2101010,
        vulkan: vk::Format::A2B10G10R10_UNORM_PACK32,
        texture: RGB10A2,
        alpha: Alpha::Opaque,
    },
];

/// The mapping for a client's fourcc, or nothing when lunette cannot import it.
#[must_use]
pub fn mapping_for(fourcc: Fourcc) -> Option<FormatMapping> {
    SUPPORTED.into_iter().find(|entry| entry.fourcc == fourcc)
}

/// Keeps the modifiers backed by a single plane, in the order reported.
///
/// A modifier whose layout spans several planes needs one memory allocation
/// per plane and `VkBindImagePlaneMemoryInfo` to bind them; the design rejects
/// that disjoint path. Filtering means such a modifier is never advertised,
/// so a client does not choose one and then have its buffer refused. WayVR's
/// `get_drm_formats` (`graphics/dmabuf.rs`) applies the same filter.
#[must_use]
pub fn single_plane_modifiers(properties: &[vk::DrmFormatModifierPropertiesEXT]) -> Vec<Modifier> {
    properties
        .iter()
        .filter(|entry| entry.drm_format_modifier_plane_count == 1)
        .map(|entry| Modifier::from(entry.drm_format_modifier))
        .collect()
}

/// The entries advertised for one fourcc, given the modifiers that pass
/// filtering.
///
/// [`Modifier::Invalid`] is always present. A client uses it to request an
/// implicit modifier: the driver picks the layout, and neither side names it.
/// Without it, a client that does not negotiate explicitly cannot import its
/// buffer. WayVR adds it unconditionally for the same reason in
/// `get_drm_formats` (`graphics/dmabuf.rs`). Each modifier is advertised
/// once, because a driver may report the same modifier under more than one
/// plane count.
#[must_use]
pub fn advertise(fourcc: Fourcc, usable: &[Modifier]) -> Vec<Format> {
    let mut modifiers = Vec::with_capacity(usable.len() + 1);
    for modifier in usable.iter().copied().chain([Modifier::Invalid]) {
        if !modifiers.contains(&modifier) {
            modifiers.push(modifier);
        }
    }

    modifiers
        .into_iter()
        .map(|modifier| Format {
            code: fourcc,
            modifier,
        })
        .collect()
}

/// LÖVR's `FORMAT_RGB10A2`, which `convertFormat` (`gpu_vk.c`) maps to
/// `VK_FORMAT_A2B10G10R10_UNORM_PACK32`.
///
/// Bindgen emits it as a bare constant whose name repeats the enum. The local
/// name is the short form the table entries use.
const RGB10A2: TextureFormat = lunette_lovr::raw::TextureFormat_FORMAT_RGB10A2;

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn modifier_properties(modifier: u64, planes: u32) -> vk::DrmFormatModifierPropertiesEXT {
        vk::DrmFormatModifierPropertiesEXT {
            drm_format_modifier: modifier,
            drm_format_modifier_plane_count: planes,
            drm_format_modifier_tiling_features: vk::FormatFeatureFlags::SAMPLED_IMAGE,
        }
    }

    #[test]
    fn an_unsupported_fourcc_is_rejected_rather_than_guessed() {
        for fourcc in [Fourcc::Nv12, Fourcc::Yuyv, Fourcc::Rgb565, Fourcc::C8] {
            assert_eq!(mapping_for(fourcc), None, "{fourcc:?} is not importable");
        }
    }

    #[test]
    fn an_x_variant_agrees_with_its_a_variant_on_everything_but_alpha() {
        for (opaque, present) in [
            (Fourcc::Xrgb8888, Fourcc::Argb8888),
            (Fourcc::Xbgr8888, Fourcc::Abgr8888),
            (Fourcc::Xbgr2101010, Fourcc::Abgr2101010),
        ] {
            let opaque = mapping_for(opaque).expect("supported");
            let present = mapping_for(present).expect("supported");

            assert_eq!(opaque.vulkan, present.vulkan);
            assert_eq!(opaque.texture, present.texture);
            assert_eq!(
                opaque.alpha,
                Alpha::Opaque,
                "an X variant has no alpha channel, so the padding byte must not be sampled"
            );
            assert_eq!(present.alpha, Alpha::Present);
        }
    }

    #[test]
    fn the_component_order_is_not_transposed() {
        // A transposed component mapping produces a plausible-looking image
        // with red and blue exchanged. Greyscale content does not reveal it.
        assert_eq!(
            mapping_for(Fourcc::Argb8888).expect("supported").vulkan,
            vk::Format::B8G8R8A8_UNORM,
            "a DRM fourcc names its components in little-endian byte order, so ARGB is BGRA in \
             Vulkan's naming"
        );
        assert_eq!(
            mapping_for(Fourcc::Abgr8888).expect("supported").vulkan,
            vk::Format::R8G8B8A8_UNORM
        );
    }

    #[test]
    fn multi_plane_modifiers_are_filtered_out() {
        let properties = [
            modifier_properties(0, 1),
            modifier_properties(1, 2),
            modifier_properties(2, 1),
            modifier_properties(3, 4),
            modifier_properties(4, 0),
        ];

        assert_eq!(
            single_plane_modifiers(&properties),
            vec![Modifier::from(0u64), Modifier::from(2u64)]
        );
    }

    #[test]
    fn the_implicit_modifier_comes_last_and_appears_once() {
        assert_eq!(
            advertise(Fourcc::Argb8888, &[]),
            vec![Format {
                code: Fourcc::Argb8888,
                modifier: Modifier::Invalid,
            }],
            "the implicit modifier is advertised even when nothing survived"
        );

        let usable = [Modifier::Linear, Modifier::Invalid, Modifier::Linear];
        let advertised = advertise(Fourcc::Xbgr8888, &usable);

        assert_eq!(
            advertised,
            vec![
                Format {
                    code: Fourcc::Xbgr8888,
                    modifier: Modifier::Linear,
                },
                Format {
                    code: Fourcc::Xbgr8888,
                    modifier: Modifier::Invalid,
                },
            ]
        );
    }
}
