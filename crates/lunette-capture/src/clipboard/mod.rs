//! Linux-only: the client side of `ext_data_control_v1` or
//! `zwlr_data_control_v1`, connected to the host compositor over a
//! Wayland socket.
//!
//! Data control bridges clipboard and primary selection without requiring focus.
//! The standardised `ext_data_control_v1` protocol is preferred, with
//! `zwlr_data_control_v1` as the fallback. If the host provides neither, the
//! bridge reports the failure and the session continues without host bridging.
//!
//! The worker thread owns the Wayland connection and its event queue because a
//! Wayland event queue cannot be dispatched from two threads. Bounded channels
//! carry commands to the worker and events back to the compositor thread.
//!
//! The worker forwards selection descriptors without reading or writing their
//! content. A read passes the lunette client's descriptor to the host, and a
//! write passes the host's descriptor to the compositor thread. See
//! [`lunette_compositor::selection`] for the transfer contract.
//!
//! A host can re-announce a selection that lunette publishes. While lunette owns
//! a selection, the worker discards that announcement and does not proxy its
//! source back to lunette's clients. The protocols do not order source
//! cancellation and replacement announcements; `docs/dev/input.md` records the
//! resulting echo-handling choice.

mod objects;

use std::{
    error::Error,
    fmt, io,
    os::{
        fd::{AsFd, AsRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    sync::mpsc::TrySendError,
    thread::{self, JoinHandle},
    time::Duration,
};

use calloop::{
    EventLoop, Interest, Mode, PostAction,
    channel::{self, Channel},
    generic::Generic,
};
use lunette_compositor::selection::{
    HostEvent, HostEvents, HostRead, HostSelection, HostSelectionSource, HostStartError, MimeType,
    OfferCounter, OfferId, RejectReason, Rejected, SelectionKind,
};
use tracing::{debug, info, warn};
use wayland_client::{
    Connection, DispatchError, EventQueue, Proxy, QueueHandle,
    backend::{ObjectId, WaylandError},
    globals::registry_queue_init,
    protocol::wl_seat::WlSeat,
};

use crate::clipboard::objects::{Device, Manager, Offer, Source};

/// A full queue rejects reads and drops publish and withdraw commands.
const COMMAND_CAPACITY: usize = 32;

/// Minimum wlr data-control device version that supports the primary selection.
const WLR_PRIMARY_SINCE: u32 = 2;

const THREAD_NAME: &str = "lunette-clipboard";

/// Maximum number of announced offers retained while awaiting a selection event.
///
/// Dropping the oldest MIME list does not destroy its host object because the
/// host may still name that object.
const PENDING_OFFER_LIMIT: usize = 32;

/// Maximum time to wait for the host to answer the startup handshake.
const HANDSHAKE_DEADLINE: Duration = Duration::from_secs(5);

/// The host desktop's clipboard accessed through a Wayland socket.
///
/// The application supplies the socket path because the source does not read
/// `WAYLAND_DISPLAY` itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DataControlSource {
    socket: PathBuf,
}

impl DataControlSource {
    #[must_use]
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }
}

impl HostSelectionSource for DataControlSource {
    fn open(self: Box<Self>, events: HostEvents) -> Result<Box<dyn HostSelection>, HostStartError> {
        let connection = connect(&self.socket)?;
        let (globals, queue) =
            registry_queue_init::<Host>(&connection).map_err(|error| HostStartError::Connect {
                socket: self.socket.display().to_string(),
                cause: Box::new(error),
            })?;
        let handle = queue.handle();

        let seat: WlSeat = globals
            .bind(&handle, 1..=9, ())
            .map_err(|_| HostStartError::NoSeat)?;
        let manager = Manager::bind(&globals, &handle)?;
        let device = manager.device(&seat, &handle);

        info!(protocol = manager.name(), "bridging the host clipboard");

        let (commands, channel) = channel::sync_channel(COMMAND_CAPACITY);
        let host = Host {
            events,
            device,
            manager,
            offers: Vec::new(),
            current: [None, None],
            sources: [None, None],
            counter: OfferCounter::new(),
        };

        let thread = thread::Builder::new()
            .name(THREAD_NAME.to_owned())
            .spawn(move || run(connection, queue, host, channel))
            .map_err(|error| HostStartError::Worker(Box::new(error)))?;

        Ok(Box::new(DataControl {
            commands: Some(commands),
            thread: Some(thread),
        }))
    }
}

struct DataControl {
    /// Dropping the sender closes the channel even when the bounded queue is full.
    commands: Option<channel::SyncSender<HostCommand>>,
    thread: Option<JoinHandle<()>>,
}

impl HostSelection for DataControl {
    fn publish(&self, kind: SelectionKind, mimes: &[MimeType]) {
        self.queue(HostCommand::Publish {
            kind,
            mimes: mimes.to_vec(),
        });
    }

    fn withdraw(&self, kind: SelectionKind) {
        self.queue(HostCommand::Withdraw { kind });
    }

    fn read(&self, request: HostRead) -> Result<(), Rejected> {
        let Some(commands) = self.commands.as_ref() else {
            return Err(Rejected {
                request,
                reason: RejectReason::Disconnected,
            });
        };

        commands
            .try_send(HostCommand::Read(request))
            .map_err(|error| {
                let (command, reason) = match error {
                    TrySendError::Full(command) => (command, RejectReason::Backlogged),
                    TrySendError::Disconnected(command) => (command, RejectReason::Disconnected),
                };
                let HostCommand::Read(request) = command else {
                    unreachable!("the command sent was a read");
                };
                Rejected { request, reason }
            })
    }
}

impl DataControl {
    fn queue(&self, command: HostCommand) {
        let Some(commands) = self.commands.as_ref() else {
            warn!("the host clipboard worker has stopped; dropping a request");
            return;
        };
        if let Err(error) = commands.try_send(command) {
            warn!(%error, "the host clipboard worker is behind; dropping a request");
        }
    }
}

impl fmt::Debug for DataControl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DataControl")
            .field("running", &self.thread.is_some())
            .finish()
    }
}

impl Drop for DataControl {
    fn drop(&mut self) {
        drop(self.commands.take());
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            warn!("the host clipboard worker panicked rather than stopping");
        }
    }
}

#[derive(Debug)]
enum HostCommand {
    Publish {
        kind: SelectionKind,
        mimes: Vec<MimeType>,
    },
    Withdraw {
        kind: SelectionKind,
    },
    Read(HostRead),
}

/// Connects to the host compositor and makes the socket nonblocking.
///
/// The startup handshake has a deadline because registry setup can otherwise
/// wait indefinitely for a host that accepted the connection but does not
/// respond. The worker uses the nonblocking socket to service commands while it
/// waits for host events.
fn connect(socket: &Path) -> Result<Connection, HostStartError> {
    let describe = |cause: Box<dyn Error + Send + Sync>| HostStartError::Connect {
        socket: socket.display().to_string(),
        cause,
    };

    let stream = UnixStream::connect(socket).map_err(|error| describe(Box::new(error)))?;
    let probe = stream
        .try_clone()
        .map_err(|error| describe(Box::new(error)))?;
    let connection = Connection::from_socket(stream).map_err(|error| describe(Box::new(error)))?;

    handshake(&connection, &probe, socket)?;

    probe
        .set_nonblocking(true)
        .map_err(|error: io::Error| describe(Box::new(error)))?;
    probe
        .set_read_timeout(None)
        .map_err(|error: io::Error| describe(Box::new(error)))?;
    Ok(connection)
}

/// Waits up to [`HANDSHAKE_DEADLINE`] for the host to answer a `wl_display.sync`.
///
/// The response is peeked, so the real event queue still receives it.
/// The probe shares the connection's file description, which applies the read
/// timeout while the socket remains blocking.
fn handshake(
    connection: &Connection,
    probe: &UnixStream,
    socket: &Path,
) -> Result<(), HostStartError> {
    let describe = |cause: Box<dyn Error + Send + Sync>| HostStartError::Connect {
        socket: socket.display().to_string(),
        cause,
    };

    probe
        .set_read_timeout(Some(HANDSHAKE_DEADLINE))
        .map_err(|error: io::Error| describe(Box::new(error)))?;

    let queue: EventQueue<Handshake> = connection.new_event_queue();
    drop(connection.display().sync(&queue.handle(), ()));
    connection
        .flush()
        .map_err(|error| describe(Box::new(error)))?;

    if peeked_a_byte(probe) {
        return Ok(());
    }
    Err(HostStartError::Unresponsive {
        socket: socket.display().to_string(),
        waited: HANDSHAKE_DEADLINE,
    })
}

/// Returns whether the socket has data before its read timeout expires.
///
/// `MSG_PEEK` leaves the response available to the real event queue.
fn peeked_a_byte(probe: &UnixStream) -> bool {
    let mut byte = 0u8;
    // SAFETY: `probe` owns the descriptor and outlives the call, and the buffer
    // is one byte with a length of one.
    let read = unsafe {
        libc::recv(
            probe.as_raw_fd(),
            std::ptr::from_mut(&mut byte).cast(),
            1,
            libc::MSG_PEEK,
        )
    };
    read > 0
}

struct Handshake;

fn run(
    connection: Connection,
    queue: EventQueue<Host>,
    host: Host,
    commands: Channel<HostCommand>,
) {
    let mut worker = Worker {
        connection,
        queue,
        host,
    };

    let outcome = pump(&mut worker, commands);
    if let Err(error) = outcome {
        worker.host.events.report(HostEvent::Lost {
            reason: error.to_string(),
        });
    }
    debug!("the host clipboard worker stopped");
}

fn pump(worker: &mut Worker, commands: Channel<HostCommand>) -> Result<(), WorkerError> {
    let mut event_loop = EventLoop::<Loop>::try_new().map_err(WorkerError::EventLoop)?;
    let handle = event_loop.handle();

    let socket = worker
        .connection
        .as_fd()
        .try_clone_to_owned()
        .map_err(WorkerError::CloneSocket)?;

    handle
        .insert_source(
            Generic::new(socket, Interest::READ, Mode::Level),
            |_readiness, _fd, control: &mut Loop| {
                control.readable = true;
                Ok(PostAction::Continue)
            },
        )
        .map_err(|error| WorkerError::Source {
            source: "the host socket",
            cause: error.error,
        })?;

    handle
        .insert_source(
            commands,
            |event, _metadata, control: &mut Loop| match event {
                channel::Event::Msg(command) => control.pending.push(command),
                channel::Event::Closed => control.stop = true,
            },
        )
        .map_err(|error| WorkerError::Source {
            source: "the clipboard command channel",
            cause: error.error,
        })?;

    let mut control = Loop::default();

    loop {
        worker.flush()?;
        event_loop
            .dispatch(None, &mut control)
            .map_err(WorkerError::Loop)?;

        if control.readable {
            control.readable = false;
            worker.read()?;
        }

        let handle = worker.queue.handle();
        for command in control.pending.drain(..) {
            worker.host.apply(command, &handle);
        }

        if control.stop {
            worker.flush()?;
            return Ok(());
        }
    }
}

#[derive(Debug, Default)]
struct Loop {
    readable: bool,
    pending: Vec<HostCommand>,
    stop: bool,
}

struct Worker {
    connection: Connection,
    queue: EventQueue<Host>,
    host: Host,
}

impl Worker {
    /// A nonblocking `WouldBlock` leaves the message buffered for the next loop
    /// and does not end the connection.
    fn flush(&self) -> Result<(), WorkerError> {
        match self.connection.flush() {
            Ok(()) => Ok(()),
            Err(WaylandError::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                debug!("the host's socket is full; the clipboard message stays buffered");
                Ok(())
            }
            Err(error) => Err(WorkerError::Wayland(error)),
        }
    }

    fn read(&mut self) -> Result<(), WorkerError> {
        self.queue
            .dispatch_pending(&mut self.host)
            .map_err(WorkerError::Dispatch)?;

        if let Some(guard) = self.connection.prepare_read() {
            match guard.read() {
                Ok(_) => {}
                // Level-triggered readiness can race with another read, so a
                // read may return `WouldBlock` with no data; that arm returns
                // normally.
                Err(WaylandError::Io(error)) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(WorkerError::Wayland(error)),
            }
        }

        self.queue
            .dispatch_pending(&mut self.host)
            .map_err(WorkerError::Dispatch)?;
        Ok(())
    }
}

#[derive(Debug)]
enum WorkerError {
    EventLoop(calloop::Error),
    CloneSocket(io::Error),
    Source {
        source: &'static str,
        cause: calloop::Error,
    },
    Loop(calloop::Error),
    Dispatch(DispatchError),
    Wayland(WaylandError),
}

impl fmt::Display for WorkerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "selection: ")?;
        match self {
            Self::EventLoop(_) => write!(f, "could not create the host clipboard event loop"),
            Self::CloneSocket(_) => write!(f, "could not duplicate the host socket"),
            Self::Source { source, cause: _ } => write!(f, "could not watch {source}"),
            Self::Loop(_) => write!(f, "the host clipboard event loop failed"),
            Self::Dispatch(_) => write!(f, "the host compositor sent something unroutable"),
            Self::Wayland(_) => write!(f, "the host compositor connection ended"),
        }
    }
}

impl Error for WorkerError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::EventLoop(cause) | Self::Source { cause, .. } | Self::Loop(cause) => Some(cause),
            Self::CloneSocket(cause) => Some(cause),
            Self::Dispatch(cause) => Some(cause),
            Self::Wayland(cause) => Some(cause),
        }
    }
}

struct Host {
    events: HostEvents,
    device: Device,
    manager: Manager,
    /// MIME types can arrive before the selection event names their offer.
    /// The host object outlives this bounded local list because the host may name
    /// it later.
    offers: Vec<(ObjectId, Vec<MimeType>)>,
    /// The current offer remains for later `receive` requests until the next
    /// selection event replaces or clears it.
    current: [Option<Current>; 2],
    /// The source persists while lunette owns the host selection.
    sources: [Option<Source>; 2],
    counter: OfferCounter,
}

struct Current {
    id: OfferId,
    offer: Offer,
}

impl Host {
    fn apply(&mut self, command: HostCommand, handle: &QueueHandle<Self>) {
        match command {
            HostCommand::Publish { kind, mimes } => self.publish(kind, &mimes, handle),
            HostCommand::Withdraw { kind } => self.withdraw(kind),
            HostCommand::Read(request) => self.read(request),
        }
    }

    fn publish(&mut self, kind: SelectionKind, mimes: &[MimeType], handle: &QueueHandle<Self>) {
        if !self.supports(kind) {
            debug!(%kind, "the host's data-control version has no primary selection");
            return;
        }

        let source = self.manager.source(handle);
        for mime in mimes {
            source.offer(mime.as_str().to_owned());
        }
        self.device.set(kind, Some(&source));

        if let Some(previous) = self.sources[kind.index()].replace(source) {
            previous.destroy();
        }
    }

    /// The data-control protocols do not check ownership for
    /// `set_selection(null)`, so this sends it when lunette owns the source
    /// being cleared and omits it otherwise.
    fn withdraw(&mut self, kind: SelectionKind) {
        if !self.supports(kind) {
            return;
        }
        let Some(source) = self.sources[kind.index()].take() else {
            debug!(%kind, "nothing to withdraw; lunette does not own the host's selection");
            return;
        };
        self.device.set(kind, None);
        source.destroy();
    }

    fn read(&mut self, request: HostRead) {
        let Some(current) = self.current[request.kind.index()].as_ref() else {
            debug!(kind = %request.kind, "the host's selection went away before it could be read");
            return;
        };
        if current.id != request.offer {
            debug!(
                kind = %request.kind,
                wanted = %request.offer,
                held = %current.id,
                "the host replaced its selection before a read of the previous one arrived",
            );
            return;
        }

        current
            .offer
            .receive(request.mime.into_string(), request.pipe.as_fd());
        // The host owns the descriptor after `receive`; dropping lunette's copy
        // lets the client observe end-of-file.
        drop(request.pipe);
    }

    fn supports(&self, kind: SelectionKind) -> bool {
        match (kind, &self.device) {
            (SelectionKind::Clipboard, _) | (SelectionKind::Primary, Device::Ext(_)) => true,
            (SelectionKind::Primary, Device::Wlr(device)) => device.version() >= WLR_PRIMARY_SINCE,
        }
    }

    fn offered(&mut self, offer: &Offer, mime: String) {
        let Some(mime) = MimeType::new(mime.as_str()) else {
            debug!(
                mime,
                "the host offered a mime type that is empty or padded with whitespace, and \
                 nothing would ever ask for it; ignoring it"
            );
            return;
        };

        let key = offer.key();
        if let Some((_, mimes)) = self.offers.iter_mut().find(|(held, _)| *held == key) {
            mimes.push(mime);
            return;
        }

        if self.offers.len() >= PENDING_OFFER_LIMIT {
            // The host object must survive after forgetting its local MIME list,
            // because the host may still name it in a later selection event.
            warn!(
                limit = PENDING_OFFER_LIMIT,
                "the host has announced more selections than it has named; forgetting the oldest"
            );
            self.offers.remove(0);
        }
        self.offers.push((key, vec![mime]));
    }

    fn take_offered(&mut self, key: &ObjectId) -> Vec<MimeType> {
        let Some(index) = self.offers.iter().position(|(held, _)| held == key) else {
            return Vec::new();
        };
        self.offers.remove(index).1
    }

    fn selected(&mut self, kind: SelectionKind, offer: Option<Offer>) {
        if self.sources[kind.index()].is_some() {
            // A host can announce a replacement before cancelling the source it
            // replaces; the protocols do not specify this ordering. Treating the
            // announcement as an echo avoids proxying lunette's source back to its
            // clients, while the warning exposes a possibly stale selection.
            if let Some(offer) = offer {
                let mimes = self.take_offered(&offer.key());
                warn!(
                    %kind,
                    ?mimes,
                    "discarding a host selection as an echo of lunette's own; if a paste inside \
                     lunette is stale, this host announces a selection before cancelling the \
                     source it replaced",
                );
                offer.destroy();
            }
            return;
        }

        let previous = self.current[kind.index()].take();

        let Some(offer) = offer else {
            if let Some(previous) = previous {
                previous.offer.destroy();
            }
            self.events.report(HostEvent::Cleared { kind });
            return;
        };

        let mimes = self.take_offered(&offer.key());
        let id = self.counter.next();
        self.events.report(HostEvent::Offered {
            kind,
            offer: id,
            mimes,
        });
        self.current[kind.index()] = Some(Current { id, offer });

        // Publish the new identifier before destroying the old offer so an
        // in-flight read is rejected as stale and does not read the replacement.
        if let Some(previous) = previous {
            previous.offer.destroy();
        }
    }

    fn send(&mut self, source: &Source, mime: String, pipe: OwnedFd) {
        let Some(kind) = self.kind_of(source) else {
            debug!("the host asked a clipboard source lunette no longer owns for data");
            return;
        };
        let Some(mime) = MimeType::new(mime.as_str()) else {
            debug!(
                mime,
                "the host asked for a mime type that is empty or padded with whitespace, which no \
                 source can have advertised; refusing it"
            );
            return;
        };
        self.events.report(HostEvent::Send { kind, mime, pipe });
    }

    fn cancelled(&mut self, source: &Source) {
        let Some(kind) = self.kind_of(source) else {
            return;
        };
        if let Some(source) = self.sources[kind.index()].take() {
            source.destroy();
        }
        self.events.report(HostEvent::Cancelled { kind });
    }

    fn finished(&mut self) {
        // The withdrawn device cannot name the pending offer objects again.
        self.offers.clear();
        self.events.report(HostEvent::Lost {
            reason: "the host withdrew lunette's data-control device".to_owned(),
        });
    }

    fn kind_of(&self, source: &Source) -> Option<SelectionKind> {
        SelectionKind::ALL.iter().copied().find(|kind| {
            self.sources[kind.index()]
                .as_ref()
                .is_some_and(|held| held.key() == source.key())
        })
    }
}
