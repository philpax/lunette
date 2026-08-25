//! The discrete steps lunette quantises a continuous scale or size to.
//!
//! Two callers need the same ladder of values. The layer pool quantises a requested panel
//! size before it becomes a pool key, so that a panel resized continuously by a
//! drag settles on a rung the free list already holds instead of allocating a
//! `Layer` per frame — and every allocation can block, which is what
//! [`crate::layers`] records. `wp_fractional_scale_v1` carries a scale in
//! 120ths and requires a small set of values rather than a continuum, both for
//! that reason and because a client re-lays-out on every change it receives.
//!
//! One ladder and one place to tune it keep the two consistent without manual
//! coordination.
//!
//! ## Scale-step laddering
//!
//! The rungs are the steps applied to a base cell and to every doubling of it:
//! 128 pixels, then 128 times each step, then 256 times each step, and so on.
//! Only the steps below 2x take part, because the doubling already covers the
//! rest and including them would produce a denser ladder — more distinct keys,
//! and a lower free-list hit rate, which reduces the benefit the ladder exists
//! to provide.

/// A scale factor on the ladder, in 120ths of one.
///
/// 120ths rather than a float because that is the unit `wp_fractional_scale_v1`
/// carries. Keeping the protocol's own unit makes the set finite, exactly
/// comparable, and free of a conversion at the boundary that reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ScaleStep(u32);

impl ScaleStep {
    /// The denominator `wp_fractional_scale_v1` fixes.
    pub const DENOMINATOR: u32 = 120;

    #[must_use]
    pub const fn in_120ths(self) -> u32 {
        self.0
    }
}

/// The ladder, ascending: one eighth apart, from 1x to 3x.
///
/// An eighth is 15 in 120ths, so every step is exact and every rung computed
/// from one is a whole number of pixels.
pub const STEPS: [ScaleStep; 17] = [
    ScaleStep(120),
    ScaleStep(135),
    ScaleStep(150),
    ScaleStep(165),
    ScaleStep(180),
    ScaleStep(195),
    ScaleStep(210),
    ScaleStep(225),
    ScaleStep(240),
    ScaleStep(255),
    ScaleStep(270),
    ScaleStep(285),
    ScaleStep(300),
    ScaleStep(315),
    ScaleStep(330),
    ScaleStep(345),
    ScaleStep(360),
];

/// The smallest rung, and so the smallest layer dimension the pool allocates.
///
/// A panel below this is cheap enough that rounding it up costs less than the
/// extra pool key would.
pub const MIN_DIMENSION: u32 = 128;

/// The largest rung.
///
/// Every device lunette targets accepts a 8192-pixel image, and a layer larger
/// than this is a mistake rather than a request: at four bytes a pixel a square
/// one already costs 256 MiB a swapchain image.
pub const MAX_DIMENSION: u32 = 8192;

/// Rounds one dimension up to the ladder.
///
/// Up rather than to the nearest, because a layer smaller than the surface
/// being shown on it discards pixels the client already rendered, which is the
/// one thing a composition layer exists to avoid.
///
/// `None` for a zero dimension. A layer with no extent has no swapchain to
/// allocate, and answering with the smallest rung would turn a caller's mistake
/// into a silently wrong-sized panel.
#[must_use]
pub fn quantize_dimension(pixels: u32) -> Option<u32> {
    if pixels == 0 {
        return None;
    }
    if pixels >= MAX_DIMENSION {
        return Some(MAX_DIMENSION);
    }

    let mut best = MAX_DIMENSION;
    let mut base = MIN_DIMENSION;
    while base <= MAX_DIMENSION {
        for step in STEPS {
            // The doubling of `base` covers everything from 2x up, and the
            // rungs it produces are the same ones.
            if step.in_120ths() >= 2 * ScaleStep::DENOMINATOR {
                break;
            }

            // Saturation is unreachable: `base` is at most `MAX_DIMENSION` and
            // a step is at most 225, so the product is under two million.
            let rung = base.saturating_mul(step.in_120ths()) / ScaleStep::DENOMINATOR;
            if rung >= pixels && rung < best {
                best = rung;
            }
        }
        base = base.saturating_mul(2);
    }

    Some(best)
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::ops::RangeInclusive;

    use pretty_assertions::assert_eq;

    use super::*;

    /// Every size a panel plausibly asks for, and a margin either side of the
    /// ladder's own ends.
    const SAMPLED: RangeInclusive<u32> = 1..=9000;

    #[test]
    fn the_ladder_ascends_and_holds_only_exact_eighths() {
        let mut previous = 0;
        for step in STEPS {
            assert!(
                step.in_120ths() > previous,
                "{step:?} does not follow {previous}"
            );
            assert_eq!(
                step.in_120ths() % 15,
                0,
                "{step:?} is not a whole eighth, so a rung from it is not a whole pixel"
            );
            previous = step.in_120ths();
        }
    }

    #[test]
    fn a_quantised_dimension_is_never_smaller_than_the_one_asked_for() {
        for pixels in SAMPLED {
            let rung = quantize_dimension(pixels).expect("a positive dimension has a rung");
            if pixels <= MAX_DIMENSION {
                assert!(rung >= pixels, "{pixels} was rounded down to {rung}");
            } else {
                assert_eq!(
                    rung, MAX_DIMENSION,
                    "{pixels} is past the ladder and must clamp to its top"
                );
            }
        }
    }

    #[test]
    fn quantising_is_idempotent() {
        for pixels in SAMPLED {
            let once = quantize_dimension(pixels).expect("a positive dimension has a rung");
            let twice = quantize_dimension(once).expect("a rung is itself a positive dimension");
            assert_eq!(twice, once, "{pixels} does not settle after one rounding");
        }
    }

    #[test]
    fn quantising_never_decreases_as_the_request_grows() {
        let mut previous = 0;
        for pixels in SAMPLED {
            let rung = quantize_dimension(pixels).expect("a positive dimension has a rung");
            assert!(
                rung >= previous,
                "{pixels} quantised to {rung}, below the {previous} the size before it took"
            );
            previous = rung;
        }
    }

    #[test]
    fn the_ladder_is_coarse_enough_to_be_worth_having() {
        // The whole point is that a drag resize settles. If consecutive rungs
        // were a pixel apart the pool would allocate per frame anyway.
        let mut rungs: Vec<u32> = (1..=MAX_DIMENSION).filter_map(quantize_dimension).collect();
        rungs.dedup();

        assert!(
            rungs.len() < 100,
            "{} rungs is not a ladder, it is a continuum",
            rungs.len()
        );
    }

    #[test]
    fn a_zero_dimension_has_no_rung() {
        assert_eq!(quantize_dimension(0), None);
    }

    #[test]
    fn the_ends_of_the_ladder_are_the_declared_ones() {
        assert_eq!(quantize_dimension(1), Some(MIN_DIMENSION));
        assert_eq!(quantize_dimension(MAX_DIMENSION), Some(MAX_DIMENSION));
        assert_eq!(quantize_dimension(u32::MAX), Some(MAX_DIMENSION));
    }

    #[test]
    fn an_ordinary_panel_lands_on_a_rung_near_what_it_asked_for() {
        // 1920x1080 is the size a mirrored monitor and most terminals ask for,
        // so the waste on it is the waste that matters.
        assert_eq!(quantize_dimension(1920), Some(1920));
        assert_eq!(quantize_dimension(1080), Some(1152));
    }
}
