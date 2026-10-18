//! Linux-only: multi-channel signed distance fields through msdfgen's C interface.
//!
//! LÖVR builds msdfgen as `libmsdfgen.so` and stages it beside `liblovr.so`, which links it for its
//! own font atlas. The UI toolkit's glyph atlas generates fields by glyph id, so it calls the same
//! library directly, through the C functions declared in `vendor/lovr/deps/msdfgen/msdfgen-c.h`.

use std::{fmt, ptr::NonNull};

/// The angle, in radians, above which a corner splits edge colours; msdfgen's recommended value.
const CORNER_ANGLE: f64 = 3.0;

mod raw {
    #![allow(non_camel_case_types)]

    use std::ffi::c_ulonglong;

    #[repr(C)]
    pub struct msShape {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct msContour {
        _private: [u8; 0],
    }

    #[link(name = "msdfgen")]
    unsafe extern "C" {
        pub fn msShapeCreate() -> *mut msShape;
        pub fn msShapeDestroy(shape: *mut msShape);
        pub fn msShapeAddContour(shape: *mut msShape) -> *mut msContour;
        pub fn msShapeNormalize(shape: *mut msShape);
        pub fn msShapeOrientContours(shape: *mut msShape);
        pub fn msEdgeColoringSimple(shape: *mut msShape, angle: f64, seed: c_ulonglong);
        pub fn msContourAddLinearEdge(contour: *mut msContour, x1: f32, y1: f32, x2: f32, y2: f32);
        pub fn msContourAddQuadraticEdge(
            contour: *mut msContour,
            x1: f32,
            y1: f32,
            x2: f32,
            y2: f32,
            x3: f32,
            y3: f32,
        );
        pub fn msContourAddCubicEdge(
            contour: *mut msContour,
            x1: f32,
            y1: f32,
            x2: f32,
            y2: f32,
            x3: f32,
            y3: f32,
            x4: f32,
            y4: f32,
        );
        pub fn msGenerateMSDF(
            data: *mut f32,
            width: i32,
            height: i32,
            shape: *mut msShape,
            range: f64,
            sx: f32,
            sy: f32,
            dx: f32,
            dy: f32,
        );
    }
}

/// One edge of a contour, in the shape's units.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Edge {
    Linear([f32; 2], [f32; 2]),
    Quadratic([f32; 2], [f32; 2], [f32; 2]),
    Cubic([f32; 2], [f32; 2], [f32; 2], [f32; 2]),
}

/// The field to generate: `width` by `height` pixels, where a shape point `p` lands on pixel
/// `scale * (p + translate)`, with `range` in the shape's units, as msdfgen measures it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Projection {
    pub width: u32,
    pub height: u32,
    pub range: f64,
    pub scale: [f64; 2],
    pub translate: [f64; 2],
}

/// Why a field could not be generated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MsdfError {
    /// msdfgen could not allocate a shape or a contour.
    Allocation,
    /// The field is wider or taller than msdfgen's integer sizes allow.
    Size { width: u32, height: u32 },
}

impl fmt::Display for MsdfError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MsdfError::Allocation => {
                write!(f, "msdfgen: a shape or contour could not be allocated")
            }
            MsdfError::Size { width, height } => {
                write!(f, "msdfgen: a {width}x{height} field is too large")
            }
        }
    }
}

impl std::error::Error for MsdfError {}

/// Generates a multi-channel distance field of the contours, answering `width * height` RGB
/// triples in msdfgen's row order: row 0 is pixel row 0 of the projection.
pub fn generate(contours: &[Vec<Edge>], projection: &Projection) -> Result<Vec<f32>, MsdfError> {
    let (Ok(width), Ok(height)) = (
        i32::try_from(projection.width),
        i32::try_from(projection.height),
    ) else {
        return Err(MsdfError::Size {
            width: projection.width,
            height: projection.height,
        });
    };
    let shape = Shape::new()?;
    for contour in contours {
        shape.add(contour)?;
    }
    let mut data = vec![0.0f32; projection.width as usize * projection.height as usize * 3];
    // SAFETY: the shape is live for this call, and `data` holds `width * height * 3` floats, the
    // size msdfgen writes for a three-channel bitmap of that size.
    unsafe {
        raw::msShapeNormalize(shape.0.as_ptr());
        raw::msShapeOrientContours(shape.0.as_ptr());
        raw::msEdgeColoringSimple(shape.0.as_ptr(), CORNER_ANGLE, 0);
        raw::msGenerateMSDF(
            data.as_mut_ptr(),
            width,
            height,
            shape.0.as_ptr(),
            projection.range,
            projection.scale[0] as f32,
            projection.scale[1] as f32,
            projection.translate[0] as f32,
            projection.translate[1] as f32,
        );
    }
    Ok(data)
}

/// An owned msdfgen shape.
struct Shape(NonNull<raw::msShape>);

impl Shape {
    fn new() -> Result<Self, MsdfError> {
        // SAFETY: msShapeCreate has no preconditions; a null result is handled.
        NonNull::new(unsafe { raw::msShapeCreate() })
            .map(Self)
            .ok_or(MsdfError::Allocation)
    }

    fn add(&self, edges: &[Edge]) -> Result<(), MsdfError> {
        // SAFETY: the shape is live; the contour it answers is owned by the shape.
        let contour = unsafe { raw::msShapeAddContour(self.0.as_ptr()) };
        let contour = NonNull::new(contour).ok_or(MsdfError::Allocation)?;
        for edge in edges {
            // SAFETY: the contour belongs to this live shape.
            unsafe {
                match *edge {
                    Edge::Linear([x1, y1], [x2, y2]) => {
                        raw::msContourAddLinearEdge(contour.as_ptr(), x1, y1, x2, y2);
                    }
                    Edge::Quadratic([x1, y1], [x2, y2], [x3, y3]) => {
                        raw::msContourAddQuadraticEdge(contour.as_ptr(), x1, y1, x2, y2, x3, y3);
                    }
                    Edge::Cubic([x1, y1], [x2, y2], [x3, y3], [x4, y4]) => {
                        raw::msContourAddCubicEdge(
                            contour.as_ptr(),
                            x1,
                            y1,
                            x2,
                            y2,
                            x3,
                            y3,
                            x4,
                            y4,
                        );
                    }
                }
            }
        }
        Ok(())
    }
}

impl Drop for Shape {
    fn drop(&mut self) {
        // SAFETY: the shape was created by msShapeCreate and is destroyed once.
        unsafe { raw::msShapeDestroy(self.0.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn square() -> Vec<Edge> {
        vec![
            Edge::Linear([0.0, 0.0], [1.0, 0.0]),
            Edge::Linear([1.0, 0.0], [1.0, 1.0]),
            Edge::Linear([1.0, 1.0], [0.0, 1.0]),
            Edge::Linear([0.0, 1.0], [0.0, 0.0]),
        ]
    }

    fn median(pixel: &[f32]) -> f32 {
        pixel[0]
            .max(pixel[1])
            .min(pixel[0].min(pixel[1]).max(pixel[2]))
    }

    #[test]
    fn a_square_is_inside_at_its_centre_and_outside_at_the_corners() -> Result<(), MsdfError> {
        let projection = Projection {
            width: 16,
            height: 16,
            range: 0.5,
            scale: [8.0, -8.0],
            translate: [0.5, -1.5],
        };
        let field = generate(&[square()], &projection)?;
        assert_eq!(field.len(), 16 * 16 * 3);
        let at = |x: usize, y: usize| median(&field[(y * 16 + x) * 3..][..3]);
        assert!(at(8, 8) > 0.5, "the centre is inside: {}", at(8, 8));
        assert!(at(0, 0) < 0.5, "the corner is outside: {}", at(0, 0));
        assert!(
            at(15, 15) < 0.5,
            "the far corner is outside: {}",
            at(15, 15)
        );
        Ok(())
    }
}
