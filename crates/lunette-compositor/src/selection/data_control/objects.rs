//! The two protocols behind one set of objects.
//!
//! `ext_data_control_v1` and `zwlr_data_control_v1` describe the same four
//! objects — a manager, a device, an offer, and a source — with different names
//! and, in one place, different semantics: a wlroots device sends the primary
//! selection only from version 2. Everything above this file works in terms of
//! [`Manager`], [`Device`], [`Offer`], and [`Source`], each an enum over the
//! variant the host turned out to speak, so the choice is made once at bind and
//! never again.
//!
//! Every `Dispatch` implementation is here too, for the same reason: each comes
//! in a pair that differs only in the type it is written against.

use std::os::fd::BorrowedFd;

use wayland_client::{
    Connection, Dispatch, Proxy, QueueHandle,
    backend::ObjectId,
    delegate_noop, event_created_child,
    globals::{GlobalList, GlobalListContents},
    protocol::{wl_callback::WlCallback, wl_registry::WlRegistry, wl_seat::WlSeat},
};
use wayland_protocols::ext::data_control::v1::client::{
    ext_data_control_device_v1::{self, ExtDataControlDeviceV1},
    ext_data_control_manager_v1::ExtDataControlManagerV1,
    ext_data_control_offer_v1::{self, ExtDataControlOfferV1},
    ext_data_control_source_v1::{self, ExtDataControlSourceV1},
};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1::{self, ZwlrDataControlDeviceV1},
    zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
    zwlr_data_control_offer_v1::{self, ZwlrDataControlOfferV1},
    zwlr_data_control_source_v1::{self, ZwlrDataControlSourceV1},
};

use crate::selection::{
    SelectionKind,
    data_control::{Handshake, Host},
    host::HostStartError,
};

/// The data-control manager, whichever protocol the host implements.
pub(super) enum Manager {
    Ext(ExtDataControlManagerV1),
    Wlr(ZwlrDataControlManagerV1),
}

impl Manager {
    /// Binds the manager, preferring the standardised protocol.
    pub(super) fn bind(
        globals: &GlobalList,
        handle: &QueueHandle<Host>,
    ) -> Result<Self, HostStartError> {
        if let Ok(manager) = globals.bind::<ExtDataControlManagerV1, _, _>(handle, 1..=1, ()) {
            return Ok(Self::Ext(manager));
        }
        if let Ok(manager) = globals.bind::<ZwlrDataControlManagerV1, _, _>(handle, 1..=2, ()) {
            return Ok(Self::Wlr(manager));
        }
        Err(HostStartError::NoDataControl)
    }

    pub(super) const fn name(&self) -> &'static str {
        match self {
            Self::Ext(_) => "ext-data-control-v1",
            Self::Wlr(_) => "wlr-data-control-v1",
        }
    }

    pub(super) fn device(&self, seat: &WlSeat, handle: &QueueHandle<Host>) -> Device {
        match self {
            Self::Ext(manager) => Device::Ext(manager.get_data_device(seat, handle, ())),
            Self::Wlr(manager) => Device::Wlr(manager.get_data_device(seat, handle, ())),
        }
    }

    pub(super) fn source(&self, handle: &QueueHandle<Host>) -> Source {
        match self {
            Self::Ext(manager) => Source::Ext(manager.create_data_source(handle, ())),
            Self::Wlr(manager) => Source::Wlr(manager.create_data_source(handle, ())),
        }
    }
}

/// The device selections arrive on, whichever protocol the host implements.
pub(super) enum Device {
    Ext(ExtDataControlDeviceV1),
    Wlr(ZwlrDataControlDeviceV1),
}

impl Device {
    /// Sets or clears one of the two selections.
    pub(super) fn set(&self, kind: SelectionKind, source: Option<&Source>) {
        match (self, kind) {
            (Self::Ext(device), SelectionKind::Clipboard) => {
                device.set_selection(source.map(Source::ext));
            }
            (Self::Ext(device), SelectionKind::Primary) => {
                device.set_primary_selection(source.map(Source::ext));
            }
            (Self::Wlr(device), SelectionKind::Clipboard) => {
                device.set_selection(source.map(Source::wlr));
            }
            (Self::Wlr(device), SelectionKind::Primary) => {
                device.set_primary_selection(source.map(Source::wlr));
            }
        }
    }
}

/// A selection the host is offering.
pub(super) enum Offer {
    Ext(ExtDataControlOfferV1),
    Wlr(ZwlrDataControlOfferV1),
}

impl Offer {
    /// Identifies the offer object, for keying the MIME types accumulated
    /// against it.
    pub(super) fn key(&self) -> ObjectId {
        match self {
            Self::Ext(offer) => offer.id(),
            Self::Wlr(offer) => offer.id(),
        }
    }

    pub(super) fn receive(&self, mime: String, pipe: BorrowedFd<'_>) {
        match self {
            Self::Ext(offer) => offer.receive(mime, pipe),
            Self::Wlr(offer) => offer.receive(mime, pipe),
        }
    }

    pub(super) fn destroy(self) {
        match self {
            Self::Ext(offer) => offer.destroy(),
            Self::Wlr(offer) => offer.destroy(),
        }
    }
}

/// A selection lunette is offering to the host.
pub(super) enum Source {
    Ext(ExtDataControlSourceV1),
    Wlr(ZwlrDataControlSourceV1),
}

impl Source {
    pub(super) fn key(&self) -> ObjectId {
        match self {
            Self::Ext(source) => source.id(),
            Self::Wlr(source) => source.id(),
        }
    }

    pub(super) fn offer(&self, mime: String) {
        match self {
            Self::Ext(source) => source.offer(mime),
            Self::Wlr(source) => source.offer(mime),
        }
    }

    pub(super) fn destroy(self) {
        match self {
            Self::Ext(source) => source.destroy(),
            Self::Wlr(source) => source.destroy(),
        }
    }

    /// # Panics
    ///
    /// If asked for the other protocol's object. Unreachable: a source is
    /// created by the manager the device came from, so the two always match.
    pub(super) fn ext(&self) -> &ExtDataControlSourceV1 {
        match self {
            Self::Ext(source) => source,
            Self::Wlr(_) => unreachable!("a wlr source cannot be set on an ext device"),
        }
    }

    /// # Panics
    ///
    /// If asked for the other protocol's object, for the reason [`Self::ext`]
    /// records.
    pub(super) fn wlr(&self) -> &ZwlrDataControlSourceV1 {
        match self {
            Self::Wlr(source) => source,
            Self::Ext(_) => unreachable!("an ext source cannot be set on a wlr device"),
        }
    }
}

impl Dispatch<WlRegistry, GlobalListContents> for Host {
    fn event(
        _state: &mut Self,
        _proxy: &WlRegistry,
        _event: <WlRegistry as Proxy>::Event,
        _data: &GlobalListContents,
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtDataControlDeviceV1, ()> for Host {
    fn event(
        state: &mut Self,
        _proxy: &ExtDataControlDeviceV1,
        event: <ExtDataControlDeviceV1 as Proxy>::Event,
        _data: &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        use ext_data_control_device_v1::Event;
        match event {
            // Announced only; the MIME types arrive on the offer itself.
            Event::DataOffer { .. } => {}
            Event::Selection { id } => {
                state.selected(SelectionKind::Clipboard, id.map(Offer::Ext));
            }
            Event::PrimarySelection { id } => {
                state.selected(SelectionKind::Primary, id.map(Offer::Ext));
            }
            Event::Finished => state.finished(),
            _ => {}
        }
    }

    event_created_child!(Host, ExtDataControlDeviceV1, [
        ext_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ExtDataControlOfferV1, ()),
    ]);
}

impl Dispatch<ZwlrDataControlDeviceV1, ()> for Host {
    fn event(
        state: &mut Self,
        _proxy: &ZwlrDataControlDeviceV1,
        event: <ZwlrDataControlDeviceV1 as Proxy>::Event,
        _data: &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        use zwlr_data_control_device_v1::Event;
        match event {
            Event::DataOffer { .. } => {}
            Event::Selection { id } => {
                state.selected(SelectionKind::Clipboard, id.map(Offer::Wlr));
            }
            Event::PrimarySelection { id } => {
                state.selected(SelectionKind::Primary, id.map(Offer::Wlr));
            }
            Event::Finished => state.finished(),
            _ => {}
        }
    }

    event_created_child!(Host, ZwlrDataControlDeviceV1, [
        zwlr_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ZwlrDataControlOfferV1, ()),
    ]);
}

impl Dispatch<ExtDataControlOfferV1, ()> for Host {
    fn event(
        state: &mut Self,
        proxy: &ExtDataControlOfferV1,
        event: <ExtDataControlOfferV1 as Proxy>::Event,
        _data: &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let ext_data_control_offer_v1::Event::Offer { mime_type } = event {
            state.offered(&Offer::Ext(proxy.clone()), mime_type);
        }
    }
}

impl Dispatch<ZwlrDataControlOfferV1, ()> for Host {
    fn event(
        state: &mut Self,
        proxy: &ZwlrDataControlOfferV1,
        event: <ZwlrDataControlOfferV1 as Proxy>::Event,
        _data: &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let zwlr_data_control_offer_v1::Event::Offer { mime_type } = event {
            state.offered(&Offer::Wlr(proxy.clone()), mime_type);
        }
    }
}

impl Dispatch<ExtDataControlSourceV1, ()> for Host {
    fn event(
        state: &mut Self,
        proxy: &ExtDataControlSourceV1,
        event: <ExtDataControlSourceV1 as Proxy>::Event,
        _data: &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let source = Source::Ext(proxy.clone());
        match event {
            ext_data_control_source_v1::Event::Send { mime_type, fd } => {
                state.send(&source, mime_type, fd);
            }
            ext_data_control_source_v1::Event::Cancelled => state.cancelled(&source),
            _ => {}
        }
    }
}

impl Dispatch<ZwlrDataControlSourceV1, ()> for Host {
    fn event(
        state: &mut Self,
        proxy: &ZwlrDataControlSourceV1,
        event: <ZwlrDataControlSourceV1 as Proxy>::Event,
        _data: &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let source = Source::Wlr(proxy.clone());
        match event {
            zwlr_data_control_source_v1::Event::Send { mime_type, fd } => {
                state.send(&source, mime_type, fd);
            }
            zwlr_data_control_source_v1::Event::Cancelled => state.cancelled(&source),
            _ => {}
        }
    }
}

delegate_noop!(Handshake: ignore WlCallback);
delegate_noop!(Host: ignore WlSeat);
delegate_noop!(Host: ignore ExtDataControlManagerV1);
delegate_noop!(Host: ignore ZwlrDataControlManagerV1);
