//! Public source identity, negotiated format, and capture-state vocabulary.

use lunette_compositor::protocol::ProcessId;

/// A source in this session. A PID or application label is never a source identity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Source {
    System,
    Process(ProcessId),
}

/// The only supported public PCM format. PipeWire converts before this boundary.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioFormat {
    sample_rate: u32,
    channels: u8,
}

impl AudioFormat {
    pub const STEREO_F32_48K: Self = Self {
        sample_rate: 48_000,
        channels: 2,
    };

    pub const fn sample_rate(self) -> u32 {
        self.sample_rate
    }

    pub const fn channels(self) -> u8 {
        self.channels
    }

    /// Validates the negotiated rate and channel count; samples must separately be F32.
    pub const fn negotiate(sample_rate: u32, channels: u8) -> Option<Self> {
        if sample_rate == 48_000 && channels == 2 {
            Some(Self::STEREO_F32_48K)
        } else {
            None
        }
    }
}

/// The origin of a node's PID assertion, rather than a security guarantee.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttributionProvenance {
    PipeWireClient,
    ApplicationMetadata,
}

/// Capture outages remain distinct from silence and an empty publication.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CaptureState {
    Starting,
    Active {
        provenance: Option<AttributionProvenance>,
    },
    Idle,
    Unavailable {
        reason: UnavailableReason,
        detail: String,
    },
    Ended,
}

/// Closed reasons that consumers can render without parsing diagnostic text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnavailableReason {
    NoServer,
    NoDefaultSink,
    InvalidDefaultSink,
    PermissionDenied,
    UnsupportedFormat,
    UnresolvedAttribution,
    CapacityExceeded,
    GraphFailure,
}

/// Limits apply to actual streams, independently of the number of readers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceLimits {
    pub simultaneous_sources: usize,
}

impl Default for SourceLimits {
    fn default() -> Self {
        Self {
            simultaneous_sources: 8,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiated_audio_format_rejects_conversion_mismatch() {
        assert_eq!(
            AudioFormat::negotiate(48_000, 2),
            Some(AudioFormat::STEREO_F32_48K)
        );
        for (rate, channels) in [(44_100, 2), (48_000, 1), (48_000, 6), (0, 0)] {
            assert_eq!(AudioFormat::negotiate(rate, channels), None);
        }
    }
}
