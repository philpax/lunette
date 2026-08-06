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

#![expect(
    clippy::expect_used,
    reason = "test scaffolding: a failed expectation is how a test reports a failure, and this \
              module is gated behind `cfg(test)` or the `test-fakes` feature"
)]

use std::{io, os::unix::net::UnixStream, time::Instant};

use wayland_client::{
    Connection, Dispatch, EventQueue, Proxy, QueueHandle,
    backend::WaylandError,
    delegate_noop,
    protocol::{
        wl_buffer::WlBuffer,
        wl_compositor::WlCompositor,
        wl_registry::{self, WlRegistry},
        wl_shm::{self, WlShm},
        wl_shm_pool::WlShmPool,
        wl_surface::WlSurface,
    },
};
use wayland_protocols::xdg::shell::client::{
    xdg_surface::{self, XdgSurface},
    xdg_toplevel::{self, XdgToplevel},
    xdg_wm_base::{self, XdgWmBase},
};

use crate::testing::{DEADLINE, TestCompositor};

/// A connected client and the queue its events arrive on.
pub(crate) struct TestClient {
    connection: Connection,
    queue: EventQueue<Driver>,
    driver: Driver,
    surface: Option<WlSurface>,
    xdg_surface: Option<XdgSurface>,
    toplevel: Option<XdgToplevel>,
}

impl TestClient {
    /// Connects over a socket pair and binds the globals a toplevel needs.
    pub(crate) fn connect(compositor: &mut TestCompositor) -> Self {
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
        }
    }

    /// Every global the compositor advertised, by interface name, sorted.
    pub(crate) fn globals(&self) -> Vec<String> {
        let mut names: Vec<String> = self
            .driver
            .globals
            .iter()
            .map(|global| global.interface.clone())
            .collect();
        names.sort();
        names
    }

    /// Runs both ends until `ready` holds, failing at the deadline.
    pub(crate) fn settle(
        &mut self,
        compositor: &mut TestCompositor,
        ready: impl Fn(&Driver) -> bool,
    ) {
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
    pub(crate) fn settle_quiet(&mut self, compositor: &mut TestCompositor) {
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
    pub(crate) fn open_toplevel(&mut self, compositor: &mut TestCompositor) {
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

    /// Attaches a shared-memory buffer and commits, which is what maps the
    /// window.
    pub(crate) fn attach_buffer(
        &mut self,
        compositor: &mut TestCompositor,
        width: i32,
        height: i32,
    ) {
        let handle = self.queue.handle();
        let shm = self.bind::<WlShm>(1);

        let stride = width * 4;
        let length = stride * height;
        let file = tempfile::tempfile().expect("a temporary file can be made");
        file.set_len(u64::try_from(length).expect("a non-negative length"))
            .expect("the file can be sized");

        let pool = shm.create_pool(file.as_fd_borrowed(), length, &handle, ());
        let buffer = pool.create_buffer(
            0,
            width,
            height,
            stride,
            wl_shm::Format::Argb8888,
            &handle,
            (),
        );

        let surface = self.surface.clone().expect("a toplevel was opened first");
        surface.attach(Some(&buffer), 0, 0);
        surface.damage(0, 0, width, height);
        surface.commit();

        self.settle_quiet(compositor);
    }

    /// Sets the toplevel's title.
    pub(crate) fn set_title(&mut self, compositor: &mut TestCompositor, title: &str) {
        self.toplevel
            .as_ref()
            .expect("a toplevel was opened first")
            .set_title(title.to_owned());
        self.settle_quiet(compositor);
    }

    /// Destroys the toplevel, as a client closing its window would.
    pub(crate) fn close_toplevel(&mut self, compositor: &mut TestCompositor) {
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
    pub(crate) fn disconnect(self, compositor: &mut TestCompositor) {
        drop(self.connection);
        drop(self.queue);
        for _ in 0..8 {
            compositor.step();
        }
    }
}

/// What the client learned from the compositor.
#[derive(Debug, Default)]
pub(crate) struct Driver {
    pub(crate) globals: Vec<Global>,
    registry: Option<WlRegistry>,
    pub(crate) configure_serial: Option<u32>,
    pub(crate) toplevel_size: Option<(i32, i32)>,
    pub(crate) closed: bool,
}

/// One entry from the registry.
#[derive(Clone, Debug)]
pub(crate) struct Global {
    pub(crate) name: u32,
    pub(crate) interface: String,
    pub(crate) version: u32,
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

delegate_noop!(Driver: ignore WlCompositor);
delegate_noop!(Driver: ignore WlSurface);
delegate_noop!(Driver: ignore WlShm);
delegate_noop!(Driver: ignore WlShmPool);
delegate_noop!(Driver: ignore WlBuffer);

/// Borrows a file's descriptor for a protocol request.
trait AsFdBorrowed {
    fn as_fd_borrowed(&self) -> std::os::fd::BorrowedFd<'_>;
}

impl AsFdBorrowed for std::fs::File {
    fn as_fd_borrowed(&self) -> std::os::fd::BorrowedFd<'_> {
        std::os::fd::AsFd::as_fd(self)
    }
}
