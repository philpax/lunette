//! Linux-only: the test seam uses nonblocking Unix socket pairs for selection transfers.
//!
//! Test-client protocol adapters for the clipboard and primary-selection protocols.

use std::{
    fs::File,
    io::{self, Read},
    net::Shutdown,
    os::{
        fd::{AsFd, OwnedFd},
        unix::net::UnixStream,
    },
    time::Instant,
};

use wayland_client::{
    Connection, Dispatch, Proxy, QueueHandle,
    backend::ObjectId,
    protocol::{
        wl_data_device::{self, WlDataDevice},
        wl_data_device_manager::WlDataDeviceManager,
        wl_data_offer::{self, WlDataOffer},
        wl_data_source::{self, WlDataSource},
    },
};
use wayland_protocols::wp::primary_selection::zv1::client::{
    zwp_primary_selection_device_manager_v1::ZwpPrimarySelectionDeviceManagerV1,
    zwp_primary_selection_device_v1::{self, ZwpPrimarySelectionDeviceV1},
    zwp_primary_selection_offer_v1::{self, ZwpPrimarySelectionOfferV1},
    zwp_primary_selection_source_v1::{self, ZwpPrimarySelectionSourceV1},
};

use crate::{
    selection::SelectionKind,
    test_client::{Driver, Global, TestClient},
    testing::{DEADLINE, TestCompositor},
};

#[derive(Clone, Debug)]
pub struct SelectionDevices {
    pub clipboard: WlDataDevice,
    pub primary: ZwpPrimarySelectionDeviceV1,
}

/// Keeps the protocol source alive while the compositor may request the selection's bytes.
#[derive(Clone, Debug)]
pub enum ClientSource {
    Clipboard(WlDataSource),
    Primary(ZwpPrimarySelectionSourceV1),
}

impl TestClient {
    /// Binds the clipboard and primary-selection devices for the seat named `name`.
    /// Host selections are announced only to the designated bridge seat.
    pub fn open_selection(
        &mut self,
        compositor: &mut TestCompositor,
        name: &str,
    ) -> SelectionDevices {
        let handle = self.queue.handle();
        let seats = self.bind_seats(compositor);
        let seat = seats
            .iter()
            .find(|seat| self.driver.seat_name(seat).as_deref() == Some(name))
            .unwrap_or_else(|| {
                panic!(
                    "no seat is named {name}; the client sees {:?}",
                    self.driver.seat_names()
                )
            })
            .clone();

        let clipboard: WlDataDeviceManager =
            self.bind_global(WlDataDeviceManager::interface().name);
        let primary: ZwpPrimarySelectionDeviceManagerV1 =
            self.bind_global(ZwpPrimarySelectionDeviceManagerV1::interface().name);

        let devices = SelectionDevices {
            clipboard: clipboard.get_data_device(&seat, &handle, ()),
            primary: primary.get_device(&seat, &handle, ()),
        };
        self.settle_quiet(compositor);
        devices
    }

    /// Publishes a client-owned selection with the listed MIME types in their supplied order.
    /// The returned source must stay alive while the compositor may request its bytes.
    ///
    /// The client must own keyboard focus before setting the selection. This test client uses
    /// serial zero, which the compositor accepts for a focused client. The compositor forwards
    /// the selection to the host only when these devices belong to the designated bridge seat.
    pub fn copy(
        &mut self,
        compositor: &mut TestCompositor,
        devices: &SelectionDevices,
        kind: SelectionKind,
        mimes: &[&str],
    ) -> ClientSource {
        let handle = self.queue.handle();
        let serial = 0;

        let source = match kind {
            SelectionKind::Clipboard => {
                let manager: WlDataDeviceManager =
                    self.bind_global(WlDataDeviceManager::interface().name);
                let source = manager.create_data_source(&handle, ());
                for mime in mimes {
                    source.offer((*mime).to_owned());
                }
                devices.clipboard.set_selection(Some(&source), serial);
                ClientSource::Clipboard(source)
            }
            SelectionKind::Primary => {
                let manager: ZwpPrimarySelectionDeviceManagerV1 =
                    self.bind_global(ZwpPrimarySelectionDeviceManagerV1::interface().name);
                let source = manager.create_source(&handle, ());
                for mime in mimes {
                    source.offer((*mime).to_owned());
                }
                devices.primary.set_selection(Some(&source), serial);
                ClientSource::Primary(source)
            }
        };

        self.settle_quiet(compositor);
        source
    }

    /// Requests `mime` from the current selection and returns the nonblocking read end.
    ///
    /// The compositor forwards the write end without reading it. The selection owner writes to
    /// it: the host for a bridged host offer, or a client source for an internal selection.
    ///
    /// # Panics
    ///
    /// Panics if the compositor has offered no selection of this kind.
    pub fn paste(
        &mut self,
        compositor: &mut TestCompositor,
        devices: &SelectionDevices,
        kind: SelectionKind,
        mime: &str,
    ) -> OwnedFd {
        let (reader, writer) = pipe();

        match kind {
            SelectionKind::Clipboard => {
                let offer = self
                    .driver
                    .clipboard_offer(devices)
                    .cloned()
                    .expect("the compositor offered a clipboard selection");
                offer.receive(mime.to_owned(), writer.as_fd());
            }
            SelectionKind::Primary => {
                let offer = self
                    .driver
                    .primary_offer(devices)
                    .cloned()
                    .expect("the compositor offered a primary selection");
                offer.receive(mime.to_owned(), writer.as_fd());
            }
        }

        // The receive request transfers this descriptor when the queue is flushed; the test
        // client's copy closes before stepping so EOF depends only on the selection owner's
        // descriptor.
        drop(writer);
        self.settle_quiet(compositor);
        reader
    }

    /// Takes pending requests forwarded to this client for data it owns.
    ///
    /// Each returned MIME type identifies the requested format. The caller owns the descriptor,
    /// writes the source's bytes, and closes it to complete the transfer.
    pub fn take_sends(&mut self) -> Vec<(String, OwnedFd)> {
        std::mem::take(&mut self.driver.sends)
    }

    /// Binds an advertised interface at the lower of the compositor and client-supported versions.
    fn bind_global<I>(&mut self, interface: &str) -> I
    where
        I: Proxy + 'static,
        Driver: Dispatch<I, ()>,
    {
        let handle = self.queue.handle();
        let global: Global = self
            .driver
            .globals
            .iter()
            .find(|global| global.interface == interface)
            .cloned()
            .unwrap_or_else(|| panic!("the compositor advertises {interface}"));
        let registry = self
            .driver
            .registry
            .as_ref()
            .expect("the registry arrived with the globals");

        registry.bind::<I, (), Driver>(
            global.name,
            global.version.min(I::interface().version),
            &handle,
            (),
        )
    }
}

impl Driver {
    /// Returns the current offer's MIME types in the order announced by the compositor.
    /// An empty result means that this device has no current offer or that no MIME announcement
    /// has arrived for it yet.
    #[must_use]
    pub fn offered(&self, devices: &SelectionDevices, kind: SelectionKind) -> Vec<String> {
        let offer = match kind {
            SelectionKind::Clipboard => self.clipboard_offer(devices).map(Proxy::id),
            SelectionKind::Primary => self.primary_offer(devices).map(Proxy::id),
        };
        let Some(offer) = offer else {
            return Vec::new();
        };
        self.offers
            .iter()
            .find(|(id, _)| *id == offer)
            .map(|(_, mimes)| mimes.clone())
            .unwrap_or_default()
    }

    #[must_use]
    pub fn has_selection(&self, devices: &SelectionDevices, kind: SelectionKind) -> bool {
        match kind {
            SelectionKind::Clipboard => self.clipboard_offer(devices).is_some(),
            SelectionKind::Primary => self.primary_offer(devices).is_some(),
        }
    }

    fn clipboard_offer(&self, devices: &SelectionDevices) -> Option<&WlDataOffer> {
        let device = devices.clipboard.id();
        self.clipboard
            .iter()
            .find(|(id, _)| *id == device)
            .and_then(|(_, offer)| offer.as_ref())
    }

    fn primary_offer(&self, devices: &SelectionDevices) -> Option<&ZwpPrimarySelectionOfferV1> {
        let device = devices.primary.id();
        self.primary
            .iter()
            .find(|(id, _)| *id == device)
            .and_then(|(_, offer)| offer.as_ref())
    }

    /// Replaces the current offer for a device, including when the selection is cleared.
    fn selected<T>(slots: &mut Vec<(ObjectId, Option<T>)>, device: ObjectId, offer: Option<T>) {
        match slots.iter_mut().find(|(id, _)| *id == device) {
            Some((_, held)) => *held = offer,
            None => slots.push((device, offer)),
        }
    }

    #[must_use]
    pub fn sends_are_empty(&self) -> bool {
        self.sends.is_empty()
    }

    #[must_use]
    pub fn cancelled(&self) -> bool {
        self.cancelled
    }

    fn record_mime(&mut self, offer: &ObjectId, mime: String) {
        match self.offers.iter_mut().find(|(id, _)| id == offer) {
            Some((_, mimes)) => mimes.push(mime),
            None => self.offers.push((offer.clone(), vec![mime])),
        }
    }
}

/// Reads a nonblocking transfer descriptor to EOF on the test thread.
///
/// The harness deadline turns a missing write or missing close into a test failure, not a
/// blocked test thread.
///
/// # Panics
///
/// Panics if EOF is not reached before the deadline or if the descriptor reports another error.
#[must_use]
pub fn read_to_end(pipe: OwnedFd) -> Vec<u8> {
    let mut file = File::from(pipe);
    let mut bytes = Vec::new();
    let deadline = Instant::now() + DEADLINE;

    loop {
        let mut chunk = [0_u8; 4096];
        match file.read(&mut chunk) {
            Ok(0) => return bytes,
            Ok(read) => bytes.extend_from_slice(&chunk[..read]),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "nothing was written to the pipe");
                std::hint::spin_loop();
            }
            Err(error) => panic!("could not read the transfer pipe: {error}"),
        }
    }
}

/// Creates the test transfer endpoints from a `UnixStream` pair because `std` has no pipe.
/// The reader is nonblocking, the writer cannot receive data, and EOF occurs only after every
/// writer descriptor is closed.
fn pipe() -> (OwnedFd, OwnedFd) {
    let (reader, writer) = UnixStream::pair().expect("a socket pair can always be made");
    reader
        .set_nonblocking(true)
        .expect("a fresh socket accepts the flag");
    writer
        .shutdown(Shutdown::Read)
        .expect("a fresh socket can be half-closed");
    (OwnedFd::from(reader), OwnedFd::from(writer))
}

impl Dispatch<WlDataDevice, ()> for Driver {
    fn event(
        state: &mut Self,
        proxy: &WlDataDevice,
        event: wl_data_device::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            wl_data_device::Event::DataOffer { id } => state.offers.push((id.id(), Vec::new())),
            wl_data_device::Event::Selection { id } => {
                Self::selected(&mut state.clipboard, proxy.id(), id);
            }
            _ => {}
        }
    }

    wayland_client::event_created_child!(Driver, WlDataDevice, [
        wl_data_device::EVT_DATA_OFFER_OPCODE => (WlDataOffer, ()),
    ]);
}

impl Dispatch<WlDataOffer, ()> for Driver {
    fn event(
        state: &mut Self,
        proxy: &WlDataOffer,
        event: wl_data_offer::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wl_data_offer::Event::Offer { mime_type } = event {
            state.record_mime(&proxy.id(), mime_type);
        }
    }
}

impl Dispatch<WlDataSource, ()> for Driver {
    fn event(
        state: &mut Self,
        _proxy: &WlDataSource,
        event: wl_data_source::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            wl_data_source::Event::Send { mime_type, fd } => {
                state.sends.push((mime_type, fd));
            }
            wl_data_source::Event::Cancelled => state.cancelled = true,
            _ => {}
        }
    }
}

impl Dispatch<ZwpPrimarySelectionDeviceV1, ()> for Driver {
    fn event(
        state: &mut Self,
        proxy: &ZwpPrimarySelectionDeviceV1,
        event: zwp_primary_selection_device_v1::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            zwp_primary_selection_device_v1::Event::DataOffer { offer } => {
                state.offers.push((offer.id(), Vec::new()));
            }
            zwp_primary_selection_device_v1::Event::Selection { id } => {
                Self::selected(&mut state.primary, proxy.id(), id);
            }
            _ => {}
        }
    }

    wayland_client::event_created_child!(Driver, ZwpPrimarySelectionDeviceV1, [
        zwp_primary_selection_device_v1::EVT_DATA_OFFER_OPCODE => (ZwpPrimarySelectionOfferV1, ()),
    ]);
}

impl Dispatch<ZwpPrimarySelectionOfferV1, ()> for Driver {
    fn event(
        state: &mut Self,
        proxy: &ZwpPrimarySelectionOfferV1,
        event: zwp_primary_selection_offer_v1::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let zwp_primary_selection_offer_v1::Event::Offer { mime_type } = event {
            state.record_mime(&proxy.id(), mime_type);
        }
    }
}

impl Dispatch<ZwpPrimarySelectionSourceV1, ()> for Driver {
    fn event(
        state: &mut Self,
        _proxy: &ZwpPrimarySelectionSourceV1,
        event: zwp_primary_selection_source_v1::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            zwp_primary_selection_source_v1::Event::Send { mime_type, fd } => {
                state.sends.push((mime_type, fd));
            }
            zwp_primary_selection_source_v1::Event::Cancelled => state.cancelled = true,
            _ => {}
        }
    }
}

wayland_client::delegate_noop!(Driver: ignore WlDataDeviceManager);
wayland_client::delegate_noop!(Driver: ignore ZwpPrimarySelectionDeviceManagerV1);
