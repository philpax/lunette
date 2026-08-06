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
    protocol::{Command, Event, ImageHandle, ImportedImage, PixelSize, Snapshot},
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

        let (event_loop, data) = build(Ingredients {
            config,
            importer: recording_importer(imports.clone()),
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

        (theirs, client)
    }

    /// Runs one round of the event loop, then flushes everything that produced.
    pub fn step(&mut self) {
        self.event_loop
            .dispatch(Duration::ZERO, &mut self.data)
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
