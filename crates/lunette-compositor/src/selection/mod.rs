//! The clipboard and the primary selection, and the bridge to the host's.
//!
//! Four protocols carry a selection: `wl_data_device` for the clipboard,
//! `zwp_primary_selection_v1` for the middle-click selection, and
//! `zwlr_data_control_v1` and `ext_data_control_v1` for a clipboard manager
//! that wants both without holding focus. lunette advertises all four to its own
//! clients, and speaks the last two *as a client* to the host compositor, which
//! is how a selection crosses the boundary in either direction.
//!
//! Every selection is per-seat, because smithay stores it in `Seat::user_data`
//! and every entry point takes the seat. The host has exactly one clipboard and
//! one primary selection, so exactly one seat is bridged to it; [`SelectionBridge`]
//! is where that mapping lives, and `docs/input.md` records the reasoning.
//!
//! # Nothing here reads or writes a selection pipe
//!
//! This is the part that usually goes wrong, so it is stated plainly: **lunette
//! never buffers selection content and never touches a selection pipe.** A
//! transfer is a descriptor handed from the process that wants the bytes to the
//! process that has them, and lunette is neither.
//!
//! - A lunette client pasting supplies a pipe to `wl_data_offer.receive`.
//!   smithay hands that descriptor to [`SelectionHandler::send_selection`], and
//!   the descriptor is forwarded to the host connection, which passes it
//!   straight to `ext_data_control_offer_v1.receive`. The host's *own* clipboard
//!   owner then writes into the lunette client's pipe.
//! - The host pasting supplies a pipe to lunette's data-control source. That
//!   descriptor arrives on the host worker as a `send` event, crosses back to the
//!   compositor thread, and is handed to `request_data_device_client_selection`,
//!   which passes it to the lunette client that owns the selection.
//!
//! So no thread of lunette's ever blocks on a pipe: a client that never reads
//! stalls only the process that owns the data, exactly as it would with no
//! lunette in the middle. WayVR instead spawns a detached thread per request and
//! writes the bytes itself (`comp.rs:365-383`), with no join, no bound, and no
//! cancellation; a client requesting the selection in a loop spawns threads
//! without limit. `docs/decisions.md` records why the descriptor is passed
//! rather than the bytes copied.
//!
//! Descriptor ownership is encoded rather than trusted. A [`HostRead`] owns its
//! [`OwnedFd`], and a rejection returns the whole request, so a refused transfer
//! either reaches the host or is closed by a named owner — never both, and never
//! neither.
//!
//! # Nothing here substitutes a MIME type
//!
//! WayVR hardcodes `"text/plain;charset=utf-8"` and `"text/plain"`
//! (`comp.rs:102-109`) whatever the source actually advertises. lunette re-offers
//! the source's own list unchanged in both directions, so there is no format to
//! negotiate and nothing to lose. A request for a type the offer does not carry
//! is refused with [`Refusal::Unrepresentable`] rather than answered with the
//! nearest thing, because content silently substituted is worse than a paste
//! that visibly did nothing.

mod data_control;
mod host;
#[cfg(test)]
mod tests;

use std::{
    error::Error,
    fmt,
    num::NonZeroU64,
    os::fd::OwnedFd,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use smithay::wayland::selection::SelectionTarget;

use crate::protocol::SeatId;
#[cfg(any(test, feature = "test-fakes"))]
pub use crate::selection::host::{FakeHost, FakeHostSource, HostCall};
pub use crate::selection::{
    data_control::DataControlSource,
    host::{
        HostEvent, HostEvents, HostSelection, HostSelectionSource, HostStartError, RejectReason,
        Rejected,
    },
};

/// One of the two selections a seat carries.
///
/// A closed set rather than a boolean, so a path that handles one and not the
/// other fails to compile rather than silently bridging half of
/// `lunette-v1.AC4.5`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SelectionKind {
    /// What an explicit copy puts on the clipboard.
    Clipboard,
    /// What selecting text puts on the middle-click selection.
    Primary,
}

impl SelectionKind {
    /// Both selections, in the order a caller that must handle each should
    /// iterate them.
    pub const ALL: [Self; 2] = [Self::Clipboard, Self::Primary];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Clipboard => "clipboard",
            Self::Primary => "primary",
        }
    }

    /// The selection a smithay target names.
    pub(crate) const fn from_target(target: SelectionTarget) -> Self {
        match target {
            SelectionTarget::Clipboard => Self::Clipboard,
            SelectionTarget::Primary => Self::Primary,
        }
    }

    /// Where this selection sits in a per-kind array.
    const fn index(self) -> usize {
        match self {
            Self::Clipboard => 0,
            Self::Primary => 1,
        }
    }
}

impl fmt::Display for SelectionKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A MIME type, as a selection source advertises it.
///
/// Compared byte for byte rather than case-insensitively. The clipboard
/// protocols carry the string a source chose and every implementation matches it
/// exactly, so normalising here would make lunette answer a request no other
/// compositor would.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MimeType(String);

impl MimeType {
    /// Wraps a MIME type, rejecting an empty one.
    ///
    /// An empty string is not a type any source can be asked for, and offering
    /// one would advertise a transfer that can never be answered.
    #[must_use]
    pub fn new(name: impl Into<String>) -> Option<Self> {
        let name = name.into();
        (!name.trim().is_empty()).then_some(Self(name))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The type as the `String` every protocol call takes.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for MimeType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Which of the host's successive offers a transfer belongs to.
///
/// The host replaces its selection whenever anything on the desktop copies, and
/// a lunette client may still be holding a `wl_data_offer` from the previous
/// one. Without an identifier the two are indistinguishable and the stale read
/// would be answered with the *new* selection's bytes — a paste of something the
/// user never copied. Minted by the host worker, strictly increasing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OfferId(NonZeroU64);

impl OfferId {
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0.get()
    }
}

impl fmt::Display for OfferId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "offer {}", self.0)
    }
}

/// Mints [`OfferId`]s, strictly increasing and never reused.
#[derive(Debug)]
pub struct OfferCounter(AtomicU64);

impl OfferCounter {
    #[must_use]
    pub const fn new() -> Self {
        Self(AtomicU64::new(1))
    }

    /// The next identifier.
    ///
    /// Saturating rather than wrapping, for the reason `Generation` saturates:
    /// a wrap would make two different offers compare equal, which is the one
    /// property the identifier exists to provide. At one offer per copy,
    /// saturation is unreachable.
    pub fn next(&self) -> OfferId {
        let raw = self.0.fetch_add(1, Ordering::Relaxed);
        match NonZeroU64::new(raw) {
            Some(raw) => OfferId(raw),
            None => {
                // Reached only if the counter wrapped past `u64::MAX` back to
                // zero, which needs more copies than a session can perform.
                self.0.store(u64::MAX, Ordering::Relaxed);
                OfferId(NonZeroU64::MAX)
            }
        }
    }
}

impl Default for OfferCounter {
    fn default() -> Self {
        Self::new()
    }
}

/// What the host is currently offering, as lunette re-advertises it.
///
/// This is `SelectionHandler::SelectionUserData`: smithay hands it back with
/// every request a client makes for the selection, which is how a request is
/// matched against the offer it was made from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostOffer {
    pub kind: SelectionKind,
    pub offer: OfferId,
    /// Exactly what the host advertises, in the host's own order. Never
    /// extended, never trimmed.
    pub mimes: Arc<[MimeType]>,
}

impl HostOffer {
    /// The MIME types as the `Vec<String>` smithay's setters take.
    pub(crate) fn mime_strings(&self) -> Vec<String> {
        self.mimes
            .iter()
            .map(|mime| mime.as_str().to_owned())
            .collect()
    }

    /// Whether this offer carries a type, by exact match.
    #[must_use]
    pub fn carries(&self, mime: &str) -> bool {
        self.mimes.iter().any(|carried| carried.as_str() == mime)
    }
}

/// A descriptor to be filled with the host's selection, and which offer to fill
/// it from.
///
/// Owns the descriptor. A rejected request comes back whole rather than as a
/// bare error, so the descriptor has a named owner at every point and cannot be
/// closed twice or leaked by a layer that only meant to report a failure. Phase
/// 2's dmabuf import holds an `OwnedFd` and reconstructs it on the error branch
/// for the same reason.
#[derive(Debug)]
pub struct HostRead {
    pub kind: SelectionKind,
    pub offer: OfferId,
    pub mime: MimeType,
    pub pipe: OwnedFd,
}

/// Why a read of the host's selection was refused.
///
/// Every variant means the client's pipe is closed unread, which it sees as an
/// empty paste. That is the correct outcome for all three: there is nothing to
/// paste, the type asked for does not exist, or what was asked for is no longer
/// what the user copied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The host has no selection of this kind.
    NoSelection,
    /// The offer carries no such MIME type. Never substituted with a near one.
    Unrepresentable,
    /// The offer the request was made from has been replaced.
    Stale,
}

impl Refusal {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NoSelection => "the host has no selection of that kind",
            Self::Unrepresentable => "the host's selection does not offer that mime type",
            Self::Stale => "the host replaced that selection before it could be read",
        }
    }
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "selection: {}", self.as_str())
    }
}

impl Error for Refusal {}

/// The one seat whose selections are the host's, and what the host is offering.
///
/// Two hands mean two seats, and a seat owns a clipboard; the host owns exactly
/// one. Rather than race the two — last writer wins, and which hand wins is
/// timing — exactly one seat is bridged and the rest keep selections that stay
/// inside lunette. Which seat that is comes from Lua, because it is policy.
pub(crate) struct SelectionBridge {
    seat: Option<SeatId>,
    host: Option<Box<dyn HostSelection>>,
    /// What the host last announced, indexed by [`SelectionKind::index`].
    offers: [Option<HostOffer>; 2],
}

impl SelectionBridge {
    pub(crate) fn new(seat: Option<SeatId>, host: Option<Box<dyn HostSelection>>) -> Self {
        Self {
            seat,
            host,
            offers: [None, None],
        }
    }

    /// The seat bridged to the host, absent when none is.
    pub(crate) const fn seat(&self) -> Option<SeatId> {
        self.seat
    }

    /// Whether a seat is the bridged one.
    pub(crate) fn bridges(&self, seat: SeatId) -> bool {
        self.seat == Some(seat)
    }

    /// Moves the bridge to another seat, or to none.
    ///
    /// Reports what changed so the caller can take the old seat's offer off the
    /// host and give the new seat what the host holds, rather than leaving both
    /// half-attached. `None` when the seat was already the bridged one.
    pub(crate) fn rebind(&mut self, seat: Option<SeatId>) -> Option<Rebind> {
        if self.seat == seat {
            return None;
        }
        let withdrawn = match seat {
            Some(seat) => self.seat.replace(seat),
            None => self.seat.take(),
        };
        Some(Rebind {
            withdrawn,
            adopted: seat,
        })
    }

    /// Records what the host is now offering.
    pub(crate) fn remember(&mut self, offer: HostOffer) {
        let index = offer.kind.index();
        self.offers[index] = Some(offer);
    }

    /// Forgets what the host was offering, because it cleared it.
    pub(crate) fn forget(&mut self, kind: SelectionKind) {
        self.offers[kind.index()] = None;
    }

    /// What the host is currently offering, of one kind.
    pub(crate) fn offer(&self, kind: SelectionKind) -> Option<&HostOffer> {
        self.offers[kind.index()].as_ref()
    }

    /// Turns a client's request for the host's selection into a read of it.
    ///
    /// Pure: it decides, it does not transfer. `made_from` is the offer the
    /// client's `wl_data_offer` was minted against, which is what makes a
    /// request that outlived its selection distinguishable from a current one.
    pub(crate) fn resolve(
        &self,
        made_from: &HostOffer,
        mime: &str,
    ) -> Result<(SelectionKind, OfferId, MimeType), Refusal> {
        let Some(current) = self.offer(made_from.kind) else {
            return Err(Refusal::NoSelection);
        };
        if current.offer != made_from.offer {
            return Err(Refusal::Stale);
        }
        if !current.carries(mime) {
            return Err(Refusal::Unrepresentable);
        }
        let mime = MimeType::new(mime).ok_or(Refusal::Unrepresentable)?;
        Ok((made_from.kind, current.offer, mime))
    }

    /// The host connection, absent when there is no host desktop.
    pub(crate) fn host(&self) -> Option<&dyn HostSelection> {
        self.host.as_deref()
    }

    /// Drops the host connection, because it ended.
    pub(crate) fn lose_host(&mut self) {
        self.host = None;
        self.offers = [None, None];
    }
}

/// What moving the bridge from one seat to another asks the caller to do.
///
/// A description rather than an action, so the decision is testable without a
/// host connection and without a seat registry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Rebind {
    /// The seat that is no longer bridged. Its offer to the host is withdrawn,
    /// and the host's offers are taken off it.
    pub(crate) withdrawn: Option<SeatId>,
    /// The seat that is bridged now, which the host's selections are offered to.
    pub(crate) adopted: Option<SeatId>,
}

impl fmt::Debug for SelectionBridge {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SelectionBridge")
            .field("seat", &self.seat)
            .field("host", &self.host.is_some())
            .field("offers", &self.offers)
            .finish()
    }
}
