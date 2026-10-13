//! Linux-only: the per-frame cycle that joins the compositor thread to the Lua session.
//! The compositor starts at the first frame with a LÖVR graphics device, because it imports client dmabufs against that device.
mod mirroring;
mod teardown;

#[cfg(test)]
mod tests;

use std::{collections::HashSet, error::Error, fmt, rc::Rc, sync::Arc};

use lunette_capture::{
    clipboard::DataControlSource,
    mirror::screencopy::WlxClient,
    monitor::{MonitorKey, OutputWatcher},
    stream::DrmFormat,
    tokens::TokenFile,
};
use lunette_compositor::{
    config::CompositorConfig,
    listener::{WaylandEnv, WaylandSocket},
    protocol::{Command, Event, ImportedBuffer, KeymapDefaults, Snapshot, SurfaceId, WindowId},
    satellite::XwaylandSatellite,
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

/// What the entry point resolved before any thread existed, for the compositor to be built from later.
#[derive(Debug)]
pub struct Startup {
    pub socket: WaylandSocket,
    pub display: WaylandEnv,
    /// Where to find xwayland-satellite. Absent means X11 clients are not served.
    pub satellite: Option<XwaylandSatellite>,
    /// How the import barrier's open questions are answered for this run.
    pub barriers: BarrierPolicy,
    /// The host's own screens, or `None` when lunette cannot reach them.
    pub host: Option<HostDesktop>,
    /// How the host desktop's clipboard is reached. Absent when there is no host Wayland session.
    ///
    /// Separate from [`Self::host`] because a host without a screencast portal still has a clipboard to bridge.
    pub clipboard: Option<DataControlSource>,
    /// The desktop's keyboard layout, which a seat that names none inherits. The entry point reads it because libraries do not read the environment.
    pub keymap_defaults: KeymapDefaults,
}

/// The host desktop the entry point opened, for the frame loop to drive.
pub struct HostDesktop {
    /// Environment-dependent upstream construction stays at the application boundary.
    pub capture_client: fn() -> Option<WlxClient>,
    /// The host's `wl_output`s, kept up to date as they change.
    pub outputs: OutputWatcher,
    /// The mirror lifecycle's frame-loop half, the same object the Lua session reaches through `MirrorRegistry`.
    pub mirrors: Rc<dyn MirrorFrames>,
    /// The per-monitor pointer mapping, rebuilt on every output change.
    pub pointer: Rc<HostPointer>,
    /// Where the portal's restore tokens are written, or `None` when they cannot be. Absent when a later lunette wrote the file, because writing over it would drop fields this version does not know.
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
/// It outlives every Lua state, so a restart discards the state without disturbing the clients.
#[derive(Debug)]
pub struct FrameDriver {
    session: Rc<Session<LovrTexture>>,
    /// The same pool [`Session`] reaches through `ClaimRegistry`, held concretely because the blit and the submit need the backend's `Layer` type, which no dyn-safe trait can return.
    layers: Rc<PoolRegistry<LovrLayers>>,
    blits: LovrBlits,
    blitted: BlitLedger,
    /// Consumed by the first successful or failed start.
    startup: Option<Startup>,
    compositor: Option<Compositor>,
    /// The host's own screens, kept for the whole session rather than only until the compositor starts.
    host: Option<HostDesktop>,
    barriers: BarrierPolicy,
    /// Handed to [`Session::begin`] while there is no compositor, so the generation still advances and a stale texture handle is still refused.
    empty: Arc<Snapshot>,
}

/// A running compositor, and the graphics state it currently shares with its thread.
///
/// The thread and its clients last for the whole process, while a hard restart replaces the device. See [`crate::restart`].
#[derive(Debug)]
struct Compositor {
    handle: CompositorHandle,
    graphics: GraphicsState,
}

/// Whether the compositor has a device to import against.
///
/// An enum rather than an `Option` because the absent case waits for a device that is being built.
#[derive(Debug)]
enum GraphicsState {
    /// A device is lent to the compositor and imports are running.
    Held(Graphics),
    /// The device has been given up for a restart, and the next session's has not arrived. The compositor refuses imports and releases offered buffers, so a client redraws later.
    ///
    /// A compositor that can never import would make clients spin redrawing, so that case is [`FrameDriver::stop_compositor`] instead.
    Quiesced,
}

/// The graphics state one device's lifetime owns.
#[derive(Debug)]
struct Graphics {
    /// Borrowed from LÖVR. Held here because destroying an image needs it.
    device: Arc<GraphicsDevice>,
    arena: ImageArena,
    /// The main thread's importer for PipeWire frames. It needs the compositor's device and arena.
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
    /// `blits` carries the same thread guarantee as the pool's backend, so only the entry point can construct it.
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

        // Audio has no graphics dependency. Lifecycle reports precede the immutable PCM publication.
        self.session.audio().begin_frame(&self.session.snapshot());
        for request in self.session.audio().take_requests() {
            self.session.queue(Command::ResolveAudioProcess(request));
        }

        // Before the lifecycle's own poll, so a monitor plugged in this frame is announced this frame.
        self.attach_outputs();

        // After the snapshot, so a handler reading `lunette.monitors()` sees the monitor it was handed. It also advances a pending portal exchange with one non-blocking poll.
        for monitor in self.session.mirrors().poll() {
            self.session.push_event(LuaEvent::MonitorAdded { monitor });
        }

        self.persist_tokens();

        // After the portal exchange, which starts a stream, and before the acquire barriers that the new texture needs.
        self.drop_stopped_mirrors();
        self.import_capture_frames();

        // Before `lovr.update`, so a claim's realisation holds for the whole frame.
        self.session.resolve_layers();

        let barriers = self.barriers;
        self.session.with_textures(|ledger| {
            ledger.refresh_stable();
            for texture in ledger.textures() {
                // SAFETY: this is the frame thread, LÖVR's graphics module is initialised because a texture exists, and `lovr.draw` has not run yet.
                if !unsafe { texture.acquire(barriers) } {
                    warn!("an imported texture could not be acquired for this frame");
                }
            }
        });

        // A mirrored monitor's texture needs the same acquire as a client's.
        self.session.with_monitor_textures(|textures| {
            for texture in textures.textures() {
                // SAFETY: as the acquire above.
                if !unsafe { texture.acquire(barriers) } {
                    warn!("a mirrored monitor's texture could not be acquired for this frame");
                }
            }
        });

        // After the acquire barriers because a copy reads the imported texture, and before `lovr.draw` because the copy is recorded into the same stream.
        self.blit_layers();

        // Last, because `destroy_due_images` is sound only after the drain has released the textures the frame's events displaced.
        if let Some(graphics) = self.compositor.as_ref().and_then(Compositor::graphics) {
            let now = self.session.generation();
            self.session.with_textures(|ledger| {
                // SAFETY: this method runs every step that can retire an image before this call. A restart replaces the arena and the device together, so a handle from an older device is unreachable.
                unsafe { destroy_due_images(ledger, &graphics.arena, &graphics.device, now) };
            });
        }
    }

    /// Closes the frame the Lua session has finished, sending what it queued.
    pub fn end_frame(&mut self) {
        // Also here because LÖVR initialises graphics during the first frame. Without this, the commands `lovr.load` queued in that frame would be lost.
        self.start_if_ready();

        let barriers = self.barriers;
        self.session.with_textures(|ledger| {
            for texture in ledger.textures() {
                // SAFETY: as the acquire, and after the frame's reads, since nothing runs between `lovr.draw` returning and this.
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

        // Once per frame, because a host sink's pointer and button calls accumulate.
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
            // Never waiting, because the compositor may be blocked reporting an event and would deadlock. The rest of the frame's commands are abandoned after a refusal, since delivering them out of order would misapply the configuration.
            if let Err(error) = compositor.handle.commands().try_send(command) {
                warn!(%error, "the frame's remaining commands were not delivered");
                break;
            }
        }
    }

    /// Stops the compositor thread, which disconnects every client.
    ///
    /// Terminal for the session, because `startup` is spent by the first start. A client left connected to a compositor that can never import would redraw for the rest of the process.
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

    /// Starts the compositor once LÖVR has a device to lend it, or lends it the new one after a restart.
    ///
    /// Both cases share the readiness test.
    fn start_if_ready(&mut self) {
        let wanted = match &self.compositor {
            None if self.startup.is_some() => Readiness::Start,
            Some(compositor) => match compositor.graphics {
                GraphicsState::Quiesced => Readiness::Adopt,
                GraphicsState::Held(_) => return,
            },
            None => return,
        };

        // SAFETY: the call reads a flag on LÖVR's graphics state, and it is safe before initialisation.
        if !unsafe { lovrGraphicsIsInitialized() } {
            return;
        }

        match wanted {
            Readiness::Start => self.start_compositor(),
            Readiness::Adopt => self.adopt_graphics(),
        }
    }

    /// Borrows LÖVR's device, starts the compositor thread against it, and points monitor capture at the formats it can import.
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

    /// Hands the compositor a device borrowed from the session that came up after a restart.
    ///
    /// The compositor re-imports every retained buffer, so a client that has not drawn since the restart gets its content back. The re-imports arrive as ordinary [`Event::BufferImported`] reports.
    fn adopt_graphics(&mut self) {
        let graphics = match borrow_graphics() {
            Ok(graphics) => graphics,
            Err(error) => {
                // Stopped rather than left without a device, because clients would spin redrawing against a compositor that refuses every commit.
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

        // `try_send` because blocking here could deadlock against a compositor blocked on the event channel. A full queue is retried next frame.
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
                // The thread has gone. Joining it drops the handle, so nothing offers a device to a channel with no reader.
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

    /// Copies each claim's window into its layer, and hands the runtime the list to composite.
    ///
    /// A layer skipped because its window has not committed still goes to the runtime, which re-composites its last image. Omitting it would hide the panel.
    fn blit_layers(&mut self) {
        let scene = self.session.scene();
        let session = Rc::clone(&self.session);
        let blits = &mut self.blits;
        let blitted = &mut self.blitted;

        self.layers.with_pool(|pool| {
            session.with_textures(|textures| {
                let report = blitted.run(pool, blits, textures, |claim| {
                    session
                        .claims()
                        .source(claim)
                        .and_then(|window| session.window(window))
                        .map(|window| window.surface)
                });

                if report.iter().any(|(_, outcome)| outcome.copied()) {
                    // Matters only on a frame that draws no scene. `crate::scene` has the reasoning.
                    session.note_copies_recorded();
                }

                for (claim, outcome) in report {
                    // `Blitted` decides which outcomes are permanent, and the blit ledger has already reported each once per claim.
                    if outcome.worth_reporting_every_frame() {
                        warn!(%claim, ?outcome, "a layer was not updated this frame");
                    }
                }
            });

            // The frame's whole layer list, which decides whether lunette's projection layer belongs in this `xrEndFrame`.
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
        self.session.audio().event(event);

        // The closed window is already absent from this snapshot, so its surface is read from the previous frame.
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
    /// Always a new texture, because installing marks the surface damaged, and a stabilised copy refreshes only from that damage.
    fn install(&self, surface: SurfaceId, buffer: &ImportedBuffer) {
        let description = crate::texture::describe(buffer);
        // SAFETY: this is the frame thread, and LÖVR's graphics module is initialised because the compositor that produced this event started. An image handle names an image the arena holds, created with `crate::import::device::IMPORT_USAGE`.
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
/// Separate from performing it because the mapping is pure and testable, while creating a texture needs a device.
#[derive(Debug, PartialEq, Eq)]
enum LedgerChange<'a> {
    /// The surface committed a buffer, which becomes its new texture.
    Install {
        surface: SurfaceId,
        buffer: &'a ImportedBuffer,
    },
    /// The surface's client is gone. Its textures are released and the description survives, so reads keep last-known values.
    MarkDead(SurfaceId),
    /// The surface itself is gone, and its entry is released.
    ///
    /// Every `wl_surface` can hold a texture but only a toplevel is reported closed, so this keeps popups, subsurfaces, and cursors from leaving freed images in the barriers.
    Forget(SurfaceId),
    /// Nothing the textures care about.
    Nothing,
}

/// Reads an event as a change to the ledger.
///
/// Exhaustive, so a new protocol variant needs an answer here.
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
        // The restart acknowledgements do not touch a texture. `FrameDriver::quiesce` handles the images, and re-imports arrive as their own `BufferImported` reports.
        Event::WindowOpened { .. }
        | Event::TitleChanged { .. }
        | Event::SurfaceDamaged { .. }
        | Event::ProcessExited { .. }
        | Event::ProcessOutput { .. }
        | Event::ProcessObservationChanged { .. }
        | Event::AudioProcessResolved(_)
        | Event::GraphicsReleased
        | Event::GraphicsAdopted { .. } => LedgerChange::Nothing,
    }
}

/// Which monitors the sweep for stopped mirrors releases.
///
/// The union of both ledgers, because a frame whose image imports but whose texture the device refuses retains a buffer without reaching [`MonitorTextures`].
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
/// Separate from [`start`] because the device is borrowed again after every restart.
///
/// # Safety of the borrow
///
/// The caller must have established that LÖVR's graphics module is initialised, and the device stays valid until [`FrameDriver::shutdown`] stops the thread or [`FrameDriver::quiesce`] takes it back.
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
        // Lifted out by `FrameDriver::new`, because it outlives this start.
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

    // A half-dead compositor holding a Wayland socket is worse for a user than a process that stops.
    let handle = thread::spawn(config, socket, Box::new(importer), PanicPolicy::Abort)
        .map_err(StartupError::Thread)?;

    info!(
        name = %name.wayland_display_num_string(),
        "compositor running; clients may connect"
    );

    Ok(handle)
}

/// The DRM formats a capture stream may negotiate.
///
/// The same set the compositor advertises, because both go through one dmabuf import path.
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

/// Drops lunette's references to the textures a ledger change released.
///
/// The images are retired by the compositor when the client destroys the buffer.
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
