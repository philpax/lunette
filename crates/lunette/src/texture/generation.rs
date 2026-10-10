//! The two counters that make a stale handle detectable.
//!
//! Neither counter concerns a texture in itself. One records which frame is
//! being drawn. A handle obtained in an earlier frame can be refused and
//! never dereferenced. The other records how many buffers have been
//! installed. The blit path uses the count to distinguish the texture it
//! last copied from the current one. Both saturate and never wrap, because
//! a wrapped counter can compare equal to an unrelated value.

use std::fmt;

/// Which frame is being drawn.
///
/// A texture handle is valid within the frame in which it is obtained.
/// Comparing the handle's generation with the current frame's generation
/// enforces that rule: the values differ for a handle from an earlier frame.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FrameGeneration(u64);

impl FrameGeneration {
    /// Before the first frame has begun.
    pub const INITIAL: Self = Self(0);

    /// The next frame, saturating and never wrapping.
    ///
    /// Wrapping would make a handle from long ago compare equal to a current
    /// one. The counter saturates to prevent that. Saturation is unreachable
    /// at one frame per display refresh.
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
/// recent installation.
///
/// The blit path stores the value it last copied and copies again when the
/// value differs. When it does not, the copy is skipped. That comparison is
/// the entire damage-skipping mechanism.
///
/// Counted across every surface and never restarted. A per-surface counter
/// would repeat an earlier value: the client unmaps and re-maps, and the
/// surface is retired and re-created. The blit path interprets a repeated
/// value as "nothing has changed" while the texture underneath it is a
/// different one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SurfaceCommit(u64);

impl SurfaceCommit {
    /// Before anything has been installed.
    pub const INITIAL: Self = Self(0);

    /// The next value, saturating and never wrapping, for the same reason as
    /// [`FrameGeneration::next`].
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
