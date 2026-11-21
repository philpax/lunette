//! Monitor mirror outcomes and the Linux capture lifecycle.

#[cfg(all(test, target_os = "linux"))]
pub mod fake;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub mod nodes;
#[cfg(target_os = "linux")]
pub mod screencopy;
#[cfg(target_os = "linux")]
pub mod source;
#[cfg(target_os = "linux")]
pub use linux::*;

use crate::portal::PortalError;

/// The result of starting an explicit fresh selection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionOutcome {
    Requested,
    Busy,
    NoMonitors,
    /// The platform shares individual displays through their menu actions.
    ChooseIndividually,
    Refused(PortalError),
}

/// The latest explicit selection's state. Existing capture remains live while it is pending or
/// failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionState {
    Idle,
    Pending,
    Ready,
    Failed(PortalError),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorOutcome {
    /// A stream is running because the held session covers this monitor.
    Mirroring,
    /// The monitor was already mirrored, and nothing changed.
    AlreadyMirroring,
    /// A portal request is in flight; the mirror lifecycle advances it.
    Requested,
    /// The portal could not be asked, refused the request, or the session was revoked, and
    /// nothing asks again until a fresh selection.
    Refused(PortalError),
    /// The native capture worker could not be started.
    Failed(String),
    /// No attached monitor carries that identity, as with a restored key whose monitor was
    /// unplugged.
    NoSuchMonitor,
}
