//! The compositor thread, its event loop, and the transports it is reached by.
//!
//! Everything the compositor owns is built inside the spawned closure, because
//! `calloop::EventLoop` is not `Send` and cannot be handed across a thread
//! boundary after construction. What crosses instead is the far end of three
//! transports: a bounded command channel down, a bounded event channel up, and
//! an [`ArcSwap`] the compositor republishes a whole [`Snapshot`] into once per
//! tick.
//!
//! Both channels are bounded, so neither direction can hide a backlog. A send
//! into a full channel waits for room rather than dropping the message: a
//! dropped `WindowClosed` leaves the main thread holding a handle that never
//! dies, which is a worse failure than a stall. The stall cannot deadlock,
//! because the main thread drains events every frame and never waits on the
//! compositor for anything.
//!
//! # How much is wired up
//!
//! The loop dispatches clients, drains commands, publishes snapshots, and
//! flushes. It advertises no globals and accepts no connections yet: the
//! listening socket, its name, and the surface handlers arrive with the ported
//! compositor state. Of the commands, only [`Command::Shutdown`] has a handler;
//! the rest are logged as unhandled, and [`crate::protocol`] records which
//! phase each is waiting on.

use std::{
    error::Error,
    fmt, io,
    sync::{Arc, mpsc},
    thread::{self, JoinHandle},
};

use arc_swap::ArcSwap;
use smithay::reexports::{
    calloop::{
        self, EventLoop, Interest, LoopSignal, Mode, PostAction, channel::Channel, generic::Generic,
    },
    wayland_server::Display,
};
use tracing::{debug, error, info, warn};

use crate::protocol::{
    Command, Event, Generation, OutputSnapshot, ProcessSnapshot, Snapshot, WindowSnapshot,
};

/// How many commands may be queued before a sender waits.
///
/// A frame's worth of Lua mutations is a handful; this leaves room for a burst
/// — a configuration that opens a dozen windows at once — without letting an
/// unresponsive compositor accumulate work indefinitely.
const COMMAND_CAPACITY: usize = 256;

/// How many events may be queued before the compositor waits.
///
/// Larger than the command capacity because a single client can produce many
/// events in one dispatch batch, and the main thread only drains once a frame.
const EVENT_CAPACITY: usize = 1024;

const THREAD_NAME: &str = "lunette-compositor";

/// Starts the compositor thread.
///
/// The returned handle owns the only command sender, so dropping it stops the
/// thread. Construction happens on the new thread and its outcome is reported
/// back, so a failure to build the event loop or the display surfaces here
/// rather than as a thread that quietly is not running.
pub fn spawn() -> Result<CompositorHandle, StartError> {
    let (commands, command_channel) = calloop::channel::sync_channel(COMMAND_CAPACITY);
    let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
    let (snapshots, reader) = snapshot_channel();
    let (started, startup) = mpsc::channel();

    let thread = thread::Builder::new()
        .name(THREAD_NAME.to_owned())
        .spawn(move || {
            abort_on_panic(THREAD_NAME, || {
                run(
                    command_channel,
                    EventSender {
                        queue: event_sender,
                    },
                    snapshots,
                    &started,
                );
            });
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

        // A disconnected channel means the thread already stopped, which is the
        // outcome being asked for.
        let _ = commands.send(Command::Shutdown);
        drop(commands);
        drop(events);
        drop(snapshots);

        thread.join().map_err(|_| ShutdownError::ThreadPanicked)
    }
}

/// The main thread's end of the command channel.
#[derive(Clone, Debug)]
pub struct CommandSender {
    queue: calloop::channel::SyncSender<Command>,
}

impl CommandSender {
    /// Queues a command, waiting for room if the channel is full.
    ///
    /// Only the main thread may call this. Calling it from the compositor
    /// thread would wait for a loop that is not running to drain the queue.
    pub fn send(&self, command: Command) -> Result<(), Disconnected> {
        self.queue.send(command).map_err(|_| Disconnected)
    }

    /// Queues a command, returning it if there is no room.
    ///
    /// For a caller that must not wait. The command comes back rather than
    /// being dropped, so the decision to discard it is the caller's.
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
    queue: mpsc::Receiver<Event>,
}

impl EventReceiver {
    /// Takes every event queued so far, without waiting for more.
    ///
    /// Called once at frame start, immediately before the snapshot is read, so
    /// a consumer of an event sees a snapshot that already accounts for it.
    pub fn drain(&self) -> mpsc::TryIter<'_, Event> {
        self.queue.try_iter()
    }
}

/// The compositor thread's end of the event channel.
#[derive(Debug)]
struct EventSender {
    queue: mpsc::SyncSender<Event>,
}

impl EventSender {
    /// Reports an event, waiting for room if the channel is full.
    #[expect(
        dead_code,
        reason = "the handlers that report events arrive with the ported compositor state; the \
                  sender is held now so the receiver the main thread owns is not disconnected"
    )]
    fn send(&self, event: Event) -> Result<(), Disconnected> {
        self.queue.send(event).map_err(|_| Disconnected)
    }
}

/// Creates the snapshot slot and its two ends.
fn snapshot_channel() -> (SnapshotPublisher, SnapshotReader) {
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
struct SnapshotPublisher {
    latest: Arc<ArcSwap<Snapshot>>,
    published: Generation,
}

impl SnapshotPublisher {
    /// Replaces the published snapshot with a newer generation.
    fn publish(
        &mut self,
        windows: Vec<WindowSnapshot>,
        processes: Vec<ProcessSnapshot>,
        outputs: Vec<OutputSnapshot>,
    ) {
        self.published = self.published.next();
        self.latest.store(Arc::new(Snapshot {
            generation: self.published,
            windows,
            processes,
            outputs,
        }));
    }
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

/// Runs `body`, aborting the process if it panics.
///
/// A compositor thread that unwinds leaves the Wayland socket held by a process
/// that no longer services it, and leaves the main thread reading a snapshot
/// that will never change again. A clean abort is the better failure.
///
/// This is a wrapper rather than a panic hook because `std::panic::set_hook` is
/// process-global: a library that installs one takes over the behaviour of
/// every consumer, the test harness included. The policy lives here and the
/// thread that wants it opts in by calling this.
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

/// Builds the compositor, reports whether it started, and then runs it.
fn run(
    commands: Channel<Command>,
    events: EventSender,
    snapshots: SnapshotPublisher,
    started: &mpsc::Sender<Result<(), StartError>>,
) {
    let (mut event_loop, mut data) = match build(commands, events, snapshots) {
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
        data.publish_if_dirty();
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

type CompositorLoop = EventLoop<'static, LoopData>;

fn build(
    commands: Channel<Command>,
    events: EventSender,
    mut snapshots: SnapshotPublisher,
) -> Result<(CompositorLoop, LoopData), StartError> {
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

    // Published before the caller is told the thread started, so a caller that
    // reads a snapshot immediately after `spawn` sees a real one rather than
    // the empty placeholder.
    snapshots.publish(Vec::new(), Vec::new(), Vec::new());

    let signal = event_loop.get_signal();
    Ok((
        event_loop,
        LoopData {
            display,
            state: CompositorState {
                events,
                snapshots,
                signal,
                windows: Vec::new(),
                processes: Vec::new(),
                outputs: Vec::new(),
                dirty: false,
            },
        },
    ))
}

/// What the event loop's callbacks are handed.
///
/// The display and the state are separate fields of one owner because
/// `dispatch_clients` takes the state by mutable reference while borrowing the
/// display, so a single struct holding both cannot be passed to it.
struct LoopData {
    display: Display<CompositorState>,
    state: CompositorState,
}

impl LoopData {
    fn publish_if_dirty(&mut self) {
        if !self.state.dirty {
            return;
        }
        self.state.dirty = false;
        self.state.snapshots.publish(
            self.state.windows.clone(),
            self.state.processes.clone(),
            self.state.outputs.clone(),
        );
    }
}

/// Everything the compositor thread owns that is not the display itself.
struct CompositorState {
    #[expect(
        dead_code,
        reason = "the handlers that report events arrive with the ported compositor state; the \
                  sender is held now so the receiver the main thread owns is not disconnected"
    )]
    events: EventSender,
    snapshots: SnapshotPublisher,
    signal: LoopSignal,
    windows: Vec<WindowSnapshot>,
    processes: Vec<ProcessSnapshot>,
    outputs: Vec<OutputSnapshot>,
    /// Whether something changed since the last publication. A snapshot is
    /// republished only when it would differ, so an idle compositor costs no
    /// allocations.
    dirty: bool,
}

impl CompositorState {
    fn stop(&self) {
        self.signal.stop();
    }

    /// Applies one command.
    ///
    /// The match is exhaustive on purpose. A variant that gains a handler in a
    /// later phase has to be moved out of the unhandled arm deliberately, and a
    /// variant added to the protocol fails to compile here until someone
    /// decides what it does.
    fn handle(&mut self, command: Command) {
        match command {
            Command::Shutdown => {
                debug!("shutting down at the main thread's request");
                self.stop();
            }
            Command::Spawn(_)
            | Command::SignalProcess { .. }
            | Command::CloseWindow { .. }
            | Command::ConfigureWindow { .. }
            | Command::Pointer { .. }
            | Command::PointerLeave { .. }
            | Command::Button { .. }
            | Command::Scroll { .. }
            | Command::Key { .. }
            | Command::Modifiers { .. }
            | Command::TypeText { .. }
            | Command::CreateSeat { .. }
            | Command::DestroySeat { .. }
            | Command::CreateOutput { .. }
            | Command::ReconfigureOutput { .. }
            | Command::DestroyOutput { .. }
            | Command::SetFramePacing { .. } => {
                warn!(?command, "no handler for this command yet; ignoring it");
            }
        }
    }
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
#[derive(Clone, Debug)]
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
            publisher.publish(Vec::new(), Vec::new(), Vec::new());
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

        publisher.publish(Vec::new(), Vec::new(), outputs.clone());

        assert_eq!(reader.load().outputs, outputs);
    }

    #[test]
    fn a_held_snapshot_does_not_change_under_a_later_publication() {
        let (mut publisher, reader) = snapshot_channel();
        publisher.publish(Vec::new(), Vec::new(), Vec::new());

        let held = reader.load();
        publisher.publish(Vec::new(), Vec::new(), Vec::new());

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
    fn a_send_to_a_full_channel_waits_for_room_rather_than_dropping() {
        let (queue, channel) = calloop::channel::sync_channel(1);
        let sender = CommandSender { queue };

        sender
            .try_send(Command::Shutdown)
            .expect("the channel starts empty");

        let (progress, watch) = mpsc::channel();
        let waiter = thread::spawn(move || {
            progress
                .send(Progress::Sending)
                .expect("the test is watching");
            sender
                .send(Command::Shutdown)
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

        channel.try_recv().expect("the queued command is delivered");

        assert_eq!(
            watch.recv_timeout(DEADLINE).expect("the sender finished"),
            Progress::Sent
        );
        channel
            .try_recv()
            .expect("the waiting command was delivered, not dropped");
        waiter.join().expect("the sending thread finished cleanly");
    }

    #[test]
    fn the_thread_starts_publishes_and_stops() {
        let compositor = spawn().expect("the compositor thread starts");

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
        let compositor = spawn().expect("the compositor thread starts");
        let snapshots = compositor.snapshots().clone();
        drop(compositor);

        // The reader outlives the thread and keeps answering with the last
        // snapshot, which is what a dead-handle read depends on.
        assert_eq!(snapshots.load().generation.get(), 1);
    }

    #[test]
    fn the_loop_keeps_draining_commands_it_has_no_handler_for() {
        let compositor = spawn().expect("the compositor thread starts");
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
