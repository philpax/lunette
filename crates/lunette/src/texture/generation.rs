//! The two counters that make a stale handle detectable.
//!
//! Neither is about a texture in itself. One says which frame is being drawn,
//! so a handle obtained in an earlier one can be refused rather than
//! dereferenced; the other says how many buffers have been installed, so the
//! blit path can tell the texture it last copied from the one behind it now.
//! Both saturate rather than wrap, because a wrapped counter compares equal to
//! a value it is nothing like.

use std::fmt;

/// Which frame is being drawn.
///
/// A texture handle is only valid within the frame it was obtained in, and this
/// is what makes that checkable rather than merely documented.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FrameGeneration(u64);

impl FrameGeneration {
    /// Before the first frame has begun.
    pub const INITIAL: Self = Self(0);

    /// The next frame, saturating rather than wrapping.
    ///
    /// Wrapping would make a handle from long ago compare equal to a current
    /// one, which is the single thing this counter exists to prevent. At one
    /// frame per display refresh, saturation is unreachable.
    #[must_use]
    pub const fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl fmt::Display for FrameGeneration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// How many buffers the whole session has installed, as of one surface's most
/// recent.
///
/// The blit path stores the value it last copied and copies again only when it
/// differs, which is the whole of the damage skipping.
///
/// Counted across every surface rather than per surface, and never restarted.
/// A per-surface counter would repeat a value a surface had before it was
/// forgotten and re-created — which happens whenever a client unmaps and
/// re-maps — and a repeat reads to the blit path as "nothing has changed" while
/// the texture underneath it is a different one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SurfaceCommit(u64);

impl SurfaceCommit {
    /// Before anything has been installed.
    pub const INITIAL: Self = Self(0);

    /// The next value, saturating rather than wrapping, for the reason
    /// [`FrameGeneration::next`] saturates.
    #[must_use]
    pub const fn next(self) -> Self {
        Self(self.0.saturating_add(1))
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl fmt::Display for SurfaceCommit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn a_frame_generation_increases_and_never_wraps() {
        assert_eq!(FrameGeneration::INITIAL.get(), 0);
        assert_eq!(FrameGeneration::INITIAL.next().get(), 1);

        let last = FrameGeneration(u64::MAX);
        assert_eq!(
            last.next(),
            last,
            "wrapping would make an ancient handle compare equal to a current one"
        );
    }
    #[test]
    fn a_surface_commit_increases_and_never_wraps() {
        assert_eq!(SurfaceCommit::INITIAL.get(), 0);
        assert_eq!(SurfaceCommit::INITIAL.next().get(), 1);

        let last = SurfaceCommit(u64::MAX);
        assert_eq!(
            last.next(),
            last,
            "a repeated value reads to the blit path as a source that has not changed"
        );
    }
}
