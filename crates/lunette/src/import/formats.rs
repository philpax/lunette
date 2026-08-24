//! Which client pixel formats lunette can import, and how each is spelled.
//!
//! Three vocabularies meet here. A client names its buffer with a DRM fourcc, a
//! Vulkan image is created with a `VkFormat`, and LÖVR wraps that image with a
//! `TextureFormat`. This module is the single place the three are related, so a
//! mismatch between them is one edit to correct rather than three to find.
//!
//! Everything below is a pure function of plain data. The device queries that
//! narrow the table to what the hardware will actually accept live in
//! [`crate::import::device`], because they need a device and these do not.
//!
//! # The X variants
//!
//! `Xrgb8888`, `Xbgr8888`, and `Xbgr2101010` have no alpha channel: the fourth
//! component is undefined padding. Vulkan has no matching format, so each maps
//! to the alpha-carrying format with the same component order, and whatever the
//! client left in the padding byte arrives as alpha. [`Alpha::Opaque`] records
//! that, and a consumer must force alpha to one rather than sampling it. WayVR
//! maps the same six fourccs without recording the
//! distinction, which is why its X-format content renders with arbitrary
//! transparency.

use ash::vk;
use lunette_lovr::raw::{TextureFormat, TextureFormat_FORMAT_BGRA8, TextureFormat_FORMAT_RGBA8};
use smithay::backend::allocator::{Format, Fourcc, Modifier};

/// Whether a format's fourth component carries alpha or padding.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Alpha {
    /// The fourth component is alpha, and is sampled.
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
    /// LÖVR's `TextureFormat`, which `convertFormat` (`gpu_vk.c`)
    /// turns back into [`FormatMapping::vulkan`]. The two have to agree: LÖVR
    /// takes an imported image's format on trust and has no way to detect a
    /// mismatch.
    pub texture: TextureFormat,
    pub alpha: Alpha,
}

/// The formats lunette imports, in the order they are advertised.
///
/// The same six WayVR covers. Multi-plane YUV is a
/// recorded gap rather than an oversight: importing it needs a per-plane
/// binding path this design does not have.
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
/// A modifier whose layout spans several planes needs one memory allocation per
/// plane and `VkBindImagePlaneMemoryInfo` to bind them, which is the disjoint
/// path this design rejects. Filtering here means such a modifier is never
/// advertised, so a client does not choose one and then have its buffer
/// refused. WayVR applies the same filter.
#[must_use]
pub fn single_plane_modifiers(properties: &[vk::DrmFormatModifierPropertiesEXT]) -> Vec<Modifier> {
    properties
        .iter()
        .filter(|entry| entry.drm_format_modifier_plane_count == 1)
        .map(|entry| Modifier::from(entry.drm_format_modifier))
        .collect()
}

/// The entries advertised for one fourcc, given the modifiers that survived
/// filtering.
///
/// [`Modifier::Invalid`] is always present. It is how a client asks for an
/// implicit modifier — the driver picks the layout and neither side names it —
/// and dropping it turns away every client that does not negotiate explicitly.
/// WayVR adds it unconditionally for the same reason.
/// Duplicates are removed rather than advertised twice, because a driver may
/// report the same modifier under more than one plane count.
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

/// LÖVR's `FORMAT_RGB10A2`, which `convertFormat` spells
/// `VK_FORMAT_A2B10G10R10_UNORM_PACK32` (`gpu_vk.c`).
///
/// Named here rather than imported because bindgen emits it as a bare constant
/// whose name repeats the enum, and the three uses read better against one
/// local name.
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
    fn every_supported_fourcc_maps_to_exactly_one_entry() {
        for entry in SUPPORTED {
            assert_eq!(
                mapping_for(entry.fourcc),
                Some(entry),
                "{:?} must resolve to its own entry",
                entry.fourcc
            );
        }
    }

    #[test]
    fn an_unsupported_fourcc_is_rejected_rather_than_guessed() {
        for fourcc in [Fourcc::Nv12, Fourcc::Yuyv, Fourcc::Rgb565, Fourcc::C8] {
            assert_eq!(mapping_for(fourcc), None, "{fourcc:?} is not importable");
        }
    }

    #[test]
    fn the_x_variants_are_marked_opaque_and_the_a_variants_are_not() {
        for fourcc in [Fourcc::Xrgb8888, Fourcc::Xbgr8888, Fourcc::Xbgr2101010] {
            let mapping = mapping_for(fourcc).expect("supported");
            assert_eq!(
                mapping.alpha,
                Alpha::Opaque,
                "{fourcc:?} has no alpha channel, so the padding byte must not be sampled"
            );
        }

        for fourcc in [Fourcc::Argb8888, Fourcc::Abgr8888, Fourcc::Abgr2101010] {
            let mapping = mapping_for(fourcc).expect("supported");
            assert_eq!(mapping.alpha, Alpha::Present, "{fourcc:?} carries alpha");
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
            assert_ne!(opaque.alpha, present.alpha);
        }
    }

    #[test]
    fn the_component_order_is_not_transposed() {
        // The one mapping error that produces a plausible-looking image with
        // red and blue exchanged, and it is invisible in greyscale content.
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
        ];

        assert_eq!(
            single_plane_modifiers(&properties),
            vec![Modifier::from(0u64), Modifier::from(2u64)]
        );
    }

    #[test]
    fn filtering_an_empty_report_yields_nothing() {
        assert_eq!(single_plane_modifiers(&[]), Vec::<Modifier>::new());
    }

    #[test]
    fn filtering_a_report_of_only_multi_plane_modifiers_yields_nothing() {
        let properties = [modifier_properties(7, 2), modifier_properties(8, 3)];
        assert_eq!(single_plane_modifiers(&properties), Vec::<Modifier>::new());
    }

    #[test]
    fn a_zero_plane_count_is_not_mistaken_for_a_single_plane() {
        assert_eq!(
            single_plane_modifiers(&[modifier_properties(9, 0)]),
            Vec::<Modifier>::new()
        );
    }

    #[test]
    fn the_implicit_modifier_is_advertised_even_when_nothing_survived() {
        assert_eq!(
            advertise(Fourcc::Argb8888, &[]),
            vec![Format {
                code: Fourcc::Argb8888,
                modifier: Modifier::Invalid,
            }]
        );
    }

    #[test]
    fn the_implicit_modifier_comes_last_and_appears_once() {
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

    #[test]
    fn advertising_carries_the_fourcc_onto_every_entry() {
        let usable = [Modifier::Linear, Modifier::from(0x0100_0000_0000_0001u64)];
        for entry in advertise(Fourcc::Abgr2101010, &usable) {
            assert_eq!(entry.code, Fourcc::Abgr2101010);
        }
    }
}
