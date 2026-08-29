//! Repacking a client's `wl_shm` buffer into pixels the frame thread can
//! upload.
//!
//! Ported from WayVR's `image_importer.rs`, with two departures.
//!
//! WayVR uploads from the compositor's own thread and then blocks on the
//! submission. lunette cannot: the frame thread is the sole kind of thread
//! allowed to submit, and blocking it on a client's commit would let a stalled
//! client extend lunette's frame time. This module validates the layout,
//! strips the stride padding, and forces alpha where the format has none. The
//! frame thread performs the upload through LÖVR's own batched path.
//!
//! WayVR accepts more formats than `wl_shm` mandates; lunette does not.
//! `Argb8888` and `Xrgb8888` are the two formats every client must support.
//! A format beyond them extends the importer, and the dmabuf path is where a
//! client that needs ten-bit colour belongs.

use std::fmt;

use lunette_compositor::surface::{PixelBuffer, ShmFormat, ShmLayout};

/// Copies a client's buffer into a tightly packed one.
///
/// A client's rows are padded to its own stride, and a texture upload requires
/// contiguous rows. Stripping the padding here means the frame thread's
/// upload is a straight memory copy with no layout arithmetic. Forcing alpha
/// for [`ShmFormat::Xrgb8888`] is free, because the copy pass already touches
/// every byte.
///
/// # Errors
///
/// Rejects a layout that describes more bytes than `pixels` holds, a stride
/// narrower than a row, and a buffer with no pixels in it. None of these is
/// recoverable: importing anyway would read past the client's pool or produce
/// a texture no graphics API will accept.
pub(crate) fn repack(pixels: &[u8], layout: ShmLayout) -> Result<PixelBuffer, ShmError> {
    let row = RowGeometry::of(layout)?;

    let required = row.bytes_read();
    if pixels.len() < required {
        return Err(ShmError::Truncated {
            available: pixels.len(),
            required,
        });
    }

    let mut packed = Vec::with_capacity(row.packed_bytes());
    for index in 0..row.rows {
        let start = index * row.stride;
        packed.extend_from_slice(&pixels[start..start + row.width_bytes]);
    }

    if layout.format == ShmFormat::Xrgb8888 {
        force_alpha_opaque(&mut packed);
    }

    PixelBuffer::new(layout.size, layout.format, packed).ok_or(ShmError::PackedSizeMismatch)
}

/// Sets every fourth byte to `0xFF`.
///
/// `Xrgb8888` is little-endian `[B, G, R, X]`, so the fourth byte of each
/// pixel carries no colour. A client is free to leave anything there. A
/// consumer that samples it renders the surface with arbitrary transparency;
/// WayVR's dmabuf path samples it for the X formats. Here the bytes are
/// copied anyway, so writing `0xFF` is free.
fn force_alpha_opaque(pixels: &mut [u8]) {
    for pixel in pixels.as_chunks_mut::<BYTES_PER_PIXEL>().0 {
        pixel[ALPHA_BYTE] = u8::MAX;
    }
}

/// The row arithmetic a repack depends on, computed once.
///
/// Every product is checked. A client controls the width, the height, and
/// the stride; an overflow here is a buffer overread reachable from any
/// connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RowGeometry {
    /// The bytes of a row that carry pixels, excluding the client's padding.
    width_bytes: usize,
    /// The bytes from the start of one row to the start of the next.
    stride: usize,
    rows: usize,
}

impl RowGeometry {
    fn of(layout: ShmLayout) -> Result<Self, ShmError> {
        if layout.size.width == 0 || layout.size.height == 0 {
            return Err(ShmError::Empty { size: layout.size });
        }

        let width_bytes = usize::try_from(layout.size.width)
            .ok()
            .and_then(|width| width.checked_mul(BYTES_PER_PIXEL))
            .ok_or(ShmError::Unrepresentable)?;
        let stride = usize::try_from(layout.stride).map_err(|_| ShmError::Unrepresentable)?;
        let rows = usize::try_from(layout.size.height).map_err(|_| ShmError::Unrepresentable)?;

        if stride < width_bytes {
            return Err(ShmError::StrideNarrowerThanRow {
                stride,
                needed: width_bytes,
            });
        }

        Ok(Self {
            width_bytes,
            stride,
            rows,
        })
    }

    /// The bytes the repack reads.
    ///
    /// The last row's padding is never read, so a buffer trimmed to its final
    /// pixel is accepted. Requiring `stride * rows` would reject it, with no
    /// benefit beyond agreement with a stricter check upstream.
    fn bytes_read(self) -> usize {
        self.stride
            .saturating_mul(self.rows - 1)
            .saturating_add(self.width_bytes)
    }

    fn packed_bytes(self) -> usize {
        self.width_bytes.saturating_mul(self.rows)
    }
}

/// Four, for both formats this path accepts.
const BYTES_PER_PIXEL: usize = ShmFormat::BYTES_PER_PIXEL as usize;

/// The index of the alpha byte within a pixel, for both formats.
const ALPHA_BYTE: usize = BYTES_PER_PIXEL - 1;

/// Why a shared-memory buffer could not be repacked.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ShmError {
    Empty {
        size: lunette_compositor::protocol::PixelSize,
    },
    Unrepresentable,
    StrideNarrowerThanRow {
        stride: usize,
        needed: usize,
    },
    Truncated {
        available: usize,
        required: usize,
    },
    PackedSizeMismatch,
}

impl fmt::Display for ShmError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "wl_shm: ")?;
        match self {
            Self::Empty { size } => write!(f, "a buffer of {size} has no pixels to import"),
            Self::Unrepresentable => write!(
                f,
                "the declared geometry does not fit in this machine's address space"
            ),
            Self::StrideNarrowerThanRow { stride, needed } => write!(
                f,
                "a stride of {stride} bytes cannot hold a row of {needed}"
            ),
            Self::Truncated {
                available,
                required,
            } => write!(
                f,
                "the buffer holds {available} bytes and the layout describes {required}"
            ),
            Self::PackedSizeMismatch => write!(
                f,
                "the repacked buffer did not match its own declared dimensions"
            ),
        }
    }
}

impl std::error::Error for ShmError {}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use lunette_compositor::protocol::PixelSize;
    use pretty_assertions::assert_eq;

    use super::*;

    fn layout(width: u32, height: u32, stride: u32, format: ShmFormat) -> ShmLayout {
        ShmLayout {
            size: PixelSize::new(width, height),
            stride,
            format,
        }
    }

    /// A buffer whose every byte is distinguishable. A misplaced row is then
    /// visible in the assertion, and repeated values cannot hide it.
    fn counted(length: usize) -> Vec<u8> {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the wrap is the point: the pattern only has to be locally distinguishable"
        )]
        (0..length).map(|index| index as u8).collect()
    }

    #[test]
    fn a_stride_exactly_the_row_width_copies_the_buffer_through() {
        let pixels = counted(2 * 4 * 3);
        let packed = repack(&pixels, layout(2, 3, 8, ShmFormat::Argb8888))
            .expect("a tightly packed buffer is valid");

        assert_eq!(packed.pixels(), pixels.as_slice());
        assert_eq!(packed.size(), PixelSize::new(2, 3));
    }

    #[test]
    fn padding_is_stripped_from_every_row() {
        // Two pixels a row, four bytes each, with eight bytes of padding.
        let mut pixels = Vec::new();
        for row in 0..3u8 {
            pixels.extend_from_slice(&[row; 8]);
            pixels.extend_from_slice(&[0xEE; 8]);
        }

        let packed = repack(&pixels, layout(2, 3, 16, ShmFormat::Argb8888))
            .expect("a padded buffer is valid");

        assert_eq!(
            packed.pixels(),
            &[
                0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2
            ]
        );
    }

    #[test]
    fn the_last_rows_padding_need_not_be_present() {
        // Three rows at a stride of 16, but the final row's padding is absent.
        // The repack never reads it, so the buffer is accepted.
        let pixels = counted(16 * 2 + 8);
        let packed = repack(&pixels, layout(2, 3, 16, ShmFormat::Argb8888))
            .expect("only the bytes that are read have to be present");

        assert_eq!(packed.pixels().len(), 2 * 4 * 3);
    }

    #[test]
    fn one_byte_short_of_the_last_row_is_rejected() {
        let pixels = counted(16 * 2 + 7);
        assert_eq!(
            repack(&pixels, layout(2, 3, 16, ShmFormat::Argb8888)),
            Err(ShmError::Truncated {
                available: 39,
                required: 40,
            })
        );
    }

    #[test]
    fn a_single_pixel_round_trips() {
        let pixels = [1, 2, 3, 4];
        let packed =
            repack(&pixels, layout(1, 1, 4, ShmFormat::Argb8888)).expect("one pixel is a buffer");

        assert_eq!(packed.pixels(), &[1, 2, 3, 4]);
        assert_eq!(packed.size(), PixelSize::new(1, 1));
    }

    #[test]
    fn a_buffer_with_no_pixels_is_rejected_rather_than_imported_empty() {
        for (width, height) in [(0, 0), (0, 4), (4, 0)] {
            assert_eq!(
                repack(&[], layout(width, height, 0, ShmFormat::Argb8888)),
                Err(ShmError::Empty {
                    size: PixelSize::new(width, height),
                }),
                "a {width}x{height} buffer has no image in it"
            );
        }
    }

    #[test]
    fn a_stride_narrower_than_a_row_is_rejected() {
        assert_eq!(
            repack(&counted(64), layout(4, 2, 15, ShmFormat::Argb8888)),
            Err(ShmError::StrideNarrowerThanRow {
                stride: 15,
                needed: 16,
            })
        );
    }

    #[test]
    fn a_zero_stride_is_rejected_before_anything_is_read() {
        assert_eq!(
            repack(&[], layout(1, 1, 0, ShmFormat::Argb8888)),
            Err(ShmError::StrideNarrowerThanRow {
                stride: 0,
                needed: 4,
            })
        );
    }

    #[test]
    fn an_x_format_has_its_alpha_forced_opaque() {
        let pixels = [0x11, 0x22, 0x33, 0x00, 0x44, 0x55, 0x66, 0x7F];
        let packed = repack(&pixels, layout(2, 1, 8, ShmFormat::Xrgb8888))
            .expect("a tightly packed buffer is valid");

        assert_eq!(
            packed.pixels(),
            &[0x11, 0x22, 0x33, 0xFF, 0x44, 0x55, 0x66, 0xFF],
            "the fourth byte of an Xrgb8888 pixel is padding, and sampling it renders the surface \
             with arbitrary transparency"
        );
    }

    #[test]
    fn an_a_format_keeps_the_alpha_the_client_wrote() {
        let pixels = [0x11, 0x22, 0x33, 0x00, 0x44, 0x55, 0x66, 0x7F];
        let packed = repack(&pixels, layout(2, 1, 8, ShmFormat::Argb8888))
            .expect("a tightly packed buffer is valid");

        assert_eq!(packed.pixels(), &pixels);
    }

    #[test]
    fn the_repacked_length_is_always_the_declared_geometry() {
        for (width, height) in [(1, 1), (1, 17), (17, 1), (64, 64)] {
            let stride = width * 4 + 12;
            let pixels = counted((stride * height) as usize);
            let packed = repack(&pixels, layout(width, height, stride, ShmFormat::Argb8888))
                .expect("a padded buffer is valid");

            assert_eq!(
                packed.pixels().len(),
                (width * height * 4) as usize,
                "{width}x{height} must repack to exactly its own pixels"
            );
        }
    }

    #[test]
    fn a_geometry_too_large_for_the_address_space_is_rejected_rather_than_wrapped() {
        // Which refusal answers depends on the pointer width: the
        // multiplication by four overflows a 32-bit `usize` and does not
        // overflow a 64-bit one, where the stride turns out narrower than the
        // row it has to hold. Either way the repack reads nothing.
        for geometry in [
            layout(u32::MAX, 1, u32::MAX, ShmFormat::Argb8888),
            layout(u32::MAX, u32::MAX, u32::MAX, ShmFormat::Argb8888),
            layout(0x1_0000, 0x1_0000, 0x4_0000, ShmFormat::Argb8888),
        ] {
            let outcome = repack(&[], geometry);
            assert!(
                matches!(
                    outcome,
                    Err(ShmError::Unrepresentable
                        | ShmError::Truncated { .. }
                        | ShmError::StrideNarrowerThanRow { .. })
                ),
                "an enormous geometry must be refused, not wrapped into a small one: {outcome:?}"
            );
        }
    }
}
