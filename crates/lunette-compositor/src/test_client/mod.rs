//! Linux-only: a real Wayland client on the calling thread, connected over an in-process
//! `UnixStream` pair.
//!
//! [`TestClient::settle`] flushes the client, steps the compositor, and dispatches replies until a
//! condition holds or [`DEADLINE`] expires. It polls without sleeping.
//!
//! Tests use `Connection::from_socket`. `connect_to_env` mutates the process environment.
//! [`Driver`] records events received from the compositor. This module retains protocol objects
//! whose lifetimes affect behaviour.
//!
//! Shared-memory buffers use anonymous `memfd` files, so the tests share no filesystem paths.

#![expect(
    clippy::expect_used,
    reason = "test scaffolding: a failed expectation is how a test reports a failure, and this \
              module is gated behind `cfg(test)` or the `test-fakes` feature"
)]

mod driver;
mod selection;

use std::{
    io,
    os::{
        fd::{AsFd, AsRawFd, FromRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    time::Instant,
};

/// Re-exports the buffer transforms a surface can declare.
pub use wayland_client::protocol::wl_output::Transform as OutputTransform;
/// Re-exports the protocol's scroll-source enum without exposing the client crate.
pub use wayland_client::protocol::wl_pointer::AxisSource;
use wayland_client::{
    Connection, Dispatch, EventQueue, Proxy,
    backend::{ObjectId, WaylandError},
    protocol::{
        wl_buffer::WlBuffer,
        wl_compositor::WlCompositor,
        wl_keyboard::WlKeyboard,
        wl_output::WlOutput,
        wl_pointer::WlPointer,
        wl_seat::WlSeat,
        wl_shm::{self, WlShm},
        wl_subcompositor::WlSubcompositor,
        wl_subsurface::WlSubsurface,
        wl_surface::WlSurface,
    },
};
/// Re-exports the decoration modes a toplevel can ask for.
pub use wayland_protocols::xdg::decoration::zv1::client::zxdg_toplevel_decoration_v1::Mode as DecorationMode;
use wayland_protocols::{
    wp::{
        content_type::v1::client::{
            wp_content_type_manager_v1::WpContentTypeManagerV1,
            wp_content_type_v1::{self, WpContentTypeV1},
        },
        fractional_scale::v1::client::{
            wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1,
            wp_fractional_scale_v1::WpFractionalScaleV1,
        },
        linux_dmabuf::zv1::client::{
            zwp_linux_buffer_params_v1::Flags as DmabufFlags, zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1,
        },
        viewporter::client::{wp_viewport::WpViewport, wp_viewporter::WpViewporter},
    },
    xdg::{
        decoration::zv1::client::{
            zxdg_decoration_manager_v1::ZxdgDecorationManagerV1,
            zxdg_toplevel_decoration_v1::ZxdgToplevelDecorationV1,
        },
        shell::client::{
            xdg_popup::XdgPopup,
            xdg_positioner::{self},
            xdg_surface::XdgSurface,
            xdg_toplevel::XdgToplevel,
            xdg_wm_base::XdgWmBase,
        },
    },
};

pub use crate::test_client::{
    driver::{Driver, Global, KeyboardEvent, PointerEvent},
    selection::{ClientSource, SelectionDevices, read_to_end},
};
use crate::{
    protocol::{ContentType, PixelSize},
    testing::{DEADLINE, TestCompositor},
};

fn protocol_content_type(content_type: ContentType) -> wp_content_type_v1::Type {
    match content_type {
        ContentType::None => wp_content_type_v1::Type::None,
        ContentType::Photo => wp_content_type_v1::Type::Photo,
        ContentType::Video => wp_content_type_v1::Type::Video,
        ContentType::Game => wp_content_type_v1::Type::Game,
    }
}

const ARGB8888: u32 = smithay::backend::allocator::Fourcc::Argb8888 as u32;

pub struct TestClient {
    connection: Connection,
    queue: EventQueue<Driver>,
    driver: Driver,
    surface: Option<WlSurface>,
    xdg_surface: Option<XdgSurface>,
    toplevel: Option<XdgToplevel>,
    /// Bound seats keyed by registry name; repeated binds reuse the stored proxy.
    seats: Vec<(u32, WlSeat)>,
    /// Bound outputs keyed by registry name; repeated binds reuse the stored proxy.
    outputs: Vec<(u32, WlOutput)>,
    /// Popups, their `xdg_surface` objects, and their surfaces stay alive for the popup's protocol
    /// lifetime.
    popups: Vec<(XdgPopup, XdgSurface, WlSurface)>,
    /// Subsurfaces stay alive while their surfaces have a subsurface role; destroying one removes
    /// that role.
    subsurfaces: Vec<WlSubsurface>,
    pointer: Option<WlPointer>,
    /// Buffers stay alive until the compositor releases them; a dropped proxy cannot receive the
    /// release.
    buffers: Vec<WlBuffer>,
    /// Fractional-scale objects stay alive while their surfaces use them; destroying one removes
    /// its state.
    fractional_scales: Vec<WpFractionalScaleV1>,
    /// One content-type object is retained per surface; requesting a second one is a protocol
    /// error, and destroying the object resets the surface's content type.
    content_types: Vec<(ObjectId, WpContentTypeV1)>,
    /// The toplevel's decoration object stays alive while the client wants a
    /// mode; destroying it returns the toplevel to the compositor's choice.
    decoration: Option<ZxdgToplevelDecorationV1>,
    /// The toplevel's viewport stays alive while the client crops or scales
    /// it; destroying it removes both.
    viewport: Option<WpViewport>,
}

impl TestClient {
    pub fn connect(compositor: &mut TestCompositor) -> Self {
        let (stream, _client) = compositor.connect();
        let mut client = Self::from_socket(stream);
        client.settle(compositor, |driver| !driver.globals.is_empty());
        client
    }

    /// Wraps a test-owned socket and waits until the registry has arrived.
    pub fn from_stream(stream: UnixStream, compositor: &mut TestCompositor) -> Self {
        let mut client = Self::from_socket(stream);
        client.settle(compositor, |driver| driver.registry.is_some());
        client
    }

    fn from_socket(stream: UnixStream) -> Self {
        let connection =
            Connection::from_socket(stream).expect("the socket pair is a valid connection");
        let queue = connection.new_event_queue();
        let handle = queue.handle();
        drop(connection.display().get_registry(&handle, ()));

        Self {
            connection,
            queue,
            driver: Driver::default(),
            surface: None,
            xdg_surface: None,
            toplevel: None,
            seats: Vec::new(),
            outputs: Vec::new(),
            popups: Vec::new(),
            subsurfaces: Vec::new(),
            pointer: None,
            buffers: Vec::new(),
            fractional_scales: Vec::new(),
            content_types: Vec::new(),
            decoration: None,
            viewport: None,
        }
    }

    /// Returns advertised interface names in sorted order.
    pub fn globals(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .driver
            .globals
            .iter()
            .map(|global| global.interface.clone())
            .collect();
        names.sort();
        names
    }

    #[must_use]
    pub fn driver(&self) -> &Driver {
        &self.driver
    }

    #[must_use]
    pub fn surface_id(&self) -> Option<ObjectId> {
        self.surface.as_ref().map(Proxy::id)
    }

    /// Polls both ends until `ready` holds or `DEADLINE` expires.
    pub fn settle(&mut self, compositor: &mut TestCompositor, ready: impl Fn(&Driver) -> bool) {
        let expiry = Instant::now() + DEADLINE;

        loop {
            self.pump(compositor);
            if ready(&self.driver) {
                return;
            }
            assert!(
                Instant::now() < expiry,
                "the compositor did not reach the expected state within {DEADLINE:?}"
            );
        }
    }

    /// Polls both ends for eight rounds without waiting for a condition.
    /// Callers use it where no condition should be awaited.
    pub fn settle_quiet(&mut self, compositor: &mut TestCompositor) {
        for _ in 0..8 {
            self.pump(compositor);
        }
    }

    fn pump(&mut self, compositor: &mut TestCompositor) {
        // After a protocol error, client requests cannot proceed, but compositor
        // steps still deliver the peer teardown.
        if self.connection.protocol_error().is_some() {
            compositor.step();
            return;
        }

        drop(self.queue.flush());
        compositor.step();

        if let Some(guard) = self.queue.prepare_read() {
            match guard.read() {
                Ok(_) => {}
                // The nonblocking socket reports that no event arrived this round.
                Err(WaylandError::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {}
                // A protocol error is observed through `is_disconnected`; other
                // read failures indicate a broken test connection.
                Err(WaylandError::Protocol(_)) => {}
                Err(error) => panic!("the client could not read from the compositor: {error}"),
            }
        }

        drop(self.queue.dispatch_pending(&mut self.driver));
    }

    /// Commits an unbuffered toplevel, waits for its first configure, and acknowledges it.
    /// Attaching a buffer before that configure is a protocol error.
    pub fn open_toplevel(&mut self, compositor: &mut TestCompositor) {
        let handle = self.queue.handle();
        let wl_compositor = self.bind::<WlCompositor>(6);
        let wm_base = self.bind::<XdgWmBase>(3);

        let surface = wl_compositor.create_surface(&handle, ());
        let xdg_surface = wm_base.get_xdg_surface(&surface, &handle, ());
        let toplevel = xdg_surface.get_toplevel(&handle, ());
        surface.commit();

        self.surface = Some(surface);
        self.xdg_surface = Some(xdg_surface);
        self.toplevel = Some(toplevel);

        let xdg = self
            .xdg_surface
            .clone()
            .unwrap_or_else(|| unreachable!("the xdg_surface was just stored"));
        self.settle(compositor, |driver| driver.configure_serial(&xdg).is_some());
        self.acknowledge_configure(&xdg);
    }

    pub fn attach_dmabuf(&mut self, compositor: &mut TestCompositor, size: PixelSize) -> ObjectId {
        let buffer = self.create_dmabuf(compositor, size);
        let id = buffer.id();
        self.attach_created(compositor, &buffer, size);
        id
    }

    /// Creates a linear `argb8888` dmabuf without attaching it.
    /// Settling before returning makes later commits observe the completed creation.
    pub fn create_dmabuf(&mut self, compositor: &mut TestCompositor, size: PixelSize) -> WlBuffer {
        let handle = self.queue.handle();
        let dmabuf = self.bind::<ZwpLinuxDmabufV1>(3);

        let (width, height) = protocol_size(size);
        let stride = size.width * 4;
        let memory = anonymous_file(i64::from(stride) * i64::from(height));

        let params = dmabuf.create_params(&handle, ());
        params.add(memory.as_fd(), 0, 0, stride, 0, 0);
        let buffer =
            params.create_immed(width, height, ARGB8888, DmabufFlags::empty(), &handle, ());
        params.destroy();

        self.settle_quiet(compositor);
        self.buffers.push(buffer.clone());
        buffer
    }

    pub fn attach_created(
        &mut self,
        compositor: &mut TestCompositor,
        buffer: &WlBuffer,
        size: PixelSize,
    ) {
        let (width, height) = protocol_size(size);
        let surface = self.surface.clone().expect("a toplevel was opened first");
        self.attach_to(compositor, &surface, buffer, width, height);
    }

    /// Attaches a shared-memory buffer of `size` and commits it.
    pub fn attach_buffer(&mut self, compositor: &mut TestCompositor, size: PixelSize) {
        let buffer = self.shm_buffer(size);
        let (width, height) = protocol_size(size);
        let surface = self.surface.clone().expect("a toplevel was opened first");

        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
    }

    /// Declares the toplevel's buffer transform, which its next commit applies.
    pub fn set_buffer_transform(&mut self, transform: OutputTransform) {
        self.surface
            .as_ref()
            .expect("a toplevel was opened first")
            .set_buffer_transform(transform);
    }

    /// Declares the toplevel's buffer scale, which its next commit applies.
    pub fn set_buffer_scale(&mut self, scale: i32) {
        self.surface
            .as_ref()
            .expect("a toplevel was opened first")
            .set_buffer_scale(scale);
    }

    /// Declares the toplevel's viewport source rectangle, `(x, y, width,
    /// height)` in surface coordinates before cropping, which its next commit
    /// applies.
    pub fn set_viewport_source(&mut self, source: (f64, f64, f64, f64)) {
        let (x, y, width, height) = source;
        self.viewport().set_source(x, y, width, height);
    }

    /// Declares the toplevel's viewport destination size, which its next
    /// commit applies.
    pub fn set_viewport_destination(&mut self, width: i32, height: i32) {
        self.viewport().set_destination(width, height);
    }

    /// Commits the toplevel's pending state without a new buffer.
    pub fn commit_toplevel(&mut self, compositor: &mut TestCompositor) {
        let surface = self.surface.clone().expect("a toplevel was opened first");
        self.commit(compositor, &surface);
    }

    /// Attaches a shared-memory buffer of `size` whose pixels start `offset`
    /// bytes into its pool, and commits it. The pool holds `pixels` from
    /// `offset` on and a different byte before it, so a reader that ignores
    /// the offset sees the wrong bytes.
    pub fn attach_buffer_at_offset(
        &mut self,
        compositor: &mut TestCompositor,
        size: PixelSize,
        offset: u32,
        pixels: &[u8],
    ) {
        let handle = self.queue.handle();
        let shm = self.bind::<WlShm>(1);
        let (width, height) = protocol_size(size);
        let stride = width * 4;
        let offset = i32::try_from(offset).expect("an offset the protocol can carry");
        let length = offset + stride * height;
        assert_eq!(
            pixels.len(),
            usize::try_from(stride * height).expect("a positive buffer length"),
            "the pixels fill the buffer exactly"
        );

        let mut contents = vec![0xA5; usize::try_from(offset).expect("a positive offset")];
        contents.extend_from_slice(pixels);
        let memory = anonymous_file(i64::from(length));
        let mut file = std::fs::File::from(memory);
        io::Write::write_all(&mut file, &contents).expect("the pool accepts its contents");

        let pool = shm.create_pool(file.as_fd(), length, &handle, ());
        let buffer = pool.create_buffer(
            offset,
            width,
            height,
            stride,
            wl_shm::Format::Argb8888,
            &handle,
            (),
        );
        pool.destroy();

        let surface = self.surface.clone().expect("a toplevel was opened first");
        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
    }

    /// The toplevel's viewport, created on first use.
    fn viewport(&mut self) -> WpViewport {
        if let Some(viewport) = &self.viewport {
            return viewport.clone();
        }
        let handle = self.queue.handle();
        let surface = self.surface.clone().expect("a toplevel was opened first");
        let viewport = self
            .bind::<WpViewporter>(1)
            .get_viewport(&surface, &handle, ());
        self.viewport = Some(viewport.clone());
        viewport
    }

    /// Creates a roleless surface, commits a buffer to it, and returns it.
    pub fn open_plain_surface(
        &mut self,
        compositor: &mut TestCompositor,
        size: PixelSize,
    ) -> WlSurface {
        let handle = self.queue.handle();
        let surface = self.bind::<WlCompositor>(6).create_surface(&handle, ());
        let buffer = self.shm_buffer(size);
        let (width, height) = protocol_size(size);

        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
        surface
    }

    /// Opens an `xdg_popup` at `origin`, commits a buffer to it, and returns its
    /// surface. Its top-left corner is anchored at `origin`.
    pub fn open_popup(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let parent = self
            .xdg_surface
            .clone()
            .expect("a toplevel was opened first");
        self.open_buffered_popup(compositor, &parent, origin, size)
    }

    /// Opens an `xdg_popup` whose parent is the popup on `parent`, commits a
    /// buffer to it, and returns its surface. `origin` is in the parent popup's
    /// coordinates.
    pub fn open_nested_popup(
        &mut self,
        compositor: &mut TestCompositor,
        parent: &WlSurface,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let parent = self
            .popups
            .iter()
            .find(|(_, _, surface)| surface == parent)
            .map(|(_, xdg_surface, _)| xdg_surface.clone())
            .expect("the parent popup was opened by this client");
        self.open_buffered_popup(compositor, &parent, origin, size)
    }

    /// Opens a popup whose configure is acknowledged and whose only content is
    /// an input region of `rects`, each `(x, y, width, height)` in the popup's
    /// coordinates. No buffer is ever attached.
    pub fn open_bufferless_popup(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
        rects: &[(i32, i32, i32, i32)],
    ) -> WlSurface {
        let parent = self
            .xdg_surface
            .clone()
            .expect("a toplevel was opened first");
        let (surface, xdg_surface) = self.create_popup(compositor, &parent, origin, size);
        self.acknowledge_configure(&xdg_surface);
        self.set_input_region(compositor, &surface, rects);
        surface
    }

    /// Opens a popup with a committed input region but without acknowledging its configure.
    /// It omits a buffer because attaching one before acknowledgment is a protocol error.
    pub fn open_unconfigured_popup(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let parent = self
            .xdg_surface
            .clone()
            .expect("a toplevel was opened first");
        let (width, height) = protocol_size(size);
        let (surface, _) = self.create_popup(compositor, &parent, origin, size);
        self.set_input_region(compositor, &surface, &[(0, 0, width, height)]);
        surface
    }

    /// Replaces a surface's input region with the union of `rects`, each
    /// `(x, y, width, height)` in the surface's coordinates, and commits it.
    /// No rectangles is an empty region, which accepts input nowhere.
    pub fn set_input_region(
        &mut self,
        compositor: &mut TestCompositor,
        surface: &WlSurface,
        rects: &[(i32, i32, i32, i32)],
    ) {
        let handle = self.queue.handle();
        let region = self.bind::<WlCompositor>(6).create_region(&handle, ());
        for &(x, y, width, height) in rects {
            region.add(x, y, width, height);
        }
        surface.set_input_region(Some(&region));
        region.destroy();
        surface.commit();
        self.settle_quiet(compositor);
    }

    /// Adds a desynchronised subsurface at `origin` and commits its buffer.
    /// The parent commit publishes the position because subsurface state is double-buffered.
    pub fn open_subsurface(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let surface = self.create_subsurface(origin);
        let buffer = self.shm_buffer(size);
        let (width, height) = protocol_size(size);
        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);

        self.commit_parent(compositor);
        surface
    }

    /// Adds a desynchronised subsurface at `origin` that never has a buffer, as a
    /// container whose children carry the content has none.
    pub fn open_bufferless_subsurface(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
    ) -> WlSurface {
        let surface = self.create_subsurface(origin);
        self.commit_parent(compositor);
        surface
    }

    /// Opens a popup on `parent`, acknowledges its configure, and commits a buffer to it.
    fn open_buffered_popup(
        &mut self,
        compositor: &mut TestCompositor,
        parent: &XdgSurface,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let (surface, xdg_surface) = self.create_popup(compositor, parent, origin, size);
        self.acknowledge_configure(&xdg_surface);

        let (width, height) = protocol_size(size);
        let buffer = self.shm_buffer(size);
        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
        surface
    }

    /// Creates a popup on `parent` anchored at `origin`, commits it without a
    /// buffer, and waits for its configure without acknowledging it.
    fn create_popup(
        &mut self,
        compositor: &mut TestCompositor,
        parent: &XdgSurface,
        origin: (i32, i32),
        size: PixelSize,
    ) -> (WlSurface, XdgSurface) {
        let handle = self.queue.handle();
        let wl_compositor = self.bind::<WlCompositor>(6);
        let wm_base = self.bind::<XdgWmBase>(3);
        let (width, height) = protocol_size(size);

        let positioner = wm_base.create_positioner(&handle, ());
        positioner.set_size(width, height);
        positioner.set_anchor_rect(origin.0, origin.1, 1, 1);
        positioner.set_anchor(xdg_positioner::Anchor::TopLeft);
        positioner.set_gravity(xdg_positioner::Gravity::BottomRight);

        let surface = wl_compositor.create_surface(&handle, ());
        let xdg_surface = wm_base.get_xdg_surface(&surface, &handle, ());
        let popup = xdg_surface.get_popup(Some(parent), &positioner, &handle, ());
        positioner.destroy();
        surface.commit();

        self.settle(compositor, |driver| {
            driver.configure_serial(&xdg_surface).is_some()
        });

        self.popups
            .push((popup, xdg_surface.clone(), surface.clone()));
        (surface, xdg_surface)
    }

    fn create_subsurface(&mut self, origin: (i32, i32)) -> WlSurface {
        let handle = self.queue.handle();
        let wl_compositor = self.bind::<WlCompositor>(6);
        let subcompositor = self.bind::<WlSubcompositor>(1);
        let parent = self.surface.clone().expect("a toplevel was opened first");

        let surface = wl_compositor.create_surface(&handle, ());
        let subsurface = subcompositor.get_subsurface(&surface, &parent, &handle, ());
        subsurface.set_position(origin.0, origin.1);
        subsurface.set_desync();

        self.subsurfaces.push(subsurface);
        surface
    }

    fn commit_parent(&mut self, compositor: &mut TestCompositor) {
        let parent = self.surface.clone().expect("a toplevel was opened first");
        parent.commit();
        self.settle_quiet(compositor);
    }

    /// Unmaps the toplevel by attaching a null buffer.
    /// The surface can be mapped again by committing another buffer.
    pub fn detach_buffer(&mut self, compositor: &mut TestCompositor) {
        let surface = self.surface.clone().expect("a toplevel was opened first");
        surface.attach(None, 0, 0);
        surface.commit();
        self.settle_quiet(compositor);
    }

    pub fn destroy_surface(&mut self, compositor: &mut TestCompositor, surface: &WlSurface) {
        surface.destroy();
        self.settle_quiet(compositor);
    }

    fn shm_buffer(&mut self, size: PixelSize) -> WlBuffer {
        let handle = self.queue.handle();
        let shm = self.bind::<WlShm>(1);
        let (width, height) = protocol_size(size);
        let stride = width * 4;
        let length = stride * height;
        let memory = anonymous_file(i64::from(length));

        let pool = shm.create_pool(memory.as_fd(), length, &handle, ());
        pool.create_buffer(
            0,
            width,
            height,
            stride,
            wl_shm::Format::Argb8888,
            &handle,
            (),
        )
    }

    fn attach_to(
        &mut self,
        compositor: &mut TestCompositor,
        surface: &WlSurface,
        buffer: &WlBuffer,
        width: i32,
        height: i32,
    ) {
        surface.attach(Some(buffer), 0, 0);
        surface.damage(0, 0, width, height);
        surface.commit();

        self.settle_quiet(compositor);
    }

    /// Waits for the first seat's pointer capability before binding its pointer.
    pub fn open_pointer(&mut self, compositor: &mut TestCompositor) -> WlPointer {
        let seat = self
            .bind_seats(compositor)
            .first()
            .cloned()
            .expect("the compositor advertised at least one seat");
        let pointer = self.open_pointer_on(compositor, &seat);
        self.pointer = Some(pointer.clone());
        pointer
    }

    /// Binds the pointer of the seat whose `wl_seat.name` equals `name`.
    pub fn open_pointer_for(&mut self, compositor: &mut TestCompositor, name: &str) -> WlPointer {
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

        self.open_pointer_on(compositor, &seat)
    }

    /// Waits for the named seat's keyboard capability before binding its keyboard.
    pub fn open_keyboard_for(&mut self, compositor: &mut TestCompositor, name: &str) -> WlKeyboard {
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

        let handle = self.queue.handle();
        self.settle(compositor, |driver| driver.has_keyboard(&seat));
        let keyboard = seat.get_keyboard(&handle, ());
        self.settle_quiet(compositor);
        keyboard
    }

    #[must_use]
    pub fn pointer(&self) -> &WlPointer {
        self.pointer
            .as_ref()
            .expect("a pointer was opened before it was used")
    }

    /// Uses the most recent enter serial; the protocol rejects any other serial.
    pub fn set_cursor(
        &mut self,
        compositor: &mut TestCompositor,
        pointer: &WlPointer,
        cursor: &WlSurface,
    ) {
        let serial = self
            .driver
            .enter_serial(pointer)
            .expect("the pointer entered a surface before a cursor was set for it");
        pointer.set_cursor(serial, Some(cursor), 0, 0);
        self.settle_quiet(compositor);
    }

    /// Binds advertised `wl_output` globals and waits for each complete configuration.
    /// Returns outputs in registry order, including an empty list when none are advertised.
    pub fn bind_outputs(&mut self, compositor: &mut TestCompositor) -> Vec<WlOutput> {
        let handle = self.queue.handle();
        let advertised: Vec<Global> = self
            .driver
            .globals
            .iter()
            .filter(|global| global.interface == WlOutput::interface().name)
            .cloned()
            .collect();

        for global in advertised {
            if self.outputs.iter().any(|(name, _)| *name == global.name) {
                continue;
            }
            let registry = self
                .driver
                .registry
                .as_ref()
                .expect("the registry arrived with the globals");
            let output = registry.bind::<WlOutput, (), Driver>(
                global.name,
                global.version.min(4),
                &handle,
                (),
            );
            self.outputs.push((global.name, output));
        }

        let bound: Vec<WlOutput> = self
            .outputs
            .iter()
            .map(|(_, output)| output.clone())
            .collect();
        self.settle(compositor, |driver| {
            bound.iter().all(|output| driver.output(output).is_some())
        });
        bound
    }

    /// Requests a surface's `wp_fractional_scale_v1` without settling, so the caller observes its
    /// reply.
    pub fn request_fractional_scale(&mut self, surface: &WlSurface) -> WpFractionalScaleV1 {
        let handle = self.queue.handle();
        let manager = self.bind::<WpFractionalScaleManagerV1>(1);
        let scale = manager.get_fractional_scale(surface, &handle, ());
        self.fractional_scales.push(scale.clone());
        scale
    }

    /// Sets a surface's content type and optionally commits it.
    /// The protocol applies the pending value at commit time.
    pub fn set_content_type(
        &mut self,
        compositor: &mut TestCompositor,
        surface: &WlSurface,
        content_type: ContentType,
        commit: bool,
    ) {
        let object = self.content_type_of(surface);
        object.set_content_type(protocol_content_type(content_type));

        if commit {
            surface.commit();
        }
        self.settle_quiet(compositor);
    }

    /// Reuses the surface's retained content-type object; requesting a second one is a protocol
    /// error.
    fn content_type_of(&mut self, surface: &WlSurface) -> WpContentTypeV1 {
        let id = surface.id();
        if let Some((_, object)) = self.content_types.iter().find(|(held, _)| *held == id) {
            return object.clone();
        }

        let handle = self.queue.handle();
        let manager = self.bind::<WpContentTypeManagerV1>(1);
        let object = manager.get_surface_content_type(surface, &handle, ());
        self.content_types.push((id, object.clone()));
        object
    }

    pub fn commit(&mut self, compositor: &mut TestCompositor, surface: &WlSurface) {
        surface.commit();
        self.settle_quiet(compositor);
    }

    /// Requests a frame callback, commits, and flushes without stepping the compositor.
    /// The caller controls stepping so callback timing remains observable.
    pub fn request_frame(&mut self, surface: &WlSurface) {
        let handle = self.queue.handle();
        surface.frame(&handle, surface.id());
        surface.commit();
        drop(self.queue.flush());
    }

    /// Returns frame callback timestamps for `surface` in arrival order; an empty slice means none arrived.
    #[must_use]
    pub fn frames(&self, surface: &WlSurface) -> &[u32] {
        self.driver.frames(&surface.id())
    }

    #[must_use]
    pub fn surface(&self) -> Option<&WlSurface> {
        self.surface.as_ref()
    }

    /// Attempts to bind a `wl_output` by registry name without requiring an
    /// advertisement. The compositor must enforce the output filter at bind time;
    /// refusing an unadvertised name produces this client's protocol error.
    pub fn bind_output_by_name(&mut self, name: u32, version: u32) -> WlOutput {
        let handle = self.queue.handle();
        self.driver
            .registry
            .as_ref()
            .expect("the registry arrived with the globals")
            .bind::<WlOutput, (), Driver>(name, version, &handle, ())
    }

    /// Reports whether a protocol error tore down this connection.
    #[must_use]
    pub fn is_disconnected(&self) -> bool {
        self.connection.protocol_error().is_some()
    }

    /// Binds advertised seats keyed by registry name and waits for each seat name.
    fn bind_seats(&mut self, compositor: &mut TestCompositor) -> Vec<WlSeat> {
        let handle = self.queue.handle();
        let advertised: Vec<Global> = self
            .driver
            .globals
            .iter()
            .filter(|global| global.interface == WlSeat::interface().name)
            .cloned()
            .collect();

        for global in advertised {
            if self.seats.iter().any(|(name, _)| *name == global.name) {
                continue;
            }
            let registry = self
                .driver
                .registry
                .as_ref()
                .expect("the registry arrived with the globals");
            let seat = registry.bind::<WlSeat, (), Driver>(
                global.name,
                global.version.min(5),
                &handle,
                (),
            );
            self.seats.push((global.name, seat));
        }

        let bound: Vec<WlSeat> = self.seats.iter().map(|(_, seat)| seat.clone()).collect();
        self.settle(compositor, |driver| {
            bound.iter().all(|seat| driver.seat_name(seat).is_some())
        });
        bound
    }

    fn open_pointer_on(&mut self, compositor: &mut TestCompositor, seat: &WlSeat) -> WlPointer {
        let handle = self.queue.handle();
        self.settle(compositor, |driver| driver.has_pointer(seat));
        let pointer = seat.get_pointer(&handle, ());
        self.settle_quiet(compositor);
        pointer
    }

    pub fn set_title(&mut self, compositor: &mut TestCompositor, title: &str) {
        self.toplevel
            .as_ref()
            .expect("a toplevel was opened first")
            .set_title(title.to_owned());
        self.settle_quiet(compositor);
    }

    pub fn close_toplevel(&mut self, compositor: &mut TestCompositor) {
        if let Some(toplevel) = self.toplevel.take() {
            toplevel.destroy();
        }
        if let Some(xdg_surface) = self.xdg_surface.take() {
            xdg_surface.destroy();
        }
        if let Some(surface) = self.surface.take() {
            surface.destroy();
        }
        self.settle_quiet(compositor);
    }

    /// Asks for a decoration mode on the open toplevel, creating its decoration
    /// object on first use, and waits for the compositor's answer.
    pub fn request_decoration(&mut self, compositor: &mut TestCompositor, mode: DecorationMode) {
        let handle = self.queue.handle();
        if self.decoration.is_none() {
            let manager = self.bind::<ZxdgDecorationManagerV1>(1);
            let toplevel = self.toplevel.as_ref().expect("a toplevel was opened first");
            self.decoration = Some(manager.get_toplevel_decoration(toplevel, &handle, ()));
        }
        let decoration = self
            .decoration
            .as_ref()
            .unwrap_or_else(|| unreachable!("the decoration was just stored"));
        decoration.set_mode(mode);
        self.settle(compositor, |driver| driver.decoration_mode == Some(mode));
    }

    /// Withdraws the toplevel's decoration preference and waits for the mode the
    /// compositor chooses instead.
    pub fn unset_decoration(&mut self, compositor: &mut TestCompositor, expected: DecorationMode) {
        self.decoration
            .as_ref()
            .expect("a decoration mode was requested first")
            .unset_mode();
        self.settle(compositor, |driver| {
            driver.decoration_mode == Some(expected)
        });
    }

    /// Acknowledges the toplevel's latest configure without committing. The next
    /// commit applies it.
    pub fn acknowledge_toplevel_configure(&mut self) {
        let xdg_surface = self
            .xdg_surface
            .clone()
            .expect("a toplevel was opened first");
        self.acknowledge_configure(&xdg_surface);
    }

    /// Acknowledges the latest configure; the protocol requires this before attaching a buffer.
    fn acknowledge_configure(&mut self, xdg_surface: &XdgSurface) {
        let Some(serial) = self.driver.configure_serial(xdg_surface) else {
            panic!("the compositor did not configure the surface");
        };
        xdg_surface.ack_configure(serial);
    }

    /// Binds a global at the lower of the offered and requested versions.
    fn bind<I: Proxy + 'static>(&self, version: u32) -> I
    where
        Driver: Dispatch<I, ()>,
    {
        let handle = self.queue.handle();
        let global = self
            .driver
            .globals
            .iter()
            .find(|global| global.interface == I::interface().name)
            .unwrap_or_else(|| panic!("the compositor did not advertise {}", I::interface().name));

        self.driver
            .registry
            .as_ref()
            .expect("the registry arrived with the globals")
            .bind::<I, (), Driver>(global.name, version.min(global.version), &handle, ())
    }

    /// Drops the connection and steps the compositor so it processes the peer teardown.
    pub fn disconnect(self, compositor: &mut TestCompositor) {
        drop(self.connection);
        drop(self.queue);
        for _ in 0..8 {
            compositor.step();
        }
    }
}

/// Converts a pixel size to Wayland's signed integer representation; values that do not fit are invalid test inputs.
fn protocol_size(size: PixelSize) -> (i32, i32) {
    (
        i32::try_from(size.width).expect("a width the protocol can carry"),
        i32::try_from(size.height).expect("a height the protocol can carry"),
    )
}

/// Creates an anonymous `length`-byte file for a `wl_shm` pool so tests do not share filesystem paths.
fn anonymous_file(length: i64) -> OwnedFd {
    let name = c"lunette-test-shm";
    // SAFETY: `name` is a valid NUL-terminated string that outlives the call,
    // and a non-negative result is a new owned descriptor.
    let descriptor = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    assert!(
        descriptor >= 0,
        "memfd_create failed: {}",
        io::Error::last_os_error()
    );

    // SAFETY: `descriptor` is a fresh, owned, non-negative descriptor, and
    // nothing else holds it.
    let memory = unsafe { OwnedFd::from_raw_fd(descriptor) };

    // SAFETY: `memory` is a valid descriptor for a writable anonymous file.
    let sized = unsafe { libc::ftruncate(memory.as_raw_fd(), length) };
    assert!(
        sized == 0,
        "ftruncate failed: {}",
        io::Error::last_os_error()
    );

    memory
}
