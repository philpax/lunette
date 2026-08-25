//! The compositor owns the Wayland display and smithay state on a dedicated thread.
//!
//! `calloop::EventLoop` is not `Send`, so the compositor constructs all of its
//! state inside that thread. The main thread sends commands through a bounded,
//! nonblocking channel. The compositor sends events through a bounded channel and
//! waits for capacity so state-changing events are not discarded. A blocking
//! command send could deadlock when dispatch emits events before it drains commands.
//! Snapshots cross the boundary as immutable values published through an [`ArcSwap`].

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

pub(crate) const COMMAND_CAPACITY: usize = 256;
pub(crate) const EVENT_CAPACITY: usize = 1024;
pub(crate) const HOST_SELECTION_CAPACITY: usize = 32;

const THREAD_NAME: &str = "lunette-compositor";

/// Starts the compositor thread and waits for construction to report its result.
///
/// Dropping the returned handle closes the command channel and stops the thread.
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

/// Starts the compositor thread with injected process-spawning and process-inspection seams.
///
/// Production uses the system spawner and `/proc` inspector. Tests inject fakes so they do not
/// fork processes or read the host's `/proc`.
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
        Err(mpsc::RecvError) => Err(StartError::NoStartupReport),
    }
}

/// The main-thread endpoints for a compositor thread.
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
    /// Dropping the handle also stops the thread, but does not wait for it.
    pub fn shutdown(self) -> Result<(), ShutdownError> {
        let Self {
            commands,
            events,
            snapshots,
            thread,
        } = self;

        // Dropping the receivers lets a blocked event send observe shutdown.
        if let Err(error) = commands.try_send(Command::Shutdown) {
            debug!(%error, "asking the compositor to stop by closing its command channel");
        }
        drop(commands);
        drop(events);
        drop(snapshots);

        thread.join().map_err(|_| ShutdownError::ThreadPanicked)
    }
}

#[derive(Clone, Debug)]
pub struct CommandSender {
    pub(crate) queue: calloop::channel::SyncSender<Command>,
}

impl CommandSender {
    /// Attempts to queue a command without waiting. Returns the unsent command if the channel is full
    /// or disconnected.
    pub fn try_send(&self, command: Command) -> Result<(), TrySendError> {
        self.queue.try_send(command).map_err(|error| match error {
            mpsc::TrySendError::Full(command) => TrySendError::Full(command),
            mpsc::TrySendError::Disconnected(command) => TrySendError::Disconnected(command),
        })
    }
}

#[derive(Debug)]
pub struct EventReceiver {
    pub(crate) queue: mpsc::Receiver<Event>,
}

impl EventReceiver {
    pub fn drain(&self) -> mpsc::TryIter<'_, Event> {
        self.queue.try_iter()
    }

    /// Waits up to `timeout` for one event.
    ///
    /// This is the only blocking protocol operation. Command sends stay nonblocking because the
    /// compositor can block here while dispatch is waiting to drain its command channel.
    pub fn wait(&self, timeout: Duration) -> Result<Event, WaitError> {
        self.queue
            .recv_timeout(timeout)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => WaitError::TimedOut,
                mpsc::RecvTimeoutError::Disconnected => WaitError::Disconnected,
            })
    }
}

/// Why an event wait did not return an event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaitError {
    /// No event arrived before the timeout. The compositor may still be running.
    TimedOut,
    /// The compositor thread is gone, so no event can arrive.
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

#[derive(Debug)]
pub(crate) struct EventSender {
    pub(crate) queue: mpsc::SyncSender<Event>,
}

impl EventSender {
    /// Sends an event, waiting for capacity so state-changing events are not discarded.
    pub(crate) fn send(&self, event: Event) -> Result<(), Disconnected> {
        self.queue.send(event).map_err(|_| Disconnected)
    }
}

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

/// Publishes immutable snapshots and advances their generation counter.
#[derive(Debug)]
pub(crate) struct SnapshotPublisher {
    latest: Arc<ArcSwap<Snapshot>>,
    published: Generation,
}

impl SnapshotPublisher {
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

pub(crate) struct SnapshotParts {
    pub(crate) windows: Vec<WindowSnapshot>,
    pub(crate) processes: Vec<ProcessSnapshot>,
    pub(crate) outputs: Vec<OutputSnapshot>,
    pub(crate) seats: Vec<SeatSnapshot>,
}

#[derive(Clone, Debug)]
pub struct SnapshotReader {
    latest: Arc<ArcSwap<Snapshot>>,
}

impl SnapshotReader {
    /// Loads an immutable snapshot. The returned value remains consistent while newer snapshots publish.
    #[must_use]
    pub fn load(&self) -> Arc<Snapshot> {
        self.latest.load_full()
    }
}

/// Selects the process behavior when the compositor thread panics.
///
/// The binary supplies this policy. This crate does not install a process-global panic hook.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PanicPolicy {
    /// Aborts so a panicking thread cannot leave its Wayland socket and stale snapshot available.
    #[default]
    Abort,
    /// Lets the thread unwind so its join handle reports the panic.
    Unwind,
}

/// Runs `body` and aborts the process if it unwinds, without installing a global panic hook.
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

pub(crate) struct Ingredients {
    pub(crate) config: CompositorConfig,
    /// `None` lets logic-headless tests insert clients over an in-process socket pair.
    pub(crate) socket: Option<WaylandSocket>,
    pub(crate) importer: Box<dyn BufferImporter>,
    pub(crate) spawner: Box<dyn ProcessSpawner>,
    pub(crate) inspector: Box<dyn ProcessInspector>,
    pub(crate) commands: Channel<Command>,
    pub(crate) events: EventSender,
    pub(crate) snapshots: SnapshotPublisher,
}

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

    let outcome = event_loop.run(None, &mut data, |data| {
        // Sweep after dispatch so imports whose buffers were destroyed during dispatch can be collected.
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
            // A failed loop leaves the Wayland socket and stale snapshot owned by this process.
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

    let mut display = Display::<CompositorState>::new().map_err(StartError::CreateDisplay)?;

    // Level-triggered readiness dispatches again when a client still has unread requests.
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
                // Treat a closed host channel as a lost selection source.
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

    // Publish before acknowledging startup so readers never observe the placeholder as initial state.
    state.publish_if_dirty();

    Ok((event_loop, LoopData { display, state }))
}

pub(crate) struct LoopData {
    pub(crate) display: Display<CompositorState>,
    pub(crate) state: CompositorState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Disconnected;

impl fmt::Display for Disconnected {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "compositor: the thread is no longer running")
    }
}

impl Error for Disconnected {}

/// A command that `CommandSender::try_send` did not queue.
#[derive(Debug)]
pub enum TrySendError {
    /// The bounded command channel has no capacity; the command is returned unsent.
    Full(Command),
    /// The compositor thread has disconnected; the command is returned unsent.
    Disconnected(Command),
}

impl TrySendError {
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

    // The bound applies to condition waits, not to a fixed sleep.
    const DEADLINE: Duration = Duration::from_secs(5);

    #[derive(Debug, PartialEq, Eq)]
    enum Progress {
        Sending,
        Sent,
    }

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

        assert_eq!(snapshots.load().generation.get(), 1);
    }

    #[test]
    fn the_loop_keeps_draining_commands_it_has_no_handler_for() {
        let compositor = test_compositor_thread();
        let commands = compositor.commands();
        let unhandled = || Command::CloseWindow {
            window: crate::protocol::WindowId::new(1).expect("non-zero"),
        };

        let mut offered = 0;
        while commands.try_send(unhandled()).is_ok() && offered < COMMAND_CAPACITY * 2 {
            offered += 1;
        }
        assert!(offered > 0, "the queue refused every command");

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
