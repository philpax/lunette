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
    protocol::{Event, ImportedBuffer, Snapshot, SurfaceId, WindowId},
    state::CompositorConfig,
    thread::{self, CompositorHandle, PanicPolicy, StartError},
};
use lunette_lovr::raw::lovrGraphicsIsInitialized;
use tracing::{error, info, warn};

use crate::{
    events::LuaEvent,
    import::{DeviceError, GraphicsDevice, ImageArena, Importer},
    layers::{BlitLedger, LovrBlits, LovrLayers},
    lua::{PoolRegistry, Session},
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
    /// The same pool [`Session`] reaches through `ClaimRegistry`, held here
    /// concretely as well. The trait is what Lua needs and is deliberately
    /// dyn-safe; the blit and the submit need the backend's own `Layer` type,
    /// which no dyn-safe trait can hand back.
    layers: Rc<PoolRegistry<LovrLayers>>,
    blits: LovrBlits,
    blitted: BlitLedger<LovrTexture>,
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
    /// `blits` carries the same thread guarantee the pool's backend does, which
    /// is why it is taken rather than made here: this type is constructed by the
    /// entry point, which is the one place able to state it.
    #[must_use]
    pub fn new(
        session: Rc<Session<LovrTexture>>,
        layers: Rc<PoolRegistry<LovrLayers>>,
        blits: LovrBlits,
        startup: Startup,
    ) -> Self {
        Self {
            session,
            layers,
            blits,
            blitted: BlitLedger::new(),
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

        // After the snapshot, for the reason the compositor's events are: a
        // handler reading `lunette.monitors()` has to see the monitor it was
        // handed. This is also what carries a portal exchange forward, so a
        // dialog the user has not answered costs one non-blocking poll a frame.
        for monitor in self.session.mirrors().poll() {
            self.session.push_event(LuaEvent::MonitorAdded { monitor });
        }

        // The frame boundary the pool decides on. Before `boot.lua` polls and
        // so before `lovr.update`, which is what lets a callback read a claim's
        // realisation and have it hold for the whole of the frame it draws.
        self.session.resolve_layers();

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

        // After the acquire barriers, because a copy reads the imported
        // texture; before `lovr.draw`, because the copy is recorded into the
        // same stream the frame's rendering is and has to precede it.
        self.blit_layers();

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

        // Once, at frame end, alongside the compositor's commands: a host sink's
        // pointer and button calls only accumulate, so a frame that moved the
        // cursor five times sends one motion.
        self.session.host().commit();

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
            // Never waiting. The compositor may be blocked reporting an event,
            // and it drains commands only between dispatches, so a main thread
            // that waited here would be waiting for a thread that is waiting
            // for it. A refused command is reported and the rest of the frame's
            // are abandoned, because they were queued in order and delivering
            // the tail without the head would apply the configuration out of
            // sequence.
            if let Err(error) = compositor.handle.commands().try_send(command) {
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
        // While the XR session still exists, because destroying a `Layer` calls
        // `xrDestroySwapchain` inline.
        self.session.claims().shutdown();
        // The cached swapchain images name textures the layers own, and those
        // go with the layers.
        self.blitted.clear();

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

    /// Copies each claim's window into the layer it holds, and hands the
    /// runtime the list to composite.
    ///
    /// The submit runs whatever the copies decided. A layer skipped because its
    /// window has not committed since the last copy still goes to the runtime,
    /// which re-composites it from the image its swapchain last released;
    /// leaving it out of the list would make its panel disappear rather than
    /// hold still.
    fn blit_layers(&mut self) {
        let now = self.session.generation();
        let session = Rc::clone(&self.session);
        let blits = &mut self.blits;
        let blitted = &mut self.blitted;

        self.layers.with_pool(|pool| {
            session.with_textures(|textures| {
                let report = blitted.run(
                    pool,
                    blits,
                    textures,
                    |claim| {
                        session
                            .claims()
                            .source(claim)
                            .and_then(|window| session.window(window))
                            .map(|window| window.surface)
                    },
                    now,
                );

                for (claim, outcome) in report {
                    // Which outcomes those are is `Blitted`'s to say: a
                    // device that cannot blit answers the same way for the
                    // rest of the session, and the blit ledger has already
                    // reported that one once per claim.
                    if outcome.worth_reporting_every_frame() {
                        warn!(%claim, ?outcome, "a layer was not updated this frame");
                    }
                }
            });

            if !pool.submit() {
                warn!("the runtime refused this frame's composition layers");
            }
        });
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

    /// Applies to the ledger what one compositor event asks of it.
    fn apply(&self, event: &Event) {
        // The window in a `WindowClosed` is already absent from this frame's
        // snapshot — that is what the event reports — so its surface is read
        // from the frame before, which the session still holds.
        let surface_of = |window| self.session.window(window).map(|window| window.surface);

        match ledger_change(event, surface_of) {
            LedgerChange::Install { surface, buffer } => self.install(surface, buffer),
            LedgerChange::MarkDead(surface) => {
                release(
                    self.session
                        .with_textures(|ledger| ledger.mark_dead(surface)),
                );
            }
            LedgerChange::Forget(surface) => {
                release(self.session.with_textures(|ledger| ledger.forget(surface)));
            }
            LedgerChange::Nothing => {}
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

/// What one compositor event asks of the texture ledger.
///
/// A separate step from performing it so that the decision is a pure function of
/// the event: turning a buffer into a texture needs a graphics device and this
/// does not, which is what makes the mapping testable.
#[derive(Debug, PartialEq, Eq)]
enum LedgerChange<'a> {
    /// The surface committed a buffer, which becomes its new texture.
    Install {
        surface: SurfaceId,
        buffer: &'a ImportedBuffer,
    },
    /// The surface's client is gone. Its textures are handed back and the
    /// description survives, so reads keep answering with last-known values.
    MarkDead(SurfaceId),
    /// The surface itself is gone. Everything the ledger holds for it is handed
    /// back, and the entry with it.
    ///
    /// This is what keeps a popup, a subsurface, or a cursor surface from
    /// leaving a texture behind. Every `wl_surface` mints a [`SurfaceId`] and so
    /// every one can hold a texture, but only a toplevel is ever reported
    /// closed — so without this the ledger would name a freed image in the
    /// frame's barriers for the rest of the session.
    Forget(SurfaceId),
    /// Nothing the textures care about. A window opening or retitling is the
    /// snapshot's business, damage is already recorded by the install that
    /// accompanies it, and the process events never touch a texture.
    Nothing,
}

/// Reads an event as a change to the ledger.
///
/// Exhaustive so that a variant added to the protocol has to be given an answer
/// here rather than silently doing nothing.
fn ledger_change<'a>(
    event: &'a Event,
    surface_of: impl FnOnce(WindowId) -> Option<SurfaceId>,
) -> LedgerChange<'a> {
    match event {
        Event::BufferImported { surface, buffer } => LedgerChange::Install {
            surface: *surface,
            buffer,
        },
        Event::WindowClosed { window } => {
            surface_of(*window).map_or(LedgerChange::Nothing, LedgerChange::MarkDead)
        }
        Event::SurfaceGone { surface } => LedgerChange::Forget(*surface),
        Event::WindowOpened { .. }
        | Event::TitleChanged { .. }
        | Event::SurfaceDamaged { .. }
        | Event::ProcessExited { .. }
        | Event::ProcessOutput { .. } => LedgerChange::Nothing,
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
    use lunette_compositor::{
        protocol::PixelSize,
        surface::{PixelBuffer, ShmFormat},
    };
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::{
        import::formats::Alpha,
        texture::{FrameGeneration, TextureDescription, TextureRef, TextureUnavailable},
    };

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
            alpha: Alpha::Present,
        }
    }

    fn window_id(raw: u64) -> WindowId {
        WindowId::new(raw).expect("non-zero")
    }

    #[test]
    fn a_surface_going_away_takes_its_texture_out_of_the_ledger() {
        // The regression: every `wl_surface` mints an identifier and can hold
        // a texture, and only a toplevel is ever reported closed. A popup or a
        // cursor surface that was never forgotten left a texture naming an
        // image the compositor had already retired.
        assert_eq!(
            ledger_change(
                &Event::SurfaceGone {
                    surface: surface(1)
                },
                |_| unreachable!("a surface event names its surface directly")
            ),
            LedgerChange::Forget(surface(1))
        );
    }

    #[test]
    fn forgetting_a_surface_hands_back_both_of_its_textures_and_stops_naming_them() {
        let mut ledger = TextureLedger::<Counted>::new();
        ledger.install(surface(1), Counted(1), description());
        ledger
            .stabilize(
                TextureRef::new(surface(1), FrameGeneration::INITIAL),
                FrameGeneration::INITIAL,
            )
            .expect("a live surface can be stabilised");

        let released = ledger.forget(surface(1));

        assert_eq!(released.imported, Some(Counted(1)));
        assert_eq!(released.stable, Some(Counted(1001)));
        assert_eq!(
            ledger.textures().count(),
            0,
            "a texture the frame no longer holds must not be named in a barrier"
        );
        assert_eq!(
            ledger.lookup(
                TextureRef::new(surface(1), FrameGeneration::INITIAL),
                FrameGeneration::INITIAL
            ),
            Err(TextureUnavailable::Unknown)
        );
    }

    #[test]
    fn a_window_closing_marks_its_surface_dead_rather_than_forgetting_it() {
        assert_eq!(
            ledger_change(
                &Event::WindowClosed {
                    window: window_id(3)
                },
                |window| (window == window_id(3)).then(|| surface(9))
            ),
            LedgerChange::MarkDead(surface(9))
        );
    }

    #[test]
    fn a_window_the_snapshot_does_not_describe_changes_nothing() {
        assert_eq!(
            ledger_change(
                &Event::WindowClosed {
                    window: window_id(3)
                },
                |_| None
            ),
            LedgerChange::Nothing
        );
    }

    #[test]
    fn an_imported_buffer_installs_against_the_surface_it_arrived_for() {
        let buffer = ImportedBuffer::Pixels(
            PixelBuffer::new(
                PixelSize::new(1, 1),
                ShmFormat::Argb8888,
                vec![0, 0, 0, 255],
            )
            .expect("one pixel"),
        );
        let event = Event::BufferImported {
            surface: surface(2),
            buffer,
        };

        let Event::BufferImported { buffer, .. } = &event else {
            unreachable!("the event was just built as an import")
        };
        assert_eq!(
            ledger_change(&event, |_| unreachable!(
                "a buffer names its surface directly"
            )),
            LedgerChange::Install {
                surface: surface(2),
                buffer,
            }
        );
    }

    #[test]
    fn the_reports_that_touch_no_texture_change_nothing() {
        for event in [
            Event::WindowOpened {
                window: window_id(1),
            },
            Event::TitleChanged {
                window: window_id(1),
                title: "htop".to_owned(),
            },
            Event::SurfaceDamaged {
                surface: surface(1),
            },
        ] {
            assert_eq!(
                ledger_change(&event, |_| None),
                LedgerChange::Nothing,
                "{event:?} has nothing to do with what the frame may sample"
            );
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
