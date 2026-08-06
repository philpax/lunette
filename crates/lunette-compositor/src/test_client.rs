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

use std::{
    io,
    os::{
        fd::{AsFd, AsRawFd, FromRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    time::Instant,
};

use wayland_client::{
    Connection, Dispatch, EventQueue, Proxy, QueueHandle,
    backend::{ObjectId, WaylandError},
    delegate_noop,
    protocol::{
        wl_buffer::{self, WlBuffer},
        wl_compositor::WlCompositor,
        wl_pointer::{self, ButtonState, WlPointer},
        wl_registry::{self, WlRegistry},
        wl_seat::{self, Capability, WlSeat},
        wl_shm::{self, WlShm},
        wl_shm_pool::WlShmPool,
        wl_surface::WlSurface,
    },
};
use wayland_protocols::{
    wp::linux_dmabuf::zv1::client::{
        zwp_linux_buffer_params_v1::{Flags as DmabufFlags, ZwpLinuxBufferParamsV1},
        zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1,
    },
    xdg::shell::client::{
        xdg_surface::{self, XdgSurface},
        xdg_toplevel::{self, XdgToplevel},
        xdg_wm_base::{self, XdgWmBase},
    },
};

use crate::{
    protocol::PixelSize,
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
    pointer: Option<WlPointer>,
    /// Every buffer this client created, held so none is destroyed early. A
    /// destroyed `wl_buffer` cannot be released, and release is what the
    /// retention tests are about.
    buffers: Vec<WlBuffer>,
}

impl TestClient {
    /// Connects over a socket pair and binds the globals a toplevel needs.
    pub fn connect(compositor: &mut TestCompositor) -> Self {
        let (stream, _client) = compositor.connect();
        let mut client = Self::from_socket(stream);
        client.settle(compositor, |driver| !driver.globals.is_empty());
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
            pointer: None,
            buffers: Vec::new(),
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
        self.queue.flush().expect("the client's requests are sent");
        compositor.step();

        if let Some(guard) = self.queue.prepare_read() {
            match guard.read() {
                Ok(_) => {}
                // Nothing arrived this round. The socket is non-blocking
                // precisely so this is an answer rather than a wait.
                Err(WaylandError::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => panic!("the client could not read from the compositor: {error}"),
            }
        }

        self.queue
            .dispatch_pending(&mut self.driver)
            .expect("the client's own event handlers do not fail");
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

        self.settle(compositor, |driver| driver.configure_serial.is_some());
        self.acknowledge_configure();
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
        let handle = self.queue.handle();
        let dmabuf = self.bind::<ZwpLinuxDmabufV1>(3);

        let width = i32::try_from(size.width).expect("a width the protocol can carry");
        let height = i32::try_from(size.height).expect("a height the protocol can carry");
        let stride = size.width * 4;
        let memory = anonymous_file(i64::from(stride) * i64::from(height));

        let params = dmabuf.create_params(&handle, ());
        // `DRM_FORMAT_MOD_LINEAR` is zero in both halves.
        params.add(memory.as_fd(), 0, 0, stride, 0, 0);
        let buffer =
            params.create_immed(width, height, ARGB8888, DmabufFlags::empty(), &handle, ());
        params.destroy();

        let id = buffer.id();
        let surface = self.surface.clone().expect("a toplevel was opened first");
        self.attach_to(compositor, &surface, &buffer, width, height);
        self.buffers.push(buffer);
        id
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

    /// Binds the seat's pointer, so a test can observe what input reaches this
    /// client.
    ///
    /// Waits for the capability rather than assuming it: asking a seat for a
    /// pointer it has not advertised is a protocol error.
    pub fn open_pointer(&mut self, compositor: &mut TestCompositor) {
        let handle = self.queue.handle();
        let seat = self.bind::<WlSeat>(5);
        self.settle(compositor, |driver| driver.has_pointer);
        self.pointer = Some(seat.get_pointer(&handle, ()));
        self.settle_quiet(compositor);
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

    fn acknowledge_configure(&mut self) {
        let (Some(xdg_surface), Some(serial)) =
            (self.xdg_surface.as_ref(), self.driver.configure_serial)
        else {
            panic!("the compositor did not configure the toplevel");
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
    pub configure_serial: Option<u32>,
    pub toplevel_size: Option<(i32, i32)>,
    pub closed: bool,
    pub has_pointer: bool,
    /// Every pointer event delivered, in order.
    pub pointer: Vec<PointerEvent>,
    /// Every buffer the compositor released, in order. A client may reuse a
    /// buffer only once it appears here.
    pub released: Vec<ObjectId>,
}

impl Driver {
    /// The first pointer enter, if one arrived.
    #[must_use]
    pub fn first_enter(&self) -> Option<(&ObjectId, f64, f64)> {
        self.pointer.iter().find_map(|event| match event {
            PointerEvent::Enter { surface, x, y } => Some((surface, *x, *y)),
            _ => None,
        })
    }

    /// Every button press and release, in order.
    #[must_use]
    pub fn buttons(&self) -> Vec<(u32, bool)> {
        self.pointer
            .iter()
            .filter_map(|event| match event {
                PointerEvent::Button { button, pressed } => Some((*button, *pressed)),
                _ => None,
            })
            .collect()
    }
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
    Enter { surface: ObjectId, x: f64, y: f64 },
    Motion { x: f64, y: f64 },
    Button { button: u32, pressed: bool },
    Leave { surface: ObjectId },
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
        _xdg_surface: &XdgSurface,
        event: xdg_surface::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            state.configure_serial = Some(serial);
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
        _seat: &WlSeat,
        event: wl_seat::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities {
            capabilities: wayland_client::WEnum::Value(capabilities),
        } = event
        {
            state.has_pointer = capabilities.contains(Capability::Pointer);
        }
    }
}

impl Dispatch<WlPointer, ()> for Driver {
    fn event(
        state: &mut Self,
        _pointer: &WlPointer,
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
                ..
            } => PointerEvent::Enter {
                surface: surface.id(),
                x: surface_x,
                y: surface_y,
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
            // Axis, frame, and the source and stop refinements say nothing
            // about routing, which is what these tests are about.
            _ => return,
        };
        state.pointer.push(recorded);
    }
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
delegate_noop!(Driver: ignore WlSurface);
delegate_noop!(Driver: ignore WlShm);
delegate_noop!(Driver: ignore WlShmPool);
delegate_noop!(Driver: ignore ZwpLinuxDmabufV1);
delegate_noop!(Driver: ignore ZwpLinuxBufferParamsV1);

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
