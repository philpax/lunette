//! Test support for a compositor driven on the calling thread.
//!
//! [`TestCompositor`] uses the real event loop, display, and handlers. Tests
//! connect clients with `UnixStream::pair()` and step the compositor directly,
//! so the harness binds no listening socket and reads or writes no runtime
//! filesystem, process environment, graphics device, XR runtime, or headset.
//!
//! [`RecordingImporter`] is the graphics seam. It records import requests and
//! returns opaque image handles without calling graphics APIs.

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
        Arc, Condvar, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

use smithay::{
    backend::allocator::{Buffer, Fourcc, Modifier, dmabuf::Dmabuf},
    input::pointer::CursorImageStatus,
    reexports::{calloop, wayland_server::Client},
};

pub use crate::selection::{FakeHost, FakeHostSource, HostCall};
use crate::{
    config::CompositorConfig,
    protocol::{
        Command, Event, ImageHandle, ImportedImage, OutputId, Pid, PixelSize, ProcessOutcome,
        ProcessSignal, SeatId, Snapshot, Stream,
    },
    spawn::{ChildProcess, Liveness, ProcessInspector, ProcessSpawner, SpawnError, SpawnPlan},
    surface::{BufferImporter, ImportFailed, PixelBuffer, ShmFormat, ShmLayout},
    thread::{
        COMMAND_CAPACITY, CommandSender, CompositorHandle, CompositorLoop, EVENT_CAPACITY,
        EventReceiver, EventSender, Ingredients, LoopData, SnapshotReader, build, snapshot_channel,
    },
    wayvr::{comp::ClientState, process::find_environment_value},
};

/// Maximum time to wait for a test condition.
pub const DEADLINE: Duration = Duration::from_secs(5);

/// A compositor thread that accepts commands without sending responses.
///
/// The thread owns the far endpoints of all three channels, so the handle stays
/// connected while the thread waits. [`SilentCompositor::stop`] releases the
/// thread before `CompositorHandle::shutdown` joins it.
#[must_use]
pub fn silent_compositor() -> (CompositorHandle, SilentCompositor) {
    let (commands, command_channel) = calloop::channel::sync_channel(COMMAND_CAPACITY);
    let (event_sender, events) = mpsc::sync_channel(EVENT_CAPACITY);
    let (snapshots, reader) = snapshot_channel();

    let stop = Arc::new((Mutex::new(false), Condvar::new()));
    let parked = Arc::clone(&stop);
    let thread = thread::Builder::new()
        .name("silent-compositor".to_owned())
        .spawn(move || {
            // Dropping an endpoint closes its channel, which would make the handle appear
            // disconnected. The endpoints stay alive, so the handle keeps waiting.
            let _channels = (
                command_channel,
                EventSender {
                    queue: event_sender,
                },
                snapshots,
            );

            let (flag, released) = &*parked;
            let mut stopped = flag.lock().expect("the stop flag is not poisoned");
            while !*stopped {
                stopped = released
                    .wait(stopped)
                    .expect("the stop flag is not poisoned");
            }
        })
        .expect("the silent compositor thread starts");

    (
        CompositorHandle::from_parts(
            CommandSender { queue: commands },
            EventReceiver { queue: events },
            reader,
            thread,
        ),
        SilentCompositor(stop),
    )
}

/// Releases a silent compositor thread before its handle is joined.
pub struct SilentCompositor(Arc<(Mutex<bool>, Condvar)>);

impl SilentCompositor {
    /// Sets the release flag and wakes the parked thread before the handle joins
    /// it.
    pub fn stop(self) {
        let (flag, released) = &*self.0;
        *flag.lock().expect("the stop flag is not poisoned") = true;
        released.notify_all();
    }
}

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
    #[must_use]
    pub fn new() -> Self {
        Self::with_config(CompositorConfig::default())
    }

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
            // `None` prevents a listener from binding and avoids runtime-path
            // access; clients use in-process socket pairs.
            socket: None,
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

    /// Connects a client over an in-process socket pair. The client end is
    /// non-blocking because the compositor advances only when the test steps it.
    pub fn connect(&mut self) -> (UnixStream, Client) {
        let (ours, theirs) = UnixStream::pair().expect("a socket pair can always be made");
        theirs
            .set_nonblocking(true)
            .expect("a fresh socket accepts the flag");

        // Accept the client as the listener does, so socket-pair clients
        // receive the same process attribution as listener clients.
        let client = self
            .data
            .state
            .accept_connection(ours)
            .expect("the display accepts a client");

        (theirs, client)
    }

    /// Connects a client with a direct output assignment. The assignment follows
    /// attachment, which clears process-derived assignments, and precedes the
    /// first dispatch, which advertises filtered outputs.
    pub fn connect_assigned(&mut self, output: OutputId) -> (UnixStream, Client) {
        let (stream, client) = self.connect();
        if let Some(state) = client.get_data::<ClientState>() {
            state.assign(Some(output));
        }
        (stream, client)
    }

    /// Runs one event-loop round and flushes its output.
    pub fn step(&mut self) {
        self.step_for(Duration::ZERO);
    }

    /// Runs one event-loop round, waiting up to `timeout` for an event.
    pub fn step_for(&mut self, timeout: Duration) {
        // Keep the same post-dispatch ordering as the running compositor: drain
        // the handlers' tasks, retire imports, send frame callbacks, publish
        // state, then flush clients.
        self.event_loop
            .dispatch(timeout, &mut self.data)
            .expect("the event loop dispatches");
        self.data.state.tick_events();
        self.data.state.sweep_imports();
        self.data.state.send_frame_callbacks();
        self.data.state.publish_if_dirty();
        drop(self.data.display.flush_clients());
    }

    #[must_use]
    pub fn snapshot(&self) -> Arc<Snapshot> {
        self.snapshots.load()
    }

    pub fn drain_events(&self) -> Vec<Event> {
        self.events.drain().collect()
    }

    /// Steps until `ready` accepts the collected events or `DEADLINE` expires.
    /// It polls the condition; it does not sleep for a fixed duration.
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

    pub fn send(&self, command: Command) {
        self.commands
            .try_send(command)
            .expect("the test compositor is still running and its queue has room");
    }

    #[must_use]
    pub fn imports(&self) -> ImportLog {
        self.imports.clone()
    }

    #[must_use]
    pub fn spawns(&self) -> SpawnLog {
        self.spawns.clone()
    }

    #[must_use]
    pub fn proc(&self) -> FakeInspector {
        self.proc.clone()
    }

    /// Returns cursor state from the compositor because a client cannot observe
    /// another seat's cursor state.
    #[must_use]
    pub fn cursor_image(&self, seat: SeatId) -> Option<CursorImage> {
        self.data
            .state
            .cursor_image(seat)
            .map(|status| match status {
                CursorImageStatus::Hidden => CursorImage::Hidden,
                CursorImageStatus::Named(_) => CursorImage::Named,
                CursorImageStatus::Surface(_) => CursorImage::Surface,
            })
    }

    /// Lets `skip` keymap uploads succeed, then fails the next `count` uploads.
    /// The production path rejects only invalid layouts, so the seam injects a
    /// failure at a chosen upload to exercise keymap restoration.
    pub fn fail_keymap_uploads(&self, skip: usize, count: usize) {
        self.data.state.fail_keymap_uploads(skip, count);
    }

    /// Advances the compositor's virtual clock. Frame pacing reads this clock,
    /// so tests avoid sleeping while exercising time-dependent behavior.
    pub fn advance_clock(&mut self, by: Duration) {
        self.data.state.advance_clock(by);
    }
}

impl Default for TestCompositor {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CursorImage {
    Hidden,
    Named,
    Surface,
}

/// Records importer requests and injected failures.
#[derive(Clone, Debug, Default)]
pub struct ImportLog {
    dmabufs: Arc<AtomicU64>,
    shm: Arc<Mutex<Vec<ShmLayout>>>,
    /// A set refusal makes every subsequent import fail with this message.
    refusal: Arc<Mutex<Option<String>>>,
    sweeps: Arc<AtomicU64>,
}

impl ImportLog {
    #[must_use]
    pub fn dmabuf_count(&self) -> u64 {
        self.dmabufs.load(Ordering::Relaxed)
    }

    /// Returns how often the compositor requests that the importer release retired
    /// images.
    #[must_use]
    pub fn sweep_count(&self) -> u64 {
        self.sweeps.load(Ordering::Relaxed)
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

#[must_use]
pub fn recording_importer(log: ImportLog) -> Box<dyn BufferImporter> {
    Box::new(RecordingImporter { log })
}

/// Replaces the graphics device without calling graphics APIs. The fabricated
/// image handle is an opaque protocol value the crate never dereferences.
#[derive(Debug)]
struct RecordingImporter {
    log: ImportLog,
}

impl RecordingImporter {
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
    fn accepts_imports(&self) -> bool {
        true
    }

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
    ) -> Result<PixelBuffer, ImportFailed> {
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

        // Repacking is outside this seam; the return is a buffer with the requested
        // shape, recorded after the layout is logged.
        let blank = vec![
            0;
            (layout.size.width as usize)
                .saturating_mul(layout.size.height as usize)
                .saturating_mul(ShmFormat::BYTES_PER_PIXEL as usize)
        ];
        PixelBuffer::new(layout.size, layout.format, blank)
            .ok_or_else(|| ImportFailed::new("the fake importer packed a buffer of the wrong size"))
    }

    /// Records the sweep request without retaining imported images.
    fn sweep(&mut self) {
        self.log.sweeps.fetch_add(1, Ordering::Relaxed);
    }
}

/// Records spawn requests and shares control of fake children between clones.
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
    /// Returns spawn requests in submission order.
    #[must_use]
    pub fn requested(&self) -> Vec<SpawnPlan> {
        self.with(|state| state.requested.clone())
    }

    /// Makes subsequent spawns fail with the supplied I/O error reason.
    pub fn refuse(&self, reason: &str) {
        self.with(|state| state.refusal = Some(reason.to_owned()));
    }

    pub fn finish(&self, index: usize, outcome: ProcessOutcome) {
        self.child(index, |child| child.outcome = Some(outcome.clone()));
    }

    pub fn write(&self, index: usize, stream: Stream, bytes: &[u8]) {
        self.child(index, |child| child.output.push((stream, bytes.to_vec())));
    }

    #[must_use]
    pub fn signals(&self, index: usize) -> Vec<ProcessSignal> {
        let mut signals = Vec::new();
        self.child(index, |child| signals.clone_from(&child.signals));
        signals
    }

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

/// A spawner seam that records requests and returns controllable fake children.
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
                liveness: Liveness::default(),
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
    /// Tracks whether the child has been reaped. A reaped child's process-group
    /// identifier must not receive signals because the kernel can reuse it.
    liveness: Liveness,
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
        self.with(|state| {
            if !state.liveness.may_signal() {
                return None;
            }
            let outcome = state.outcome.take();
            if outcome.is_some() {
                state.liveness = Liveness::Reaped;
            }
            outcome
        })
    }

    fn read_output(&mut self) -> Vec<(Stream, Vec<u8>)> {
        self.with(|state| std::mem::take(&mut state.output))
    }

    fn signal(&mut self, signal: ProcessSignal) {
        self.with(|state| {
            if state.liveness.may_signal() {
                state.signals.push(signal);
            }
        });
    }
}

impl Drop for FakeChild {
    /// Matches the real child lifecycle: a running child's process group is
    /// terminated and the child is marked reaped; a reaped child receives no signal.
    fn drop(&mut self) {
        self.signal(ProcessSignal::Terminate);
        self.with(|state| state.liveness = Liveness::Reaped);
    }
}

/// A process inspector backed by in-memory tables, not `/proc`.
/// Environment blocks use the same NUL-separated, byte-preserving format as
/// `/proc/<pid>/environ`.
#[derive(Clone, Debug, Default)]
pub struct FakeInspector {
    environments: Arc<Mutex<HashMap<i32, Vec<u8>>>>,
    dead: Arc<Mutex<Vec<i32>>>,
}

impl FakeInspector {
    /// Sets a process environment block in the NUL-separated format used by
    /// `/proc/<pid>/environ`.
    pub fn set_environment(&self, pid: i32, block: Vec<u8>) {
        if let Ok(mut environments) = self.environments.lock() {
            environments.insert(pid, block);
        }
    }

    /// Encodes one variable as `key=value\0` in the process environment block.
    pub fn set_variable(&self, pid: i32, key: &str, value: &[u8]) {
        let mut block = Vec::new();
        block.extend_from_slice(key.as_bytes());
        block.push(b'=');
        block.extend_from_slice(value);
        block.push(0);
        self.set_environment(pid, block);
    }

    /// Makes `is_running` report that the process no longer exists.
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

        Ok(find_environment_value(block, key.as_bytes()))
    }

    fn is_running(&self, pid: Pid) -> bool {
        self.dead
            .lock()
            .is_ok_and(|dead| !dead.contains(&pid.get()))
    }
}
