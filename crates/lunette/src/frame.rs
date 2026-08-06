//! Linux-only: the per-frame cycle that joins the compositor thread to the Lua
//! session.
//!
//! Everything else in this crate is one half of a seam. [`crate::lua`] reads a
//! snapshot and queues commands; [`lunette_compositor::thread`] publishes
//! snapshots and consumes commands; [`crate::import`] turns a client buffer into
//! an image and [`crate::texture`] turns that into something Lua can sample.
//! This module is what runs between them, once per frame, in the order the
//! pieces require.
//!
//! # The order of a frame
//!
//! At frame start, in this order and for the reasons given:
//!
//! 1. Start the compositor if LÖVR has created its graphics device and the
//!    compositor is not running yet. See below.
//! 2. Install the compositor's latest snapshot on the session, which advances
//!    the frame generation and so invalidates the previous frame's texture
//!    handles.
//! 3. Drain the event channel. Every event is applied to the texture ledger and
//!    then queued for `lovr.lun*` dispatch. The drain follows the snapshot
//!    rather than preceding it so that a handler reading `lunette.windows()`
//!    sees a snapshot that already accounts for the event it was handed.
//! 4. Refresh the stabilised copies, and record an acquire barrier over every
//!    texture the frame may sample.
//! 5. Destroy the images whose deferral has elapsed. This is last because
//!    [`destroy_due_images`] is only sound after the frame's events have been
//!    drained and the textures they displaced have been released, which is
//!    step 3.
//!
//! At frame end: record the release barriers, then hand the frame's queued
//! commands to the compositor.
//!
//! # Why the compositor cannot start with everything else
//!
//! The compositor imports client dmabufs against LÖVR's `VkDevice`, so it
//! cannot exist before LÖVR has made one — which happens inside `boot.lua`,
//! several steps after the process starts. So the start is deferred to the
//! first frame at which `lovrGraphicsIsInitialized` answers true, and the
//! listening socket is bound long before that, by the entry point, for the
//! reason `crates/lunette/src/main.rs` records.
//!
//! A failure to start is reported once and not retried. The socket is dropped
//! with the attempt, so a second attempt would be against a name that is no
//! longer bound, and the failures that can occur here — a device without the
//! import extensions, a thread that cannot be spawned — do not become true
//! later.

use std::{error::Error, fmt, rc::Rc, sync::Arc};

use lunette_compositor::{
    client::{DisplayName, WaylandSocket, XwaylandSatellite},
    protocol::{Event, ImportedBuffer, Snapshot, SurfaceId},
    state::CompositorConfig,
    thread::{self, CompositorHandle, PanicPolicy, StartError},
};
use lunette_lovr::raw::lovrGraphicsIsInitialized;
use tracing::{error, info, warn};

use crate::{
    events::LuaEvent,
    import::{DeviceError, GraphicsDevice, ImageArena, Importer},
    lua::Session,
    texture::{BarrierPolicy, LovrTexture, Released, TextureLedger, destroy_due_images},
};

/// What the entry point resolved before any thread existed, for the compositor
/// to be built from later.
///
/// The socket is here rather than being bound on demand because binding it is
/// what produces the display name, and the display name has to be exported into
/// the environment while the process is still single-threaded.
#[derive(Debug)]
pub struct Startup {
    pub socket: WaylandSocket,
    pub display: DisplayName,
    /// Where to find xwayland-satellite. Absent means X11 clients are not
    /// served.
    pub satellite: Option<XwaylandSatellite>,
    /// How the two open questions about the import barrier are answered for
    /// this run. Both are milestone 0's to measure.
    pub barriers: BarrierPolicy,
}

/// Drives one frame of the session against the compositor.
///
/// Owned by the boot sequence and outliving every Lua state, so that a restart
/// throws the state away without disturbing the clients.
#[derive(Debug)]
pub struct FrameDriver {
    session: Rc<Session<LovrTexture>>,
    /// Consumed by the first successful or failed start.
    startup: Option<Startup>,
    compositor: Option<Compositor>,
    barriers: BarrierPolicy,
    /// Handed to [`Session::begin`] while there is no compositor, so that the
    /// generation still advances and a texture handle from the frame before is
    /// still refused.
    empty: Arc<Snapshot>,
}

/// A running compositor and the two things shared with its thread.
#[derive(Debug)]
struct Compositor {
    handle: CompositorHandle,
    /// Borrowed from LÖVR. Held here because destroying an image needs it, and
    /// destruction happens on this side.
    device: Arc<GraphicsDevice>,
    arena: ImageArena,
}

impl FrameDriver {
    #[must_use]
    pub fn new(session: Rc<Session<LovrTexture>>, startup: Startup) -> Self {
        Self {
            session,
            barriers: startup.barriers,
            startup: Some(startup),
            compositor: None,
            empty: Arc::new(Snapshot::default()),
        }
    }

    /// Prepares the frame the Lua session is about to run.
    pub fn begin_frame(&mut self) {
        self.start_if_ready();

        let snapshot = self.compositor.as_ref().map_or_else(
            || Arc::clone(&self.empty),
            |compositor| compositor.handle.snapshots().load(),
        );
        self.session.begin(snapshot);

        self.drain_events();

        let barriers = self.barriers;
        self.session.with_textures(|ledger| {
            ledger.refresh_stable();
            for texture in ledger.textures() {
                // SAFETY: this is the frame thread, LÖVR's graphics module is
                // initialised because a texture exists at all, and the acquire
                // is recorded before anything in the frame can sample it —
                // `lovr.draw` has not run yet.
                if !unsafe { texture.acquire(barriers) } {
                    warn!("an imported texture could not be acquired for this frame");
                }
            }
        });

        // Last, and only here: `destroy_due_images` is sound only after the
        // frame's events have been drained into the ledger and the textures
        // they displaced have been released, which the drain above did.
        if let Some(compositor) = &self.compositor {
            let now = self.session.generation();
            self.session.with_textures(|ledger| {
                // SAFETY: the ordering the function documents is the ordering
                // of this method, stated in the module note above.
                unsafe { destroy_due_images(ledger, &compositor.arena, &compositor.device, now) };
            });
        }
    }

    /// Closes the frame the Lua session has finished, sending what it queued.
    pub fn end_frame(&mut self) {
        // Again here, and not only at frame start. LÖVR initialises graphics
        // during the first frame, so at that frame's start there was no device
        // to lend and no compositor — but by its end there is, and `lovr.load`
        // has already run and queued whatever it asked for. Without this the
        // first frame's commands, which is where a configuration does its
        // spawning, are flushed into nothing.
        self.start_if_ready();

        let barriers = self.barriers;
        self.session.with_textures(|ledger| {
            for texture in ledger.textures() {
                // SAFETY: as the acquire, and after the frame's reads: nothing
                // else runs between `lovr.draw` returning and this.
                if !unsafe { texture.release(barriers) } {
                    warn!("an imported texture could not be released at frame end");
                }
            }
        });

        let commands = self.session.flush();
        let Some(compositor) = &self.compositor else {
            if !commands.is_empty() {
                warn!(
                    queued = commands.len(),
                    "the configuration asked for something before the compositor was running"
                );
            }
            return;
        };

        for command in commands {
            // Waiting rather than dropping. A dropped `CloseWindow` is a window
            // that never closes, and the wait cannot deadlock: the compositor
            // thread drains its queue on every pass of its own loop and never
            // waits on this one.
            if let Err(error) = compositor.handle.commands().send(command) {
                warn!(%error, "the frame's remaining commands were not delivered");
                break;
            }
        }
    }

    /// Stops the compositor and releases every texture the session held.
    ///
    /// Called before the Lua state closes, because closing it destroys LÖVR's
    /// graphics module and with it the device the compositor thread borrowed.
    ///
    /// The images themselves are deliberately not destroyed. LÖVR retires an
    /// imported texture's image *view* through its own morgue, which is emptied
    /// only by `gpu_destroy`, and `vkDestroyImage` on an image that still has a
    /// view is invalid. There are no further frames to defer into, so the
    /// images are left for the device teardown that follows immediately.
    pub fn shutdown(&mut self) {
        let released = self.session.with_textures(TextureLedger::take_all);
        for texture in released {
            texture.release_ref();
        }

        let Some(compositor) = self.compositor.take() else {
            return;
        };

        let live = compositor.arena.live();
        if let Err(error) = compositor.handle.shutdown() {
            error!(%error, "the compositor thread did not stop cleanly");
        }
        info!(
            images = live,
            "compositor stopped; its images are freed with the graphics device"
        );
    }

    /// Starts the compositor once LÖVR has a device to lend it.
    fn start_if_ready(&mut self) {
        if self.compositor.is_some() || self.startup.is_none() {
            return;
        }

        // SAFETY: the call reads a flag on LÖVR's graphics state and touches no
        // Rust memory. It is safe before initialisation, which is the whole
        // reason it is what the readiness test asks.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return;
        }

        let Some(startup) = self.startup.take() else {
            return;
        };

        match start(startup) {
            Ok(compositor) => self.compositor = Some(compositor),
            Err(error) => error!(
                "{error}; lunette will run with no compositor, so no client can connect for the \
                 rest of this session"
            ),
        }
    }

    /// Applies the frame's events to the ledger and queues them for Lua.
    fn drain_events(&self) {
        let Some(compositor) = &self.compositor else {
            return;
        };

        for event in compositor.handle.events().drain() {
            self.apply(&event);
            if let Some(event) = LuaEvent::from_compositor(&event) {
                self.session.push_event(event);
            }
        }
    }

    /// What one compositor event means to the textures the frame can hand out.
    ///
    /// Exhaustive so that a variant added to the protocol has to be given an
    /// answer here rather than silently doing nothing.
    fn apply(&self, event: &Event) {
        match event {
            Event::BufferImported { surface, buffer } => self.install(*surface, buffer),
            Event::WindowClosed { window } => {
                // The window is already absent from this frame's snapshot —
                // that is what the event reports — so the surface is read from
                // the frame before, which the session still holds.
                if let Some(window) = self.session.window(*window) {
                    let released = self
                        .session
                        .with_textures(|ledger| ledger.mark_dead(window.surface));
                    release(released);
                }
            }
            // Nothing to do on this side. A window opening or retitling is the
            // snapshot's business, damage is already recorded by the install
            // that accompanies it, and the process events never touch a
            // texture.
            Event::WindowOpened { .. }
            | Event::TitleChanged { .. }
            | Event::SurfaceDamaged { .. }
            | Event::ProcessExited { .. }
            | Event::ProcessOutput { .. } => {}
        }
    }

    /// Turns an imported buffer into a texture and installs it.
    ///
    /// A new texture every time, including for shared memory where the pixels
    /// could have been written into the existing one. Installing is what marks
    /// the surface damaged, which is what a stabilised copy is refreshed from,
    /// and a refill that skipped the install would leave that copy showing an
    /// older frame for ever.
    fn install(&self, surface: SurfaceId, buffer: &ImportedBuffer) {
        let description = crate::texture::describe(buffer);
        // SAFETY: this is the frame thread and LÖVR's graphics module is
        // initialised, because the compositor that produced this event could
        // not have started otherwise. An image handle names an image the arena
        // holds, created with the usage `crate::import::device::IMPORT_USAGE`
        // declares.
        let texture = unsafe {
            match buffer {
                ImportedBuffer::Image(image) => LovrTexture::import(image),
                ImportedBuffer::Pixels(pixels) => LovrTexture::upload(pixels),
            }
        };

        let texture = match texture {
            Ok(texture) => texture,
            Err(error) => {
                warn!(%surface, %error, "a client's buffer could not be made into a texture");
                return;
            }
        };

        let released = self
            .session
            .with_textures(|ledger| ledger.install(surface, texture, description));
        release(released);
    }
}

/// Borrows LÖVR's device and starts the compositor against it.
fn start(startup: Startup) -> Result<Compositor, StartupError> {
    let Startup {
        socket,
        display: name,
        satellite,
        barriers: _,
    } = startup;

    // SAFETY: the caller has established that LÖVR's graphics module is
    // initialised, and it stays initialised until `FrameDriver::shutdown` has
    // stopped the thread that borrows the device.
    let device = unsafe { GraphicsDevice::borrow_from_lovr() }.map_err(StartupError::Device)?;

    let arena = ImageArena::new();
    let importer = Importer::new(Arc::clone(&device), arena.clone());
    let config = CompositorConfig {
        dmabuf: device.dmabuf_support(),
        display: Some(name),
        satellite,
        ..CompositorConfig::default()
    };

    // The binary's choice, not the compositor crate's: a half-dead compositor
    // holding a Wayland socket is worse for a user than a process that stops.
    let handle = thread::spawn(config, socket, Box::new(importer), PanicPolicy::Abort)
        .map_err(StartupError::Thread)?;

    info!(%name, "compositor running; clients may connect");

    Ok(Compositor {
        handle,
        device,
        arena,
    })
}

/// Drops lunette's references to the textures a ledger change handed back.
///
/// The images behind them are not retired here. The compositor retires an image
/// when the client destroys the buffer it came from, which is the point at which
/// nothing can commit it again; a texture being displaced says only that a newer
/// buffer arrived.
fn release(released: Released<LovrTexture>) {
    for texture in released {
        texture.release_ref();
    }
}

/// Why the compositor could not be started.
#[derive(Debug)]
pub enum StartupError {
    Device(DeviceError),
    Thread(StartError),
}

impl fmt::Display for StartupError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "startup: ")?;
        match self {
            Self::Device(cause) => write!(f, "{cause}"),
            Self::Thread(cause) => write!(f, "{cause}"),
        }
    }
}

impl Error for StartupError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Device(cause) => Some(cause),
            Self::Thread(cause) => Some(cause),
        }
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use lunette_compositor::protocol::PixelSize;
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::texture::{FrameGeneration, TextureDescription, TextureRef, TextureUnavailable};

    /// A texture that is a counter, so the ledger's bookkeeping can be
    /// exercised without a graphics device.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct Counted(u64);

    impl crate::texture::CopyableTexture for Counted {
        fn allocate_copy(&self) -> Option<Self> {
            Some(Self(self.0 + 1000))
        }

        fn copy_to(&self, _destination: &Self) -> bool {
            true
        }
    }

    fn surface(raw: u64) -> SurfaceId {
        SurfaceId::new(raw).expect("non-zero")
    }

    fn description() -> TextureDescription {
        TextureDescription {
            size: PixelSize::new(4, 4),
            alpha: crate::import::formats::Alpha::Present,
        }
    }

    #[test]
    fn every_live_texture_is_offered_a_barrier() {
        let mut ledger = TextureLedger::<Counted>::new();
        ledger.install(surface(1), Counted(1), description());
        ledger.install(surface(2), Counted(2), description());

        let mut seen: Vec<u64> = ledger.textures().map(|texture| texture.0).collect();
        seen.sort_unstable();

        assert_eq!(seen, vec![1, 2]);
    }

    #[test]
    fn a_dead_surfaces_texture_is_not_offered_a_barrier() {
        let mut ledger = TextureLedger::<Counted>::new();
        ledger.install(surface(1), Counted(1), description());
        let released = ledger.mark_dead(surface(1));

        assert_eq!(released.imported, Some(Counted(1)));
        assert_eq!(
            ledger.textures().count(),
            0,
            "a texture already handed back must not be named in a barrier"
        );
    }

    #[test]
    fn a_stabilised_copy_is_offered_a_barrier_alongside_its_source() {
        let mut ledger = TextureLedger::<Counted>::new();
        ledger.install(surface(1), Counted(1), description());
        ledger
            .stabilize(
                TextureRef::new(surface(1), FrameGeneration::INITIAL),
                FrameGeneration::INITIAL,
            )
            .expect("a live surface can be stabilised");

        assert_eq!(ledger.textures().count(), 2);
    }

    #[test]
    fn teardown_hands_back_every_texture_once() {
        let mut ledger = TextureLedger::<Counted>::new();
        ledger.install(surface(1), Counted(1), description());
        ledger.install(surface(2), Counted(2), description());

        let mut taken: Vec<u64> = ledger
            .take_all()
            .into_iter()
            .map(|texture| texture.0)
            .collect();
        taken.sort_unstable();

        assert_eq!(taken, vec![1, 2]);
        assert!(
            ledger.take_all().is_empty(),
            "a second teardown has nothing left to release"
        );
        assert_eq!(
            ledger.lookup(
                TextureRef::new(surface(1), FrameGeneration::INITIAL),
                FrameGeneration::INITIAL
            ),
            Err(TextureUnavailable::Unknown)
        );
    }
}
