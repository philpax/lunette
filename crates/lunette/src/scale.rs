//! The discrete steps lunette quantises a continuous scale or size to.
//!
//! Two consumers use the same ladder. The layer pool quantises a requested
//! panel size before it becomes a pool key, so a panel resized continuously by
//! a drag stabilises on a rung the free list already holds and does not
//! allocate a `Layer` per frame. Every `Layer` allocation can block;
//! [`crate::layers`] records the constraint. `wp_fractional_scale_v1` carries
//! a scale in 120ths and accepts a small set of values for the same reason,
//! and because a client re-lays out on every change it is told about.
//!
//! One ladder and one place to tune it keep the two consumers consistent by
//! construction.
//!
//! # Rungs of the ladder
//!
//! The rungs are the steps applied to a base cell and to every doubling of it:
//! 128 pixels, then 128 times each step, then 256 times each step, and so on.
//! The steps below 2x take part; the doubling covers the rest. Including the
//! higher steps would produce a denser ladder: more distinct keys, and a lower
//! free-list hit rate, the rate the ladder exists to raise.

/// A scale factor on the ladder, in 120ths of one.
///
/// 120ths is the unit `wp_fractional_scale_v1` carries, not a float. Keeping
/// the protocol's own unit makes the set finite, exactly comparable, and free
/// of a conversion at the boundary that reports it.
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

/// The ladder as scale factors, ascending: what `lunette.scaleSteps()` answers.
#[must_use]
pub fn ladder() -> Vec<f64> {
    STEPS
        .iter()
        .map(|step| f64::from(step.in_120ths()) / f64::from(ScaleStep::DENOMINATOR))
        .collect()
}

/// The smallest rung, and so the smallest layer dimension the pool allocates.
///
/// A panel below this is cheap enough that rounding it up costs less than the
/// extra pool key would.
pub const MIN_DIMENSION: u32 = 128;

/// The largest rung.
///
/// Every device lunette targets accepts an 8192-pixel image. Only layers at or
/// below this size are legitimate requests: at four bytes a pixel, a square
/// layer at the limit costs 256 MiB per swapchain image.
pub const MAX_DIMENSION: u32 = 8192;

/// Rounds one dimension up to the ladder.
///
/// The rounding direction is up, not to the nearest rung: a layer smaller
/// than the surface shown on it discards pixels the client already rendered,
/// and a composition layer exists to avoid that loss.
///
/// `None` for a zero dimension. A layer with no extent has no swapchain to
/// allocate, and answering with the smallest rung would turn a caller's
/// mistake into a silently wrong-sized panel.
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

    /// Every size a panel plausibly requests, plus a margin either side of the
    /// ladder's own ends.
    const SAMPLED: RangeInclusive<u32> = 1..=9000;

    /// The scale chooser moves between neighbouring rungs, so the order matters, and an eighth
    /// keeps every rung computed from a step a whole number of pixels.
    #[test]
    fn the_ladder_is_every_eighth_from_one_to_three_ascending() {
        assert_eq!(
            ladder(),
            vec![
                1.0, 1.125, 1.25, 1.375, 1.5, 1.625, 1.75, 1.875, 2.0, 2.125, 2.25, 2.375, 2.5,
                2.625, 2.75, 2.875, 3.0,
            ]
        );
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
        // A drag resize must stabilise on a rung. Consecutive rungs a pixel
        // apart would make the pool allocate per frame.
        let mut rungs: Vec<u32> = (1..=MAX_DIMENSION).filter_map(quantize_dimension).collect();
        rungs.dedup();

        assert!(
            rungs.len() < 100,
            "{} rungs is not a ladder, it is a continuum",
            rungs.len()
        );
    }

    #[test]
    fn the_ends_and_an_ordinary_panel_land_on_the_expected_rungs() {
        assert_eq!(quantize_dimension(0), None, "a zero dimension has no rung");
        assert_eq!(quantize_dimension(1), Some(MIN_DIMENSION));
        assert_eq!(quantize_dimension(MAX_DIMENSION), Some(MAX_DIMENSION));
        assert_eq!(quantize_dimension(u32::MAX), Some(MAX_DIMENSION));
        // A mirrored monitor and most terminals ask for 1920x1080, so the
        // waste on that size matters most.
        assert_eq!(quantize_dimension(1920), Some(1920));
        assert_eq!(quantize_dimension(1080), Some(1152));
    }
}
