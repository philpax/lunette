//! Linux-only: reads the host compositor's `wl_output`s over a Wayland socket.
//!
//! This is where a [`Roster`] comes from. Nothing else in the crate produces
//! one: the portal reports streams, not monitors, and correlating a stream to a
//! monitor (`crate::portal::correlation`) needs the monitors to already be
//! known.
//!
//! # Why not `wlx_capture::wayland::WlxClient`
//!
//! Because it connects through `WAYLAND_DISPLAY` itself and takes no socket
//! parameter, and `CONTRIBUTING.md` forbids a library reading the environment.
//! That is not a stylistic objection here: lunette's entry point overwrites
//! `WAYLAND_DISPLAY` with lunette's *own* socket before any other thread exists,
//! so a component that reads the variable later would enumerate lunette's
//! compositor rather than the host's, and find nothing.
//!
//! So the enumeration is written directly against `wayland-client`, which is
//! already in the tree and already used the same way by
//! [`crate::hid::wl_virtual`]: the socket arrives as a path, and the entry point
//! is the only thing that resolves it. It also costs nothing extra —
//! `WlxClient` carries a dmabuf and screencopy client this has no use for.
//!
//! # Where a connector name comes from
//!
//! `wl_output.name`, added in `wl_output` version 4, whose documented content is
//! the connector name — `DP-1`, `HDMI-A-1`, `eDP-1`. Both wlroots and mutter
//! send it. That is a strictly better source than the portal's `mapping_id`,
//! which `docs/decisions.md` records as unusable: `mapping_id` is a real
//! connector name on xdg-desktop-portal-wlr only, a random UUID on GNOME, and
//! absent on KDE. It still passes [`ConnectorName::parse`], because a
//! compositor is free to put anything there and a name that is not a connector
//! must not be stored as though it were one.
//!
//! # Logical geometry, and the fallback
//!
//! `zxdg_output_v1` reports the logical position and size directly, which is the
//! space the portal reports a stream's `position` and `size` in and the space a
//! pointer is placed in. A compositor without `zxdg_output_manager_v1` is
//! handled by deriving the size from `wl_output.mode` and `wl_output.scale`,
//! swapping the axes when the transform rotates. The derived form is integer
//! division and so is wrong on a fractional scale; every compositor lunette
//! targets implements `zxdg_output_manager_v1`, and the fallback exists so that
//! one that does not still produces monitors rather than none.
//!
//! # Nothing here blocks after startup
//!
//! [`OutputWatcher::connect`] performs two round trips, because a client cannot
//! know what exists until the compositor has answered. After that,
//! [`OutputWatcher::poll`] reads only what has already arrived: the descriptor
//! is polled with a zero timeout and the guard dropped when nothing is there, so
//! a frame is never held up by the host compositor.

mod state;
#[cfg(test)]
mod tests;

use std::{
    error::Error,
    fmt, io,
    os::{fd::AsRawFd, unix::net::UnixStream},
    path::{Path, PathBuf},
};

use tracing::{debug, info, warn};
use wayland_client::{
    ConnectError, Connection, Dispatch, DispatchError, EventQueue, Proxy, QueueHandle,
    backend::WaylandError,
    protocol::{
        wl_output::{self, Mode, WlOutput},
        wl_registry::{self, WlRegistry},
    },
};
use wayland_protocols::xdg::xdg_output::zv1::client::{
    zxdg_output_manager_v1::ZxdgOutputManagerV1,
    zxdg_output_v1::{self, ZxdgOutputV1},
};

pub use crate::monitor::outputs::state::{HostOutputs, OutputId};
use crate::monitor::{
    geometry::{LogicalPosition, LogicalSize, PixelExtent, SurfaceTransform},
    roster::Roster,
};

/// The host compositor's outputs, kept up to date as they change.
///
/// Holds a live connection rather than enumerating once, so that a monitor
/// plugged in, unplugged, or moved while lunette runs is seen. The frame loop
/// calls [`Self::poll`] once a frame and hands the roster it returns to the
/// mirror lifecycle and the pointer mapping.
pub struct OutputWatcher {
    connection: Connection,
    queue: EventQueue<Registry>,
    registry: Registry,
    /// Set once the connection has failed. A failed watcher reports nothing
    /// further rather than logging the same disconnection every frame.
    finished: bool,
}

impl OutputWatcher {
    /// Connects to the host compositor and enumerates what it has.
    ///
    /// `socket` is a path rather than something read from `WAYLAND_DISPLAY`,
    /// for the reason the module note gives: by the time anything here runs, the
    /// entry point has already pointed that variable at lunette's own socket.
    ///
    /// Two round trips, and they block. The first brings the registry's globals
    /// in, and the second brings in the events of the outputs bound during the
    /// first. This runs once, before the frame loop exists.
    ///
    /// # Errors
    ///
    /// [`OutputError::Socket`] when the path cannot be reached, which is what a
    /// machine with no Wayland session sees. [`OutputError::Connect`] and
    /// [`OutputError::Exchange`] when the compositor is there but the exchange
    /// fails.
    pub fn connect(socket: &Path) -> Result<Self, OutputError> {
        let stream = UnixStream::connect(socket).map_err(|source| OutputError::Socket {
            path: socket.to_path_buf(),
            source,
        })?;
        debug!(socket = %socket.display(), "connecting to the host compositor");
        Self::from_stream(stream)
    }

    /// Enumerates over a connection that is already open.
    ///
    /// The seam [`Self::connect`] is built on, and what an integration test uses
    /// to point the enumeration at a compositor reached over a socket pair
    /// rather than a path. The round trips block, so a caller whose compositor
    /// runs on the same thread has to put one of the two on another.
    ///
    /// # Errors
    ///
    /// As [`Self::connect`], minus the case of opening the socket.
    pub fn from_stream(stream: UnixStream) -> Result<Self, OutputError> {
        let connection = Connection::from_socket(stream).map_err(OutputError::Connect)?;

        let mut queue = connection.new_event_queue();
        let handle = queue.handle();
        connection.display().get_registry(&handle, ());

        let mut registry = Registry::default();
        for _ in 0..2 {
            queue
                .roundtrip(&mut registry)
                .map_err(OutputError::Protocol)?;
        }

        info!(
            outputs = registry.outputs.len(),
            logical_geometry = registry.manager.is_some(),
            "read the host compositor's outputs",
        );

        Ok(Self {
            connection,
            queue,
            registry,
            finished: false,
        })
    }

    /// The outputs as they were last read.
    #[must_use]
    pub const fn outputs(&self) -> &HostOutputs {
        &self.registry.outputs
    }

    /// Whether `zxdg_output_manager_v1` is available, so logical geometry is
    /// reported rather than derived.
    #[must_use]
    pub const fn has_logical_geometry(&self) -> bool {
        self.registry.manager.is_some()
    }

    /// Reads whatever has already arrived, and reports a new roster if anything
    /// changed.
    ///
    /// Never waits. The descriptor is polled with a zero timeout, so a frame is
    /// not held up by the host compositor, and `None` — nothing changed — is the
    /// answer on almost every frame.
    ///
    /// A connection that has failed answers `None` for the rest of the session.
    /// The failure is not recoverable: the host session has ended, and the
    /// monitors lunette knew about are gone with it.
    pub fn poll(&mut self) -> Option<Roster> {
        if self.finished {
            return None;
        }

        if let Err(error) = self.pump() {
            warn!(
                %error,
                "the host compositor's outputs can no longer be read, so lunette will keep the \
                 monitors it last saw",
            );
            self.finished = true;
            return None;
        }

        self.registry
            .outputs
            .take_changed()
            .then(|| self.registry.outputs.roster())
    }

    /// Flushes lunette's requests and dispatches whatever has already arrived.
    fn pump(&mut self) -> Result<(), OutputError> {
        self.queue.flush().map_err(OutputError::Exchange)?;

        // `prepare_read` answers `None` when the queue still holds undispatched
        // events, which is the case where there is nothing to read anyway.
        if let Some(guard) = self.connection.prepare_read()
            && readable(self.connection.backend().poll_fd().as_raw_fd())
        {
            guard.read().map_err(OutputError::Exchange)?;
        }

        self.queue
            .dispatch_pending(&mut self.registry)
            .map_err(OutputError::Protocol)?;
        Ok(())
    }
}

impl fmt::Debug for OutputWatcher {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OutputWatcher")
            .field("outputs", &self.registry.outputs.len())
            .field("finished", &self.finished)
            .finish_non_exhaustive()
    }
}

/// Why the host compositor's outputs could not be read.
#[derive(Debug)]
pub enum OutputError {
    Socket {
        path: PathBuf,
        source: io::Error,
    },
    Connect(ConnectError),
    /// The connection failed while reading or writing, which is what the host
    /// session ending looks like.
    Exchange(WaylandError),
    /// The compositor sent something that does not parse, or lunette sent
    /// something it refused.
    Protocol(DispatchError),
}

impl fmt::Display for OutputError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("host outputs: ")?;
        match self {
            Self::Socket { path, .. } => write!(
                f,
                "the host compositor's socket at {} could not be opened",
                path.display()
            ),
            Self::Connect(_) => f.write_str("the host compositor refused the connection"),
            Self::Exchange(_) => f.write_str("the connection to the host compositor failed"),
            Self::Protocol(_) => {
                f.write_str("the exchange with the host compositor did not complete")
            }
        }
    }
}

impl Error for OutputError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Socket { source, .. } => Some(source),
            Self::Connect(cause) => Some(cause),
            Self::Exchange(cause) => Some(cause),
            Self::Protocol(cause) => Some(cause),
        }
    }
}

/// The `wl_output` version lunette asks for.
///
/// Four is where `wl_output.name` arrives, which is the connector name and the
/// whole reason to bind above the minimum. A compositor offering less is bound
/// at what it offers and simply reports no connector.
const WANTED_OUTPUT_VERSION: u32 = 4;

/// The `zxdg_output_manager_v1` version lunette asks for.
///
/// Three, where `zxdg_output_v1.name` and `.description` are deprecated in
/// favour of `wl_output`'s. Nothing here reads either, so the version is asked
/// for only so a compositor need not send them.
const WANTED_XDG_OUTPUT_VERSION: u32 = 3;

/// Whether a descriptor has something to read, right now.
///
/// A zero-timeout `poll`, which is what makes [`OutputWatcher::poll`] able to
/// use `wayland-client`'s blocking read without ever blocking on it. The
/// alternative — putting the socket into non-blocking mode behind the library's
/// back — would also break the round trips [`OutputWatcher::connect`] performs.
fn readable(descriptor: i32) -> bool {
    let mut fds = libc::pollfd {
        fd: descriptor,
        events: libc::POLLIN,
        revents: 0,
    };

    // SAFETY: `fds` is a single valid `pollfd` for the duration of the call, and
    // the count matches. A zero timeout means the call returns immediately.
    let ready = unsafe { libc::poll(&raw mut fds, 1, 0) };
    ready > 0
}

/// The dispatch state: what the registry has announced, and what it was bound to.
#[derive(Default)]
struct Registry {
    outputs: HostOutputs,
    /// The bound `wl_output`s, so an output withdrawn from the registry can be
    /// released and its `zxdg_output_v1` destroyed with it.
    bound: Vec<Bound>,
    manager: Option<ZxdgOutputManagerV1>,
}

impl Registry {
    /// Creates the `zxdg_output_v1` for every output that does not have one.
    ///
    /// Called both when an output is bound and when the manager arrives, because
    /// the registry announces globals in whichever order it likes and the two
    /// orders need the same outcome.
    fn attach_logical_geometry(&mut self, handle: &QueueHandle<Self>) {
        let Some(manager) = &self.manager else {
            return;
        };

        for bound in &mut self.bound {
            if bound.logical.is_none() {
                bound.logical = Some(manager.get_xdg_output(&bound.output, handle, bound.id));
            }
        }
    }
}

/// One bound output, and the logical-geometry object over it.
struct Bound {
    id: OutputId,
    output: WlOutput,
    logical: Option<ZxdgOutputV1>,
}

impl Dispatch<WlRegistry, ()> for Registry {
    fn event(
        state: &mut Self,
        registry: &WlRegistry,
        event: wl_registry::Event,
        (): &(),
        _connection: &Connection,
        handle: &QueueHandle<Self>,
    ) {
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } if interface == WlOutput::interface().name => {
                let id = OutputId::new(name);
                let output = registry.bind::<WlOutput, _, _>(
                    name,
                    version.min(WANTED_OUTPUT_VERSION),
                    handle,
                    id,
                );
                state.outputs.add(id);
                state.bound.push(Bound {
                    id,
                    output,
                    logical: None,
                });
                state.attach_logical_geometry(handle);
            }
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } if interface == ZxdgOutputManagerV1::interface().name => {
                state.manager = Some(registry.bind::<ZxdgOutputManagerV1, _, _>(
                    name,
                    version.min(WANTED_XDG_OUTPUT_VERSION),
                    handle,
                    (),
                ));
                state.attach_logical_geometry(handle);
            }
            wl_registry::Event::GlobalRemove { name } => {
                let id = OutputId::new(name);
                if !state.outputs.remove(id) {
                    return;
                }

                if let Some(index) = state.bound.iter().position(|bound| bound.id == id) {
                    let bound = state.bound.remove(index);
                    if let Some(logical) = bound.logical {
                        logical.destroy();
                    }
                    // `release` exists from version 3. Below that the object is
                    // simply dropped, which leaks one server-side object per
                    // unplug and is what the protocol leaves a client with.
                    if bound.output.version() >= 3 {
                        bound.output.release();
                    }
                }
                debug!(%id, "an output was unplugged");
            }
            _ => {}
        }
    }
}

impl Dispatch<WlOutput, OutputId> for Registry {
    fn event(
        state: &mut Self,
        _output: &WlOutput,
        event: wl_output::Event,
        id: &OutputId,
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            wl_output::Event::Geometry {
                x,
                y,
                make,
                model,
                transform,
                ..
            } => state.outputs.record_geometry(
                *id,
                LogicalPosition::new(x, y),
                SurfaceTransform::from_wl_output(u32::from(transform)),
                make,
                model,
            ),
            wl_output::Event::Mode {
                flags,
                width,
                height,
                ..
            } => {
                let current = flags
                    .into_result()
                    .is_ok_and(|flags| flags.contains(Mode::Current));
                let Some(pixels) = PixelExtent::from_signed(width, height) else {
                    warn!(
                        %id,
                        width,
                        height,
                        "the host reported a mode with a negative dimension, which is not a \
                         resolution; it is ignored rather than recorded as zero",
                    );
                    return;
                };
                state.outputs.record_mode(*id, current, pixels);
            }
            wl_output::Event::Scale { factor } => state.outputs.record_scale(*id, factor),
            wl_output::Event::Name { name } => state.outputs.record_name(*id, &name),
            _ => {}
        }
    }
}

impl Dispatch<ZxdgOutputV1, OutputId> for Registry {
    fn event(
        state: &mut Self,
        _logical: &ZxdgOutputV1,
        event: zxdg_output_v1::Event,
        id: &OutputId,
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        match event {
            zxdg_output_v1::Event::LogicalPosition { x, y } => state
                .outputs
                .record_logical_position(*id, LogicalPosition::new(x, y)),
            zxdg_output_v1::Event::LogicalSize { width, height } => {
                let Some(size) = LogicalSize::from_signed(width, height) else {
                    warn!(
                        %id,
                        width,
                        height,
                        "the host reported a logical size with a negative dimension, which places \
                         no monitor; it is ignored rather than recorded as zero",
                    );
                    return;
                };
                state.outputs.record_logical_size(*id, size);
            }
            _ => {}
        }
    }
}

impl Dispatch<ZxdgOutputManagerV1, ()> for Registry {
    fn event(
        _state: &mut Self,
        _manager: &ZxdgOutputManagerV1,
        _event: <ZxdgOutputManagerV1 as Proxy>::Event,
        (): &(),
        _connection: &Connection,
        _handle: &QueueHandle<Self>,
    ) {
        // The manager has no events. The implementation is required because
        // binding the global needs one.
    }
}
