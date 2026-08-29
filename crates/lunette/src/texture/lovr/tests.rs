//! The calls the LÖVR texture path makes, split by what each needs.
//!
//! The declaration a texture is created with, the format a `wl_shm` buffer
//! becomes, and the two predicates over a shape are all arithmetic over
//! values LÖVR is later told about, so they are exercised here without a
//! graphics device. Everything that records a barrier or a copy is not.

use lunette_lovr::raw::TextureFormat_FORMAT_RGBA8;
use pretty_assertions::assert_eq;

use super::*;

#[test]
fn every_shm_format_is_uploaded_as_bgra() {
    for format in [ShmFormat::Argb8888, ShmFormat::Xrgb8888] {
        assert_eq!(shm_texture_format(format), TextureFormat_FORMAT_BGRA8);
    }
}

#[test]
fn the_texture_declaration_matches_what_the_import_creates() {
    let info = texture_info(PixelSize::new(2, 2), TextureFormat_FORMAT_BGRA8, 42, true);

    assert_eq!(info.usage, TEXTURE_SAMPLE | TEXTURE_TRANSFER);
    assert!(info.foreign);
    assert_eq!(info.handle, 42);
    assert_eq!(info.layers, 1);
    assert_eq!(info.mipmaps, 1);
    assert_eq!(info.samples, 1);
    assert!(!info.srgb);
    assert!(!info.xr);
    assert_eq!(info.imageCount, 0);
    assert!(info.images.is_null());
}

#[test]
fn a_texture_lovr_allocates_is_not_declared_foreign() {
    let info = texture_info(PixelSize::new(2, 2), TextureFormat_FORMAT_BGRA8, 0, false);
    assert!(
        !info.foreign,
        "the flag suppresses the initial transition, which a texture LÖVR is about to fill \
         genuinely wants"
    );
    assert_eq!(info.handle, 0);
}

fn shape(width: u32, height: u32, layers: u32) -> TextureShape {
    TextureShape {
        size: PixelSize::new(width, height),
        layers,
        format: TextureFormat_FORMAT_BGRA8,
        srgb: false,
    }
}

#[test]
fn two_textures_of_one_format_are_copied_without_a_blit_whatever_their_encoding() {
    // `lovrTextureCopy` branches on the format alone, so requiring
    // `GPU_FEATURE_BLIT` here would refuse a copy the device would have
    // made and demote the panel for the rest of the session.
    let plain = shape(64, 64, 1);
    let encoded = TextureShape {
        srgb: true,
        ..plain
    };

    assert!(!needs_blit(plain, encoded));
    assert!(!needs_blit(plain, plain));
    assert!(needs_blit(
        plain,
        TextureShape {
            format: TextureFormat_FORMAT_RGBA8,
            ..plain
        }
    ));
}

#[test]
fn a_source_smaller_than_its_destination_leaves_a_margin_the_copy_does_not_write() {
    // The size ladder rounds up, so this is the ordinary case for a layer:
    // an 800x600 window is served by a 1024x1024 one, and the margin is
    // uninitialised swapchain memory until something clears it.
    assert!(!covers(shape(800, 600, 1), shape(1024, 1024, 1)));
    assert!(!covers(shape(1920, 1080, 1), shape(1920, 1152, 1)));
    assert!(
        !covers(shape(512, 512, 1), shape(512, 512, 2)),
        "a stereo destination has a second layer the copy does not reach"
    );
}

#[test]
fn a_source_at_least_as_large_as_its_destination_writes_all_of_it() {
    assert!(covers(shape(1024, 1024, 1), shape(1024, 1024, 1)));
    assert!(
        covers(shape(2048, 2048, 2), shape(1024, 1024, 1)),
        "the extent is the region the two share, so a larger source is clipped to the destination"
    );
}
