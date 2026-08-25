//! Bridges clipboard and primary-selection offers between the host and one seat.
//!
//! Client-owned selections reach the host only from the bridge seat. Host-owned
//! selections are advertised on that seat as compositor-owned offers, carrying
//! the host offer identity so later reads use the offer that was advertised.

use std::os::fd::OwnedFd;

use smithay::{
    input::Seat,
    reexports::wayland_server::{Resource, protocol::wl_surface::WlSurface},
    wayland::selection::{
        SelectionSource,
        data_device::{
            clear_data_device_selection, current_data_device_selection_userdata,
            request_data_device_client_selection, set_data_device_focus, set_data_device_selection,
        },
        primary_selection::{
            clear_primary_selection, current_primary_selection_userdata,
            request_primary_client_selection, set_primary_focus, set_primary_selection,
        },
    },
};
use tracing::{debug, info, warn};

use crate::{
    protocol::SeatId,
    selection::{HostEvent, HostOffer, HostRead, MimeType, SelectionKind},
    state::compositor::CompositorState,
};

impl CompositorState {
    /// Selection offers follow keyboard focus for both selection protocols.
    ///
    /// Wayland sends an offer only to the client focused on the seat.
    pub(super) fn focus_selection(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let client = focused.and_then(|surface| surface.client());
        set_data_device_focus(&self.display, seat, client.clone());
        set_primary_focus(&self.display, seat, client);
    }

    /// Publishes or withdraws a client-owned selection only when it belongs to the bridge seat.
    /// Other seats retain independent selections for their focused clients.
    pub(super) fn client_selection(
        &mut self,
        kind: SelectionKind,
        source: Option<&SelectionSource>,
        seat: &Seat<Self>,
    ) {
        let Some(id) = self.seats.id_of(seat) else {
            debug!("a selection was set on a seat lunette does not track");
            return;
        };
        if !self.selection.bridges(id) {
            debug!(seat = %id, %kind, "a selection was set on a seat that is not bridged");
            return;
        }

        let mimes: Vec<MimeType> = source
            .map(SelectionSource::mime_types)
            .unwrap_or_default()
            .into_iter()
            .filter_map(MimeType::new)
            .collect();

        // A source without MIME types cannot answer a request, so withdraw only
        // lunette's host offer instead of publishing an empty selection.
        if mimes.is_empty() {
            self.selection.withdraw_from_host(kind);
            return;
        }
        self.selection.publish_to_host(kind, &mimes);
    }

    /// Forwards a client request for a host-owned selection to the host.
    ///
    /// The pipe belongs to the client. The host writes the requested bytes into
    /// it, or the compositor closes it when the request is refused.
    pub(super) fn serve_selection(&mut self, mime: &str, pipe: OwnedFd, offer: &HostOffer) {
        let resolved = self.selection.resolve(offer, mime);
        let Some(host) = self.selection.host() else {
            debug!(mime, "there is no host desktop to read a selection from");
            return;
        };

        match resolved {
            Ok((kind, offer, mime)) => {
                if let Err(rejected) = host.read(HostRead {
                    kind,
                    offer,
                    mime,
                    pipe,
                }) {
                    warn!(%rejected, "a paste from the host was not delivered");
                }
            }
            Err(refusal) => {
                debug!(mime, %refusal, "refusing a read of the host's selection");
                drop(pipe);
            }
        }
    }

    /// Changes the seat whose selections are bridged to the host.
    ///
    /// The new bridge state is reported with the next state snapshot. An existing
    /// client-owned selection on the new seat is not re-advertised because
    /// Smithay does not expose its MIME list; a later selection change is
    /// forwarded.
    pub(super) fn set_clipboard_bridge(&mut self, seat: Option<SeatId>) {
        if let Some(wanted) = seat
            && self.seats.get(wanted).is_none()
        {
            warn!(seat = %wanted, "the clipboard bridge was asked for a seat that does not exist");
            return;
        }

        let Some(rebind) = self.selection.rebind(seat) else {
            return;
        };

        if let Some(previous) = rebind.withdrawn {
            self.unbridge(previous);
        }
        for &kind in SelectionKind::ALL {
            match self.selection.offer(kind).cloned() {
                Some(offer) => self.offer_to_bridge(&offer),
                None => self.clear_on_bridge(kind),
            }
        }

        match rebind.adopted {
            Some(seat) => info!(%seat, "the host clipboard is bridged to this seat now"),
            None => info!("no seat is bridged to the host clipboard now"),
        }
        self.touch();
    }

    /// Removes compositor-owned offers in both directions when a bridge moves.
    /// Client-owned selections remain on their seat.
    fn unbridge(&mut self, seat: SeatId) {
        for &kind in SelectionKind::ALL {
            self.selection.withdraw_from_host(kind);
            self.clear_lunettes_selection(seat, kind);
        }
    }

    /// Clears a selection only when its user data identifies it as compositor-owned.
    fn clear_lunettes_selection(&mut self, seat: SeatId, kind: SelectionKind) {
        let Some(entry) = self.seats.get(seat) else {
            return;
        };
        let handle = entry.seat().clone();

        // Drop the read borrow before the clear mutably borrows the same `RefCell`.
        let ours = match kind {
            SelectionKind::Clipboard => current_data_device_selection_userdata(&handle).is_some(),
            SelectionKind::Primary => current_primary_selection_userdata(&handle).is_some(),
        };
        if !ours {
            debug!(%seat, %kind, "leaving a selection a lunette client owns where it is");
            return;
        }

        match kind {
            SelectionKind::Clipboard => clear_data_device_selection(&self.display, &handle),
            SelectionKind::Primary => clear_primary_selection(&self.display, &handle),
        }
    }

    pub(crate) fn host_selection(&mut self, event: HostEvent) {
        match event {
            HostEvent::Offered { kind, offer, mimes } => {
                let offer = HostOffer {
                    kind,
                    offer,
                    mimes: mimes.into(),
                };
                self.selection.remember(offer.clone());
                self.offer_to_bridge(&offer);
            }
            HostEvent::Cleared { kind } => {
                self.selection.forget(kind);
                self.clear_on_bridge(kind);
            }
            HostEvent::Send { kind, mime, pipe } => self.host_wants_bytes(kind, &mime, pipe),
            HostEvent::Cancelled { kind } => {
                debug!(%kind, "the host took the selection back from lunette");
                self.selection.host_took_back(kind);
            }
            HostEvent::Lost { reason } => {
                warn!(
                    reason,
                    "the host clipboard connection ended; nothing bridges now"
                );
                self.selection.lose_host();
                for &kind in SelectionKind::ALL {
                    self.clear_on_bridge(kind);
                }
            }
        }
    }

    /// Advertises the host offer's unchanged MIME list on the bridge seat.
    /// The stored identity binds later reads to this offer, even after the host
    /// announces a replacement offer.
    fn offer_to_bridge(&mut self, offer: &HostOffer) {
        let Some(seat) = self.bridge_seat() else {
            return;
        };
        let mimes = offer.mime_strings();
        match offer.kind {
            SelectionKind::Clipboard => {
                set_data_device_selection(&self.display, &seat, mimes, offer.clone());
            }
            SelectionKind::Primary => {
                set_primary_selection(&self.display, &seat, mimes, offer.clone());
            }
        }
    }

    fn clear_on_bridge(&mut self, kind: SelectionKind) {
        let Some(seat) = self.selection.seat() else {
            return;
        };
        self.clear_lunettes_selection(seat, kind);
    }

    /// Forwards a host request for a client-owned selection to the bridge seat.
    /// The client-side selection source rejects MIME types that it does not offer.
    fn host_wants_bytes(&mut self, kind: SelectionKind, mime: &MimeType, pipe: OwnedFd) {
        let Some(seat) = self.bridge_seat() else {
            debug!(%kind, "the host asked for a selection no seat is bridged to");
            return;
        };

        let refused = match kind {
            SelectionKind::Clipboard => {
                request_data_device_client_selection(&seat, mime.as_str().to_owned(), pipe)
                    .err()
                    .map(|error| error.to_string())
            }
            SelectionKind::Primary => {
                request_primary_client_selection(&seat, mime.as_str().to_owned(), pipe)
                    .err()
                    .map(|error| error.to_string())
            }
        };
        if let Some(error) = refused {
            debug!(%kind, %mime, error, "a paste on the host could not be answered");
        }
    }

    fn bridge_seat(&self) -> Option<Seat<Self>> {
        let id = self.selection.seat()?;
        match self.seats.get(id) {
            Some(entry) => Some(entry.seat().clone()),
            None => {
                debug!(seat = %id, "the bridged seat no longer exists");
                None
            }
        }
    }

    pub(super) fn report_bridge(&self) {
        match (self.selection.seat(), self.selection.host().is_some()) {
            (Some(seat), true) => info!(%seat, "the host clipboard is bridged to this seat"),
            (_, false) => info!("no host clipboard is bridged; selections stay inside lunette"),
            (None, true) => info!("no seat is bridged to the host clipboard yet"),
        }
    }
}
