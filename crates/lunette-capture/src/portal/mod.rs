//! Linux-only: the vocabulary of `org.freedesktop.portal.ScreenCast`.
//!
//! The portal is an unmanaged dependency: another project's D-Bus interface,
//! reached through another project's client. It sits behind the
//! [`ScreenCastPortal`] seam, and the tests substitute [`fake::FakePortal`];
//! they do not mock D-Bus. [`wlx::WlxPortal`] is the production
//! implementation, and it is the only thing in this crate that touches
//! `wlx-capture`'s portal client.
//!
//! The seam exchanges plain data. A request states what lunette asks the
//! portal for, and a response states what the user granted. The correlation
//! module assigns each returned stream to its monitor. That assignment is
//! pure, so it is tested without a portal, without PipeWire, and without a
//! display.
//!
//! # Awaiting the user
//!
//! Restore is best-effort, and the portal's specification says so. A rejected
//! token produces no error; the user sees a dialog. xdg-desktop-portal-wlr's
//! v1 restore payload carries only `output_name`, so an unplugged or renamed
//! monitor falls back to a prompt silently. There is an open upstream issue:
//! persist mode does not reliably preserve which monitors were selected.
//!
//! [`RequestProgress::AwaitingUser`] is therefore an ordinary state, not an
//! error. Every call on the seam returns immediately. Nothing here blocks, so
//! nothing here can be on a frame's critical path.

pub mod correlation;
#[cfg(test)]
pub mod fake;
pub mod wlx;

use std::{error::Error, fmt, num::NonZeroU32};

use serde::{Deserialize, Serialize};

use crate::monitor::geometry::LogicalPosition;
pub use crate::portal::{
    correlation::{Correlation, StreamMatch, Unmatched, correlate},
    wlx::WlxPortal,
};

/// The portal, as lunette uses it.
///
/// Two calls, both non-blocking. [`Self::begin`] states what is wanted and
/// [`Self::poll`] reports how far the portal has got. The caller drives the
/// exchange from wherever it already runs; the portal owns no thread or
/// executor.
///
/// Not `Send`. `wlx-capture`'s `ScreenCastManager` polls D-Bus futures with a
/// no-op waker on the calling thread, its `DbusFuture` is not `Send`, and
/// `ScreenCastParams.token` is an `Rc<str>`. The trait does not require
/// `Send`, so the implementation does not claim it: a portal lives on one
/// thread, the capture thread's.
pub trait ScreenCastPortal {
    /// Asks for a session. Returns as soon as the request is recorded.
    ///
    /// An error here means the request could not be made at all. A request the
    /// user declines is not an error from this call; it arrives at
    /// [`Self::poll`] as [`RequestProgress::Failed`].
    fn begin(&mut self, request: SessionRequest) -> Result<RequestId, PortalError>;

    /// Advances the exchange without blocking and reports where it has got to.
    ///
    /// Polling an identifier that has already reported a terminal progress, or
    /// one this portal never issued, yields
    /// [`PortalError::UnknownRequest`]: a terminal result is delivered once,
    /// and the caller owns it afterwards.
    fn poll(&mut self, request: RequestId) -> RequestProgress;
}

/// What lunette asks the portal for.
///
/// Two of the portal's options are not fields; the seam sets them. `types` is
/// always monitors alone: a window belongs to lunette's own compositor, not to
/// a mirror. `multiple` is always true, which removes the prescribed selection
/// order. WayVR's Wayland path requests one stream per output with
/// `allow_multiple: false` and prompts once per screen; this setting ends that
/// repeated per-screen prompting.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionRequest {
    /// A token from a previous session, if one was stored for these monitors.
    ///
    /// Supplying one is a request, not an instruction. The backend may ignore
    /// it and prompt anyway, and it reports nothing when it does.
    pub restore_token: Option<RestoreToken>,
    pub cursor: CursorPolicy,
}

impl SessionRequest {
    /// A request for a session that survives until the user revokes it.
    ///
    /// Every request asks for [`PersistMode::UntilRevoked`]. Anything weaker
    /// re-prompts on the next launch, the outcome the restore token exists to
    /// avoid. The backend may grant less;
    /// [`SessionResponse::granted_persist_mode`] is what it actually granted.
    #[must_use]
    pub const fn new(restore_token: Option<RestoreToken>, cursor: CursorPolicy) -> Self {
        Self {
            restore_token,
            cursor,
        }
    }
}

/// Whether the host's cursor should appear in the captured frames.
///
/// The portal has three modes; this type has two. The portal distinguishes
/// `EMBEDDED`, which draws the cursor into the pixels, from `METADATA`, which
/// reports its position alongside them. `wlx-capture` collapses the choice to
/// a bool and picks the first available of `EMBEDDED`, `METADATA`, and
/// `HIDDEN`, and reports nothing about which it got. A `Metadata` variant
/// would offer a choice the seam cannot deliver, so the type contains only
/// what the seam can deliver.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum CursorPolicy {
    /// No cursor. The mirror shows the desktop without a cursor, and lunette
    /// draws its own pointer.
    #[default]
    Hidden,
    /// The host cursor, however the backend can supply it.
    Visible,
}

/// How long a granted session survives.
///
/// The portal's `persist_mode`, represented as a closed set and not as the
/// wire integer. The backend may grant less than was asked for and returns
/// what it granted in the `Start` response, which is why
/// [`SessionResponse`] carries this separately from [`SessionRequest`].
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
/// Single-use: the portal invalidates the token it was given and returns a new
/// one in every `Start` response. A client that stores only the first token
/// loses restore on the second run, which is why
/// [`crate::tokens::TokenStore::record`] takes the new one every time, not
/// only when none was stored.
///
/// A newtype, not a `String`, so it cannot be transposed with the monitor's
/// key, which is the other string in every call that handles one.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RestoreToken(String);

impl RestoreToken {
    /// Wraps a token from a portal response, rejecting an empty one.
    ///
    /// An empty token is not a token the portal would accept back. Storing one
    /// would produce a stored session that silently re-prompts forever.
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

/// A PipeWire node identifier, as the portal reports it for a stream.
///
/// Non-zero because node 0 is the PipeWire core, not a stream. A zero here is
/// therefore a malformed response, not a node lunette could connect to.
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

/// One stream the portal granted.
///
/// `position` is optional because the portal's stream properties are: a
/// backend may omit it, and [`correlation`] then reports the stream unmatched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortalStream {
    pub node: NodeId,
    /// The stream's top-left corner in the compositor's logical space.
    pub position: Option<LogicalPosition>,
}

/// What the portal granted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionResponse {
    /// One entry per screen the user selected. Order means nothing: it
    /// corresponds neither to the selection order nor to output enumeration
    /// order, which is why [`correlate`] matches on position.
    pub streams: Vec<PortalStream>,
    /// The token to store for the next launch, replacing whatever was stored.
    pub restore_token: Option<RestoreToken>,
    pub granted_persist_mode: GrantedPersistMode,
}

/// What the backend granted for persistence, as far as it can be observed.
///
/// The backend may downgrade the requested mode and returns what it granted in
/// the `Start` response, so storing the requested value would produce a record
/// that lies about what the next launch will do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GrantedPersistMode {
    Granted(PersistMode),
    /// The response's `persist_mode` was not observed.
    ///
    /// `wlx-capture`'s `parse_start_response` reads `streams` and
    /// `restore_token` and discards the rest, so [`wlx::WlxPortal`] cannot see
    /// it. Recorded as its own case, not defaulted to the requested mode: an
    /// unobserved grant and a confirmed one are different facts, and only the
    /// second is worth writing down as one.
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

/// A request in flight, as issued by one [`ScreenCastPortal`].
///
/// Opaque and not transferable between portals: an identifier one implementation
/// minted means nothing to another.
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

/// How far a request has got.
///
/// Three of the five are non-terminal and mean "call again later". The two
/// terminal ones are delivered once, after which the identifier is spent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RequestProgress {
    /// Accepted, and waiting behind another request. The portal serialises
    /// them: two dialogs at once is not a thing to show a user in a headset.
    Queued,
    /// Talking to the portal.
    Negotiating,
    /// A dialog is on the user's screen. Ordinary, not exceptional.
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
    /// The portal answered the request with a non-zero response code. Code 1
    /// is the user cancelling, a refusal and not a fault.
    Refused { code: u32 },
    /// The granted session ended outside lunette, as when the user stops the screen share from
    /// the host desktop. Like a refusal, it holds until an explicit selection.
    Revoked,
    /// The backend offers no monitor sources, so there is nothing to mirror.
    NoMonitorSources { available: u32 },
    /// The backend offers no cursor mode compatible with the request.
    NoCursorMode { available: u32 },
    /// The response was not shaped as the specification says.
    Malformed(&'static str),
    /// The response named a stream whose node identifier cannot be connected
    /// to. The error reports it and does not skip it, so a backend that
    /// starts producing such nodes is visible; the mirror count does not
    /// quietly halve.
    UnusableNode { raw: u32 },
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
            Self::Revoked => write!(f, "the screen share was stopped outside lunette"),
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
        }
    }
}

impl Error for PortalError {}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

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
    fn a_cancelled_request_reads_as_a_refusal_rather_than_a_fault() {
        assert_eq!(
            PortalError::Refused { code: 1 }.to_string(),
            "screencast portal: the user cancelled the screen selection",
        );
    }
}
