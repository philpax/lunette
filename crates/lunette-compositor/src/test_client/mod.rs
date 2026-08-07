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
//! What the client learned from the compositor is [`Driver`], in `driver.rs`,
//! together with every `Dispatch` implementation that records it. This file is
//! the sending half: connecting, binding globals, opening surfaces, and driving
//! the pair forward.
//!
//! Linux-only: the shared-memory buffer is a `memfd`. An anonymous file rather
//! than a temporary one, so a test writes nothing to the filesystem and cannot
//! collide with another test over a name.

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

/// The protocol's own scroll-source enum, re-exported so a test can name the
/// value it expects without depending on `wayland-client` itself.
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
    },
    xdg::shell::client::{
        xdg_popup::XdgPopup,
        xdg_positioner::{self},
        xdg_surface::XdgSurface,
        xdg_toplevel::XdgToplevel,
        xdg_wm_base::XdgWmBase,
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

/// lunette's content type as the protocol spells it, so a test names the domain
/// type and the wire form stays here.
fn protocol_content_type(content_type: ContentType) -> wp_content_type_v1::Type {
    match content_type {
        ContentType::None => wp_content_type_v1::Type::None,
        ContentType::Photo => wp_content_type_v1::Type::Photo,
        ContentType::Video => wp_content_type_v1::Type::Video,
        ContentType::Game => wp_content_type_v1::Type::Game,
    }
}

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
    /// The `wp_content_type_v1` of each surface that has one, by surface. One
    /// per surface is all the protocol allows — a second `get_surface_content
    /// _type` is a protocol error — and held so none is destroyed early, since
    /// destroying one resets its surface's content type to none.
    content_types: Vec<(ObjectId, WpContentTypeV1)>,
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
            content_types: Vec::new(),
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

    /// Tells the compositor what this surface is drawing, and commits.
    ///
    /// `wp_content_type_v1` is double-buffered like everything else a client
    /// sets, so the value takes effect at the commit rather than at the
    /// request; a caller establishing that passes `commit: false` and commits
    /// itself.
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

    /// The surface's `wp_content_type_v1`, creating it on first use.
    ///
    /// One per surface: a second `get_surface_content_type` for the same
    /// surface is a protocol error, so a client changing its mind reuses the
    /// object it already has.
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

    /// Commits a surface without attaching anything new to it.
    pub fn commit(&mut self, compositor: &mut TestCompositor, surface: &WlSurface) {
        surface.commit();
        self.settle_quiet(compositor);
    }

    /// Asks for a frame callback on a surface and commits, which is what a
    /// client does at the end of every frame it draws.
    ///
    /// Flushes but does not settle. Whether the compositor answers, and after
    /// how much of its clock, is what a pacing test is asserting about, so
    /// running the compositor here would decide the answer before the test
    /// could ask for it.
    pub fn request_frame(&mut self, surface: &WlSurface) {
        let handle = self.queue.handle();
        surface.frame(&handle, surface.id());
        surface.commit();
        drop(self.queue.flush());
    }

    /// The timestamp of every frame callback a surface has been answered, in
    /// order.
    #[must_use]
    pub fn frames(&self, surface: &WlSurface) -> &[u32] {
        self.driver.frames(&surface.id())
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
