//! Clipboard and primary-selection bridging across the host boundary.
//!
//! lunette advertises `wl_data_device`, `zwp_primary_selection_v1`,
//! `zwlr_data_control_v1`, and `ext_data_control_v1` to its clients. It uses the
//! data-control protocols as a client of the host compositor, so selections cross
//! the boundary in both directions.
//!
//! Selections belong to individual seats in lunette. The host exposes one
//! clipboard and one primary selection, so [`SelectionBridge`] maps one
//! designated seat to both host selections; other seats keep their selections
//! local. See `docs/dev/input.md` for the selection contract.
//!
//! # Descriptor passing
//!
//! lunette forwards selection descriptors without buffering or reading from or
//! writing to a selection pipe.
//!
//! A lunette client requests a host offer through `wl_data_offer.receive` or
//! `zwp_primary_selection_offer.receive`. Smithay invokes
//! [`SelectionHandler::send_selection`], and lunette forwards the descriptor to
//! the selected host data-control offer (`ext_data_control_offer_v1` or
//! `zwlr_data_control_offer_v1`), where the host's selection owner writes.
//! When the host requests a selection lunette owns, the data-control source
//! that lunette published supplies the descriptor. The host worker emits
//! [`HostEvent::Send`], and the compositor forwards the descriptor to the
//! bridge seat's client through `request_data_device_client_selection` or
//! `request_primary_client_selection`. The client that owns the selection
//! writes it.
//!
//! The compositor and host worker do not wait on selection pipes. Their bounded
//! command and event queues use nonblocking sends, so a slow reader stalls the
//! process that owns the bytes.
//!
//! [`HostRead`] owns a host-request descriptor until [`HostSelection::read`]
//! accepts it. A rejected request returns the complete value in [`Rejected`], so
//! the caller remains its owner and closes it by dropping the request.
//!
//! # MIME types
//!
//! lunette re-offers each source's MIME list unchanged in both directions. MIME
//! requests match byte for byte; a request for an unadvertised type is refused
//! with [`Refusal::Unrepresentable`]. The bridge substitutes no encoding.

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

use lunette_luau::closed_set;
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

closed_set! {
    /// Identifies a seat's clipboard or primary selection.
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    pub enum SelectionKind {
        /// What an explicit copy puts on the clipboard.
        Clipboard = "clipboard",
        /// What selecting text puts on the middle-click selection.
        Primary = "primary",
    }
}

impl SelectionKind {
    pub(crate) const fn from_target(target: SelectionTarget) -> Self {
        match target {
            SelectionTarget::Clipboard => Self::Clipboard,
            SelectionTarget::Primary => Self::Primary,
        }
    }

    pub(crate) const fn index(self) -> usize {
        match self {
            Self::Clipboard => 0,
            Self::Primary => 1,
        }
    }
}

/// A MIME type advertised by a selection source.
///
/// The selection protocols require MIME types to compare byte for byte.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MimeType(String);

impl MimeType {
    /// Rejects an empty MIME type or one with surrounding whitespace.
    ///
    /// Later requests compare the stored value byte for byte with the advertised
    /// value.
    #[must_use]
    pub fn new(name: impl Into<String>) -> Option<Self> {
        let name = name.into();
        (!name.is_empty() && name.trim().len() == name.len()).then_some(Self(name))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

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

/// Identifies the host offer used for a transfer.
///
/// The bridge compares this identifier with the current offer before sending a
/// descriptor, so a client-held offer cannot read a replacement selection.
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

/// Mints [`OfferId`] values from a monotonic counter.
#[derive(Debug)]
pub struct OfferCounter(AtomicU64);

impl OfferCounter {
    #[must_use]
    pub const fn new() -> Self {
        Self(AtomicU64::new(1))
    }

    /// Returns the next identifier, saturating at the maximum value.
    ///
    /// Wrapping would allow an old offer to compare equal to a later offer.
    pub fn next(&self) -> OfferId {
        let raw = self.0.fetch_add(1, Ordering::Relaxed);
        match NonZeroU64::new(raw) {
            Some(raw) => OfferId(raw),
            None => {
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

/// A host offer re-advertised to lunette clients.
///
/// Smithay stores this value as selection user data. A later receive request
/// supplies the same value, allowing the bridge to reject a replaced offer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostOffer {
    pub kind: SelectionKind,
    pub offer: OfferId,
    /// The host-advertised MIME list, preserving its order and spelling.
    pub mimes: Arc<[MimeType]>,
}

impl HostOffer {
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

/// A host-selection read request with its destination descriptor.
///
/// `pipe` remains owned by this request until [`HostSelection::read`] accepts it.
/// A rejected request returns the complete value in [`Rejected`], so the caller
/// closes the descriptor by dropping the request.
#[derive(Debug)]
pub struct HostRead {
    pub kind: SelectionKind,
    pub offer: OfferId,
    pub mime: MimeType,
    pub pipe: OwnedFd,
}

/// Why a host-selection read is refused.
///
/// The caller drops the client's destination descriptor without sending it to
/// the host for every variant, so the client observes end-of-file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The host has no selection of this kind.
    NoSelection,
    /// The offer does not carry the requested MIME type.
    Unrepresentable,
    /// The offer advertised to the client has been replaced.
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

/// Maps one lunette seat to the host's clipboard and primary selection.
///
/// The bridge seat is chosen by Lua policy; other seats keep their selections in
/// lunette.
pub(crate) struct SelectionBridge {
    seat: Option<SeatId>,
    host: Option<Box<dyn HostSelection>>,
    /// The latest host offer for each selection kind.
    offers: [Option<HostOffer>; 2],
    /// Whether lunette owns each selection on the host.
    ///
    /// The data-control protocols clear a selection without checking its owner,
    /// so the bridge withdraws a selection it published and no other.
    published: [bool; 2],
}

impl SelectionBridge {
    pub(crate) fn new(seat: Option<SeatId>, host: Option<Box<dyn HostSelection>>) -> Self {
        Self {
            seat,
            host,
            offers: [None, None],
            published: [false, false],
        }
    }

    pub(crate) const fn seat(&self) -> Option<SeatId> {
        self.seat
    }

    pub(crate) fn bridges(&self, seat: SeatId) -> bool {
        self.seat == Some(seat)
    }

    /// Changes the bridged seat and reports the old and new seats.
    ///
    /// The caller processes the withdrawn seat before the adopted seat: it removes
    /// compositor-owned offers from the old seat, then advertises or clears host
    /// offers on the new seat. Returns `None` when no seat changes.
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

    pub(crate) fn remember(&mut self, offer: HostOffer) {
        let index = offer.kind.index();
        self.offers[index] = Some(offer);
    }

    pub(crate) fn forget(&mut self, kind: SelectionKind) {
        self.offers[kind.index()] = None;
    }

    pub(crate) fn offer(&self, kind: SelectionKind) -> Option<&HostOffer> {
        self.offers[kind.index()].as_ref()
    }

    /// Validates a client request against the current host offer.
    ///
    /// This pure operation rejects a cleared, replaced, or MIME-incompatible
    /// offer before any descriptor is sent to the host. `made_from` identifies
    /// the offer advertised to the client.
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

    pub(crate) fn host(&self) -> Option<&dyn HostSelection> {
        self.host.as_deref()
    }

    /// Publishes a lunette-owned selection and records its ownership.
    pub(crate) fn publish_to_host(&mut self, kind: SelectionKind, mimes: &[MimeType]) {
        let Some(host) = self.host.as_deref() else {
            return;
        };
        host.publish(kind, mimes);
        self.published[kind.index()] = true;
    }

    /// Withdraws a selection that lunette published.
    ///
    /// Clearing an unowned host selection would destroy another application's
    /// clipboard contents.
    pub(crate) fn withdraw_from_host(&mut self, kind: SelectionKind) {
        if !self.published[kind.index()] {
            return;
        }
        self.published[kind.index()] = false;
        if let Some(host) = self.host.as_deref() {
            host.withdraw(kind);
        }
    }

    pub(crate) const fn host_took_back(&mut self, kind: SelectionKind) {
        self.published[kind.index()] = false;
    }

    /// Clears host state after the host connection ends.
    pub(crate) fn lose_host(&mut self) {
        self.host = None;
        self.offers = [None, None];
        self.published = [false, false];
    }
}

/// Describes a bridge transition in processing order.
///
/// The caller withdraws compositor-owned offers from `withdrawn` before it
/// advertises or clears host offers on `adopted`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Rebind {
    pub(crate) withdrawn: Option<SeatId>,
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
