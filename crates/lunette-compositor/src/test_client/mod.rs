//! A real Wayland client, driven a step at a time by the test that owns it.
//!
//! The compositor's tests are worth little if they call its handlers directly:
//! what they need to establish is that a client speaking the protocol gets what
//! it expects. So this is an actual `wayland-client` connection, over the far
//! end of the socket pair [`crate::testing::TestCompositor`] hands out.
//!
//! Both ends live on the calling thread, which is why nothing here blocks.
//! [`TestClient::settle`] alternates between the two — flush the client,
//! step the compositor, read what came back — until a condition the caller
//! names holds, or until a deadline declares it never will. There are no
//! sleeps: a fixed one passes on a quiet machine and fails on a loaded one, and
//! none of this is a test about timing.
//!
//! `Connection::connect_to_env` is never used, here or anywhere. It calls
//! `env::remove_var("WAYLAND_SOCKET")` internally, and mutating the environment
//! of a multithreaded test binary is unsound. `Connection::from_socket` is the
//! only form.
//!
//! Linux-only: the shared-memory buffer is a `memfd`. An anonymous file rather
//! than a temporary one, so a test writes nothing to the filesystem and cannot
//! collide with another test over a name.

#![expect(
    clippy::expect_used,
    reason = "test scaffolding: a failed expectation is how a test reports a failure, and this \
              module is gated behind `cfg(test)` or the `test-fakes` feature"
)]

mod selection;

use std::{
    io::{self, Read, Seek, SeekFrom},
    os::{
        fd::{AsFd, AsRawFd, FromRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    time::Instant,
};

/// The protocol's own scroll-source enum, re-exported so a test can name the
/// value it expects without depending on `wayland-client` itself.
pub use wayland_client::protocol::wl_pointer::AxisSource;
use wayland_client::{
    Connection, Dispatch, EventQueue, Proxy, QueueHandle,
    backend::{ObjectId, WaylandError},
    delegate_noop,
    protocol::{
        wl_buffer::{self, WlBuffer},
        wl_compositor::WlCompositor,
        wl_data_offer::WlDataOffer,
        wl_keyboard::{self, KeyState, WlKeyboard},
        wl_output::{self, WlOutput},
        wl_pointer::{self, ButtonState, WlPointer},
        wl_region::WlRegion,
        wl_registry::{self, WlRegistry},
        wl_seat::{self, Capability, WlSeat},
        wl_shm::{self, WlShm},
        wl_shm_pool::WlShmPool,
        wl_subcompositor::WlSubcompositor,
        wl_subsurface::WlSubsurface,
        wl_surface::{self, WlSurface},
    },
};
use wayland_protocols::{
    wp::{
        fractional_scale::v1::client::{
            wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1,
            wp_fractional_scale_v1::{self, WpFractionalScaleV1},
        },
        linux_dmabuf::zv1::client::{
            zwp_linux_buffer_params_v1::{Flags as DmabufFlags, ZwpLinuxBufferParamsV1},
            zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1,
        },
        primary_selection::zv1::client::zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1,
    },
    xdg::shell::client::{
        xdg_popup::XdgPopup,
        xdg_positioner::{self, XdgPositioner},
        xdg_surface::{self, XdgSurface},
        xdg_toplevel::{self, XdgToplevel},
        xdg_wm_base::{self, XdgWmBase},
    },
};

pub use crate::test_client::selection::{ClientSource, SelectionDevices, read_to_end};
use crate::{
    protocol::{PixelSize, ScrollAxis},
    testing::{DEADLINE, TestCompositor},
};

/// `DRM_FORMAT_ARGB8888`, which is the format a test advertises and attaches.
const ARGB8888: u32 = smithay::backend::allocator::Fourcc::Argb8888 as u32;

/// A connected client and the queue its events arrive on.
pub struct TestClient {
    connection: Connection,
    queue: EventQueue<Driver>,
    driver: Driver,
    surface: Option<WlSurface>,
    xdg_surface: Option<XdgSurface>,
    toplevel: Option<XdgToplevel>,
    /// Every seat this client has bound, by the registry name of its global, so
    /// a second look at the registry does not bind the same seat twice.
    seats: Vec<(u32, WlSeat)>,
    /// Every output this client has bound, by the registry name of its global,
    /// for the reason the seats are keyed that way.
    outputs: Vec<(u32, WlOutput)>,
    /// Every popup the client has opened, held so none is destroyed early.
    popups: Vec<(XdgPopup, XdgSurface)>,
    /// Every subsurface the client has created, held for the same reason: a
    /// destroyed `wl_subsurface` puts its surface back to having no role.
    subsurfaces: Vec<WlSubsurface>,
    /// The pointer of the first seat, which is the one a single-seat test uses.
    pointer: Option<WlPointer>,
    /// Every buffer this client created, held so none is destroyed early. A
    /// destroyed `wl_buffer` cannot be released, and release is what the
    /// retention tests are about.
    buffers: Vec<WlBuffer>,
    /// Every `wp_fractional_scale_v1` the client asked for, held so none is
    /// destroyed early. A destroyed object is removed from the surface's state
    /// and stops being sent anything.
    fractional_scales: Vec<WpFractionalScaleV1>,
}

impl TestClient {
    /// Connects over a socket pair and binds the globals a toplevel needs.
    pub fn connect(compositor: &mut TestCompositor) -> Self {
        let (stream, _client) = compositor.connect();
        let mut client = Self::from_socket(stream);
        client.settle(compositor, |driver| !driver.globals.is_empty());
        client
    }

    /// Wraps a socket a test opened itself, and settles until the registry has
    /// arrived.
    ///
    /// For the tests that need a client connected some other way than
    /// [`TestClient::connect`] — one already assigned to an output, say.
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
        }
    }

    /// Every global the compositor advertised, by interface name, sorted.
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

    /// What the client has learned so far.
    #[must_use]
    pub fn driver(&self) -> &Driver {
        &self.driver
    }

    /// The toplevel's surface, for a test asserting that an event named it.
    #[must_use]
    pub fn surface_id(&self) -> Option<ObjectId> {
        self.surface.as_ref().map(Proxy::id)
    }

    /// Runs both ends until `ready` holds, failing at the deadline.
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

    /// Runs both ends a fixed number of rounds, for a test asserting that
    /// something did *not* happen.
    pub fn settle_quiet(&mut self, compositor: &mut TestCompositor) {
        for _ in 0..8 {
            self.pump(compositor);
        }
    }

    fn pump(&mut self, compositor: &mut TestCompositor) {
        // A connection the compositor tore down has nothing left to say, and
        // every operation on it fails. Stepping the compositor alone is what a
        // test asserting the teardown still needs.
        if self.connection.protocol_error().is_some() {
            compositor.step();
            return;
        }

        drop(self.queue.flush());
        compositor.step();

        if let Some(guard) = self.queue.prepare_read() {
            match guard.read() {
                Ok(_) => {}
                // Nothing arrived this round. The socket is non-blocking
                // precisely so this is an answer rather than a wait.
                Err(WaylandError::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {}
                // A refused bind is answered with a protocol error, which is
                // the outcome the output-filter tests are about. It is reported
                // through `is_disconnected` rather than raised here.
                Err(WaylandError::Protocol(_)) => {}
                Err(error) => panic!("the client could not read from the compositor: {error}"),
            }
        }

        drop(self.queue.dispatch_pending(&mut self.driver));
    }

    /// Creates a toplevel and drives it as far as its first configure.
    ///
    /// The order matters and is the usual way these tests fail confusingly:
    /// the first commit carries no buffer, the client waits for
    /// `xdg_surface.configure`, and only then may it attach. Attaching before
    /// the first configure is a protocol error.
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

    /// Attaches a linear `argb8888` dmabuf of `size` and commits.
    ///
    /// The descriptor is a `memfd` rather than anything a driver produced.
    /// Nothing between here and the importer looks at what the descriptor
    /// addresses — the compositor passes it on, and the importer under test is
    /// the fake one — so a real device is not needed to exercise the path.
    ///
    /// Returns the buffer's object id, which is what a test asserting on
    /// releases compares against.
    pub fn attach_dmabuf(&mut self, compositor: &mut TestCompositor, size: PixelSize) -> ObjectId {
        let buffer = self.create_dmabuf(compositor, size);
        let id = buffer.id();
        self.attach_created(compositor, &buffer, size);
        id
    }

    /// Creates a linear `argb8888` dmabuf of `size` and lets the compositor
    /// answer, without attaching it to anything.
    ///
    /// The two halves are separate operations to the compositor and it can be in
    /// different states for each: `create_immed` reaches `dmabuf_imported`, and
    /// the commit is what asks for the image. A restart quiesce that falls
    /// between them is what this exists to drive.
    pub fn create_dmabuf(&mut self, compositor: &mut TestCompositor, size: PixelSize) -> WlBuffer {
        let handle = self.queue.handle();
        let dmabuf = self.bind::<ZwpLinuxDmabufV1>(3);

        let (width, height) = protocol_size(size);
        let stride = size.width * 4;
        let memory = anonymous_file(i64::from(stride) * i64::from(height));

        let params = dmabuf.create_params(&handle, ());
        // `DRM_FORMAT_MOD_LINEAR` is zero in both halves.
        params.add(memory.as_fd(), 0, 0, stride, 0, 0);
        let buffer =
            params.create_immed(width, height, ARGB8888, DmabufFlags::empty(), &handle, ());
        params.destroy();

        // The create is answered before the caller goes on, so that a case
        // choosing when to commit is choosing it relative to a create the
        // compositor has already seen.
        self.settle_quiet(compositor);
        self.buffers.push(buffer.clone());
        buffer
    }

    /// Attaches a buffer this client already created to its toplevel's surface,
    /// and commits.
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

    /// Attaches a shared-memory buffer of `size` and commits, which is what
    /// maps the window.
    pub fn attach_buffer(&mut self, compositor: &mut TestCompositor, size: PixelSize) {
        let buffer = self.shm_buffer(size);
        let (width, height) = protocol_size(size);
        let surface = self.surface.clone().expect("a toplevel was opened first");

        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
    }

    /// Creates a surface with no role, commits a buffer to it, and hands it
    /// back.
    ///
    /// The shape of a cursor surface, a popup, and a subsurface: it mints a
    /// `SurfaceId` and its buffer is imported, and it is never a window. A test
    /// destroys the returned surface to drive what happens when one goes away.
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

    /// Opens an `xdg_popup` of the toplevel, at `origin` in the toplevel's own
    /// coordinates, and commits a buffer to it.
    ///
    /// The positioner anchors the popup's top-left corner at `origin`: the
    /// anchor rectangle is a single pixel there, the anchor edge is its
    /// top-left, and the gravity is bottom-right, so the popup grows away from
    /// that corner and its geometry starts exactly at it. A menu placed by any
    /// other combination lands somewhere a test would have to re-derive.
    ///
    /// Returns the popup's surface, which is what a routing test compares an
    /// enter against.
    pub fn open_popup(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let handle = self.queue.handle();
        let wl_compositor = self.bind::<WlCompositor>(6);
        let wm_base = self.bind::<XdgWmBase>(3);
        let parent = self
            .xdg_surface
            .clone()
            .expect("a toplevel was opened first");
        let (width, height) = protocol_size(size);

        let positioner = wm_base.create_positioner(&handle, ());
        positioner.set_size(width, height);
        positioner.set_anchor_rect(origin.0, origin.1, 1, 1);
        positioner.set_anchor(xdg_positioner::Anchor::TopLeft);
        positioner.set_gravity(xdg_positioner::Gravity::BottomRight);

        let surface = wl_compositor.create_surface(&handle, ());
        let xdg_surface = wm_base.get_xdg_surface(&surface, &handle, ());
        let popup = xdg_surface.get_popup(Some(&parent), &positioner, &handle, ());
        positioner.destroy();
        surface.commit();

        self.settle(compositor, |driver| {
            driver.configure_serial(&xdg_surface).is_some()
        });
        self.acknowledge_configure(&xdg_surface);

        let buffer = self.shm_buffer(size);
        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
        self.popups.push((popup, xdg_surface));
        surface
    }

    /// Opens a popup and never acknowledges its configure.
    ///
    /// The point of the exercise is a popup that would otherwise be hit: an
    /// input region covering the popup's extent is committed, so the geometry
    /// alone would accept a click. A popup with neither a buffer nor a region is
    /// skipped by the input-region test whether or not the configure was
    /// answered, and would say nothing about the configure check.
    ///
    /// No buffer, because attaching one before acknowledging the configure is a
    /// protocol error.
    pub fn open_unconfigured_popup(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let handle = self.queue.handle();
        let wl_compositor = self.bind::<WlCompositor>(6);
        let wm_base = self.bind::<XdgWmBase>(3);
        let parent = self
            .xdg_surface
            .clone()
            .expect("a toplevel was opened first");
        let (width, height) = protocol_size(size);

        let positioner = wm_base.create_positioner(&handle, ());
        positioner.set_size(width, height);
        positioner.set_anchor_rect(origin.0, origin.1, 1, 1);
        positioner.set_anchor(xdg_positioner::Anchor::TopLeft);
        positioner.set_gravity(xdg_positioner::Gravity::BottomRight);

        let surface = wl_compositor.create_surface(&handle, ());
        let xdg_surface = wm_base.get_xdg_surface(&surface, &handle, ());
        let popup = xdg_surface.get_popup(Some(&parent), &positioner, &handle, ());
        positioner.destroy();
        surface.commit();

        self.settle(compositor, |driver| {
            driver.configure_serial(&xdg_surface).is_some()
        });

        let region = wl_compositor.create_region(&handle, ());
        region.add(0, 0, width, height);
        surface.set_input_region(Some(&region));
        region.destroy();
        surface.commit();
        self.settle_quiet(compositor);

        self.popups.push((popup, xdg_surface));
        surface
    }

    /// Adds a subsurface of the toplevel at `origin`, with a buffer committed.
    ///
    /// Desynchronised, and the parent is committed afterwards: a subsurface's
    /// position is part of its *parent's* double-buffered state, so without the
    /// parent commit the child sits at the origin however it was positioned.
    ///
    /// Returns the subsurface's own surface.
    pub fn open_subsurface(
        &mut self,
        compositor: &mut TestCompositor,
        origin: (i32, i32),
        size: PixelSize,
    ) -> WlSurface {
        let handle = self.queue.handle();
        let wl_compositor = self.bind::<WlCompositor>(6);
        let subcompositor = self.bind::<WlSubcompositor>(1);
        let parent = self.surface.clone().expect("a toplevel was opened first");
        let (width, height) = protocol_size(size);

        let surface = wl_compositor.create_surface(&handle, ());
        let subsurface = subcompositor.get_subsurface(&surface, &parent, &handle, ());
        subsurface.set_position(origin.0, origin.1);
        subsurface.set_desync();

        let buffer = self.shm_buffer(size);
        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);

        parent.commit();
        self.settle_quiet(compositor);

        self.subsurfaces.push(subsurface);
        surface
    }

    /// Attaches a null buffer to the toplevel's surface, which unmaps it.
    ///
    /// The protocol lets the client map it again by committing another buffer,
    /// which is why this is not the same as destroying the surface.
    pub fn detach_buffer(&mut self, compositor: &mut TestCompositor) {
        let surface = self.surface.clone().expect("a toplevel was opened first");
        surface.attach(None, 0, 0);
        surface.commit();
        self.settle_quiet(compositor);
    }

    /// Destroys a surface this client made and lets the compositor notice.
    pub fn destroy_surface(&mut self, compositor: &mut TestCompositor, surface: &WlSurface) {
        surface.destroy();
        self.settle_quiet(compositor);
    }

    /// A shared-memory buffer of `size`, in the format a test attaches.
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

    /// Attaches a buffer to one of the client's surfaces, damages all of it,
    /// and commits.
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

    /// Binds the first seat's pointer, so a test can observe what input reaches
    /// this client.
    ///
    /// Waits for the capability rather than assuming it: asking a seat for a
    /// pointer it has not advertised is a protocol error.
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

    /// Binds the pointer of the seat advertising `name` on `wl_seat.name`.
    ///
    /// The name is how a client tells two seats apart; there is nothing else on
    /// the wire that distinguishes them.
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

    /// Binds the keyboard of the seat advertising `name` on `wl_seat.name`.
    ///
    /// Waits for the capability first, for the reason a pointer does: asking a
    /// seat for a keyboard it has not advertised is a protocol error.
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

    /// The pointer of the first seat, for a test that opened one.
    #[must_use]
    pub fn pointer(&self) -> &WlPointer {
        self.pointer
            .as_ref()
            .expect("a pointer was opened before it was used")
    }

    /// Asks for a cursor image on `pointer`, as a client does when the pointer
    /// enters one of its surfaces.
    ///
    /// The serial has to be the one that entered, or smithay refuses the request
    /// (`wayland/seat/pointer.rs:379-381`) and the handler under test never runs.
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

    /// Binds every `wl_output` the compositor advertised, and waits for each to
    /// report its configuration.
    ///
    /// Returns the outputs in the order the registry announced them. A client
    /// that was shown none gets an empty list rather than a failure: seeing no
    /// output is what the filter does, and a test asserting it needs to be able
    /// to observe it.
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

    /// Asks the compositor for the `wp_fractional_scale_v1` of one surface.
    ///
    /// Does not settle: whether the compositor answers, and with what, is the
    /// thing a caller is asserting about, so waiting for an answer here would
    /// hide the case where there is none.
    pub fn request_fractional_scale(&mut self, surface: &WlSurface) -> WpFractionalScaleV1 {
        let handle = self.queue.handle();
        let manager = self.bind::<WpFractionalScaleManagerV1>(1);
        let scale = manager.get_fractional_scale(surface, &handle, ());
        self.fractional_scales.push(scale.clone());
        scale
    }

    /// The client's own toplevel surface, for a caller that needs to name it.
    #[must_use]
    pub fn surface(&self) -> Option<&WlSurface> {
        self.surface.as_ref()
    }

    /// Binds one `wl_output` by the registry name of its global, without
    /// checking that the compositor advertised it.
    ///
    /// The only way to establish that the filter is enforced at bind and not
    /// merely at advertisement: a client that guesses a name it was never told
    /// must still be refused. The compositor answers a refused bind with a
    /// protocol error, so a caller expects the connection to die.
    pub fn bind_output_by_name(&mut self, name: u32, version: u32) -> WlOutput {
        let handle = self.queue.handle();
        self.driver
            .registry
            .as_ref()
            .expect("the registry arrived with the globals")
            .bind::<WlOutput, (), Driver>(name, version, &handle, ())
    }

    /// Whether the connection has been torn down by a protocol error.
    #[must_use]
    pub fn is_disconnected(&self) -> bool {
        self.connection.protocol_error().is_some()
    }

    /// Binds every seat the compositor has advertised, and waits for each to
    /// report its name and capabilities.
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

    /// Sets the toplevel's title.
    pub fn set_title(&mut self, compositor: &mut TestCompositor, title: &str) {
        self.toplevel
            .as_ref()
            .expect("a toplevel was opened first")
            .set_title(title.to_owned());
        self.settle_quiet(compositor);
    }

    /// Destroys the toplevel, as a client closing its window would.
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

    /// Acknowledges the configure one `xdg_surface` was last sent.
    ///
    /// A client may not attach a buffer before it has, and doing so is where
    /// these tests fail confusingly rather than with a protocol error.
    fn acknowledge_configure(&mut self, xdg_surface: &XdgSurface) {
        let Some(serial) = self.driver.configure_serial(xdg_surface) else {
            panic!("the compositor did not configure the surface");
        };
        xdg_surface.ack_configure(serial);
    }

    /// Binds a global by interface, at the lower of the version the compositor
    /// offers and the version asked for.
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

    /// The connection, for a test that wants to close it abruptly.
    pub fn disconnect(self, compositor: &mut TestCompositor) {
        drop(self.connection);
        drop(self.queue);
        for _ in 0..8 {
            compositor.step();
        }
    }
}

/// What the client learned from the compositor.
#[derive(Debug, Default)]
pub struct Driver {
    pub globals: Vec<Global>,
    registry: Option<WlRegistry>,
    /// The serial each `xdg_surface` was last configured with. Keyed, because a
    /// popup has its own `xdg_surface` and acknowledging the wrong one is a
    /// protocol error.
    configures: Vec<(ObjectId, u32)>,
    /// Every configure serial the compositor ever sent, in order. Kept apart
    /// from `configures` because that one keeps only the latest per surface,
    /// and the property worth asserting — that no two events anywhere share a
    /// serial — needs all of them.
    configure_serials: Vec<u32>,
    pub toplevel_size: Option<(i32, i32)>,
    pub closed: bool,
    /// Every seat the client has bound, in the order it bound them.
    seats: Vec<SeatRecord>,
    /// Every pointer event delivered, in order, against the pointer it was
    /// delivered to. Two seats mean two pointers, and an event that does not
    /// say which one it reached says nothing about routing.
    pointer: Vec<(ObjectId, PointerEvent)>,
    /// Every keyboard event delivered, in order, against the keyboard it was
    /// delivered to. Two seats mean two keyboards, for the reason they mean two
    /// pointers.
    keyboard: Vec<(ObjectId, KeyboardEvent)>,
    /// Every buffer the compositor released, in order. A client may reuse a
    /// buffer only once it appears here.
    pub released: Vec<ObjectId>,
    /// What each bound `wl_output` reported, by output object. Applied at
    /// `done`, because the properties arrive as separate events and a test
    /// reading between two of them would see half a configuration.
    outputs: Vec<(ObjectId, OutputRecord)>,
    /// Which outputs each surface was told it is on, by surface. Kept as a list
    /// rather than a set so that a duplicate enter is visible rather than
    /// absorbed.
    surface_outputs: Vec<(ObjectId, Vec<ObjectId>)>,
    /// Every `wl_surface.preferred_buffer_scale` a surface was sent, in order.
    /// In order rather than latest-only, because the protocol sends one only
    /// when the value changes and a test asserting that needs to count them.
    surface_buffer_scales: Vec<(ObjectId, Vec<i32>)>,
    /// Every `wp_fractional_scale_v1.preferred_scale` an object was sent, in
    /// 120ths, in order. Kept whole for the reason the buffer scales are.
    fractional_scales: Vec<(ObjectId, Vec<u32>)>,

    // The selection half, in `selection.rs`. The fields live here because that
    // is where the struct is, and everything that reads them is in the submodule.
    /// The MIME types each selection offer advertised, by offer object.
    offers: Vec<(ObjectId, Vec<String>)>,
    /// The clipboard offer each data device was last given, by device. Keyed
    /// because two seats mean two devices, and a selection that does not say
    /// which one it reached says nothing about the bridge.
    clipboard: Vec<(ObjectId, Option<WlDataOffer>)>,
    /// The primary-selection offer each device was last given, keyed for the
    /// reason the clipboard is.
    primary: Vec<(ObjectId, Option<ZwpPrimarySelectionOfferV1>)>,
    /// Requests the compositor made of this client's own sources, each with the
    /// descriptor to write into.
    sends: Vec<(String, OwnedFd)>,
    /// Whether one of this client's sources was cancelled.
    cancelled: bool,
}

impl Driver {
    /// The serial an `xdg_surface` was last configured with.
    #[must_use]
    pub fn configure_serial(&self, xdg_surface: &XdgSurface) -> Option<u32> {
        let id = xdg_surface.id();
        self.configures
            .iter()
            .find(|(target, _)| *target == id)
            .map(|(_, serial)| *serial)
    }

    /// Every configure serial the compositor has sent, in order.
    #[must_use]
    pub fn configure_serials(&self) -> Vec<u32> {
        self.configure_serials.clone()
    }

    /// What an output reported, as of its latest `done`.
    ///
    /// Absent until the first `done`, so a caller never reads a configuration
    /// the compositor is half-way through sending.
    #[must_use]
    pub fn output(&self, output: &WlOutput) -> Option<OutputState> {
        let id = output.id();
        self.outputs
            .iter()
            .find(|(target, _)| *target == id)
            .and_then(|(_, record)| record.current.clone())
    }

    /// Which outputs a surface has been told it is on, in the order it was told.
    ///
    /// Keyed by object identifier rather than by the proxy, because a test that
    /// opened a toplevel through [`TestClient::open_toplevel`] holds the
    /// identifier and not the surface.
    #[must_use]
    pub fn surface_outputs(&self, surface: &ObjectId) -> Vec<ObjectId> {
        self.surface_outputs
            .iter()
            .find(|(target, _)| target == surface)
            .map_or_else(Vec::new, |(_, outputs)| outputs.clone())
    }

    /// Every `preferred_buffer_scale` a surface has been sent, in order.
    #[must_use]
    pub fn buffer_scales(&self, surface: &ObjectId) -> Vec<i32> {
        self.surface_buffer_scales
            .iter()
            .find(|(target, _)| target == surface)
            .map_or_else(Vec::new, |(_, scales)| scales.clone())
    }

    /// Every `preferred_scale` a `wp_fractional_scale_v1` has been sent, in
    /// 120ths, in order.
    #[must_use]
    pub fn preferred_scales(&self, scale: &WpFractionalScaleV1) -> Vec<u32> {
        let id = scale.id();
        self.fractional_scales
            .iter()
            .find(|(target, _)| *target == id)
            .map_or_else(Vec::new, |(_, scales)| scales.clone())
    }

    /// The name a seat advertised on `wl_seat.name`, once it has.
    #[must_use]
    pub fn seat_name(&self, seat: &WlSeat) -> Option<String> {
        self.seat(seat).and_then(|record| record.name.clone())
    }

    /// Every seat name the client has seen, for a failure message.
    #[must_use]
    pub fn seat_names(&self) -> Vec<String> {
        self.seats
            .iter()
            .filter_map(|record| record.name.clone())
            .collect()
    }

    /// Whether a seat has advertised a pointer capability.
    #[must_use]
    pub fn has_pointer(&self, seat: &WlSeat) -> bool {
        self.seat(seat).is_some_and(|record| record.has_pointer)
    }

    /// Whether a seat has advertised a keyboard capability.
    #[must_use]
    pub fn has_keyboard(&self, seat: &WlSeat) -> bool {
        self.seat(seat).is_some_and(|record| record.has_keyboard)
    }

    /// Every event delivered to one keyboard, in order.
    #[must_use]
    pub fn keyboard_events(&self, keyboard: &WlKeyboard) -> Vec<KeyboardEvent> {
        let id = keyboard.id();
        self.keyboard
            .iter()
            .filter(|(target, _)| *target == id)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// Every key press and release delivered to one keyboard, in order.
    #[must_use]
    pub fn keys(&self, keyboard: &WlKeyboard) -> Vec<(u32, bool)> {
        self.keyboard_events(keyboard)
            .into_iter()
            .filter_map(|event| match event {
                KeyboardEvent::Key { key, pressed } => Some((key, pressed)),
                _ => None,
            })
            .collect()
    }

    /// The last modifier masks the compositor told one keyboard about.
    #[must_use]
    pub fn modifiers(&self, keyboard: &WlKeyboard) -> Option<(u32, u32)> {
        self.keyboard_events(keyboard)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                KeyboardEvent::Modifiers { depressed, locked } => Some((depressed, locked)),
                _ => None,
            })
    }

    /// Every keymap the compositor uploaded to one keyboard, in order.
    ///
    /// The text as the client would read it, so a test can assert that a
    /// keymap was restored to exactly what it was before.
    #[must_use]
    pub fn keymaps(&self, keyboard: &WlKeyboard) -> Vec<String> {
        self.keyboard_events(keyboard)
            .into_iter()
            .filter_map(|event| match event {
                KeyboardEvent::Keymap { text } => Some(text),
                _ => None,
            })
            .collect()
    }

    /// Whether one keyboard currently holds focus on a surface.
    #[must_use]
    pub fn keyboard_focus(&self, keyboard: &WlKeyboard) -> Option<ObjectId> {
        self.keyboard_events(keyboard)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                KeyboardEvent::Enter { surface } => Some(Some(surface)),
                KeyboardEvent::Leave { .. } => Some(None),
                _ => None,
            })
            .flatten()
    }

    /// Every event delivered to one pointer, in order.
    #[must_use]
    pub fn events(&self, pointer: &WlPointer) -> Vec<PointerEvent> {
        let id = pointer.id();
        self.pointer
            .iter()
            .filter(|(target, _)| *target == id)
            .map(|(_, event)| event.clone())
            .collect()
    }

    /// The first pointer enter delivered to one pointer, if one arrived.
    #[must_use]
    pub fn first_enter(&self, pointer: &WlPointer) -> Option<(ObjectId, f64, f64)> {
        self.events(pointer)
            .into_iter()
            .find_map(|event| match event {
                PointerEvent::Enter { surface, x, y, .. } => Some((surface, x, y)),
                _ => None,
            })
    }

    /// The serial of the last enter delivered to one pointer, which is what a
    /// `set_cursor` request has to carry.
    #[must_use]
    pub fn enter_serial(&self, pointer: &WlPointer) -> Option<u32> {
        self.events(pointer)
            .into_iter()
            .rev()
            .find_map(|event| match event {
                PointerEvent::Enter { serial, .. } => Some(serial),
                _ => None,
            })
    }

    /// Every button press and release delivered to one pointer, in order.
    #[must_use]
    pub fn buttons(&self, pointer: &WlPointer) -> Vec<(u32, bool)> {
        self.events(pointer)
            .into_iter()
            .filter_map(|event| match event {
                PointerEvent::Button { button, pressed } => Some((button, pressed)),
                _ => None,
            })
            .collect()
    }

    fn seat(&self, seat: &WlSeat) -> Option<&SeatRecord> {
        let id = seat.id();
        self.seats.iter().find(|record| record.seat == id)
    }

    fn seat_mut(&mut self, seat: &WlSeat) -> &mut SeatRecord {
        let id = seat.id();
        if let Some(index) = self.seats.iter().position(|record| record.seat == id) {
            return &mut self.seats[index];
        }
        self.seats.push(SeatRecord {
            seat: id,
            name: None,
            has_pointer: false,
            has_keyboard: false,
        });
        self.seats
            .last_mut()
            .unwrap_or_else(|| unreachable!("the record was just pushed"))
    }
}

/// What one bound `wl_output` has told the client about itself.
///
/// Two halves, because the protocol sends the properties as separate events and
/// applies them at `done`. A test reading `current` never sees a configuration
/// the compositor is part-way through sending.
#[derive(Debug, Default)]
struct OutputRecord {
    pending: OutputState,
    current: Option<OutputState>,
}

/// One output's configuration, as the client was told it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OutputState {
    /// The current mode's resolution, in pixels.
    pub size: (i32, i32),
    /// The current mode's refresh rate, in millihertz, which is the unit
    /// `wl_output.mode` carries.
    pub refresh: i32,
    /// The physical size in millimetres, from `wl_output.geometry`.
    pub physical: (i32, i32),
    /// The integer scale, which is one until the compositor says otherwise.
    pub scale: i32,
    /// The name, present only from version 4.
    pub name: Option<String>,
    pub description: Option<String>,
}

/// What one bound seat has told the client about itself.
#[derive(Debug)]
struct SeatRecord {
    seat: ObjectId,
    name: Option<String>,
    has_pointer: bool,
    has_keyboard: bool,
}

/// One entry from the registry.
#[derive(Clone, Debug)]
pub struct Global {
    pub name: u32,
    pub interface: String,
    pub version: u32,
}

/// A pointer event as the client received it.
///
/// Coordinates are surface-local, which is the whole point of asserting on
/// them: the compositor is what translates a sink-relative position into the
/// surface's own frame.
#[derive(Clone, Debug, PartialEq)]
pub enum PointerEvent {
    Enter {
        surface: ObjectId,
        x: f64,
        y: f64,
        /// What a `set_cursor` request has to quote back.
        serial: u32,
    },
    Motion {
        x: f64,
        y: f64,
    },
    Button {
        button: u32,
        pressed: bool,
    },
    Leave {
        surface: ObjectId,
    },
    /// `wl_pointer.axis_source`. Recorded as the protocol's own enum, because
    /// what a client does with a scroll turns on whether it came from a notched
    /// wheel or a continuous surface.
    AxisSource {
        source: wl_pointer::AxisSource,
    },
    /// `wl_pointer.axis`, the one axis event every version receives.
    Axis {
        axis: ScrollAxis,
        value: f64,
    },
    /// `wl_pointer.axis_discrete`, which smithay synthesises from the v120
    /// count for a client older than version 8.
    AxisDiscrete {
        axis: ScrollAxis,
        steps: i32,
    },
}

/// The axis a `wl_pointer` axis event named, or nothing for one from a protocol
/// version this client does not know.
fn scroll_axis(axis: wayland_client::WEnum<wl_pointer::Axis>) -> Option<ScrollAxis> {
    match axis {
        wayland_client::WEnum::Value(wl_pointer::Axis::VerticalScroll) => {
            Some(ScrollAxis::Vertical)
        }
        wayland_client::WEnum::Value(wl_pointer::Axis::HorizontalScroll) => {
            Some(ScrollAxis::Horizontal)
        }
        _ => None,
    }
}

impl Dispatch<WlRegistry, ()> for Driver {
    fn event(
        state: &mut Self,
        registry: &WlRegistry,
        event: wl_registry::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        state.registry = Some(registry.clone());
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } => state.globals.push(Global {
                name,
                interface,
                version,
            }),
            wl_registry::Event::GlobalRemove { name } => {
                state.globals.retain(|global| global.name != name);
            }
            _ => {}
        }
    }
}

/// `wl_surface.enter` and `wl_surface.leave` are what a client learns its
/// output from, and `preferred_buffer_scale` is what it learns the whole-number
/// scale from, so the surface cannot be a no-op the way the rest of its events
/// are.
impl Dispatch<WlSurface, ()> for Driver {
    fn event(
        state: &mut Self,
        surface: &WlSurface,
        event: wl_surface::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let id = surface.id();

        match event {
            wl_surface::Event::Enter { output } => {
                entry_for(&mut state.surface_outputs, id).push(output.id());
            }
            wl_surface::Event::Leave { output } => {
                entry_for(&mut state.surface_outputs, id).retain(|held| held != &output.id());
            }
            wl_surface::Event::PreferredBufferScale { factor } => {
                entry_for(&mut state.surface_buffer_scales, id).push(factor);
            }
            _ => {}
        }
    }
}

impl Dispatch<WpFractionalScaleV1, ()> for Driver {
    fn event(
        state: &mut Self,
        scale: &WpFractionalScaleV1,
        event: wp_fractional_scale_v1::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wp_fractional_scale_v1::Event::PreferredScale { scale: preferred } = event {
            entry_for(&mut state.fractional_scales, scale.id()).push(preferred);
        }
    }
}

/// The list an object's events accumulate into, appending an empty one on the
/// first sighting.
///
/// A `Vec` of pairs rather than a map for the reason [`Driver`]'s other keyed
/// records are: the counts are in the single digits, and a test reading one out
/// wants the order it arrived in.
fn entry_for<T>(records: &mut Vec<(ObjectId, Vec<T>)>, id: ObjectId) -> &mut Vec<T> {
    if let Some(index) = records.iter().position(|(target, _)| *target == id) {
        return &mut records[index].1;
    }
    records.push((id, Vec::new()));
    let last = records.len() - 1;
    &mut records[last].1
}

impl Dispatch<WlOutput, ()> for Driver {
    fn event(
        state: &mut Self,
        output: &WlOutput,
        event: wl_output::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let id = output.id();
        let pending = match state.outputs.iter_mut().find(|(target, _)| *target == id) {
            Some((_, pending)) => pending,
            None => {
                state.outputs.push((id, OutputRecord::default()));
                let last = state.outputs.len() - 1;
                &mut state.outputs[last].1
            }
        };

        match event {
            wl_output::Event::Geometry {
                physical_width,
                physical_height,
                ..
            } => {
                pending.pending.physical = (physical_width, physical_height);
            }
            wl_output::Event::Mode {
                flags,
                width,
                height,
                refresh,
            } => {
                if flags
                    .into_result()
                    .is_ok_and(|flags| flags.contains(wl_output::Mode::Current))
                {
                    pending.pending.size = (width, height);
                    pending.pending.refresh = refresh;
                }
            }
            wl_output::Event::Scale { factor } => pending.pending.scale = factor,
            wl_output::Event::Name { name } => pending.pending.name = Some(name),
            wl_output::Event::Description { description } => {
                pending.pending.description = Some(description);
            }
            wl_output::Event::Done => pending.current = Some(pending.pending.clone()),
            _ => {}
        }
    }
}

impl Dispatch<XdgWmBase, ()> for Driver {
    fn event(
        _state: &mut Self,
        wm_base: &XdgWmBase,
        event: xdg_wm_base::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        // A client that does not pong is disconnected as unresponsive.
        if let xdg_wm_base::Event::Ping { serial } = event {
            wm_base.pong(serial);
        }
    }
}

impl Dispatch<XdgSurface, ()> for Driver {
    fn event(
        state: &mut Self,
        xdg_surface: &XdgSurface,
        event: xdg_surface::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            let id = xdg_surface.id();
            state.configure_serials.push(serial);
            match state
                .configures
                .iter_mut()
                .find(|(target, _)| *target == id)
            {
                Some((_, recorded)) => *recorded = serial,
                None => state.configures.push((id, serial)),
            }
        }
    }
}

impl Dispatch<XdgToplevel, ()> for Driver {
    fn event(
        state: &mut Self,
        _toplevel: &XdgToplevel,
        event: xdg_toplevel::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            xdg_toplevel::Event::Configure { width, height, .. } => {
                state.toplevel_size = Some((width, height));
            }
            xdg_toplevel::Event::Close => state.closed = true,
            _ => {}
        }
    }
}

impl Dispatch<WlSeat, ()> for Driver {
    fn event(
        state: &mut Self,
        seat: &WlSeat,
        event: wl_seat::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            wl_seat::Event::Capabilities {
                capabilities: wayland_client::WEnum::Value(capabilities),
            } => {
                let record = state.seat_mut(seat);
                record.has_pointer = capabilities.contains(Capability::Pointer);
                record.has_keyboard = capabilities.contains(Capability::Keyboard);
            }
            wl_seat::Event::Name { name } => state.seat_mut(seat).name = Some(name),
            _ => {}
        }
    }
}

impl Dispatch<WlPointer, ()> for Driver {
    fn event(
        state: &mut Self,
        pointer: &WlPointer,
        event: wl_pointer::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let recorded = match event {
            wl_pointer::Event::Enter {
                surface,
                surface_x,
                surface_y,
                serial,
            } => PointerEvent::Enter {
                surface: surface.id(),
                x: surface_x,
                y: surface_y,
                serial,
            },
            wl_pointer::Event::Motion {
                surface_x,
                surface_y,
                ..
            } => PointerEvent::Motion {
                x: surface_x,
                y: surface_y,
            },
            wl_pointer::Event::Button { button, state, .. } => PointerEvent::Button {
                button,
                pressed: state == wayland_client::WEnum::Value(ButtonState::Pressed),
            },
            wl_pointer::Event::Leave { surface, .. } => PointerEvent::Leave {
                surface: surface.id(),
            },
            wl_pointer::Event::AxisSource { axis_source } => {
                let wayland_client::WEnum::Value(source) = axis_source else {
                    return;
                };
                PointerEvent::AxisSource { source }
            }
            wl_pointer::Event::Axis { axis, value, .. } => {
                let Some(axis) = scroll_axis(axis) else {
                    return;
                };
                PointerEvent::Axis { axis, value }
            }
            wl_pointer::Event::AxisDiscrete { axis, discrete } => {
                let Some(axis) = scroll_axis(axis) else {
                    return;
                };
                PointerEvent::AxisDiscrete {
                    axis,
                    steps: discrete,
                }
            }
            // The frame and stop refinements say nothing these tests assert on.
            _ => return,
        };
        state.pointer.push((pointer.id(), recorded));
    }
}

/// A keyboard event as the client received it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyboardEvent {
    /// The layout the compositor uploaded, read back out of the mapped file.
    Keymap {
        text: String,
    },
    Enter {
        surface: ObjectId,
    },
    Leave {
        surface: ObjectId,
    },
    /// The key in evdev numbering, which is what `wl_keyboard.key` carries.
    Key {
        key: u32,
        pressed: bool,
    },
    Modifiers {
        depressed: u32,
        locked: u32,
    },
}

impl Dispatch<WlKeyboard, ()> for Driver {
    fn event(
        state: &mut Self,
        keyboard: &WlKeyboard,
        event: wl_keyboard::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        let recorded = match event {
            wl_keyboard::Event::Keymap { fd, size, .. } => KeyboardEvent::Keymap {
                text: read_keymap(&fd, size),
            },
            wl_keyboard::Event::Enter { surface, .. } => KeyboardEvent::Enter {
                surface: surface.id(),
            },
            wl_keyboard::Event::Leave { surface, .. } => KeyboardEvent::Leave {
                surface: surface.id(),
            },
            wl_keyboard::Event::Key { key, state, .. } => KeyboardEvent::Key {
                key,
                pressed: state == wayland_client::WEnum::Value(KeyState::Pressed),
            },
            wl_keyboard::Event::Modifiers {
                mods_depressed,
                mods_locked,
                ..
            } => KeyboardEvent::Modifiers {
                depressed: mods_depressed,
                locked: mods_locked,
            },
            // `repeat_info` is policy the client applies itself and says
            // nothing about what was delivered.
            _ => return,
        };
        state.keyboard.push((keyboard.id(), recorded));
    }
}

/// The keymap the compositor sent, as the client reads it.
///
/// The size the protocol carries includes the terminating NUL, which is not
/// part of the text; a comparison against the compositor's own string would
/// otherwise never match.
fn read_keymap(fd: &OwnedFd, size: u32) -> String {
    let length = usize::try_from(size).expect("a keymap size that fits in memory");
    let mut file = std::fs::File::from(
        fd.try_clone()
            .expect("the keymap descriptor can be duplicated"),
    );
    // The descriptor is duplicated rather than owned, so it shares its offset
    // with the one the compositor kept: a second keymap event would otherwise
    // read from where the first one stopped.
    file.seek(SeekFrom::Start(0))
        .expect("the keymap file is seekable");
    let mut bytes = vec![0_u8; length];
    file.read_exact(&mut bytes)
        .expect("the keymap file holds the bytes the compositor announced");

    String::from_utf8(
        bytes
            .split(|byte| *byte == 0)
            .next()
            .expect("split always yields at least one piece")
            .to_vec(),
    )
    .expect("a keymap is text")
}

impl Dispatch<WlBuffer, ()> for Driver {
    fn event(
        state: &mut Self,
        buffer: &WlBuffer,
        event: wl_buffer::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wl_buffer::Event::Release = event {
            state.released.push(buffer.id());
        }
    }
}

delegate_noop!(Driver: ignore WlCompositor);
delegate_noop!(Driver: ignore WlShm);
delegate_noop!(Driver: ignore WlShmPool);
delegate_noop!(Driver: ignore ZwpLinuxDmabufV1);
delegate_noop!(Driver: ignore ZwpLinuxBufferParamsV1);
delegate_noop!(Driver: ignore WlRegion);
delegate_noop!(Driver: ignore WlSubcompositor);
delegate_noop!(Driver: ignore WpFractionalScaleManagerV1);
delegate_noop!(Driver: ignore WlSubsurface);
delegate_noop!(Driver: ignore XdgPositioner);
// An `xdg_popup` carries its own configure and a `popup_done`; neither says
// anything about where input lands, which is what these tests are about.
delegate_noop!(Driver: ignore XdgPopup);

/// A size as the protocol counts it, which is in signed pixels.
///
/// A size that does not fit is a test asking for something no client could ask
/// for.
fn protocol_size(size: PixelSize) -> (i32, i32) {
    (
        i32::try_from(size.width).expect("a width the protocol can carry"),
        i32::try_from(size.height).expect("a height the protocol can carry"),
    )
}

/// An anonymous file of `length` bytes, to back a `wl_shm` pool.
///
/// A `memfd` rather than a file under `/tmp`: a test that touches the
/// filesystem is one that can collide with another test, leak on a failure, or
/// fail on a read-only root. Nothing here needs a name.
fn anonymous_file(length: i64) -> OwnedFd {
    let name = c"lunette-test-shm";
    // SAFETY: `name` is a valid NUL-terminated string that outlives the call,
    // and `memfd_create` returns an owned descriptor or -1.
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
