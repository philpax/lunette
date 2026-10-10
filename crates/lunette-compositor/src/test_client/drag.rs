//! Linux-only: drag-and-drop requests and the events a test reads back.
//!
//! A drag starts from a button press: [`TestClient::start_drag`] quotes the
//! serial of the latest press its pointer received, which is the implicit grab
//! smithay requires. The receiving side reads the offer it was entered with
//! from the same data device that carries its clipboard.

use std::os::fd::{AsFd, OwnedFd};

use wayland_client::{
    Proxy,
    backend::ObjectId,
    protocol::{
        wl_compositor::WlCompositor,
        wl_data_device_manager::{DndAction, WlDataDeviceManager},
        wl_data_offer::WlDataOffer,
        wl_data_source::WlDataSource,
        wl_pointer::WlPointer,
        wl_surface::WlSurface,
    },
};

use crate::{
    protocol::PixelSize,
    test_client::{Driver, PointerEvent, SelectionDevices, TestClient, pipe, protocol_size},
    testing::TestCompositor,
};

/// What a data device received during a drag.
#[derive(Clone, Debug, PartialEq)]
pub enum DragEvent {
    /// The drag entered `surface`, offering the listed MIME types, or none
    /// when the drag carries no data source.
    Enter {
        surface: ObjectId,
        x: f64,
        y: f64,
        offer: Option<ObjectId>,
    },
    Motion {
        x: f64,
        y: f64,
    },
    Leave,
    Drop,
}

/// What a data source received during a drag.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceEvent {
    Cancelled,
    DropPerformed,
    Finished,
}

/// The objects a drag keeps alive while it lasts.
#[derive(Debug)]
pub struct DragSource {
    pub source: WlDataSource,
    pub icon: Option<WlSurface>,
}

impl TestClient {
    /// Starts a drag from this client's toplevel with a source offering
    /// `mimes` for copying, and an icon of `icon` pixels when one is given.
    ///
    /// The drag quotes the serial of the latest press `pointer` received, so
    /// the compositor must have delivered a press to this client first.
    ///
    /// # Panics
    ///
    /// Panics if `pointer` has received no press, or no toplevel is open.
    pub fn start_drag(
        &mut self,
        compositor: &mut TestCompositor,
        devices: &SelectionDevices,
        pointer: &WlPointer,
        mimes: &[&str],
        icon: Option<PixelSize>,
    ) -> DragSource {
        let handle = self.queue.handle();
        let serial = self
            .driver
            .events(pointer)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                PointerEvent::Button {
                    pressed: true,
                    serial,
                    ..
                } => Some(serial),
                _ => None,
            })
            .expect("the pointer received a press to drag from");
        let origin = self.surface.clone().expect("a toplevel was opened first");

        let manager: WlDataDeviceManager = self.bind_global(WlDataDeviceManager::interface().name);
        let source = manager.create_data_source(&handle, ());
        for mime in mimes {
            source.offer((*mime).to_owned());
        }
        source.set_actions(DndAction::Copy);

        let icon = icon.map(|size| {
            let surface = self.bind::<WlCompositor>(6).create_surface(&handle, ());
            (surface, size)
        });
        devices.clipboard.start_drag(
            Some(&source),
            &origin,
            icon.as_ref().map(|(surface, _)| surface),
            serial,
        );
        // The icon role is given by `start_drag`, so its content follows it.
        let icon = icon.map(|(surface, size)| {
            let buffer = self.shm_buffer(size);
            let (width, height) = protocol_size(size);
            self.attach_to(compositor, &surface, &buffer, width, height);
            self.buffers.push(buffer);
            surface
        });
        self.settle_quiet(compositor);
        DragSource { source, icon }
    }

    /// Moves a drag icon relative to the pointer with `wl_surface.offset` and
    /// commits the move.
    pub fn offset_icon(
        &mut self,
        compositor: &mut TestCompositor,
        icon: &WlSurface,
        x: i32,
        y: i32,
    ) {
        icon.offset(x, y);
        icon.commit();
        self.settle_quiet(compositor);
    }

    /// Accepts `mime` from the current drag offer and chooses to copy it, which
    /// lets a drop over this client complete.
    ///
    /// # Panics
    ///
    /// Panics if no drag has entered these devices.
    pub fn accept_drag(
        &mut self,
        compositor: &mut TestCompositor,
        devices: &SelectionDevices,
        mime: &str,
    ) {
        let (serial, offer) = self
            .driver
            .drag_offer(devices)
            .expect("a drag with data entered this client");
        offer.accept(serial, Some(mime.to_owned()));
        offer.set_actions(DndAction::Copy, DndAction::Copy);
        self.settle_quiet(compositor);
    }

    /// Requests `mime` from the dropped offer and returns the read end, which
    /// the dragging client writes.
    ///
    /// # Panics
    ///
    /// Panics if no drag has entered these devices.
    pub fn receive_drop(
        &mut self,
        compositor: &mut TestCompositor,
        devices: &SelectionDevices,
        mime: &str,
    ) -> OwnedFd {
        let (_, offer) = self
            .driver
            .drag_offer(devices)
            .expect("a drag with data entered this client");
        let (reader, writer) = pipe();
        offer.receive(mime.to_owned(), writer.as_fd());
        drop(writer);
        self.settle_quiet(compositor);
        reader
    }

    /// Tells the dragging client that the drop is complete.
    ///
    /// # Panics
    ///
    /// Panics if no drag has entered these devices.
    pub fn finish_drop(&mut self, compositor: &mut TestCompositor, devices: &SelectionDevices) {
        let (_, offer) = self
            .driver
            .drag_offer(devices)
            .expect("a drag with data entered this client");
        offer.finish();
        self.settle_quiet(compositor);
    }
}

impl Driver {
    /// Returns the drag events these devices received, in arrival order.
    #[must_use]
    pub fn drag_events(&self, devices: &SelectionDevices) -> Vec<DragEvent> {
        let device = devices.clipboard.id();
        self.drags
            .iter()
            .filter(|(id, _)| *id == device)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// Returns the MIME types the latest drag offer on these devices carried.
    #[must_use]
    pub fn drag_mimes(&self, devices: &SelectionDevices) -> Vec<String> {
        let Some((_, offer)) = self.drag_offer(devices) else {
            return Vec::new();
        };
        let offer = offer.id();
        self.offers
            .iter()
            .find(|(id, _)| *id == offer)
            .map(|(_, mimes)| mimes.clone())
            .unwrap_or_default()
    }

    /// Returns the drag events `source` received, in arrival order.
    #[must_use]
    pub fn source_events(&self, source: &WlDataSource) -> Vec<SourceEvent> {
        let source = source.id();
        self.source_events
            .iter()
            .filter(|(id, _)| *id == source)
            .map(|(_, event)| *event)
            .collect()
    }

    /// The serial and offer of the latest drag that entered these devices.
    fn drag_offer(&self, devices: &SelectionDevices) -> Option<(u32, WlDataOffer)> {
        let device = devices.clipboard.id();
        self.drag_offers
            .iter()
            .rev()
            .find(|(id, _, _)| *id == device)
            .map(|(_, serial, offer)| (*serial, offer.clone()))
    }
}
