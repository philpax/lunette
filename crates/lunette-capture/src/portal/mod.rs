//! Linux-only: the vocabulary of `org.freedesktop.portal.ScreenCast`.
//!
//! The portal is an unmanaged D-Bus dependency. This module defines the
//! [`ScreenCastPortal`] seam that [`wlx::WlxPortal`] implements, and tests use
//! [`fake::FakePortal`] instead of a session bus.
//!
//! Requests and responses carry plain data. A request states what lunette
//! requires, a response states what the user granted, and [`correlation`]
//! matches returned streams to monitors. Correlation is a pure function, so
//! testing it requires neither PipeWire nor a display.
//!
//! # Restore behaviour
//!
//! Restore is best-effort. The portal rejects a stored token when a monitor was
//! unplugged or renamed, and it presents the selection dialog again without
//! reporting an error. Persist mode does not reliably preserve which monitors
//! were selected. [`RequestProgress::AwaitingUser`] reports this dialog, and
//! every call on the seam returns immediately rather than blocking on it.

pub mod correlation;
#[cfg(any(test, feature = "test-fakes"))]
pub mod fake;
pub mod wlx;

use std::{error::Error, fmt, num::NonZeroU32};

use serde::{Deserialize, Serialize};

use crate::monitor::{
    geometry::{LogicalPosition, LogicalSize},
    name::ConnectorName,
};
pub use crate::portal::{
    correlation::{Correlation, MatchStrength, StreamMatch, Unmatched, correlate},
    wlx::WlxPortal,
};

/// The non-blocking portal interface used by lunette.
///
/// [`Self::begin`] starts a request and [`Self::poll`] reports progress. An
/// implementation owns no thread or executor. Implementations are thread-affine
/// because the portal client and its futures are not `Send`.
pub trait ScreenCastPortal {
    /// Starts a session request and returns after the portal records it.
    ///
    /// This error means the request could not be started. User refusal is
    /// reported later by [`Self::poll`] as [`RequestProgress::Failed`].
    fn begin(&mut self, request: SessionRequest) -> Result<RequestId, PortalError>;

    /// Advances the exchange without blocking and reports its state.
    ///
    /// Terminal results are delivered once. Polling an identifier after that, or
    /// polling an identifier this portal did not issue, returns
    /// [`PortalError::UnknownRequest`].
    fn poll(&mut self, request: RequestId) -> RequestProgress;
}

/// What lunette asks the portal for.
///
/// The implementation requests monitor sources only and allows multiple streams.
/// Lunette's windows belong to its own compositor, and one multi-screen dialog
/// avoids prompting separately for each screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionRequest {
    /// A token from a previous session, when one was stored. The backend may
    /// reject it and prompt again without reporting an error.
    pub restore_token: Option<RestoreToken>,
    pub cursor: CursorPolicy,
    /// The requested session lifetime. The backend may grant less;
    /// [`SessionResponse::granted_persist_mode`] records the observed grant.
    pub persist_mode: PersistMode,
}

impl SessionRequest {
    /// Creates a request for a session that survives until the user revokes it.
    ///
    /// A shorter lifetime would require another prompt on the next launch.
    #[must_use]
    pub const fn new(restore_token: Option<RestoreToken>, cursor: CursorPolicy) -> Self {
        Self {
            restore_token,
            cursor,
            persist_mode: PersistMode::UntilRevoked,
        }
    }
}

/// Whether the host cursor appears in captured frames.
///
/// The underlying client exposes this choice as a boolean and does not report
/// which portal cursor mode it selected. This type therefore exposes only the
/// two behaviours the client can represent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum CursorPolicy {
    /// Excludes the host cursor so lunette can draw its own pointer.
    #[default]
    Hidden,
    /// Includes the host cursor using the backend's available mode.
    Visible,
}

/// How long a granted session survives.
///
/// This closed set represents the portal's `persist_mode` values. The backend may
/// grant less than requested, so [`SessionResponse`] carries the observed value
/// separately from [`SessionRequest`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PersistMode {
    /// The session is not persisted, and the next launch prompts.
    DoNot,
    /// The session survives as long as this process does.
    WhileRunning,
    /// The session survives until the user revokes it in the portal's settings.
    UntilRevoked,
}

impl PersistMode {
    /// Returns the wire value for the portal's `persist_mode` option.
    #[must_use]
    pub const fn as_portal_value(self) -> u32 {
        match self {
            Self::DoNot => 0,
            Self::WhileRunning => 1,
            Self::UntilRevoked => 2,
        }
    }

    /// Converts a portal `persist_mode` value, or returns `None` for an unknown
    /// value.
    #[must_use]
    pub const fn from_portal_value(value: u32) -> Option<Self> {
        match value {
            0 => Some(Self::DoNot),
            1 => Some(Self::WhileRunning),
            2 => Some(Self::UntilRevoked),
            _ => None,
        }
    }
}

impl fmt::Display for PersistMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::DoNot => "not persisted",
            Self::WhileRunning => "persisted while lunette runs",
            Self::UntilRevoked => "persisted until revoked",
        })
    }
}

/// An opaque token that lets a later session skip the prompt.
///
/// The portal invalidates a token after use and returns a replacement in each
/// `Start` response. The token is a newtype so callers cannot confuse it with a
/// monitor key.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RestoreToken(String);

impl RestoreToken {
    /// Wraps a non-empty token from a portal response.
    ///
    /// An empty token cannot restore a session and would cause repeated prompts.
    #[must_use]
    pub fn new(token: impl Into<String>) -> Option<Self> {
        let token = token.into();
        (!token.is_empty()).then_some(Self(token))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A non-zero PipeWire node identifier reported for a stream.
///
/// PipeWire reserves node 0 for the core, so a zero value is malformed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct NodeId(NonZeroU32);

impl NodeId {
    #[must_use]
    pub const fn new(raw: u32) -> Option<Self> {
        match NonZeroU32::new(raw) {
            Some(id) => Some(Self(id)),
            None => None,
        }
    }

    #[must_use]
    pub const fn get(self) -> u32 {
        self.0.get()
    }
}

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "node {}", self.0)
    }
}

/// One stream granted by the portal.
///
/// The backend may report either, both, or neither of `position` and `size`.
/// [`correlation`] uses the available properties and records match confidence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortalStream {
    pub node: NodeId,
    /// The stream's top-left corner in logical compositor space.
    pub position: Option<LogicalPosition>,
    /// The stream's extent in logical compositor space.
    pub size: Option<LogicalSize>,
    /// A connector name when the backend supplies one in `mapping_id`.
    ///
    /// Connector names are optional and backend-dependent. [`correlation`] uses
    /// geometry when this field is absent or unusable. `wlx-capture` does not read
    /// `mapping_id`, so [`wlx::WlxPortal`] always leaves this field as `None`.
    pub connector: Option<ConnectorName>,
}

/// What the portal granted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionResponse {
    /// One entry per selected screen. The order is unspecified; [`correlate`]
    /// matches streams to monitors by their properties.
    pub streams: Vec<PortalStream>,
    /// The replacement token to store for the next launch.
    pub restore_token: Option<RestoreToken>,
    pub granted_persist_mode: GrantedPersistMode,
}

/// The persistence mode the backend granted, when it is observable.
///
/// The backend may downgrade the requested mode. Persisting the requested value
/// instead of the observed value would misrepresent the next launch.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GrantedPersistMode {
    Granted(PersistMode),
    /// The response did not expose `persist_mode`. An unobserved grant is kept
    /// separate from a confirmed grant rather than defaulted to the request.
    Unstated,
}

impl fmt::Display for GrantedPersistMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Granted(mode) => write!(f, "{mode}"),
            Self::Unstated => f.write_str("persistence not stated by the backend"),
        }
    }
}

/// An in-flight request issued by one [`ScreenCastPortal`].
///
/// The identifier is opaque and valid only for the portal that issued it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RequestId(u64);

impl RequestId {
    #[must_use]
    pub(crate) const fn from_raw(raw: u64) -> Self {
        Self(raw)
    }
}

impl fmt::Display for RequestId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "portal request {}", self.0)
    }
}

/// The current state of a portal request.
///
/// Non-terminal states require another poll. Terminal states are delivered once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RequestProgress {
    /// Accepted and waiting behind another request. The portal serialises
    /// dialogs.
    Queued,
    /// Negotiating with the portal.
    Negotiating,
    /// Waiting for the user to respond to the dialog.
    AwaitingUser,
    Ready(SessionResponse),
    Failed(PortalError),
}

/// Why a portal exchange could not be completed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PortalError {
    /// The session bus could not be reached, or the exchange failed on it.
    Dbus(String),
    /// The identifier was never issued by this portal, or its result has
    /// already been taken.
    UnknownRequest(RequestId),
    /// The portal refused the request. Code 1 means that the user cancelled it.
    Refused { code: u32 },
    /// The backend offers no monitor sources, so there is nothing to mirror.
    NoMonitorSources { available: u32 },
    /// The backend offers no cursor mode compatible with the request.
    NoCursorMode { available: u32 },
    /// The response was not shaped as the specification says.
    Malformed(&'static str),
    /// The response named a node that cannot be connected to. The error is
    /// reported instead of silently dropping the stream.
    UnusableNode { raw: u32 },
    /// The underlying client cannot express the requested persistence mode.
    /// The client maps persistence to a boolean, so requesting a different value
    /// would risk granting a longer-lived session than requested.
    UnsupportedPersistMode(PersistMode),
}

impl fmt::Display for PortalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "screencast portal: ")?;
        match self {
            Self::Dbus(message) => write!(f, "{message}"),
            Self::UnknownRequest(id) => write!(f, "{id} is not in flight"),
            Self::Refused { code } => match code {
                1 => write!(f, "the user cancelled the screen selection"),
                other => write!(f, "the request was refused with response code {other}"),
            },
            Self::NoMonitorSources { available } => write!(
                f,
                "the backend offers no monitor sources to capture (source types {available:#x})"
            ),
            Self::NoCursorMode { available } => write!(
                f,
                "the backend offers no usable cursor mode (cursor modes {available:#x})"
            ),
            Self::Malformed(what) => write!(f, "the response carried no usable {what}"),
            Self::UnusableNode { raw } => write!(
                f,
                "a stream named PipeWire node {raw}, which is the core rather than a stream"
            ),
            Self::UnsupportedPersistMode(mode) => write!(
                f,
                "a session {mode} cannot be requested through this portal client"
            ),
        }
    }
}

impl Error for PortalError {}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn every_persist_mode_round_trips_through_its_portal_value() {
        for mode in [
            PersistMode::DoNot,
            PersistMode::WhileRunning,
            PersistMode::UntilRevoked,
        ] {
            assert_eq!(
                PersistMode::from_portal_value(mode.as_portal_value()),
                Some(mode),
            );
        }
    }

    #[test]
    fn a_persist_mode_the_specification_does_not_define_is_rejected() {
        assert_eq!(PersistMode::from_portal_value(3), None);
        assert_eq!(PersistMode::from_portal_value(u32::MAX), None);
    }

    #[test]
    fn an_empty_restore_token_is_not_a_token() {
        assert_eq!(RestoreToken::new(""), None);
        assert!(RestoreToken::new("abc").is_some());
    }

    #[test]
    fn pipewire_node_zero_is_the_core_rather_than_a_stream() {
        assert_eq!(NodeId::new(0), None);
        assert_eq!(NodeId::new(42).map(NodeId::get), Some(42));
    }

    #[test]
    fn a_session_request_always_asks_for_the_longest_lived_grant() {
        let request = SessionRequest::new(None, CursorPolicy::Hidden);

        assert_eq!(request.persist_mode, PersistMode::UntilRevoked);
    }

    #[test]
    fn a_cancelled_request_reads_as_a_refusal_rather_than_a_fault() {
        assert_eq!(
            PortalError::Refused { code: 1 }.to_string(),
            "screencast portal: the user cancelled the screen selection",
        );
    }
}
