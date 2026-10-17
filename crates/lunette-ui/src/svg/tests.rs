#![expect(
    clippy::expect_used,
    reason = "Tests fail loudly on a malformed fixture; that is the assertion."
)]

use pretty_assertions::assert_eq;

use super::*;

const SQUARE: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <rect width="10" height="10" fill="#ff0000"/>
</svg>"##;

const WIDE: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">
  <rect width="20" height="10" fill="#0000ff"/>
</svg>"##;

const CIRCLE: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
  <circle cx="5" cy="5" r="4" fill="#00ff00"/>
</svg>"##;

const TRANSLUCENT: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4">
  <rect width="4" height="4" fill="#ffffff" fill-opacity="0.5"/>
</svg>"##;

const CLEAR: [u8; 4] = [0, 0, 0, 0];

fn size(width: u32, height: u32) -> RasterSize {
    RasterSize::new(f64::from(width), f64::from(height)).expect("the size is valid")
}

fn raster(document: &str, width: u32, height: u32) -> Raster {
    rasterize(document.as_bytes(), size(width, height)).expect("the document rasterises")
}

fn pixel(raster: &Raster, x: u32, y: u32) -> [u8; 4] {
    let start = ((y * raster.width + x) * 4) as usize;
    let mut rgba = [0; 4];
    rgba.copy_from_slice(&raster.pixels[start..start + 4]);
    rgba
}

#[test]
fn a_filled_square_covers_the_canvas() {
    let raster = raster(SQUARE, 4, 4);
    assert_eq!((raster.width, raster.height), (4, 4));
    let (pixels, rest) = raster.pixels.as_chunks::<4>();
    assert_eq!((pixels.len(), rest.len()), (4 * 4, 0));
    for rgba in pixels {
        assert_eq!(*rgba, [255, 0, 0, 255]);
    }
}

#[test]
fn the_canvas_has_the_requested_size_whatever_the_document_size() {
    let raster = raster(SQUARE, 7, 3);
    assert_eq!((raster.width, raster.height), (7, 3));
    assert_eq!(raster.pixels.len(), 7 * 3 * 4);
}

#[test]
fn a_wide_document_is_fitted_and_centred_vertically() {
    let raster = raster(WIDE, 20, 20);
    assert_eq!(pixel(&raster, 10, 2), CLEAR, "above the document");
    assert_eq!(
        pixel(&raster, 0, 5),
        [0, 0, 255, 255],
        "the document's top row"
    );
    assert_eq!(pixel(&raster, 10, 10), [0, 0, 255, 255], "the centre");
    assert_eq!(
        pixel(&raster, 19, 14),
        [0, 0, 255, 255],
        "the document's bottom row"
    );
    assert_eq!(pixel(&raster, 10, 17), CLEAR, "below the document");
}

#[test]
fn a_square_document_is_fitted_and_centred_horizontally() {
    let raster = raster(SQUARE, 30, 10);
    assert_eq!(pixel(&raster, 5, 5), CLEAR, "left of the document");
    assert_eq!(
        pixel(&raster, 10, 0),
        [255, 0, 0, 255],
        "the document's left column"
    );
    assert_eq!(
        pixel(&raster, 19, 9),
        [255, 0, 0, 255],
        "the document's right column"
    );
    assert_eq!(pixel(&raster, 25, 5), CLEAR, "right of the document");
}

#[test]
fn a_circle_is_drawn_at_its_scaled_position() {
    let raster = raster(CIRCLE, 100, 100);
    assert_eq!(pixel(&raster, 50, 50), [0, 255, 0, 255], "the centre");
    assert_eq!(
        pixel(&raster, 50, 15),
        [0, 255, 0, 255],
        "inside the top edge"
    );
    assert_eq!(pixel(&raster, 2, 2), CLEAR, "the corner outside the circle");
    assert_eq!(pixel(&raster, 50, 5), CLEAR, "above the circle");
}

#[test]
fn pixels_have_straight_alpha() {
    let raster = raster(TRANSLUCENT, 4, 4);
    let [red, green, blue, alpha] = pixel(&raster, 2, 2);
    assert_eq!(
        (red, green, blue),
        (255, 255, 255),
        "colour is not premultiplied"
    );
    assert!((127..=128).contains(&alpha), "half opacity, not {alpha}");
}

#[test]
fn malformed_xml_is_an_error() {
    let error = rasterize(b"<svg", size(4, 4)).expect_err("the document is malformed");
    assert!(matches!(
        error,
        SvgError::Parse(usvg::Error::ParsingFailed(_))
    ));
    assert!(
        error
            .to_string()
            .starts_with("svg: the document is not well-formed XML: "),
        "{error}"
    );
}

#[test]
fn text_that_is_not_svg_is_an_error() {
    let error = rasterize(b"an icon", size(4, 4)).expect_err("the text is not SVG");
    assert!(matches!(error, SvgError::Parse(_)), "{error}");
}

#[test]
fn bytes_that_are_not_utf8_are_an_error() {
    let error = rasterize(&[0xff, 0xfe, 0x00], size(4, 4)).expect_err("the bytes are not UTF-8");
    assert_eq!(error.to_string(), "svg: the document is not UTF-8 text");
}

#[test]
fn a_document_without_a_size_is_an_error() {
    let error = rasterize(
        br##"<svg xmlns="http://www.w3.org/2000/svg" width="0" height="10"/>"##,
        size(4, 4),
    )
    .expect_err("the document has no area");
    assert_eq!(
        error.to_string(),
        "svg: the document has no positive width and height and no view box"
    );
}

#[test]
fn hrefs_to_files_are_not_followed() {
    // An absolute path to a drawable file in the repository, which usvg's default resolver loads.
    let mark = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs/assets/mark.svg");
    let document = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 16 16">
          <image width="16" height="16" xlink:href="{mark}"/>
        </svg>"##
    );
    let raster = raster(&document, 16, 16);
    assert!(raster.pixels.iter().all(|&byte| byte == 0));
}

#[test]
fn embedded_data_images_are_drawn() {
    let document = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">
          <image width="10" height="10" xlink:href="data:image/svg+xml;utf8,{}"/>
        </svg>"##,
        SQUARE
            .replace('<', "%3C")
            .replace('>', "%3E")
            .replace('#', "%23")
            .replace('"', "'")
    );
    let raster = raster(&document, 4, 4);
    assert_eq!(pixel(&raster, 2, 2), [255, 0, 0, 255]);
}

#[test]
fn a_compressed_document_is_drawn() {
    let raster = raster_bytes(&gzip_stored(SQUARE.as_bytes()), 4, 4);
    assert_eq!(pixel(&raster, 2, 2), [255, 0, 0, 255]);
}

#[test]
fn malformed_compression_is_an_error() {
    let error = rasterize(&[0x1f, 0x8b, 0x08, 0x00, 0xff], size(4, 4))
        .expect_err("the gzip stream is truncated");
    assert_eq!(
        error.to_string(),
        "svg: the document's gzip compression is malformed"
    );
}

fn raster_bytes(document: &[u8], width: u32, height: u32) -> Raster {
    rasterize(document, size(width, height)).expect("the document rasterises")
}

/// A gzip member holding `data` in one stored deflate block, so the test needs no compressor.
fn gzip_stored(data: &[u8]) -> Vec<u8> {
    let length = u16::try_from(data.len()).expect("the fixture fits one stored block");
    let mut out = vec![0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff];
    out.push(0x01);
    out.extend(length.to_le_bytes());
    out.extend((!length).to_le_bytes());
    out.extend(data);
    out.extend(crc32(data).to_le_bytes());
    out.extend(u32::from(length).to_le_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

#[test]
fn sides_from_one_to_the_limit_are_accepted() {
    for (width, height) in [
        (1.0, 1.0),
        (f64::from(MAX_SIDE), 1.0),
        (1.0, f64::from(MAX_SIDE)),
    ] {
        let size = RasterSize::new(width, height).expect("the size is in range");
        assert_eq!(
            (f64::from(size.width()), f64::from(size.height())),
            (width, height)
        );
    }
}

#[test]
fn sides_outside_the_limit_or_fractional_are_rejected() {
    for value in [
        0.0,
        -1.0,
        2.5,
        f64::from(MAX_SIDE) + 1.0,
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
    ] {
        let error = RasterSize::new(value, 4.0).expect_err("the width is rejected");
        assert!(
            matches!(
                error,
                SvgError::Size {
                    axis: Axis::Width,
                    ..
                }
            ),
            "{value}: {error}"
        );
        let error = RasterSize::new(4.0, value).expect_err("the height is rejected");
        assert!(
            matches!(
                error,
                SvgError::Size {
                    axis: Axis::Height,
                    ..
                }
            ),
            "{value}: {error}"
        );
    }
    assert_eq!(
        RasterSize::new(4.0, 0.5)
            .expect_err("the height is fractional")
            .to_string(),
        "svg: the height 0.5 is not a whole number of pixels from 1 to 4096"
    );
}
