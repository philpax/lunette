//! Linux-only: the vocabulary of `org.freedesktop.portal.ScreenCast`.
//!
//! The portal is an unmanaged dependency — another project's D-Bus interface,
//! reached through another project's client — so it sits behind the
//! [`ScreenCastPortal`] seam and the tests substitute [`fake::FakePortal`]
//! rather than mocking D-Bus. [`wlx::WlxPortal`] is the production
//! implementation, and it is the only thing in this crate that touches
//! `wlx-capture`'s portal client.
//!
//! What the seam is written in is plain data: a request says what lunette wants
//! and a response says what the user granted. [`correlation`] then decides
//! which monitor each returned stream belongs to, and that decision is pure, so
//! it is tested without a portal, without PipeWire, and without a display.
//!
//! # A prompt is normal
//!
//! Restore is best-effort and the portal says so. A rejected token produces no
//! error — the user simply sees a dialog. xdg-desktop-portal-wlr's v1 restore
//! payload carries only `output_name` (`src/screencast/screencast.c:706-711`),
//! so an unplugged or renamed monitor falls back to a prompt silently, and
//! there is a standing upstream issue that persist mode does not reliably
//! preserve which monitors were selected.
//!
//! [`RequestProgress::AwaitingUser`] is therefore an ordinary state rather than
//! an error, and every call on the seam returns immediately. Nothing here
//! blocks, so nothing here can be on a frame's critical path.

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

/// The portal, as lunette needs it.
///
/// Two calls, both non-blocking. [`Self::begin`] states what is wanted and
/// [`Self::poll`] reports how far the portal has got, so the caller drives the
/// exchange from wherever it already runs rather than the portal owning a
/// thread or an executor.
///
/// Not `Send`. `wlx-capture`'s `ScreenCastManager` polls D-Bus futures with a
/// no-op waker on the calling thread (`pipewire/mod.rs:840`), its `DbusFuture`
/// is not `Send` (`mod.rs:632`), and `ScreenCastParams.token` is an `Rc<str>`
/// (`mod.rs:46`). The trait does not require `Send` so that the implementation
/// does not have to lie about it: a portal lives on one thread, and it is the
/// capture thread's.
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
/// Two of the portal's options are not fields, because they are the phase's
/// decisions rather than the caller's. `types` is always monitors alone: a
/// window belongs to lunette's own compositor, not to a mirror. `multiple` is
/// always true, which is what removes the prescribed selection order — WayVR's
/// Wayland path requests one stream per output with `allow_multiple: false`
/// (`overlays/screen/pw.rs:93-99`) and prompts once per screen, and that ritual
/// is the thing `lunette-v1.AC3.4` exists to eliminate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionRequest {
    /// A token from a previous session, if one was stored for these monitors.
    ///
    /// Supplying one is a request, not an instruction. The backend may ignore
    /// it and prompt anyway, and it reports nothing when it does.
    pub restore_token: Option<RestoreToken>,
    pub cursor: CursorPolicy,
    /// How long the granted session should survive. The backend may grant less;
    /// [`SessionResponse::granted_persist_mode`] is what it actually granted.
    pub persist_mode: PersistMode,
}

impl SessionRequest {
    /// A request for a session that survives until the user revokes it.
    ///
    /// [`PersistMode::UntilRevoked`] is what lunette wants every time: anything
    /// weaker re-prompts on the next launch, which is the outcome the restore
    /// token exists to avoid.
    #[must_use]
    pub const fn new(restore_token: Option<RestoreToken>, cursor: CursorPolicy) -> Self {
        Self {
            restore_token,
            cursor,
            persist_mode: PersistMode::UntilRevoked,
        }
    }
}

/// Whether the host's cursor should appear in the captured frames.
///
/// Two variants rather than the portal's three. The portal distinguishes
/// `EMBEDDED`, which draws the cursor into the pixels, from `METADATA`, which
/// reports its position alongside them; `wlx-capture` collapses the choice to a
/// bool and picks the first available of `EMBEDDED`, `METADATA`, and `HIDDEN`
/// (`pipewire/mod.rs:796-805`), and reports nothing about which it got.
/// Offering a `Metadata` variant this seam cannot honour would be a promise
/// broken silently, so the type says only what it can deliver.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum CursorPolicy {
    /// No cursor. The mirror shows the desktop as though nothing were pointing
    /// at it, and lunette draws its own pointer.
    #[default]
    Hidden,
    /// The host cursor, however the backend can supply it.
    Visible,
}

/// How long a granted session survives.
///
/// The portal's `persist_mode`, as a closed set rather than the wire integer.
/// The backend may grant less than was asked for and returns what it granted in
/// the `Start` response, which is why [`SessionResponse`] carries this
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
    /// The integer the portal's `persist_mode` option carries.
    #[must_use]
    pub const fn as_portal_value(self) -> u32 {
        match self {
            Self::DoNot => 0,
            Self::WhileRunning => 1,
            Self::UntilRevoked => 2,
        }
    }

    /// Reads a `persist_mode` from a portal response, or `None` if the backend
    /// named a mode this version of the specification does not define.
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
/// Single-use: the portal invalidates the token it was given and returns a new
/// one in every `Start` response. A client that stores only the first token
/// loses restore on the second run, which is why
/// [`crate::tokens::TokenStore::record`] takes the new one every time rather
/// than only when none was stored.
///
/// A newtype rather than a `String` so it cannot be transposed with the
/// monitor's key, which is the other string in every call that handles one.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RestoreToken(String);

impl RestoreToken {
    /// Wraps a token from a portal response, rejecting an empty one.
    ///
    /// An empty token is not a token the portal would accept back, and storing
    /// one would produce a stored session that silently re-prompts forever.
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
/// Non-zero because node 0 is the PipeWire core rather than a stream, so a zero
/// here is a malformed response rather than a node lunette could connect to.
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
/// `position` and `size` are separately optional because the portal's stream
/// properties are: a backend may report one, both, or neither.
/// [`correlation`] uses whichever arrived and says so in the strength of the
/// match it produces.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortalStream {
    pub node: NodeId,
    /// The stream's top-left corner in the compositor's logical space.
    pub position: Option<LogicalPosition>,
    /// The stream's extent in the same space.
    pub size: Option<LogicalSize>,
    /// A connector name, when the backend put a real one in `mapping_id`.
    ///
    /// Opportunistic, never the mechanism. xdg-desktop-portal-wlr sets
    /// `mapping_id` to the `wl_output` name, which on wlroots is the connector
    /// name; mutter sets a random UUID and only under a RemoteDesktop session;
    /// xdg-desktop-portal-kde omits it. [`ConnectorName::parse`] is what
    /// separates the first case from the second.
    ///
    /// `wlx-capture` does not read `mapping_id` at all — `parse_streams`
    /// (`pipewire/mod.rs:693-733`) takes `node_id`, `position`, and `size` —
    /// so [`wlx::WlxPortal`] always leaves this `None`. Lifting that is an
    /// upstream change, and geometry is the mechanism either way.
    pub connector: Option<ConnectorName>,
}

/// What the portal granted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionResponse {
    /// One entry per screen the user selected. Order means nothing: it
    /// corresponds neither to the selection order nor to output enumeration
    /// order, which is why [`correlate`] matches on geometry.
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
    /// `wlx-capture`'s `parse_start_response` (`pipewire/mod.rs:686-691`) reads
    /// `streams` and `restore_token` and discards the rest, so
    /// [`wlx::WlxPortal`] cannot see it. Recorded as its own case rather than
    /// defaulted to the requested mode: an unobserved grant and a confirmed one
    /// are different facts, and only the second is worth writing down as one.
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
    /// The portal answered the request with a non-zero response code. 1 is the
    /// user cancelling, which is a refusal rather than a fault.
    Refused { code: u32 },
    /// The backend offers no monitor sources, so there is nothing to mirror.
    NoMonitorSources { available: u32 },
    /// The backend offers no cursor mode compatible with the request.
    NoCursorMode { available: u32 },
    /// The response was not shaped as the specification says.
    Malformed(&'static str),
    /// The response named a stream whose node identifier cannot be connected
    /// to. Reported rather than skipped, so a backend that starts producing
    /// them is visible rather than quietly halving the mirrors.
    UnusableNode { raw: u32 },
    /// A persistence mode the underlying client cannot express was requested.
    ///
    /// `wlx-capture`'s `ScreenCastParams.persist` is a bool mapping to 0 or 2
    /// (`pipewire/mod.rs:513`), so [`PersistMode::WhileRunning`] has no
    /// representation. Sending 2 instead would ask for a longer-lived grant
    /// than the caller wanted, which is the wrong direction to guess in.
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
