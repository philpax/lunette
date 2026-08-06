//! Linux-only: speaks `ext_data_control_v1`, or `zwlr_data_control_v1`, to the
//! host compositor over a Wayland socket.
//!
//! This is the only part of `lunette-compositor` that is a Wayland *client*.
//! Data control is the protocol a clipboard manager uses: it reads and writes
//! the selection without holding focus, which is exactly what an overlay needs,
//! since lunette's windows are never the host's focused surface.
//!
//! Two protocols because one is not deployed. `ext_data_control_v1` is the
//! standardised successor and is preferred; `zwlr_data_control_v1` is what every
//! wlroots compositor has shipped for years and is the fallback. A host that has
//! neither is reported once and the clipboard simply does not cross — the rest
//! of the session is unaffected.
//!
//! # Thread affinity, and why there is a worker at all
//!
//! A `wayland_client::EventQueue` may not be dispatched from two threads, and
//! the compositor thread is already dispatching lunette's own clients. So the
//! host connection lives on a thread of its own, with a `calloop` loop over two
//! sources: the host socket, and a bounded command channel from the compositor.
//! Events go back the other way on [`HostEvents`], which is a bounded channel
//! registered on the compositor's own loop.
//!
//! The worker never reads or writes selection *content*. A read is
//! `offer.receive(mime, fd)` with the lunette client's own descriptor, and a
//! write is a descriptor handed back to the compositor thread for the lunette
//! client that owns the data. See [`crate::selection`] for why.
//!
//! # The echo
//!
//! Publishing a selection to the host makes the host announce that selection
//! back on the same device, because a data-control device sees every selection
//! including the ones it set. Re-offering it to lunette's clients would replace
//! the client's own source with a proxy of itself, so a `selection` event
//! arriving while lunette owns a live source for that kind is discarded. The
//! host cancels a source before announcing the one that replaced it — smithay
//! does so in `set_clipboard_selection`, and wlroots likewise — so a genuine
//! change is never mistaken for an echo.

use std::{
    collections::HashMap,
    error::Error,
    fmt, io,
    os::{
        fd::{AsFd, BorrowedFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    sync::mpsc::TrySendError,
    thread::{self, JoinHandle},
};

use smithay::reexports::calloop::{
    self, EventLoop, Interest, Mode, PostAction,
    channel::{self, Channel},
    generic::Generic,
};
use tracing::{debug, info, warn};
use wayland_client::{
    Connection, Dispatch, DispatchError, EventQueue, Proxy, QueueHandle,
    backend::{ObjectId, WaylandError},
    delegate_noop, event_created_child,
    globals::{GlobalList, GlobalListContents, registry_queue_init},
    protocol::{wl_registry::WlRegistry, wl_seat::WlSeat},
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
    HostRead, MimeType, OfferCounter, OfferId, SelectionKind,
    host::{
        HostEvent, HostEvents, HostSelection, HostSelectionSource, HostStartError, RejectReason,
        Rejected,
    },
};

/// How many requests may be queued for the host before one is refused.
///
/// A paste is one request, so this is a burst of pastes rather than a backlog.
/// Bounded because the alternative is a queue that grows for as long as a client
/// keeps asking, which is what WayVR's thread-per-request has instead of a queue
/// at all.
const COMMAND_CAPACITY: usize = 32;

/// The `zwlr_data_control_device_v1` version that gained the primary selection.
const WLR_PRIMARY_SINCE: u32 = 2;

const THREAD_NAME: &str = "lunette-clipboard";

/// The host desktop's clipboard, reached over its Wayland socket.
///
/// The socket is a path rather than something read from `WAYLAND_DISPLAY`,
/// because this is a library: the binary reads the host's value before it
/// exports its own and passes the result in.
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
        // Connecting and binding happen here, on the caller's thread, so a host
        // that cannot be reached is reported as a failure to open rather than as
        // a worker that quietly is not running.
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
            offers: HashMap::new(),
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

/// The compositor thread's end of the host clipboard worker.
struct DataControl {
    /// Taken by `Drop` before the join, because closing the channel is what
    /// wakes the worker and a message could not be relied on to fit.
    commands: Option<channel::SyncSender<HostCommand>>,
    /// Taken by `Drop`, which is the only thing that joins it.
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
    /// Queues a command that carries no descriptor, so a refusal has nothing to
    /// hand back and is only worth logging.
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
    /// Stops the worker by closing the channel, then waits for it.
    ///
    /// Closing rather than sending a stop message: a full queue would refuse the
    /// message and the join below would then wait for a thread nothing had asked
    /// to stop.
    fn drop(&mut self) {
        drop(self.commands.take());
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            warn!("the host clipboard worker panicked rather than stopping");
        }
    }
}

/// What the compositor thread asks the host worker to do.
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

/// Connects to the host compositor, with the socket non-blocking.
///
/// Non-blocking because the worker polls the descriptor itself: a blocking read
/// inside the loop would hold the thread past the point where a command needs
/// answering.
fn connect(socket: &Path) -> Result<Connection, HostStartError> {
    let describe = |cause: Box<dyn Error + Send + Sync>| HostStartError::Connect {
        socket: socket.display().to_string(),
        cause,
    };

    let stream = UnixStream::connect(socket).map_err(|error| describe(Box::new(error)))?;
    stream
        .set_nonblocking(true)
        .map_err(|error: io::Error| describe(Box::new(error)))?;
    Connection::from_socket(stream).map_err(|error| describe(Box::new(error)))
}

/// The worker thread's body.
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

/// Runs the two sources until the connection ends or the compositor stops.
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
        .insert_source(commands, |event, _metadata, control: &mut Loop| {
            match event {
                channel::Event::Msg(command) => control.pending.push(command),
                // The compositor dropped its sender, which is a stop.
                channel::Event::Closed => control.stop = true,
            }
        })
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

/// What the loop's two callbacks record for the body to act on.
///
/// The callbacks cannot touch the connection, because `calloop` borrows the
/// loop's data for the duration of a dispatch and the connection lives beside
/// it; so they set flags and the body does the work.
#[derive(Debug, Default)]
struct Loop {
    readable: bool,
    pending: Vec<HostCommand>,
    stop: bool,
}

/// The connection, its queue, and the state events dispatch into.
struct Worker {
    connection: Connection,
    queue: EventQueue<Host>,
    host: Host,
}

impl Worker {
    fn flush(&self) -> Result<(), WorkerError> {
        self.connection.flush().map_err(WorkerError::Wayland)
    }

    /// Reads whatever the host sent and dispatches it.
    fn read(&mut self) -> Result<(), WorkerError> {
        self.queue
            .dispatch_pending(&mut self.host)
            .map_err(WorkerError::Dispatch)?;

        if let Some(guard) = self.connection.prepare_read() {
            match guard.read() {
                Ok(_) => {}
                // The socket is non-blocking and level-triggered, so an empty
                // read is ordinary rather than a fault.
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

/// Why the host clipboard worker stopped.
#[derive(Debug)]
enum WorkerError {
    EventLoop(calloop::Error),
    CloneSocket(io::Error),
    Source {
        source: &'static str,
        cause: calloop::Error,
    },
    Loop(calloop::Error),
    /// A protocol error, or an event the queue could not route.
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

/// Everything the host connection knows, and the target every event dispatches
/// into.
struct Host {
    events: HostEvents,
    device: Device,
    manager: Manager,
    /// Offers the host has announced but not yet made current, with the MIME
    /// types accumulated so far. An offer's types arrive as separate events
    /// before the `selection` event names it.
    offers: HashMap<ObjectId, Vec<MimeType>>,
    /// The offer that is current for each kind, held alive so a later
    /// `receive` has something to ask.
    current: [Option<Current>; 2],
    /// The source lunette published for each kind, while it owns the selection.
    sources: [Option<Source>; 2],
    counter: OfferCounter,
}

/// The host's current selection of one kind.
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

    /// Offers a lunette client's selection to the host.
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

        if let Some(previous) = self.sources[index(kind)].replace(source) {
            previous.destroy();
        }
    }

    /// Gives up lunette's ownership of a selection.
    fn withdraw(&mut self, kind: SelectionKind) {
        if !self.supports(kind) {
            return;
        }
        self.device.set(kind, None);
        if let Some(source) = self.sources[index(kind)].take() {
            source.destroy();
        }
    }

    /// Asks the host to fill a lunette client's pipe with the host's selection.
    fn read(&mut self, request: HostRead) {
        let Some(current) = self.current[index(request.kind)].as_ref() else {
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
        // The descriptor is dropped here, which closes lunette's copy. The host
        // holds its own now, and the client holds the other end; a copy kept
        // open on this side would stop the client ever seeing the end of the
        // data.
        drop(request.pipe);
    }

    /// Whether the bound protocol version carries this selection at all.
    fn supports(&self, kind: SelectionKind) -> bool {
        match (kind, &self.device) {
            (SelectionKind::Clipboard, _) | (SelectionKind::Primary, Device::Ext(_)) => true,
            (SelectionKind::Primary, Device::Wlr(device)) => device.version() >= WLR_PRIMARY_SINCE,
        }
    }

    /// Records a MIME type against the offer that advertised it.
    fn offered(&mut self, offer: &Offer, mime: String) {
        let Some(mime) = MimeType::new(mime) else {
            debug!("the host offered an empty mime type; ignoring it");
            return;
        };
        self.offers.entry(offer.key()).or_default().push(mime);
    }

    /// Takes an announced offer as the current selection of one kind.
    fn selected(&mut self, kind: SelectionKind, offer: Option<Offer>) {
        if self.sources[index(kind)].is_some() {
            // lunette owns this selection, so the host is announcing lunette's
            // own source back to it. Re-offering it would replace the client's
            // source with a proxy of itself.
            if let Some(offer) = offer {
                self.offers.remove(&offer.key());
                offer.destroy();
            }
            return;
        }

        let previous = self.current[index(kind)].take();

        let Some(offer) = offer else {
            if let Some(previous) = previous {
                previous.offer.destroy();
            }
            self.events.report(HostEvent::Cleared { kind });
            return;
        };

        let mimes = self.offers.remove(&offer.key()).unwrap_or_default();
        let id = self.counter.next();
        self.events.report(HostEvent::Offered {
            kind,
            offer: id,
            mimes,
        });
        self.current[index(kind)] = Some(Current { id, offer });

        // Destroyed only after the replacement is recorded: a client mid-read
        // holds the old offer's identifier, and `read` refuses on the identifier
        // rather than on the object still existing.
        if let Some(previous) = previous {
            previous.offer.destroy();
        }
    }

    /// The host asked for the bytes behind a source lunette published.
    fn send(&mut self, source: &Source, mime: String, pipe: OwnedFd) {
        let Some(kind) = self.kind_of(source) else {
            debug!("the host asked a clipboard source lunette no longer owns for data");
            return;
        };
        let Some(mime) = MimeType::new(mime) else {
            debug!("the host asked for an empty mime type; refusing it");
            return;
        };
        self.events.report(HostEvent::Send { kind, mime, pipe });
    }

    /// Something else on the host took a selection lunette owned.
    fn cancelled(&mut self, source: &Source) {
        let Some(kind) = self.kind_of(source) else {
            return;
        };
        if let Some(source) = self.sources[index(kind)].take() {
            source.destroy();
        }
        self.events.report(HostEvent::Cancelled { kind });
    }

    fn kind_of(&self, source: &Source) -> Option<SelectionKind> {
        SelectionKind::ALL.into_iter().find(|kind| {
            self.sources[index(*kind)]
                .as_ref()
                .is_some_and(|held| held.key() == source.key())
        })
    }
}

/// Where a selection sits in the per-kind arrays.
const fn index(kind: SelectionKind) -> usize {
    match kind {
        SelectionKind::Clipboard => 0,
        SelectionKind::Primary => 1,
    }
}

/// The data-control manager, whichever protocol the host implements.
enum Manager {
    Ext(ExtDataControlManagerV1),
    Wlr(ZwlrDataControlManagerV1),
}

impl Manager {
    /// Binds the manager, preferring the standardised protocol.
    fn bind(globals: &GlobalList, handle: &QueueHandle<Host>) -> Result<Self, HostStartError> {
        if let Ok(manager) = globals.bind::<ExtDataControlManagerV1, _, _>(handle, 1..=1, ()) {
            return Ok(Self::Ext(manager));
        }
        if let Ok(manager) = globals.bind::<ZwlrDataControlManagerV1, _, _>(handle, 1..=2, ()) {
            return Ok(Self::Wlr(manager));
        }
        Err(HostStartError::NoDataControl)
    }

    const fn name(&self) -> &'static str {
        match self {
            Self::Ext(_) => "ext-data-control-v1",
            Self::Wlr(_) => "wlr-data-control-v1",
        }
    }

    fn device(&self, seat: &WlSeat, handle: &QueueHandle<Host>) -> Device {
        match self {
            Self::Ext(manager) => Device::Ext(manager.get_data_device(seat, handle, ())),
            Self::Wlr(manager) => Device::Wlr(manager.get_data_device(seat, handle, ())),
        }
    }

    fn source(&self, handle: &QueueHandle<Host>) -> Source {
        match self {
            Self::Ext(manager) => Source::Ext(manager.create_data_source(handle, ())),
            Self::Wlr(manager) => Source::Wlr(manager.create_data_source(handle, ())),
        }
    }
}

/// The device selections arrive on, whichever protocol the host implements.
enum Device {
    Ext(ExtDataControlDeviceV1),
    Wlr(ZwlrDataControlDeviceV1),
}

impl Device {
    /// Sets or clears one of the two selections.
    fn set(&self, kind: SelectionKind, source: Option<&Source>) {
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
enum Offer {
    Ext(ExtDataControlOfferV1),
    Wlr(ZwlrDataControlOfferV1),
}

impl Offer {
    /// Identifies the offer object, for keying the MIME types accumulated
    /// against it.
    fn key(&self) -> ObjectId {
        match self {
            Self::Ext(offer) => offer.id(),
            Self::Wlr(offer) => offer.id(),
        }
    }

    fn receive(&self, mime: String, pipe: BorrowedFd<'_>) {
        match self {
            Self::Ext(offer) => offer.receive(mime, pipe),
            Self::Wlr(offer) => offer.receive(mime, pipe),
        }
    }

    fn destroy(self) {
        match self {
            Self::Ext(offer) => offer.destroy(),
            Self::Wlr(offer) => offer.destroy(),
        }
    }
}

/// A selection lunette is offering to the host.
enum Source {
    Ext(ExtDataControlSourceV1),
    Wlr(ZwlrDataControlSourceV1),
}

impl Source {
    fn key(&self) -> ObjectId {
        match self {
            Self::Ext(source) => source.id(),
            Self::Wlr(source) => source.id(),
        }
    }

    fn offer(&self, mime: String) {
        match self {
            Self::Ext(source) => source.offer(mime),
            Self::Wlr(source) => source.offer(mime),
        }
    }

    fn destroy(self) {
        match self {
            Self::Ext(source) => source.destroy(),
            Self::Wlr(source) => source.destroy(),
        }
    }

    /// # Panics
    ///
    /// If asked for the other protocol's object. Unreachable: a source is
    /// created by the manager the device came from, so the two always match.
    fn ext(&self) -> &ExtDataControlSourceV1 {
        match self {
            Self::Ext(source) => source,
            Self::Wlr(_) => unreachable!("a wlr source cannot be set on an ext device"),
        }
    }

    /// # Panics
    ///
    /// If asked for the other protocol's object, for the reason [`Self::ext`]
    /// records.
    fn wlr(&self) -> &ZwlrDataControlSourceV1 {
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
            Event::Finished => state.events.report(HostEvent::Lost {
                reason: "the host withdrew lunette's data-control device".to_owned(),
            }),
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
            Event::Finished => state.events.report(HostEvent::Lost {
                reason: "the host withdrew lunette's data-control device".to_owned(),
            }),
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

delegate_noop!(Host: ignore WlSeat);
delegate_noop!(Host: ignore ExtDataControlManagerV1);
delegate_noop!(Host: ignore ZwlrDataControlManagerV1);
