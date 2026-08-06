//! A compositor that runs on the calling thread, for tests.
//!
//! The compositor's own tests must run with no graphics device, no XR runtime,
//! and no headset attached (`AC9.4`), and they must not touch the filesystem or
//! the environment. What makes that possible is here: [`TestCompositor`] builds
//! the real event loop, the real display, and the real handlers, but binds no
//! listening socket and is stepped by the test rather than by a thread.
//!
//! Clients arrive over a `UnixStream::pair()`. One end goes to
//! `DisplayHandle::insert_client`, the other is the client's. No socket is
//! bound, no path is written, and `XDG_RUNTIME_DIR` is never read.
//!
//! [`RecordingImporter`] stands in for the graphics device. It is the seam the
//! whole no-GPU property rests on: nothing below it is reachable from this
//! crate.

#![expect(
    clippy::expect_used,
    reason = "test scaffolding: a failed expectation is how a test reports a failure, and this \
              module is gated behind `cfg(test)` or the `test-fakes` feature"
)]

use std::{
    collections::HashMap,
    io,
    os::unix::net::UnixStream,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::Duration,
};

use smithay::{
    backend::allocator::{Buffer, Fourcc, Modifier, dmabuf::Dmabuf},
    reexports::{calloop, wayland_server::Client},
};

use crate::{
    process::{ChildProcess, ProcessInspector, ProcessSpawner, SpawnError, SpawnPlan},
    protocol::{
        Command, Event, ImageHandle, ImportedImage, Pid, PixelSize, ProcessOutcome, ProcessSignal,
        Snapshot, Stream,
    },
    state::{ClientState, CompositorConfig},
    surface::{BufferImporter, ImportFailed, ShmLayout},
    thread::{
        COMMAND_CAPACITY, CommandSender, CompositorLoop, EVENT_CAPACITY, EventReceiver,
        EventSender, Ingredients, LoopData, SnapshotReader, build, snapshot_channel,
    },
};

/// How long a test waits for a condition before declaring it a failure.
///
/// Nothing here waits for a duration. This is only the point at which waiting
/// for a condition stops being patience and starts being a hang.
pub const DEADLINE: Duration = Duration::from_secs(5);

/// A compositor stepped by the caller rather than by a thread.
pub struct TestCompositor {
    event_loop: CompositorLoop,
    data: LoopData,
    commands: CommandSender,
    events: EventReceiver,
    snapshots: SnapshotReader,
    imports: ImportLog,
    spawns: SpawnLog,
    proc: FakeInspector,
}

impl TestCompositor {
    /// Builds a compositor with the default configuration and no graphics
    /// device.
    #[must_use]
    pub fn new() -> Self {
        Self::with_config(CompositorConfig::default())
    }

    /// Builds a compositor with a configuration of the caller's choosing.
    #[must_use]
    pub fn with_config(config: CompositorConfig) -> Self {
        let (commands, command_channel) = calloop::channel::sync_channel(COMMAND_CAPACITY);
        let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
        let (snapshots, reader) = snapshot_channel();
        let imports = ImportLog::default();
        let spawns = SpawnLog::default();
        let proc = FakeInspector::default();

        let (event_loop, data) = build(Ingredients {
            config,
            importer: recording_importer(imports.clone()),
            spawner: Box::new(FakeSpawner {
                log: spawns.clone(),
            }),
            inspector: Box::new(proc.clone()),
            commands: command_channel,
            events: EventSender {
                queue: event_sender,
            },
            snapshots,
        })
        .unwrap_or_else(|error| panic!("the test compositor could not be built: {error}"));

        Self {
            event_loop,
            data,
            commands: CommandSender { queue: commands },
            events: EventReceiver { queue: events },
            snapshots: reader,
            imports,
            spawns,
            proc,
        }
    }

    /// Connects a client over a socket pair and hands back the client's end.
    ///
    /// The client's end is non-blocking, because both ends live on the same
    /// thread: a blocking read on the client would wait for a compositor that
    /// only runs when the test steps it.
    pub fn connect(&mut self) -> (UnixStream, Client) {
        let (ours, theirs) = UnixStream::pair().expect("a socket pair can always be made");
        theirs
            .set_nonblocking(true)
            .expect("a fresh socket accepts the flag");

        let client = self
            .data
            .display
            .handle()
            .insert_client(ours, Arc::new(ClientState::default()))
            .expect("the display accepts a client");

        // The same call the listening socket makes, so a test sees the same
        // attribution a real connection gets.
        self.data.state.attach_client(&client);

        (theirs, client)
    }

    /// Runs one round of the event loop, then flushes everything that produced.
    ///
    /// Returns immediately when nothing is ready, so a caller stepping in a
    /// loop spins rather than waits.
    pub fn step(&mut self) {
        self.step_for(Duration::ZERO);
    }

    /// Runs one round, waiting up to `timeout` for something to happen.
    ///
    /// The wait is what lets a timer inside the compositor — the one that reaps
    /// spawned processes — fire without the test sleeping.
    pub fn step_for(&mut self, timeout: Duration) {
        self.event_loop
            .dispatch(timeout, &mut self.data)
            .expect("the event loop dispatches");
        self.data.state.send_frame_callbacks();
        self.data.state.publish_if_dirty();
        drop(self.data.display.flush_clients());
    }

    /// The latest published snapshot.
    #[must_use]
    pub fn snapshot(&self) -> Arc<Snapshot> {
        self.snapshots.load()
    }

    /// Every event reported since the last drain.
    pub fn drain_events(&self) -> Vec<Event> {
        self.events.drain().collect()
    }

    /// Steps until the events collected satisfy `ready`, failing at the
    /// deadline.
    ///
    /// Waits for a condition rather than for a duration: the compositor's own
    /// timers decide when a process's output and exit are noticed, and a fixed
    /// sleep long enough for that on one machine is not long enough on another.
    pub fn collect_events(&mut self, ready: impl Fn(&[Event]) -> bool) -> Vec<Event> {
        let expiry = std::time::Instant::now() + DEADLINE;
        let mut collected = Vec::new();

        loop {
            self.step_for(Duration::from_millis(10));
            collected.extend(self.drain_events());

            if ready(&collected) {
                return collected;
            }
            assert!(
                std::time::Instant::now() < expiry,
                "the compositor did not report the expected events within {DEADLINE:?}: \
                 {collected:?}"
            );
        }
    }

    /// Queues a command, as the main thread would.
    pub fn send(&self, command: Command) {
        self.commands
            .send(command)
            .expect("the test compositor is still running");
    }

    /// How many buffers the importer was asked for.
    #[must_use]
    pub fn imports(&self) -> ImportLog {
        self.imports.clone()
    }

    /// What the spawner was asked to start, and the children it handed back.
    #[must_use]
    pub fn spawns(&self) -> SpawnLog {
        self.spawns.clone()
    }

    /// The `/proc` the compositor consults when attributing a client.
    #[must_use]
    pub fn proc(&self) -> FakeInspector {
        self.proc.clone()
    }
}

impl Default for TestCompositor {
    fn default() -> Self {
        Self::new()
    }
}

/// What the fake importer was asked to do.
#[derive(Clone, Debug, Default)]
pub struct ImportLog {
    dmabufs: Arc<AtomicU64>,
    shm: Arc<Mutex<Vec<ShmLayout>>>,
    /// When set, every import is refused with this message. Lets a test drive
    /// the path where a client's buffer cannot be imported.
    refusal: Arc<Mutex<Option<String>>>,
}

impl ImportLog {
    #[must_use]
    pub fn dmabuf_count(&self) -> u64 {
        self.dmabufs.load(Ordering::Relaxed)
    }

    #[must_use]
    pub fn shm_layouts(&self) -> Vec<ShmLayout> {
        self.shm
            .lock()
            .map(|layouts| layouts.clone())
            .unwrap_or_default()
    }

    /// Makes every subsequent import fail.
    pub fn refuse(&self, reason: &str) {
        if let Ok(mut refusal) = self.refusal.lock() {
            *refusal = Some(reason.to_owned());
        }
    }

    fn refused(&self) -> Option<ImportFailed> {
        self.refusal
            .lock()
            .ok()
            .and_then(|refusal| refusal.clone())
            .map(ImportFailed::new)
    }
}

/// A fake importer reporting into `log`.
#[must_use]
pub fn recording_importer(log: ImportLog) -> Box<dyn BufferImporter> {
    Box::new(RecordingImporter { log })
}

/// Stands in for the graphics device.
///
/// It records what it was asked for and answers with a handle that is not a
/// real image. Nothing in this crate dereferences the handle — that is the
/// whole point of it crossing the protocol as an opaque integer — so a
/// fabricated one is indistinguishable from a real one here.
struct RecordingImporter {
    log: ImportLog,
}

impl RecordingImporter {
    /// A handle that is deliberately not a valid image.
    fn fabricate(size: PixelSize, format: Fourcc) -> ImportedImage {
        ImportedImage {
            image: ImageHandle::new(0xDEAD_0000_0000_0001).unwrap_or_else(|| unreachable!()),
            size,
            format,
            modifier: Modifier::Linear,
        }
    }
}

impl BufferImporter for RecordingImporter {
    fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> Result<ImportedImage, ImportFailed> {
        if let Some(refusal) = self.log.refused() {
            return Err(refusal);
        }

        self.log.dmabufs.fetch_add(1, Ordering::Relaxed);
        let size = dmabuf.size();
        #[expect(
            clippy::cast_sign_loss,
            reason = "smithay rejects a dmabuf with a negative size before it reaches a handler"
        )]
        Ok(Self::fabricate(
            PixelSize::new(size.w as u32, size.h as u32),
            dmabuf.format().code,
        ))
    }

    fn import_shm(
        &mut self,
        pixels: &[u8],
        layout: ShmLayout,
    ) -> Result<ImportedImage, ImportFailed> {
        if let Some(refusal) = self.log.refused() {
            return Err(refusal);
        }

        let expected = (layout.stride as usize).saturating_mul(layout.size.height as usize);
        assert!(
            pixels.len() >= expected,
            "the compositor handed the importer fewer bytes than the layout describes"
        );

        if let Ok(mut layouts) = self.log.shm.lock() {
            layouts.push(layout);
        }
        Ok(Self::fabricate(layout.size, Fourcc::Argb8888))
    }
}

/// What the fake spawner was asked to start, and the children it handed back.
///
/// Cloneable and shared, so a test holds one while the compositor holds the
/// other and neither has to reach into the other's state.
#[derive(Clone, Debug, Default)]
pub struct SpawnLog {
    inner: Arc<Mutex<SpawnLogState>>,
}

#[derive(Debug, Default)]
struct SpawnLogState {
    requested: Vec<SpawnPlan>,
    children: Vec<Arc<Mutex<FakeChildState>>>,
    refusal: Option<String>,
    next_pid: i32,
}

impl SpawnLog {
    /// Everything the compositor asked to be started, in order.
    #[must_use]
    pub fn requested(&self) -> Vec<SpawnPlan> {
        self.with(|state| state.requested.clone())
    }

    /// Makes every subsequent spawn fail, as a mistyped program name does.
    pub fn refuse(&self, reason: &str) {
        self.with(|state| state.refusal = Some(reason.to_owned()));
    }

    /// Ends the nth child that was started.
    pub fn finish(&self, index: usize, outcome: ProcessOutcome) {
        self.child(index, |child| child.outcome = Some(outcome.clone()));
    }

    /// Makes the nth child appear to have written something.
    pub fn write(&self, index: usize, stream: Stream, bytes: &[u8]) {
        self.child(index, |child| child.output.push((stream, bytes.to_vec())));
    }

    /// Every signal the nth child's process group was sent.
    #[must_use]
    pub fn signals(&self, index: usize) -> Vec<ProcessSignal> {
        let mut signals = Vec::new();
        self.child(index, |child| signals.clone_from(&child.signals));
        signals
    }

    /// The pid the nth child was given.
    #[must_use]
    pub fn pid(&self, index: usize) -> Option<Pid> {
        let mut pid = None;
        self.child(index, |child| pid = Some(child.pid));
        pid
    }

    fn child(&self, index: usize, act: impl FnOnce(&mut FakeChildState)) {
        let child = self.with(|state| state.children.get(index).cloned());
        if let Some(child) = child
            && let Ok(mut child) = child.lock()
        {
            act(&mut child);
        }
    }

    fn with<T>(&self, act: impl FnOnce(&mut SpawnLogState) -> T) -> T {
        let mut state = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        act(&mut state)
    }
}

/// A spawner that starts nothing and records what it was asked for.
#[derive(Debug, Default)]
pub struct FakeSpawner {
    pub log: SpawnLog,
}

impl ProcessSpawner for FakeSpawner {
    fn spawn(&mut self, plan: &SpawnPlan) -> Result<Box<dyn ChildProcess>, SpawnError> {
        self.log.with(|state| {
            state.requested.push(plan.clone());

            if let Some(reason) = state.refusal.clone() {
                return Err(SpawnError::for_test(
                    plan.argv.program().to_owned(),
                    io::Error::new(io::ErrorKind::NotFound, reason),
                ));
            }

            state.next_pid += 1;
            let pid = Pid::new(10_000 + state.next_pid)
                .unwrap_or_else(|| unreachable!("the counter starts above zero"));
            let child = Arc::new(Mutex::new(FakeChildState {
                pid,
                outcome: None,
                output: Vec::new(),
                signals: Vec::new(),
            }));
            state.children.push(Arc::clone(&child));

            Ok(Box::new(FakeChild { pid, state: child }) as Box<dyn ChildProcess>)
        })
    }
}

#[derive(Debug)]
struct FakeChildState {
    pid: Pid,
    outcome: Option<ProcessOutcome>,
    output: Vec<(Stream, Vec<u8>)>,
    signals: Vec<ProcessSignal>,
}

#[derive(Debug)]
struct FakeChild {
    pid: Pid,
    state: Arc<Mutex<FakeChildState>>,
}

impl FakeChild {
    fn with<T>(&self, act: impl FnOnce(&mut FakeChildState) -> T) -> T {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        act(&mut state)
    }
}

impl ChildProcess for FakeChild {
    fn pid(&self) -> Pid {
        self.pid
    }

    fn poll(&mut self) -> Option<ProcessOutcome> {
        self.with(|state| state.outcome.take())
    }

    fn read_output(&mut self) -> Vec<(Stream, Vec<u8>)> {
        self.with(|state| std::mem::take(&mut state.output))
    }

    fn signal(&mut self, signal: ProcessSignal) {
        self.with(|state| state.signals.push(signal));
    }
}

/// A `/proc` that answers from a table rather than from the filesystem.
///
/// A test that wants a client attributed to a process plants that process's
/// token against the connecting pid, which over a socket pair is the test's own.
#[derive(Clone, Debug, Default)]
pub struct FakeInspector {
    environments: Arc<Mutex<HashMap<i32, Vec<u8>>>>,
    dead: Arc<Mutex<Vec<i32>>>,
}

impl FakeInspector {
    /// Sets a process's whole environment block, NUL-separated as `/proc` has
    /// it.
    pub fn set_environment(&self, pid: i32, block: Vec<u8>) {
        if let Ok(mut environments) = self.environments.lock() {
            environments.insert(pid, block);
        }
    }

    /// Sets a single variable in a process's environment.
    pub fn set_variable(&self, pid: i32, key: &str, value: &[u8]) {
        let mut block = Vec::new();
        block.extend_from_slice(key.as_bytes());
        block.push(b'=');
        block.extend_from_slice(value);
        block.push(0);
        self.set_environment(pid, block);
    }

    /// Makes a process appear to have ended.
    pub fn kill(&self, pid: i32) {
        if let Ok(mut dead) = self.dead.lock() {
            dead.push(pid);
        }
    }
}

impl ProcessInspector for FakeInspector {
    fn read_environment(&self, pid: Pid, key: &str) -> io::Result<Option<Vec<u8>>> {
        let environments = self
            .environments
            .lock()
            .map_err(|_| io::Error::other("the fake environment table is poisoned"))?;
        let block = environments
            .get(&pid.get())
            .ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;

        Ok(crate::process::find_environment_value(
            block,
            key.as_bytes(),
        ))
    }

    fn is_running(&self, pid: Pid) -> bool {
        self.dead
            .lock()
            .is_ok_and(|dead| !dead.contains(&pid.get()))
    }
}
