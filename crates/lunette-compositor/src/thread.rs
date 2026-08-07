//! The compositor thread, its event loop, and the transports it is reached by.
//!
//! Everything the compositor owns is built inside the spawned closure, because
//! `calloop::EventLoop` is not `Send` and cannot be handed across a thread
//! boundary after construction. What crosses instead is the far end of three
//! transports: a bounded command channel down, a bounded event channel up, and
//! an [`ArcSwap`] the compositor republishes a whole [`Snapshot`] into once per
//! tick.
//!
//! Both channels are bounded, so neither direction can hide a backlog. The two
//! directions handle a full channel differently, and the asymmetry is the whole
//! of what stops them deadlocking.
//!
//! The compositor's [`EventSender::send`] waits for room. A dropped
//! `WindowClosed` leaves the main thread holding a handle that never dies,
//! which is worse than a stall, so no event is ever discarded.
//!
//! The main thread's [`CommandSender::try_send`] never waits. It is the only
//! way to queue a command, and a full queue comes back as
//! [`TrySendError::Full`] carrying the command that was not sent. If it waited
//! too, the pair would deadlock: the compositor fills the event channel inside
//! a dispatch callback — one client can commit hundreds of times in a batch —
//! and blocks there without draining commands, while the main thread, having
//! already drained this frame's events, blocks filling the command channel.
//! Neither could then reach the call that would free the other. With the main
//! thread unable to block, it always returns to the frame loop and drains
//! events, which is what releases the compositor.
//!
//! # How much is wired up
//!
//! The loop dispatches clients, drains commands, answers frame callbacks,
//! publishes snapshots, and flushes. Every global is advertised, and
//! [`crate::state`] serves them. [`crate::protocol`] records which commands
//! have handlers and which are still inert.

use std::{
    error::Error,
    fmt, io,
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
    time::Duration,
};

use arc_swap::ArcSwap;
use smithay::reexports::{
    calloop::{self, EventLoop, Interest, Mode, PostAction, channel::Channel, generic::Generic},
    wayland_server::Display,
};
use tracing::{debug, error, info, warn};

use crate::{
    client::{self, WaylandSocket},
    process::{ProcFilesystem, ProcessInspector, ProcessSpawner, SystemSpawner},
    protocol::{
        Command, Event, Generation, OutputSnapshot, ProcessSnapshot, SeatSnapshot, Snapshot,
        WindowSnapshot,
    },
    selection::{HostEvent, HostEvents},
    state::{CompositorConfig, CompositorState, StateParts},
    surface::BufferImporter,
};

/// How many commands may be queued before a sender waits.
///
/// A frame's worth of Lua mutations is a handful; this leaves room for a burst
/// — a configuration that opens a dozen windows at once — without letting an
/// unresponsive compositor accumulate work indefinitely.
pub(crate) const COMMAND_CAPACITY: usize = 256;

/// How many events may be queued before the compositor waits.
///
/// Larger than the command capacity because a single client can produce many
/// events in one dispatch batch, and the main thread only drains once a frame.
pub(crate) const EVENT_CAPACITY: usize = 1024;

/// How many host clipboard reports may be queued before one is discarded.
///
/// A report is a copy on the host desktop, or a paste of lunette's own
/// selection. Neither happens in bursts, so the bound is small; it exists so a
/// compositor that has stopped dispatching cannot make the host worker grow a
/// queue of descriptors.
pub(crate) const HOST_SELECTION_CAPACITY: usize = 32;

const THREAD_NAME: &str = "lunette-compositor";

/// Starts the compositor thread.
///
/// The returned handle owns the only command sender, so dropping it stops the
/// thread. Construction happens on the new thread and its outcome is reported
/// back, so a failure to build the event loop or the display surfaces here
/// rather than as a thread that quietly is not running.
pub fn spawn(
    config: CompositorConfig,
    socket: WaylandSocket,
    importer: Box<dyn BufferImporter>,
    panics: PanicPolicy,
) -> Result<CompositorHandle, StartError> {
    spawn_with(
        config,
        Some(socket),
        importer,
        Box::new(SystemSpawner),
        Box::new(ProcFilesystem),
        panics,
    )
}

/// Starts the compositor thread against spawner and `/proc` implementations of
/// the caller's choosing.
///
/// The two seams exist for tests, which must not fork and must not read the
/// real `/proc`. Production calls [`spawn`], which supplies the real ones.
pub fn spawn_with(
    config: CompositorConfig,
    socket: Option<WaylandSocket>,
    importer: Box<dyn BufferImporter>,
    spawner: Box<dyn ProcessSpawner>,
    inspector: Box<dyn ProcessInspector>,
    panics: PanicPolicy,
) -> Result<CompositorHandle, StartError> {
    let (commands, command_channel) = calloop::channel::sync_channel(COMMAND_CAPACITY);
    let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
    let (snapshots, reader) = snapshot_channel();
    let (started, startup) = mpsc::channel();

    let thread = thread::Builder::new()
        .name(THREAD_NAME.to_owned())
        .spawn(move || {
            let body = move || {
                run(
                    Ingredients {
                        config,
                        socket,
                        importer,
                        spawner,
                        inspector,
                        commands: command_channel,
                        events: EventSender {
                            queue: event_sender,
                        },
                        snapshots,
                    },
                    &started,
                );
            };

            match panics {
                PanicPolicy::Abort => abort_on_panic(THREAD_NAME, body),
                PanicPolicy::Unwind => body(),
            }
        })
        .map_err(StartError::SpawnThread)?;

    match startup.recv() {
        Ok(Ok(())) => Ok(CompositorHandle {
            commands: CommandSender { queue: commands },
            events: EventReceiver { queue: events },
            snapshots: reader,
            thread,
        }),
        Ok(Err(error)) => {
            drop(thread.join());
            Err(error)
        }
        // The thread aborts the process rather than unwinding, so this arm is
        // reachable only if `run` returns without reporting, which it cannot.
        Err(mpsc::RecvError) => Err(StartError::NoStartupReport),
    }
}

/// The main thread's end of a running compositor.
#[derive(Debug)]
pub struct CompositorHandle {
    commands: CommandSender,
    events: EventReceiver,
    snapshots: SnapshotReader,
    thread: JoinHandle<()>,
}

impl CompositorHandle {
    #[must_use]
    pub fn commands(&self) -> &CommandSender {
        &self.commands
    }

    #[must_use]
    pub fn events(&self) -> &EventReceiver {
        &self.events
    }

    #[must_use]
    pub fn snapshots(&self) -> &SnapshotReader {
        &self.snapshots
    }

    /// Assembles a handle over channels whose far ends the caller owns.
    ///
    /// For [`crate::testing`], which builds a thread that is not a compositor so
    /// that a caller's behaviour against one that never answers can be driven.
    /// Production reaches a handle only through [`spawn_with`], which is the one
    /// place able to promise that the thread on the other end is running `run`.
    #[cfg(any(test, feature = "test-fakes"))]
    pub(crate) fn from_parts(
        commands: CommandSender,
        events: EventReceiver,
        snapshots: SnapshotReader,
        thread: JoinHandle<()>,
    ) -> Self {
        Self {
            commands,
            events,
            snapshots,
            thread,
        }
    }

    /// Stops the compositor and waits for the thread to finish.
    ///
    /// Clients are disconnected as the display drops. Dropping the handle
    /// without calling this also stops the thread, because closing the command
    /// channel is itself a stop, but nothing then waits for it.
    pub fn shutdown(self) -> Result<(), ShutdownError> {
        let Self {
            commands,
            events,
            snapshots,
            thread,
        } = self;

        // Best effort, and enough on its own only when there is room. A refused
        // or disconnected send is not a failure to stop: dropping the sender
        // below closes the channel, which the loop reads as a stop, and
        // dropping the receiver releases a compositor waiting to report an
        // event so it can reach that close.
        if let Err(error) = commands.try_send(Command::Shutdown) {
            debug!(%error, "asking the compositor to stop by closing its command channel");
        }
        drop(commands);
        drop(events);
        drop(snapshots);

        thread.join().map_err(|_| ShutdownError::ThreadPanicked)
    }
}

/// The main thread's end of the command channel.
#[derive(Clone, Debug)]
pub struct CommandSender {
    pub(crate) queue: calloop::channel::SyncSender<Command>,
}

impl CommandSender {
    /// Queues a command, returning it if there is no room.
    ///
    /// The only way to queue one, and it never waits. A caller that blocked
    /// here could deadlock against a compositor blocked reporting an event;
    /// this module's documentation sets out the cycle. The command comes back
    /// rather than being dropped, so the decision to discard it is the
    /// caller's, and a full queue is a report rather than a silent loss.
    pub fn try_send(&self, command: Command) -> Result<(), TrySendError> {
        self.queue.try_send(command).map_err(|error| match error {
            mpsc::TrySendError::Full(command) => TrySendError::Full(command),
            mpsc::TrySendError::Disconnected(command) => TrySendError::Disconnected(command),
        })
    }
}

/// The main thread's end of the event channel.
#[derive(Debug)]
pub struct EventReceiver {
    pub(crate) queue: mpsc::Receiver<Event>,
}

impl EventReceiver {
    /// Takes every event queued so far, without waiting for more.
    ///
    /// Called once at frame start, immediately before the snapshot is read, so
    /// a consumer of an event sees a snapshot that already accounts for it.
    pub fn drain(&self) -> mpsc::TryIter<'_, Event> {
        self.queue.try_iter()
    }

    /// Waits up to `timeout` for one event.
    ///
    /// The only blocking read in the protocol, and it exists for one caller:
    /// the restart quiesce, which must not destroy the graphics device until
    /// the compositor has said it has let go of it.
    ///
    /// It does not reintroduce the cycle this module's documentation describes.
    /// The deadlock there needs both directions to wait; a caller of this is by
    /// construction *receiving*, so a compositor blocked in [`EventSender::send`]
    /// is released by the very call that is waiting on it. A caller must still
    /// reach the command channel only through [`CommandSender::try_send`].
    pub fn wait(&self, timeout: Duration) -> Result<Event, WaitError> {
        self.queue
            .recv_timeout(timeout)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => WaitError::TimedOut,
                mpsc::RecvTimeoutError::Disconnected => WaitError::Disconnected,
            })
    }
}

/// Why waiting for an event produced none.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaitError {
    /// Nothing arrived within the bound. The compositor may still be working.
    TimedOut,
    /// The compositor thread is gone, so nothing will ever arrive.
    Disconnected,
}

impl fmt::Display for WaitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compositor: ")?;
        match self {
            Self::TimedOut => write!(f, "no event arrived within the bound"),
            Self::Disconnected => write!(f, "the thread is no longer running"),
        }
    }
}

impl Error for WaitError {}

/// The compositor thread's end of the event channel.
#[derive(Debug)]
pub(crate) struct EventSender {
    pub(crate) queue: mpsc::SyncSender<Event>,
}

impl EventSender {
    /// Reports an event, waiting for room if the channel is full.
    ///
    /// This is the side that waits, because an event has nowhere else to go: a
    /// dropped one leaves the main thread's model of the compositor
    /// permanently wrong. The wait ends when the main thread next drains, and
    /// it always reaches that drain because nothing it does on the command
    /// channel can block.
    pub(crate) fn send(&self, event: Event) -> Result<(), Disconnected> {
        self.queue.send(event).map_err(|_| Disconnected)
    }
}

/// Creates the snapshot slot and its two ends.
pub(crate) fn snapshot_channel() -> (SnapshotPublisher, SnapshotReader) {
    let latest = Arc::new(ArcSwap::from_pointee(Snapshot::default()));
    (
        SnapshotPublisher {
            latest: Arc::clone(&latest),
            published: Generation::INITIAL,
        },
        SnapshotReader { latest },
    )
}

/// The compositor thread's end of the snapshot slot.
///
/// Owning the generation counter here, rather than accepting one from the
/// caller, is what makes the counter monotonic by construction: there is one
/// publisher, and it is the only thing that can stamp a snapshot.
#[derive(Debug)]
pub(crate) struct SnapshotPublisher {
    latest: Arc<ArcSwap<Snapshot>>,
    published: Generation,
}

impl SnapshotPublisher {
    /// Replaces the published snapshot with a newer generation.
    pub(crate) fn publish(&mut self, parts: SnapshotParts) {
        let SnapshotParts {
            windows,
            processes,
            outputs,
            seats,
        } = parts;

        self.published = self.published.next();
        self.latest.store(Arc::new(Snapshot {
            generation: self.published,
            windows,
            processes,
            outputs,
            seats,
        }));
    }
}

/// Everything a snapshot is assembled from, minus the generation.
///
/// A struct rather than four positional arguments: they are all lists of
/// similar shape, so transposing two would compile and publish nonsense.
pub(crate) struct SnapshotParts {
    pub(crate) windows: Vec<WindowSnapshot>,
    pub(crate) processes: Vec<ProcessSnapshot>,
    pub(crate) outputs: Vec<OutputSnapshot>,
    pub(crate) seats: Vec<SeatSnapshot>,
}

/// The main thread's end of the snapshot slot.
#[derive(Clone, Debug)]
pub struct SnapshotReader {
    latest: Arc<ArcSwap<Snapshot>>,
}

impl SnapshotReader {
    /// Takes the latest snapshot, which the caller then holds for the frame.
    ///
    /// Reading twice within a frame can otherwise straddle a publication and
    /// answer two different questions about the same instant.
    #[must_use]
    pub fn load(&self) -> Arc<Snapshot> {
        self.latest.load_full()
    }
}

/// What a panic on the compositor thread does to the process.
///
/// The choice is the caller's rather than this crate's. `std::panic::set_hook`
/// is process-global, so a library that installs one takes over the behaviour
/// of every consumer, the test harness included; instead the policy is offered
/// here and the binary states which one it wants.
///
/// [`crate::thread::abort_on_panic`] is the implementation of the first, and is
/// public so a consumer that spawns its own compositor-adjacent thread can
/// apply the same rule to it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PanicPolicy {
    /// Abort the process. What `crates/lunette/src/frame.rs` asks for: a
    /// compositor thread that unwinds leaves the Wayland socket held by a
    /// process that no longer services it, and leaves the main thread reading a
    /// snapshot that will never change again.
    #[default]
    Abort,
    /// Let the thread unwind and leave the process running. For a test harness,
    /// which reports a panicking thread rather than being killed by it.
    Unwind,
}

/// Runs `body`, aborting the process if it panics.
///
/// A wrapper rather than a panic hook, for the reason [`PanicPolicy`] records.
pub fn abort_on_panic<R>(name: &'static str, body: impl FnOnce() -> R) -> R {
    let guard = AbortGuard { name };
    let value = body();
    drop(guard);
    value
}

struct AbortGuard {
    name: &'static str,
}

impl Drop for AbortGuard {
    fn drop(&mut self) {
        if thread::panicking() {
            error!(thread = self.name, "thread panicked; aborting the process");
            std::process::abort();
        }
    }
}

/// Everything `run` needs to build the compositor, bundled so the thread body
/// takes one argument rather than six.
pub(crate) struct Ingredients {
    pub(crate) config: CompositorConfig,
    /// Absent only in a test, which connects clients over a socket pair rather
    /// than through a bound socket.
    pub(crate) socket: Option<WaylandSocket>,
    pub(crate) importer: Box<dyn BufferImporter>,
    pub(crate) spawner: Box<dyn ProcessSpawner>,
    pub(crate) inspector: Box<dyn ProcessInspector>,
    pub(crate) commands: Channel<Command>,
    pub(crate) events: EventSender,
    pub(crate) snapshots: SnapshotPublisher,
}

/// Builds the compositor, reports whether it started, and then runs it.
fn run(ingredients: Ingredients, started: &mpsc::Sender<Result<(), StartError>>) {
    let (mut event_loop, mut data) = match build(ingredients) {
        Ok(built) => {
            drop(started.send(Ok(())));
            built
        }
        Err(error) => {
            drop(started.send(Err(error)));
            return;
        }
    };

    info!("compositor thread running");

    // No timeout: with every source registered up front there is nothing to do
    // between events, and waking on a timer would burn a wakeup per tick for a
    // compositor that is usually idle.
    let outcome = event_loop.run(None, &mut data, |data| {
        // After the dispatch rather than before: a client that destroyed a
        // buffer did so during it, and this is where the import holding that
        // buffer's image becomes collectable.
        data.state.sweep_imports();
        data.state.send_frame_callbacks();
        data.state.publish_if_dirty();
        if let Err(error) = data.display.flush_clients() {
            warn!(%error, "could not flush clients");
        }
    });

    match outcome {
        Ok(()) => info!("compositor thread stopped"),
        Err(error) => {
            // The same reasoning as the panic policy: a loop that stopped
            // dispatching leaves a socket held and a snapshot frozen.
            error!(%error, "compositor event loop failed; aborting the process");
            std::process::abort();
        }
    }
}

pub(crate) type CompositorLoop = EventLoop<'static, LoopData>;

pub(crate) fn build(ingredients: Ingredients) -> Result<(CompositorLoop, LoopData), StartError> {
    let Ingredients {
        config,
        socket,
        importer,
        spawner,
        inspector,
        commands,
        events,
        snapshots,
    } = ingredients;

    let event_loop = CompositorLoop::try_new().map_err(StartError::CreateEventLoop)?;
    let handle = event_loop.handle();

    // Mutable because reaching the backend for its poll handle takes the
    // display by mutable reference.
    let mut display = Display::<CompositorState>::new().map_err(StartError::CreateDisplay)?;

    // Level triggered: a dispatch that leaves requests unread is woken again
    // rather than waiting for the next byte to arrive.
    let poll_fd = display
        .backend()
        .poll_fd()
        .try_clone_to_owned()
        .map_err(StartError::ClonePollFd)?;
    handle
        .insert_source(
            Generic::new(poll_fd, Interest::READ, Mode::Level),
            |_readiness, _fd, data: &mut LoopData| {
                data.display.dispatch_clients(&mut data.state)?;
                Ok(PostAction::Continue)
            },
        )
        .map_err(|error| StartError::InsertSource {
            source: "the wayland display",
            cause: error.error,
        })?;

    if let Some(socket) = socket {
        handle
            .insert_source(socket.source, |stream, _metadata, data: &mut LoopData| {
                client::accept(data, stream);
            })
            .map_err(|error| StartError::InsertSource {
                source: "the listening socket",
                cause: error.error,
            })?;
    }

    let (host_selection, host_reports) = calloop::channel::sync_channel(HOST_SELECTION_CAPACITY);
    handle
        .insert_source(host_reports, |event, _metadata, data: &mut LoopData| {
            match event {
                calloop::channel::Event::Msg(report) => data.state.host_selection(report),
                // The host worker stopped without reporting why, which is what a
                // panic there looks like from here.
                calloop::channel::Event::Closed => {
                    data.state.host_selection(HostEvent::Lost {
                        reason: "the host clipboard worker stopped".to_owned(),
                    });
                }
            }
        })
        .map_err(|error| StartError::InsertSource {
            source: "the host clipboard channel",
            cause: error.error,
        })?;

    handle
        .insert_source(commands, |event, _metadata, data: &mut LoopData| {
            match event {
                calloop::channel::Event::Msg(command) => data.state.handle(command),
                // The main thread dropped its sender, which is a stop.
                calloop::channel::Event::Closed => data.state.stop(),
            }
        })
        .map_err(|error| StartError::InsertSource {
            source: "the command channel",
            cause: error.error,
        })?;

    let mut state = CompositorState::new(StateParts {
        display: &display.handle(),
        config,
        importer,
        spawner,
        inspector,
        events,
        snapshots,
        signal: event_loop.get_signal(),
        loop_handle: handle,
        host_selection: HostEvents {
            queue: host_selection,
        },
    });

    // Published before the caller is told the thread started, so a caller that
    // reads a snapshot immediately after `spawn` sees a real one — with the
    // output already described — rather than the empty placeholder.
    state.publish_if_dirty();

    Ok((event_loop, LoopData { display, state }))
}

/// What the event loop's callbacks are handed.
///
/// The display and the state are separate fields of one owner because
/// `dispatch_clients` takes the state by mutable reference while borrowing the
/// display, so a single struct holding both cannot be passed to it.
pub(crate) struct LoopData {
    pub(crate) display: Display<CompositorState>,
    pub(crate) state: CompositorState,
}

/// The channel's other end is gone, so the message cannot be delivered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Disconnected;

impl fmt::Display for Disconnected {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compositor: the thread is no longer running")
    }
}

impl Error for Disconnected {}

/// Why a command could not be queued without waiting.
///
/// Carries the command back rather than dropping it, and so is no more
/// cloneable than [`Command`] is.
#[derive(Debug)]
pub enum TrySendError {
    /// The channel is full. The command is returned unsent.
    Full(Command),
    /// The compositor thread is gone. The command is returned unsent.
    Disconnected(Command),
}

impl TrySendError {
    /// The command that was not sent.
    #[must_use]
    pub fn into_command(self) -> Command {
        match self {
            Self::Full(command) | Self::Disconnected(command) => command,
        }
    }
}

impl fmt::Display for TrySendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compositor: ")?;
        match self {
            Self::Full(_) => write!(
                f,
                "the command queue is full, so the command was not sent; the compositor is not \
                 keeping up"
            ),
            Self::Disconnected(_) => write!(f, "the thread is no longer running"),
        }
    }
}

impl Error for TrySendError {}

/// Why the compositor thread could not be started.
#[derive(Debug)]
pub enum StartError {
    SpawnThread(io::Error),
    CreateEventLoop(calloop::Error),
    CreateDisplay(smithay::reexports::wayland_server::backend::InitError),
    ClonePollFd(io::Error),
    InsertSource {
        source: &'static str,
        cause: calloop::Error,
    },
    NoStartupReport,
}

impl fmt::Display for StartError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compositor: ")?;
        match self {
            Self::SpawnThread(_) => write!(f, "could not start the compositor thread"),
            Self::CreateEventLoop(_) => write!(f, "could not create the event loop"),
            Self::CreateDisplay(_) => write!(f, "could not create the wayland display"),
            Self::ClonePollFd(_) => {
                write!(f, "could not duplicate the wayland display's poll handle")
            }
            Self::InsertSource { source, cause: _ } => {
                write!(f, "could not watch {source}")
            }
            Self::NoStartupReport => write!(
                f,
                "the thread stopped before reporting whether it had started"
            ),
        }
    }
}

impl Error for StartError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::SpawnThread(cause) | Self::ClonePollFd(cause) => Some(cause),
            Self::CreateEventLoop(cause) | Self::InsertSource { cause, .. } => Some(cause),
            Self::CreateDisplay(cause) => Some(cause),
            Self::NoStartupReport => None,
        }
    }
}

/// Why the compositor thread could not be stopped cleanly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShutdownError {
    ThreadPanicked,
}

impl fmt::Display for ShutdownError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compositor: ")?;
        match self {
            Self::ThreadPanicked => write!(f, "the thread panicked rather than stopping"),
        }
    }
}

impl Error for ShutdownError {}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::time::{Duration, Instant};

    use pretty_assertions::assert_eq;

    use super::*;
    use crate::testing::{ImportLog, recording_importer};

    fn test_compositor_thread() -> CompositorHandle {
        spawn_with(
            CompositorConfig::default(),
            None,
            recording_importer(ImportLog::default()),
            Box::new(crate::testing::FakeSpawner::default()),
            Box::new(crate::testing::FakeInspector::default()),
            PanicPolicy::Unwind,
        )
        .expect("the compositor thread starts")
    }

    /// Long enough that a loaded machine does not fail the test, short enough
    /// that a genuine hang is reported rather than waited on for ever. Nothing
    /// here waits for a duration; this is only the point at which waiting for a
    /// condition is declared a failure.
    const DEADLINE: Duration = Duration::from_secs(5);

    #[derive(Debug, PartialEq, Eq)]
    enum Progress {
        Sending,
        Sent,
    }

    /// A publication carrying only the outputs a test cares about.
    fn parts(outputs: Vec<OutputSnapshot>) -> SnapshotParts {
        SnapshotParts {
            windows: Vec::new(),
            processes: Vec::new(),
            outputs,
            seats: Vec::new(),
        }
    }

    #[test]
    fn a_reader_starts_at_the_initial_generation_with_nothing_in_it() {
        let (_publisher, reader) = snapshot_channel();
        let snapshot = reader.load();

        assert_eq!(snapshot.generation, Generation::INITIAL);
        assert!(snapshot.windows.is_empty());
        assert!(snapshot.processes.is_empty());
        assert!(snapshot.outputs.is_empty());
    }

    #[test]
    fn generations_increase_strictly_with_every_publication() {
        let (mut publisher, reader) = snapshot_channel();

        let mut previous = reader.load().generation;
        for _ in 0..16 {
            publisher.publish(parts(Vec::new()));
            let current = reader.load().generation;
            assert!(
                current > previous,
                "generation {current} did not advance past {previous}"
            );
            previous = current;
        }
    }

    #[test]
    fn a_reader_sees_the_most_recent_publication() {
        let (mut publisher, reader) = snapshot_channel();
        let outputs = vec![OutputSnapshot {
            output: crate::protocol::OutputId::new(1).expect("non-zero"),
            mode: crate::protocol::OutputMode {
                size: crate::protocol::PixelSize::new(1920, 1080),
                scale: crate::protocol::OutputScale::new(1.0).expect("positive"),
                refresh: crate::protocol::RefreshRate::from_millihertz(90_000),
            },
        }];

        publisher.publish(parts(outputs.clone()));

        assert_eq!(reader.load().outputs, outputs);
    }

    #[test]
    fn a_held_snapshot_does_not_change_under_a_later_publication() {
        let (mut publisher, reader) = snapshot_channel();
        publisher.publish(parts(Vec::new()));

        let held = reader.load();
        publisher.publish(parts(Vec::new()));

        assert_eq!(held.generation.get(), 1);
        assert_eq!(reader.load().generation.get(), 2);
    }

    #[test]
    fn a_command_offered_to_a_full_channel_comes_back_rather_than_vanishing() {
        let (sender, channel) = calloop::channel::sync_channel(1);
        let sender = CommandSender { queue: sender };

        sender
            .try_send(Command::Shutdown)
            .expect("the first command fits");

        let refused = sender
            .try_send(Command::Shutdown)
            .expect_err("the second does not");
        assert!(matches!(refused, TrySendError::Full(Command::Shutdown)));

        channel
            .try_recv()
            .expect("the first command is still there");
        sender
            .try_send(Command::Shutdown)
            .expect("draining one makes room for another");
    }

    #[test]
    fn an_event_sent_to_a_full_channel_waits_for_room_rather_than_dropping() {
        let (queue, channel) = mpsc::sync_channel(1);
        let sender = EventSender { queue };
        let surface = crate::protocol::SurfaceId::new(1).expect("non-zero");

        sender
            .send(Event::SurfaceDamaged { surface })
            .expect("the channel starts empty");

        let (progress, watch) = mpsc::channel();
        let waiter = thread::spawn(move || {
            progress
                .send(Progress::Sending)
                .expect("the test is watching");
            sender
                .send(Event::SurfaceDamaged { surface })
                .expect("the channel is alive");
            progress.send(Progress::Sent).expect("the test is watching");
        });

        assert_eq!(
            watch.recv_timeout(DEADLINE).expect("the sender started"),
            Progress::Sending
        );
        assert!(
            matches!(watch.try_recv(), Err(mpsc::TryRecvError::Empty)),
            "the send completed while the channel was still full"
        );

        channel.try_recv().expect("the queued event is delivered");

        assert_eq!(
            watch.recv_timeout(DEADLINE).expect("the sender finished"),
            Progress::Sent
        );
        channel
            .try_recv()
            .expect("the waiting event was delivered, not dropped");
        waiter.join().expect("the sending thread finished cleanly");
    }

    #[test]
    fn the_thread_starts_publishes_and_stops() {
        let compositor = test_compositor_thread();

        let snapshot = compositor.snapshots().load();
        assert_eq!(
            snapshot.generation.get(),
            1,
            "the thread publishes once before reporting that it started"
        );
        assert_eq!(compositor.events().drain().count(), 0);

        compositor.shutdown().expect("the thread stops cleanly");
    }

    #[test]
    fn dropping_the_handle_stops_the_thread() {
        let compositor = test_compositor_thread();
        let snapshots = compositor.snapshots().clone();
        drop(compositor);

        // The reader outlives the thread and keeps answering with the last
        // snapshot, which is what a dead-handle read depends on.
        assert_eq!(snapshots.load().generation.get(), 1);
    }

    #[test]
    fn the_loop_keeps_draining_commands_it_has_no_handler_for() {
        let compositor = test_compositor_thread();
        let commands = compositor.commands();
        let unhandled = || Command::CloseWindow {
            window: crate::protocol::WindowId::new(1).expect("non-zero"),
        };

        // Offer commands until the queue refuses one, or until well past its
        // capacity, which happens when the loop is draining as fast as the test
        // fills. Either outcome is a live loop.
        let mut offered = 0;
        while commands.try_send(unhandled()).is_ok() && offered < COMMAND_CAPACITY * 2 {
            offered += 1;
        }
        assert!(offered > 0, "the queue refused every command");

        // Room reappears only because the loop took something off the queue.
        let deadline = Instant::now() + DEADLINE;
        while commands.try_send(unhandled()).is_err() {
            assert!(
                Instant::now() < deadline,
                "the loop stopped draining commands it does not handle"
            );
            std::hint::spin_loop();
        }

        compositor.shutdown().expect("the thread stops cleanly");
    }
}
