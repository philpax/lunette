//! Linux-only: the per-frame cycle that joins the compositor thread to the Lua
//! session.
//!
//! Everything else in this crate is one half of a seam. [`crate::lua`] reads a
//! snapshot and queues commands; [`lunette_compositor::thread`] publishes
//! snapshots and consumes commands; [`crate::import`] turns a client buffer into
//! an image and [`crate::texture`] turns that into something Lua can sample.
//! This module runs between them once per frame, in the order the pieces need.
//!
//! # The order of a frame
//!
//! At frame start, in this order and for the reasons given:
//!
//! 1. Start the compositor if LÖVR has created its graphics device and the
//!    compositor is not running yet. See below.
//! 2. Install the compositor's latest snapshot on the session. The install
//!    advances the frame generation and invalidates the previous frame's
//!    texture handles.
//! 3. Drain the event channel. Every event is applied to the texture ledger
//!    and then queued for `lovr.lun*` dispatch. The drain follows the snapshot
//!    so a handler reading `lunette.windows()` sees a snapshot that already
//!    accounts for the event it was handed.
//! 4. Refresh the stabilised copies, and record an acquire barrier over every
//!    texture the frame may sample.
//! 5. Destroy the images whose deferral has elapsed. This is last because
//!    [`destroy_due_images`] is sound only once everything that can retire an
//!    image has run: the drain at step 3, which releases the textures a
//!    client's commits displaced, and the capture import and the sweep for
//!    stopped mirrors, which release a mirrored monitor's textures.
//!
//! At frame end: record the release barriers, then hand the frame's queued
//! commands to the compositor.
//!
//! # Why the compositor cannot start with everything else
//!
//! The compositor imports client dmabufs against LÖVR's `VkDevice`, so it
//! cannot exist before LÖVR has made one. LÖVR makes it inside `boot.lua`,
//! several steps after the process starts. The start is deferred to the first
//! frame at which `lovrGraphicsIsInitialized` answers true, and the
//! listening socket is bound long before that, by the entry point. The reason
//! is in `crates/lunette/src/main.rs`.
//!
//! A failure to start is reported once and not retried. The socket is dropped
//! with the attempt, so a second attempt would be against a name that is no
//! longer bound, and the failures that can occur here, a device without the
//! import extensions or a thread that cannot be spawned, do not become true
//! later.
//!
//! # Why the same is true after a restart
//!
//! `lunette.restart()` destroys the device and builds another, and the
//! compositor thread outlives both. The readiness test runs for every device,
//! not the first one. [`FrameDriver::quiesce`] takes the device back before
//! the Lua state closes, and the first frame of the next session at which LÖVR
//! has one again lends it out. [`crate::restart`] states the ordering that
//! makes the exchange safe, and it is the exacting part of this module.
mod mirroring;
mod teardown;

#[cfg(test)]
mod tests;

use std::{collections::HashSet, error::Error, fmt, rc::Rc, sync::Arc};

use lunette_capture::{
    monitor::{MonitorKey, OutputWatcher},
    stream::DrmFormat,
    tokens::TokenFile,
};
use lunette_compositor::{
    client::{DisplayName, WaylandSocket, XwaylandSatellite},
    protocol::{Command, Event, ImportedBuffer, KeymapDefaults, Snapshot, SurfaceId, WindowId},
    selection::DataControlSource,
    state::CompositorConfig,
    thread::{self, CompositorHandle, PanicPolicy, StartError, TrySendError},
};
use lunette_lovr::raw::lovrGraphicsIsInitialized;
use tracing::{debug, error, info, warn};

use crate::{
    events::LuaEvent,
    host::HostPointer,
    import::{CaptureImporter, DeviceError, GraphicsDevice, ImageArena, Importer},
    layers::{BlitLedger, LovrBlits, LovrLayers},
    lua::{PoolRegistry, Session},
    mirrors::MirrorFrames,
    texture::{BarrierPolicy, LovrTexture, Released, destroy_due_images},
};

/// What the entry point resolved before any thread existed, for the compositor
/// to be built from later.
///
/// The socket is here because binding it produces the display name, and the
/// display name must be exported into the environment while the process is
/// still single-threaded.
#[derive(Debug)]
pub struct Startup {
    pub socket: WaylandSocket,
    pub display: DisplayName,
    /// Where to find xwayland-satellite. Absent means X11 clients are not
    /// served.
    pub satellite: Option<XwaylandSatellite>,
    /// How the two open questions about the import barrier are answered for
    /// this run. Both are what milestone 0 exists to measure.
    pub barriers: BarrierPolicy,
    /// The host's own screens, or `None` when lunette cannot reach them.
    pub host: Option<HostDesktop>,
    /// How the host desktop's clipboard is reached. Absent when there is no
    /// host Wayland session, and selections then stay inside lunette.
    ///
    /// Separate from [`Self::host`] because it survives a host whose screens
    /// cannot be captured: a session with no screencast portal still has a
    /// clipboard worth bridging.
    pub clipboard: Option<DataControlSource>,
    /// The desktop's own keyboard layout, which a seat that names none
    /// inherits. The entry point reads it from `XKB_DEFAULT_*`, because the
    /// compositor crate is a library and libraries do not read the
    /// environment.
    pub keymap_defaults: KeymapDefaults,
}

/// The host desktop the entry point opened, for the frame loop to drive.
///
/// Resolved by the binary, which retains the host display for direct capture
/// and passes explicit host configuration to the other subsystems.
pub struct HostDesktop {
    /// Environment-dependent upstream construction stays at the application boundary.
    pub capture_client: fn() -> Option<lunette_capture::mirror::screencopy::WlxClient>,
    /// The host's `wl_output`s, kept up to date as they change.
    pub outputs: OutputWatcher,
    /// The mirror lifecycle's frame-loop half. The same object the Lua session
    /// reaches through `MirrorRegistry`, held here through the other trait.
    pub mirrors: Rc<dyn MirrorFrames>,
    /// The per-monitor pointer mapping, which is rebuilt on every output
    /// change.
    pub pointer: Rc<HostPointer>,
    /// Where the portal's restore tokens are written, or `None` when they
    /// cannot be. The entry point resolves the path, because the state
    /// directory is its knowledge, and it is absent when the file on disk was
    /// written by a later lunette. Writing this version's fields over it would
    /// drop the ones this version does not know about.
    pub tokens: Option<TokenFile>,
}

impl fmt::Debug for HostDesktop {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HostDesktop")
            .field("outputs", &self.outputs)
            .field("tokens", &self.tokens)
            .finish_non_exhaustive()
    }
}

/// Drives one frame of the session against the compositor.
///
/// Owned by the boot sequence and outliving every Lua state, so a restart
/// throws the state away without disturbing the clients.
#[derive(Debug)]
pub struct FrameDriver {
    session: Rc<Session<LovrTexture>>,
    /// The same pool [`Session`] reaches through `ClaimRegistry`, held here
    /// concretely as well. Lua needs the trait, which is dyn-safe by design; the
    /// blit and the submit need the backend's own `Layer` type, which no
    /// dyn-safe trait can hand back.
    layers: Rc<PoolRegistry<LovrLayers>>,
    blits: LovrBlits,
    blitted: BlitLedger<LovrTexture>,
    /// Consumed by the first successful or failed start.
    startup: Option<Startup>,
    compositor: Option<Compositor>,
    /// The host's own screens, for the whole session rather than only until
    /// the compositor starts. This is why it is lifted out of [`Startup`]
    /// here.
    host: Option<HostDesktop>,
    barriers: BarrierPolicy,
    /// Handed to [`Session::begin`] while there is no compositor, so the
    /// generation still advances and a texture handle from the frame before is
    /// still refused.
    empty: Arc<Snapshot>,
}

/// A running compositor, and whatever graphics state it currently shares with
/// its thread.
///
/// The two are separate because they have different lifetimes. The thread, its
/// socket, and its clients last for the whole process; the device does not,
/// because `lunette.restart()` destroys it and builds another. See
/// [`crate::restart`].
#[derive(Debug)]
struct Compositor {
    handle: CompositorHandle,
    graphics: GraphicsState,
}

/// Whether the compositor has a device to import against.
///
/// An explicit state rather than an `Option`, because the two absent cases are
/// answered differently: one is waiting for a device that is being built, and
/// the other has given up on ever having one.
#[derive(Debug)]
enum GraphicsState {
    /// A device is lent to the compositor and imports are running.
    Held(Graphics),
    /// The device has been given up for a restart, and the next session's has
    /// not arrived. The compositor refuses imports and releases the buffers it
    /// is offered, so a client that commits now redraws later.
    ///
    /// There is no third state for "no device, ever again". A
    /// compositor that can never import refuses every commit and releases the
    /// buffer, and a client answers a released buffer by drawing another, so
    /// the clients would spin for the rest of the process. The answer to a
    /// device that cannot be borrowed is [`FrameDriver::stop_compositor`],
    /// which disconnects them.
    Quiesced,
}

/// The graphics state one device's lifetime owns.
#[derive(Debug)]
struct Graphics {
    /// Borrowed from LÖVR. Held here because destroying an image needs it, and
    /// destruction happens on this side.
    device: Arc<GraphicsDevice>,
    arena: ImageArena,
    /// The main thread's own importer, for the frames PipeWire produces. Held
    /// beside the compositor because it needs the same device and the same
    /// arena, and both arrive at the same moment.
    capture: CaptureImporter,
}

impl Compositor {
    /// The device and its arena, when one is lent.
    fn graphics(&self) -> Option<&Graphics> {
        match &self.graphics {
            GraphicsState::Held(graphics) => Some(graphics),
            GraphicsState::Quiesced => None,
        }
    }

    fn graphics_mut(&mut self) -> Option<&mut Graphics> {
        match &mut self.graphics {
            GraphicsState::Held(graphics) => Some(graphics),
            GraphicsState::Quiesced => None,
        }
    }
}

impl FrameDriver {
    /// `blits` carries the same thread guarantee the pool's backend does. This
    /// type is constructed by the entry point, the one place able to state it,
    /// so `blits` is taken rather than made here.
    #[must_use]
    pub fn new(
        session: Rc<Session<LovrTexture>>,
        layers: Rc<PoolRegistry<LovrLayers>>,
        blits: LovrBlits,
        mut startup: Startup,
    ) -> Self {
        Self {
            session,
            layers,
            blits,
            blitted: BlitLedger::new(),
            barriers: startup.barriers,
            host: startup.host.take(),
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

        // Before the lifecycle's own poll, so a monitor plugged in this
        // frame is announced this frame rather than next.
        self.attach_outputs();

        // After the snapshot, for the reason the compositor's events are: a
        // handler reading `lunette.monitors()` has to see the monitor it was
        // handed. This also carries a portal exchange forward, so a dialog the
        // user has not answered costs one non-blocking poll a frame.
        for monitor in self.session.mirrors().poll() {
            self.session.push_event(LuaEvent::MonitorAdded { monitor });
        }

        self.persist_tokens();

        // After the portal exchange, because that starts a stream, and before
        // the barriers below, because a texture installed here has to be
        // acquired for the frame that is about to sample it.
        self.drop_stopped_mirrors();
        self.import_capture_frames();

        // The frame boundary the pool decides on. Before `boot.lua` polls and
        // so before `lovr.update`, which lets a callback read a claim's
        // realisation and have it hold for the whole of the frame it draws.
        self.session.resolve_layers();

        let barriers = self.barriers;
        self.session.with_textures(|ledger| {
            ledger.refresh_stable();
            for texture in ledger.textures() {
                // SAFETY: this is the frame thread, LÖVR's graphics module is
                // initialised because a texture exists, and the acquire
                // is recorded before anything in the frame can sample it.
                // `lovr.draw` has not run yet.
                if !unsafe { texture.acquire(barriers) } {
                    warn!("an imported texture could not be acquired for this frame");
                }
            }
        });

        // The same acquire for a mirrored monitor's texture. An image imported
        // from PipeWire needs it exactly as a client's does; they differ only
        // in which ledger holds them.
        self.session.with_monitor_textures(|textures| {
            for texture in textures.textures() {
                // SAFETY: as the acquire above.
                if !unsafe { texture.acquire(barriers) } {
                    warn!("a mirrored monitor's texture could not be acquired for this frame");
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
        if let Some(graphics) = self.compositor.as_ref().and_then(Compositor::graphics) {
            let now = self.session.generation();
            self.session.with_textures(|ledger| {
                // SAFETY: the ordering the function documents is the ordering
                // of this method, stated in the module note above. The arena
                // and the device are one lifetime's: a restart replaces both
                // together, so a handle from an older device is unreachable
                // from here.
                unsafe { destroy_due_images(ledger, &graphics.arena, &graphics.device, now) };
            });
        }
    }

    /// Closes the frame the Lua session has finished, sending what it queued.
    pub fn end_frame(&mut self) {
        // Again here, and not only at frame start. LÖVR initialises graphics
        // during the first frame, so at that frame's start there was no device
        // to lend and no compositor. By its end there is, and `lovr.load` has
        // already run and queued whatever it asked for. Without this the first
        // frame's commands, where a configuration does its spawning, are
        // flushed into nothing.
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

        self.session.with_monitor_textures(|textures| {
            for texture in textures.textures() {
                // SAFETY: as above.
                if !unsafe { texture.release(barriers) } {
                    warn!("a mirrored monitor's texture could not be released at frame end");
                }
            }
        });

        // Once, at frame end, alongside the compositor's commands: a host
        // sink's pointer and button calls only accumulate, so a frame that
        // moved the cursor five times sends one motion.
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
            // for it. A refused command is reported and the rest of the
            // frame's are abandoned, because they were queued in order and
            // delivering the tail without the head would apply the
            // configuration out of sequence.
            if let Err(error) = compositor.handle.commands().try_send(command) {
                warn!(%error, "the frame's remaining commands were not delivered");
                break;
            }
        }
    }

    /// Stops the compositor thread, which disconnects every client.
    ///
    /// Terminal for the session: [`FrameDriver::start_if_ready`] starts a
    /// compositor only while [`FrameDriver::startup`] is unspent, and it is
    /// spent by the first start. Every caller reaches here having decided that
    /// no client can be served again, and disconnecting conveys that to the
    /// clients. A client that stays connected to a compositor that can never import
    /// redraws, is refused, and redraws again for the rest of the process.
    ///
    /// [`FrameDriver::startup`]: FrameDriver#structfield.startup
    fn stop_compositor(&mut self) {
        let Some(mut compositor) = self.compositor.take() else {
            return;
        };
        let live = match &mut compositor.graphics {
            GraphicsState::Held(graphics) => {
                graphics.capture.forget_buffers();
                graphics.arena.live()
            }
            GraphicsState::Quiesced => 0,
        };

        if let Err(error) = compositor.handle.shutdown() {
            error!(%error, "the compositor thread did not stop cleanly");
        }
        info!(
            images = live,
            "compositor stopped; its images are freed with the graphics device"
        );
    }

    /// Starts the compositor once LÖVR has a device to lend it, or lends it
    /// the new one after a restart.
    ///
    /// Both cases wait on the same signal and neither can be done earlier, so
    /// they share the readiness test. Two call sites would both have to
    /// remember it.
    fn start_if_ready(&mut self) {
        let wanted = match &self.compositor {
            None if self.startup.is_some() => Readiness::Start,
            Some(compositor) => match compositor.graphics {
                GraphicsState::Quiesced => Readiness::Adopt,
                GraphicsState::Held(_) => return,
            },
            None => return,
        };

        // SAFETY: the call reads a flag on LÖVR's graphics state and touches
        // no Rust memory. It is safe before initialisation, which is why the
        // readiness test queries it.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return;
        }

        match wanted {
            Readiness::Start => self.start_compositor(),
            Readiness::Adopt => self.adopt_graphics(),
        }
    }

    /// Borrows LÖVR's device, starts the compositor thread against it, and
    /// points monitor capture at the formats it can import.
    fn start_compositor(&mut self) {
        let Some(startup) = self.startup.take() else {
            return;
        };

        let graphics = match borrow_graphics() {
            Ok(graphics) => graphics,
            Err(error) => {
                error!(
                    "{error}; lunette will run with no compositor, so no client can connect for \
                     the rest of this session"
                );
                return;
            }
        };

        match start(startup, &graphics) {
            Ok(handle) => {
                self.negotiate_capture_formats(&graphics.device);
                self.compositor = Some(Compositor {
                    handle,
                    graphics: GraphicsState::Held(graphics),
                });
            }
            Err(error) => error!(
                "{error}; lunette will run with no compositor, so no client can connect for the \
                 rest of this session"
            ),
        }
    }

    /// Hands the compositor a device borrowed from the session that came up
    /// after a restart.
    ///
    /// The compositor has been idle since it acknowledged the quiesce, holding
    /// its clients and their buffers. Adopting lets it import again, and it
    /// re-imports every retained buffer as it does, so a client that has drawn
    /// nothing since the restart gets its content back regardless.
    ///
    /// Nothing is waited on here. The re-imports arrive as ordinary
    /// [`Event::BufferImported`] reports and are drained by the next frame
    /// through the path a commit already takes.
    fn adopt_graphics(&mut self) {
        let graphics = match borrow_graphics() {
            Ok(graphics) => graphics,
            Err(error) => {
                // Stopped rather than left running with no device. A
                // compositor that cannot import refuses every commit and
                // releases the buffer, and a client answers a released buffer
                // by drawing another, so the clients would spin for the rest
                // of the process. Disconnecting says so, and the failures that
                // reach here do not become false later.
                error!(
                    "{error}; the compositor has no device to import against, so it is stopped and \
                     its clients are disconnected"
                );
                self.stop_compositor();
                return;
            }
        };

        let importer = Importer::new(Arc::clone(&graphics.device), graphics.arena.clone());
        let Some(compositor) = &mut self.compositor else {
            return;
        };

        // `try_send` and not a wait, for the reason the whole protocol uses
        // it: a main thread that blocked filling this channel could deadlock
        // against a compositor blocked filling the event channel. A full queue
        // here is a frame's worth of commands ahead and is drained by the frame that
        // follows, so the retry is the next frame's.
        let offered = compositor
            .handle
            .commands()
            .try_send(Command::AdoptGraphics {
                importer: Box::new(importer),
            });
        match offered {
            Ok(()) => compositor.graphics = GraphicsState::Held(graphics),
            Err(TrySendError::Full(_)) => {
                debug!("the compositor's queue was full; offering it the new device next frame");
                return;
            }
            Err(TrySendError::Disconnected(_)) => {
                error!("the compositor thread is gone, so the restart cannot restore its clients");
                // The thread has already gone; this joins it and drops the
                // handle, so nothing keeps offering a device to a channel with
                // no reader.
                self.stop_compositor();
                return;
            }
        }

        let device = match &compositor.graphics {
            GraphicsState::Held(graphics) => Arc::clone(&graphics.device),
            GraphicsState::Quiesced => return,
        };
        self.negotiate_capture_formats(&device);
    }

    /// Copies each claim's window into the layer it holds, and hands the
    /// runtime the list to composite.
    ///
    /// The submit runs whatever the copies decided. A layer skipped because
    /// its window has not committed since the last copy still goes to the
    /// runtime, which re-composites it from the image its swapchain last
    /// released; leaving it out of the list would make its panel disappear
    /// rather than hold still.
    fn blit_layers(&mut self) {
        let now = self.session.generation();
        let scene = self.session.scene();
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

                if report.iter().any(|(_, outcome)| outcome.copied()) {
                    // Only matters on a frame that draws no scene, where the
                    // gate on `lovr.headset.getPass` submits the stream these
                    // copies were recorded into. `crate::scene` has the
                    // reasoning.
                    session.note_copies_recorded();
                }

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

            // The frame's whole layer list, and with it whether lunette's own
            // projection layer belongs in this `xrEndFrame`.
            if !pool.submit(scene) {
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

    /// Applies to the ledger what one compositor event requests of it.
    fn apply(&self, event: &Event) {
        // The window in a `WindowClosed` is already absent from this frame's
        // snapshot, which the event reports, so its surface is read
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
    /// could have been written into the existing one. Installing marks the
    /// surface damaged, and a stabilised copy is refreshed from that damage; a
    /// refill that skipped the install would leave that copy showing an older
    /// frame for ever.
    fn install(&self, surface: SurfaceId, buffer: &ImportedBuffer) {
        let description = crate::texture::describe(buffer);
        // SAFETY: this is the frame thread and LÖVR's graphics module is
        // initialised, because the compositor that produced this event could
        // not have started otherwise. An image handle names an image the
        // arena holds, created with the usage `crate::import::device::IMPORT_USAGE`
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

/// What one compositor event requests of the texture ledger.
///
/// A separate step from performing it: the decision is a pure function of the
/// event, and turning a buffer into a texture needs a graphics device while
/// this does not. The split makes the mapping testable.
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
    /// The surface itself is gone. Everything the ledger holds for it is
    /// handed back, and the entry with it.
    ///
    /// This keeps a popup, a subsurface, or a cursor surface from leaving a
    /// texture behind. Every `wl_surface` has its own [`SurfaceId`], so every
    /// one can hold a texture, but only a toplevel is ever reported closed.
    /// Without this the ledger would name a freed image in the frame's
    /// barriers for the rest of the session.
    Forget(SurfaceId),
    /// Nothing the textures care about. A window opening or retitling is the
    /// snapshot's business, damage is already recorded by the install that
    /// accompanies it, and the process events never touch a texture.
    Nothing,
}

/// Reads an event as a change to the ledger.
///
/// Exhaustive so a variant added to the protocol has to be given an
/// answer here, with no silent default.
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
        // The restart acknowledgements say nothing about a texture. The
        // images are handled by `FrameDriver::quiesce`, which operates the
        // exchange, and the re-imports a `GraphicsAdopted` follows arrive as
        // their own `BufferImported` reports and are installed by the arm
        // above.
        Event::WindowOpened { .. }
        | Event::TitleChanged { .. }
        | Event::SurfaceDamaged { .. }
        | Event::ProcessExited { .. }
        | Event::ProcessOutput { .. }
        | Event::GraphicsReleased
        | Event::GraphicsAdopted { .. } => LedgerChange::Nothing,
    }
}

/// Which monitors the sweep for stopped mirrors releases.
///
/// The union of what the two ledgers name, not either one alone. `holding` is
/// the monitors [`MonitorTextures`] has a texture for; `retaining` is the
/// monitors [`CaptureImporter`] still holds buffers for. The sets diverge: a
/// frame whose image imports but whose texture the device refuses retains a
/// buffer and never reaches the texture ledger, so reading only `holding`
/// would leave that monitor's buffers alive for the rest of the process.
///
/// Pure and separate from the sweep because the part worth getting right is
/// the set, and the release itself is FFI.
///
/// [`CaptureImporter`]: crate::import::CaptureImporter
fn stopped_monitors(
    holding: Vec<MonitorKey>,
    retaining: Vec<MonitorKey>,
    mirroring: impl Fn(&MonitorKey) -> bool,
) -> Vec<MonitorKey> {
    let mut named = HashSet::new();

    holding
        .into_iter()
        .chain(retaining)
        .filter(|monitor| named.insert(monitor.clone()))
        .filter(|monitor| !mirroring(monitor))
        .collect()
}

/// Which half of [`FrameDriver::start_if_ready`] the state calls for.
#[derive(Clone, Copy, Debug)]
enum Readiness {
    /// There is no compositor yet.
    Start,
    /// There is one, quiesced by a restart, waiting for a device.
    Adopt,
}

/// Borrows LÖVR's device and builds the state one device's lifetime owns.
///
/// Called at startup and again after every restart, which is why it is
/// separate from [`start`]: the thread is started once and the device is
/// borrowed as many times as the session is rebuilt.
///
/// # Safety of the borrow
///
/// The caller must have established that LÖVR's graphics module is
/// initialised, and the device stays valid until either
/// [`FrameDriver::shutdown`] has stopped the thread that borrows it or
/// [`FrameDriver::quiesce`] has taken it back.
fn borrow_graphics() -> Result<Graphics, StartupError> {
    // SAFETY: the caller's guarantee, stated above.
    let device = unsafe { GraphicsDevice::borrow_from_lovr() }.map_err(StartupError::Device)?;
    let arena = ImageArena::new();

    Ok(Graphics {
        capture: CaptureImporter::new(Arc::clone(&device), arena.clone()),
        device,
        arena,
    })
}

/// Starts the compositor thread against a device that has just been borrowed.
fn start(startup: Startup, graphics: &Graphics) -> Result<CompositorHandle, StartupError> {
    let Startup {
        socket,
        display: name,
        satellite,
        barriers: _,
        // Lifted out by `FrameDriver::new`, because it outlives this start
        // and is not consumed by it.
        host: _,
        clipboard,
        keymap_defaults,
    } = startup;

    let importer = Importer::new(Arc::clone(&graphics.device), graphics.arena.clone());
    let config = CompositorConfig {
        dmabuf: graphics.device.dmabuf_support(),
        display: Some(name),
        satellite,
        host_selection: clipboard.map(|source| Box::new(source) as _),
        keymap_defaults,
        ..CompositorConfig::default()
    };

    // The binary's choice, not the compositor crate's: a half-dead compositor
    // holding a Wayland socket is worse for a user than a process that stops.
    let handle = thread::spawn(config, socket, Box::new(importer), PanicPolicy::Abort)
        .map_err(StartupError::Thread)?;

    info!(%name, "compositor running; clients may connect");

    Ok(handle)
}

/// The DRM formats a capture stream may negotiate.
///
/// The same set the compositor advertises to its own clients, because both go
/// through the one dmabuf import path: a format the importer cannot accept is
/// a format the stream must not agree to, whichever side produced the buffer.
fn capture_formats(device: &GraphicsDevice) -> Vec<DrmFormat> {
    device
        .dmabuf_support()
        .formats
        .into_iter()
        .map(|format| DrmFormat {
            code: format.code,
            modifier: format.modifier,
        })
        .collect()
}

/// Drops lunette's references to the textures a ledger change handed back.
///
/// The images behind them are not retired here. The compositor retires an
/// image when the client destroys the buffer it came from, the point at which
/// nothing can commit it again; a texture being displaced says that a newer
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
