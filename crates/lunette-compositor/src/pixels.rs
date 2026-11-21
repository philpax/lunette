//! Owned desktop pixels transferred to the frame thread.

use crate::protocol::PixelSize;

/// Owned pixels packed as `width * height * 4` bytes for texture upload.
///
/// Construction rejects any other length, so consumers can use the dimensions without
/// repeating the size check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PixelBuffer {
    size: PixelSize,
    format: PixelFormat,
    pixels: Vec<u8>,
}

impl PixelBuffer {
    #[must_use]
    pub fn new(size: PixelSize, format: PixelFormat, pixels: Vec<u8>) -> Option<Self> {
        let expected = usize::try_from(size.width)
            .ok()?
            .checked_mul(usize::try_from(size.height).ok()?)?
            .checked_mul(PixelFormat::BYTES_PER_PIXEL as usize)?;

        (pixels.len() == expected).then_some(Self {
            size,
            format,
            pixels,
        })
    }

    #[must_use]
    pub fn size(&self) -> PixelSize {
        self.size
    }

    #[must_use]
    pub fn format(&self) -> PixelFormat {
        self.format
    }

    #[must_use]
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }
}

/// A tightly packed pixel format supported by the frame uploader.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PixelFormat {
    /// Little-endian bytes in `[B, G, R, A]` order.
    Argb8888,
    /// Little-endian bytes in `[B, G, R, X]` order. The importer sets the fourth
    /// byte to opaque alpha before upload.
    Xrgb8888,
}

impl PixelFormat {
    pub const BYTES_PER_PIXEL: u32 = 4;
}
