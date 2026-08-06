//! What the clipboard and the primary selection do, in both directions.
//!
//! Split from [`crate::state::compositor`] for the reason [`crate::state::input`]
//! is: that file owns the globals and the state they are served from, and this
//! one owns what happens when a selection changes. The vocabulary — MIME types,
//! offer identifiers, the bridge seat — lives in [`crate::selection`], which has
//! no smithay state in it and can be reasoned about on its own.
//!
//! Three paths meet here.
//!
//! - A lunette client sets a selection, and if it did so on the bridge seat the
//!   offer is published to the host.
//! - The host sets a selection, and it is offered to the bridge seat as a
//!   compositor-owned selection whose user data names the offer it came from.
//! - Either side asks the other for the bytes, and a descriptor is passed
//!   through. Nothing here reads or writes one.

use std::os::fd::OwnedFd;

use smithay::{
    input::Seat,
    reexports::wayland_server::{Resource, protocol::wl_surface::WlSurface},
    wayland::selection::{
        SelectionSource,
        data_device::{
            clear_data_device_selection, request_data_device_client_selection,
            set_data_device_focus, set_data_device_selection,
        },
        primary_selection::{
            clear_primary_selection, request_primary_client_selection, set_primary_focus,
            set_primary_selection,
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
    /// Gives a seat's data devices the client that now holds its keyboard.
    ///
    /// Both selections, because a client that is focused for one and not the
    /// other would see half a clipboard. Without this no client is ever offered
    /// a selection at all: `wl_data_device` delivers an offer only to the
    /// focused client, which is the protocol's own rule.
    pub(super) fn focus_selection(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let client = focused.and_then(|surface| surface.client());
        set_data_device_focus(&self.display, seat, client.clone());
        set_primary_focus(&self.display, seat, client);
    }

    /// A client set, or cleared, one of its seat's selections.
    ///
    /// Only the bridge seat reaches the host. Another seat's selection is stored
    /// by smithay against that seat and is offered to the clients focused on it,
    /// which is what makes two hands able to hold two different clipboards.
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
        let Some(host) = self.selection.host() else {
            return;
        };

        let mimes: Vec<MimeType> = source
            .map(SelectionSource::mime_types)
            .unwrap_or_default()
            .into_iter()
            .filter_map(MimeType::new)
            .collect();

        // A source that advertises nothing can answer no request, so publishing
        // it would put a selection on the host that every paste comes back empty
        // from. Withdrawing says the same thing honestly.
        if mimes.is_empty() {
            host.withdraw(kind);
            return;
        }
        host.publish(kind, &mimes);
    }

    /// A client asked to read the selection lunette took from the host.
    ///
    /// The descriptor is the client's own pipe. It goes to the host connection
    /// unread, and the host's clipboard owner writes into it directly; a refusal
    /// closes it, which the client sees as an empty paste.
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

    /// Names the seat whose selections are the host desktop's, or takes the
    /// bridge away.
    ///
    /// The change takes effect where every other mutation does: this runs when
    /// the command is applied, and the snapshot that reports it is published at
    /// the end of the same tick.
    ///
    /// A selection the new seat already held is *not* pushed to the host. Only a
    /// compositor-owned selection can be read back, and one a client owns cannot
    /// be re-advertised without asking that client for a MIME list smithay does
    /// not expose. The next copy on the seat crosses; the one from before the
    /// bridge moved does not.
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
        for kind in SelectionKind::ALL {
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

    /// Detaches a seat from the host: its offer comes off the host, and the
    /// host's offers come off it.
    ///
    /// Both halves, because leaving either would be a seat that still speaks for
    /// the host in one direction — a paste on the desktop reaching a hand that
    /// no longer owns the clipboard, or a stale offer sitting on a seat nothing
    /// refreshes.
    fn unbridge(&mut self, seat: SeatId) {
        if let Some(host) = self.selection.host() {
            for kind in SelectionKind::ALL {
                host.withdraw(kind);
            }
        }

        let Some(entry) = self.seats.get(seat) else {
            return;
        };
        let handle = entry.seat().clone();
        clear_data_device_selection(&self.display, &handle);
        clear_primary_selection(&self.display, &handle);
    }

    /// Applies one report from the host desktop's clipboard.
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
            }
            HostEvent::Lost { reason } => {
                warn!(
                    reason,
                    "the host clipboard connection ended; nothing bridges now"
                );
                self.selection.lose_host();
                for kind in SelectionKind::ALL {
                    self.clear_on_bridge(kind);
                }
            }
        }
    }

    /// Offers what the host holds to the bridge seat.
    ///
    /// The MIME list is the host's own, unchanged. The [`HostOffer`] rides along
    /// as smithay's `SelectionUserData`, which is how a later read is matched
    /// against the offer it was made from rather than against whatever the host
    /// holds by then.
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
        let Some(seat) = self.bridge_seat() else {
            return;
        };
        match kind {
            SelectionKind::Clipboard => clear_data_device_selection(&self.display, &seat),
            SelectionKind::Primary => clear_primary_selection(&self.display, &seat),
        }
    }

    /// The host asked for the bytes behind a selection a lunette client owns.
    ///
    /// The descriptor goes straight to that client. `request_*_client_selection`
    /// refuses a MIME type the client's source does not carry, which is the same
    /// rule the other direction follows and for the same reason.
    fn host_wants_bytes(&mut self, kind: SelectionKind, mime: &MimeType, pipe: OwnedFd) {
        let Some(seat) = self.bridge_seat() else {
            debug!(%kind, "the host asked for a selection no seat is bridged to");
            return;
        };

        // The two calls return two different `SelectionRequestError` types, so
        // the message is taken here rather than the error being carried out of
        // the match; what a caller does with either is report it.
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

    /// The bridge seat, as the smithay handle every selection call takes.
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

    /// Reports what the clipboard bridge is doing, once, at startup.
    pub(super) fn report_bridge(&self) {
        match (self.selection.seat(), self.selection.host().is_some()) {
            (Some(seat), true) => info!(%seat, "the host clipboard is bridged to this seat"),
            (_, false) => info!("no host clipboard is bridged; selections stay inside lunette"),
            (None, true) => info!("no seat is bridged to the host clipboard yet"),
        }
    }
}
