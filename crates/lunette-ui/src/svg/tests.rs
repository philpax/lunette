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
