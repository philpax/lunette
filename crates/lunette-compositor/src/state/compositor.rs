//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs and backend/wayvr/mod.rs (the globals and output fragments), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The state every global is served from, and the commit path underneath it.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

#[cfg(any(test, feature = "test-fakes"))]
use smithay::input::pointer::CursorImageStatus;
use smithay::{
    backend::allocator::Format,
    desktop::{PopupKind, PopupManager, find_popup_root_surface, get_popup_toplevel_coords},
    input::SeatState,
    reexports::{
        calloop::{
            LoopHandle, LoopSignal, RegistrationToken,
            timer::{TimeoutAction, Timer},
        },
        wayland_protocols::xdg::shell::server::xdg_toplevel,
        wayland_server::{
            Client, DisplayHandle, Resource,
            backend::{ClientData, ClientId, DisconnectReason, ObjectId},
            protocol::{wl_buffer::WlBuffer, wl_callback::WlCallback, wl_surface::WlSurface},
        },
    },
    utils::{Logical, Rectangle, Size, Transform},
    wayland::{
        compositor::{self, CompositorClientState, send_surface_state, with_states},
        dmabuf::{DmabufFeedback, DmabufFeedbackBuilder, DmabufGlobal, DmabufState},
        fractional_scale::{FractionalScaleManagerState, with_fractional_scale},
        selection::{
            data_device::DataDeviceState,
            ext_data_control::DataControlState as ExtDataControlState,
            primary_selection::PrimarySelectionState,
            wlr_data_control::DataControlState as WlrDataControlState,
        },
        shell::{
            kde::decoration::KdeDecorationState,
            xdg::{
                PopupSurface, ToplevelSurface, XdgShellState, XdgToplevelSurfaceData,
                XdgToplevelSurfaceRoleAttributes, decoration::XdgDecorationState,
            },
        },
        shm::ShmState,
        viewporter::ViewporterState,
    },
};
use tracing::{debug, info, warn};

use crate::{
    client::{DisplayName, Satellite, XwaylandSatellite},
    output::{OutputEntry, OutputRegistry, integer_scale},
    process::{
        DisplayEnvironment, ProcessInspector, ProcessRegistry, ProcessSpawner, Report, SpawnRequest,
    },
    protocol::{
        Command, Event, KeyboardConfig, KeymapDefaults, OutputId, OutputMode, OutputScale, Pid,
        PixelSize, ProcessId, ProcessOutcome, ProcessSignal, RefreshRate, SeatId,
        SpawnRequest as SpawnCommand, SurfaceId, ToplevelState, ToplevelStates, WindowId,
    },
    seat::SeatRegistry,
    selection::{HostEvents, HostSelectionSource, SelectionBridge},
    surface::{BufferImporter, RetainedBuffers, SurfaceContent, SurfaceRegistry},
    thread::{EventSender, LoopData, SnapshotParts, SnapshotPublisher},
    window::{Window, WindowManager},
};

/// The seat lunette starts with, which is the one a caller that has not asked
/// for any gets.
///
/// Fixed rather than allocated, because it exists before anything has run that
/// could allocate one. Further seats are named by whoever creates them, through
/// [`Command::CreateSeat`].
pub const DEFAULT_SEAT: SeatId = match SeatId::new(1) {
    Some(seat) => seat,
    None => unreachable!(),
};

/// The output a client that was not assigned one is shown.
///
/// Fixed rather than allocated, for the reason [`DEFAULT_SEAT`] is: it exists
/// before anything has run that could have created one. A client adopted from
/// outside lunette is never assigned an output — nothing spawned it, so nothing
/// named one for it — and a client with no `wl_output` at all cannot pick a
/// scale or a refresh rate. Further outputs are created from Lua, through
/// [`Command::CreateOutput`].
pub const DEFAULT_OUTPUT: OutputId = match OutputId::new(1) {
    Some(output) => output,
    None => unreachable!(),
};

/// The default seat's name, which clients see on `wl_seat.name`.
const SEAT_NAME: &str = "lunette";

/// How often spawned processes are checked for output and for having exited.
///
/// A tenth of a second. Output from a spawned application is diagnostic, so the
/// latency does not matter; the interval is short enough that a process that
/// exits is reported within a frame or two of it happening.
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// How lunette configures its virtual monitor and its buffer support.
///
/// WayVR fixes the resolution at `mod.rs:172` as `WAYVR_SCREEN_RES`. Lunette's
/// outputs are configurable from Phase 8, so this is a value with a default
/// rather than a constant.
#[derive(Debug)]
pub struct CompositorConfig {
    pub output: OutputMode,
    pub dmabuf: DmabufSupport,
    /// How the host desktop's clipboard is reached. Absent means selections stay
    /// inside lunette, which is what a session with no host Wayland socket gets.
    pub host_selection: Option<Box<dyn HostSelectionSource>>,
    /// Which display lunette is. Absent when no socket was bound, which is the
    /// case in a test: a spawned client is then told nothing about where to
    /// connect, because there is nowhere to connect to.
    pub display: Option<DisplayName>,
    /// Where to find xwayland-satellite. Absent means X11 clients are not
    /// served, which is a session worth having.
    pub satellite: Option<XwaylandSatellite>,
    /// The desktop's own keyboard layout, which a seat that names none inherits.
    /// The binary reads it from the environment; nothing in this crate does.
    pub keymap_defaults: KeymapDefaults,
}

impl Default for CompositorConfig {
    fn default() -> Self {
        Self {
            output: OutputMode {
                // WayVR's `WAYVR_SCREEN_RES`, kept because it is a size that
                // suits a panel a user reads at arm's length rather than a
                // monitor they sit in front of.
                size: PixelSize::new(2560, 1440),
                scale: OutputScale::new(1.0).unwrap_or_else(|| unreachable!("one is positive")),
                refresh: RefreshRate::from_millihertz(60_000),
            },
            dmabuf: DmabufSupport::default(),
            host_selection: None,
            display: None,
            satellite: None,
            keymap_defaults: KeymapDefaults::default(),
        }
    }
}

/// What lunette can accept over `zwp_linux_dmabuf_v1`.
///
/// Both fields come from the graphics device, which this crate does not have,
/// so they arrive as a parameter. Without a device — in a test, or on a machine
/// whose driver lacks the import extensions — the global is still advertised
/// with no formats, and clients fall back to `wl_shm`.
#[derive(Clone, Debug, Default)]
pub struct DmabufSupport {
    /// The DRM render node the formats belong to. Version 4 feedback cannot be
    /// built without it: `DmabufFeedbackBuilder::new` takes the device
    /// unconditionally.
    pub main_device: Option<RenderNode>,
    pub formats: Vec<Format>,
}

/// A DRM render node, as the `st_rdev` of its device file.
///
/// `libc::dev_t` is what smithay's feedback builder takes. Wrapping it means a
/// caller cannot pass a major or a minor by mistake, and it names where the
/// number has to come from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct RenderNode(libc::dev_t);

impl RenderNode {
    /// Builds a device number from the major and minor a Vulkan
    /// `VkPhysicalDeviceDrmPropertiesEXT` reports.
    #[must_use]
    pub fn from_major_minor(major: u32, minor: u32) -> Self {
        Self(libc::makedev(major, minor))
    }

    #[must_use]
    pub const fn get(self) -> libc::dev_t {
        self.0
    }
}

/// Everything the compositor thread owns other than the display itself.
///
/// This is WayVR's `Application` (`comp.rs:68-94`). Every `delegate_*!` at the
/// bottom of this file names it, so it is the single type smithay dispatches
/// protocol traffic into.
pub(crate) struct CompositorState {
    pub(super) display: DisplayHandle,
    pub(super) config: CompositorConfig,
    /// What a spawned client is told about how to reach lunette, derived once
    /// from the display name rather than rebuilt per spawn.
    environment: DisplayEnvironment,

    pub(super) compositor: compositor::CompositorState,
    pub(super) xdg_shell: XdgShellState,
    pub(super) shm: ShmState,
    pub(super) seat_state: SeatState<Self>,
    /// Every seat lunette serves. Holding an entry is what keeps its `wl_seat`
    /// global advertised.
    pub(super) seats: SeatRegistry,
    pub(super) dmabuf: DmabufState,
    pub(super) data_device: DataDeviceState,
    pub(super) primary_selection: PrimarySelectionState,
    pub(super) wlr_data_control: WlrDataControlState,
    pub(super) ext_data_control: ExtDataControlState,
    /// Which seat's selections are the host's, and what the host is offering.
    pub(super) selection: SelectionBridge,
    pub(super) kde_decoration: KdeDecorationState,
    pub(super) popups: PopupManager,
    /// Every virtual monitor lunette advertises. Holding an entry is what keeps
    /// its `wl_output` global advertised.
    pub(super) outputs: OutputRegistry,

    // Held for their lifetime rather than their API: dropping any of these
    // withdraws the global it created, so a client that binds it afterwards is
    // talking to a protocol lunette no longer speaks.
    #[expect(dead_code, reason = "held so the global stays advertised")]
    dmabuf_global: DmabufGlobal,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    dmabuf_feedback: Option<DmabufFeedback>,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    xdg_decoration: XdgDecorationState,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    viewporter: ViewporterState,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    fractional_scale: FractionalScaleManagerState,

    pub(super) importer: Box<dyn BufferImporter>,
    spawner: Box<dyn ProcessSpawner>,
    inspector: Box<dyn ProcessInspector>,
    pub(super) surfaces: SurfaceRegistry,
    pub(super) buffers: RetainedBuffers<WlBuffer>,
    pub(super) contents: HashMap<SurfaceId, SurfaceContent>,
    pub(super) windows: WindowManager,
    processes: ProcessRegistry,
    /// Which process each connected client was attributed to.
    clients: HashMap<ClientId, ProcessId>,
    /// Which output each spawned process's clients are shown. Only processes
    /// whose spawn named one appear; the rest fall back to the default output.
    assignments: HashMap<ProcessId, OutputId>,
    /// The timer that reaps children and collects their output, present only
    /// while there is something to reap.
    process_poll: Option<RegistrationToken>,
    loop_handle: LoopHandle<'static, LoopData>,
    /// Polled with the spawned processes, and dropped with the state: dropping
    /// it asks the bridge's process group to stop, which is how
    /// xwayland-satellite and the `Xwayland` it started are reaped.
    satellite: Satellite,
    pub(super) frame_callbacks: HashMap<ObjectId, Vec<WlCallback>>,
    /// How many keymap uploads to let through, and how many to fail after
    /// them. Always `(0, 0)` in production; see
    /// [`CompositorState::fail_keymap_uploads`].
    #[cfg(any(test, feature = "test-fakes"))]
    failing_uploads: std::cell::Cell<(usize, usize)>,

    /// The baseline for the millisecond timestamps the protocol wants.
    ///
    /// WayVR reads the wall clock and unwraps the conversion (`time.rs:4-9`).
    /// Wayland's timestamps must be monotonic, and a wall clock is not: a clock
    /// step backwards makes a client see time reverse, and NTP steps happen.
    started: Instant,

    events: EventSender,
    snapshots: SnapshotPublisher,
    signal: LoopSignal,
    dirty: bool,
}

impl CompositorState {
    /// Advertises every global and returns the state that serves them.
    ///
    /// Nine globals, and `wl_compositor` brings a tenth: `CompositorState::new`
    /// creates `wl_subcompositor` unconditionally
    /// (`smithay-0.7.0/src/wayland/compositor/mod.rs:685-710`), so omitting it
    /// is not an option a caller has.
    pub(crate) fn new(parts: StateParts<'_>) -> Self {
        let StateParts {
            display,
            mut config,
            importer,
            spawner,
            inspector,
            events,
            snapshots,
            signal,
            loop_handle,
            host_selection,
        } = parts;
        // Version 6 rather than the 5 `CompositorState::new` defaults to
        // (`smithay-0.7.0/src/wayland/compositor/mod.rs:680-685`). Six is the
        // version that carries `wl_surface.preferred_buffer_scale`, which is
        // how a client learns the whole-number scale of the output it is on
        // without binding a `wl_output` at all — and binding one is exactly what
        // lunette's filter may refuse it. Below six, `send_surface_state`
        // returns without sending anything
        // (`compositor/mod.rs:409-412`), so the call would be dead.
        let compositor = compositor::CompositorState::new_v6::<Self>(display);
        let xdg_shell = XdgShellState::new::<Self>(display);
        // An empty extra-format list, as WayVR passes at `mod.rs:185`, so only
        // `wl_shm`'s two mandatory formats are advertised. Anything further is
        // a format the importer would have to be taught.
        let shm = ShmState::new::<Self>(display, Vec::new());
        let viewporter = ViewporterState::new::<Self>(display);
        // Paired with the viewporter above, and useless without it: a client
        // told to render at 1.5 lands the buffer at the right logical size by
        // setting an integer `wl_surface.set_buffer_scale` and correcting with
        // `wp_viewport.set_destination`. WayVR advertises the viewporter and not
        // this, which is why its own `with_fractional_scale` calls write user
        // data no client can read.
        let fractional_scale = FractionalScaleManagerState::new::<Self>(display);
        let xdg_decoration = XdgDecorationState::new::<Self>(display);
        let kde_decoration = KdeDecorationState::new::<Self>(
            display,
            smithay::reexports::wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration_manager::Mode::Server,
        );

        let mut seat_state = SeatState::new();
        let mut seats = SeatRegistry::default();
        if let Err(error) = seats.create(
            &mut seat_state,
            display,
            DEFAULT_SEAT,
            SEAT_NAME,
            &KeyboardConfig::default(),
            &config.keymap_defaults,
        ) {
            warn!(
                %error,
                "could not create the default seat; input will reach no client until one is made"
            );
        }

        let mut outputs = OutputRegistry::default();
        if let Err(error) = outputs.create(display, DEFAULT_OUTPUT, config.output) {
            warn!(
                %error,
                "could not create the default output; a client assigned none will see no monitor"
            );
        }

        let (dmabuf, dmabuf_global, dmabuf_feedback) =
            create_dmabuf_global(display, &config.dmabuf);

        // Every client may read and write both selections. lunette hosts the
        // applications a user started deliberately, so there is no privilege
        // boundary here to draw; WayVR admits every client too
        // (`mod.rs:176-178`).
        let data_device = DataDeviceState::new::<Self>(display);
        let primary_selection = PrimarySelectionState::new::<Self>(display);
        let wlr_data_control =
            WlrDataControlState::new::<Self, _>(display, Some(&primary_selection), |_| true);
        let ext_data_control =
            ExtDataControlState::new::<Self, _>(display, Some(&primary_selection), |_| true);

        let host = config.host_selection.take().and_then(|source| {
            source
                .open(host_selection)
                .inspect_err(|error| {
                    warn!(%error, "the host clipboard will not be bridged this session");
                })
                .ok()
        });

        let mut spawner = spawner;
        let satellite = match config.display {
            Some(name) => Satellite::start(spawner.as_mut(), config.satellite.as_ref(), name),
            None => {
                debug!("no wayland socket was bound, so no x11 bridge is started");
                Satellite::default()
            }
        };

        let mut state = Self {
            display: display.clone(),
            environment: config
                .display
                .map(DisplayName::environment)
                .unwrap_or_default(),
            config,
            compositor,
            xdg_shell,
            shm,
            seat_state,
            seats,
            dmabuf,
            data_device,
            primary_selection,
            wlr_data_control,
            ext_data_control,
            selection: SelectionBridge::new(Some(DEFAULT_SEAT), host),
            kde_decoration,
            popups: PopupManager::default(),
            outputs,
            dmabuf_global,
            dmabuf_feedback,
            xdg_decoration,
            viewporter,
            fractional_scale,
            importer,
            spawner,
            inspector,
            satellite,
            surfaces: SurfaceRegistry::default(),
            buffers: RetainedBuffers::default(),
            contents: HashMap::new(),
            windows: WindowManager::default(),
            processes: ProcessRegistry::default(),
            clients: HashMap::new(),
            assignments: HashMap::new(),
            process_poll: None,
            loop_handle,
            frame_callbacks: HashMap::new(),
            #[cfg(any(test, feature = "test-fakes"))]
            failing_uploads: std::cell::Cell::new((0, 0)),
            started: Instant::now(),
            events,
            snapshots,
            signal,
            dirty: true,
        };

        // The bridge is a child like any other and has to be waited on, so the
        // poll timer starts with it rather than with the first `lunette.spawn`.
        if state.satellite.is_running() {
            state.watch_processes();
        }

        state.report_bridge();
        state
    }

    pub(crate) fn stop(&self) {
        self.signal.stop();
    }

    /// Applies one command from the main thread.
    ///
    /// The match is exhaustive on purpose. A variant that gains a handler in a
    /// later phase has to be moved out of the unhandled arm deliberately, and a
    /// variant added to the protocol fails to compile here until someone
    /// decides what it does.
    pub(crate) fn handle(&mut self, command: Command) {
        match command {
            Command::Shutdown => {
                debug!("shutting down at the main thread's request");
                self.stop();
            }
            Command::CloseWindow { window } => self.close_window(window),
            Command::ConfigureWindow {
                window,
                size,
                states,
            } => self.configure_window(window, size, &states),
            Command::Pointer {
                seat,
                sink,
                position,
            } => self.move_pointer(seat, Some((sink, position))),
            Command::PointerLeave { seat } => self.move_pointer(seat, None),
            Command::Button {
                seat,
                sink,
                button,
                pressed,
            } => self.press_button(seat, sink, button, pressed),
            Command::Spawn(request) => self.spawn_process(&request),
            Command::SignalProcess { process, signal } => self.signal_process(process, signal),
            Command::CreateSeat {
                seat,
                name,
                keyboard,
            } => self.create_seat(seat, &name, keyboard.as_ref()),
            Command::DestroySeat { seat } => self.destroy_seat(seat),
            Command::SetClipboardBridge { seat } => self.set_clipboard_bridge(seat),
            Command::Key { seat, key, pressed } => self.press_key(seat, key, pressed),
            Command::Modifiers { seat, modifiers } => self.set_modifiers(seat, &modifiers),
            Command::Focus { seat, sink } => self.set_focus(seat, sink),
            Command::TypeText { seat, text } => self.type_text(seat, &text),
            Command::Scroll {
                seat,
                sink,
                axis,
                delta,
            } => self.scroll(seat, sink, axis, delta),
            Command::ReleaseGraphics => self.release_graphics(),
            Command::AdoptGraphics { importer } => self.adopt_graphics(importer),
            Command::CreateOutput { output, mode } => self.create_output(output, mode),
            Command::ReconfigureOutput { output, mode } => self.reconfigure_output(output, mode),
            Command::DestroyOutput { output } => self.destroy_output(output),
            Command::SetFramePacing { .. } => {
                warn!(?command, "no handler for this command yet; ignoring it");
            }
        }
    }

    /// Creates a virtual monitor and advertises its global.
    ///
    /// A duplicate identifier is reported and dropped rather than replacing the
    /// output that holds it: the clients already bound to that one would be
    /// silently reconfigured to a mode nobody asked them to take.
    fn create_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.create(&self.display, output, mode) {
            Ok(()) => {
                info!(%output, "an output was created");
                self.touch();
            }
            Err(error) => warn!(%error, "could not create an output"),
        }
    }

    /// Changes an output's mode, and tells everything on it.
    ///
    /// The `wl_output` events are the registry's; the per-surface scales and the
    /// toplevel configures are [`CompositorState::rescale_output`]'s. A client
    /// told its monitor changed and not told its own new scale keeps rendering
    /// at the old one.
    fn reconfigure_output(&mut self, output: OutputId, mode: OutputMode) {
        match self.outputs.reconfigure(output, mode) {
            Ok(()) => {
                self.rescale_output(output);
                self.touch();
            }
            Err(error) => warn!(%error, "could not reconfigure an output"),
        }
    }

    /// Withdraws an output.
    ///
    /// The default output is refused. It is what a client that was assigned no
    /// output is shown, and every adopted client is one of those, so a session
    /// without it has clients that can see no monitor at all.
    fn destroy_output(&mut self, output: OutputId) {
        if output == DEFAULT_OUTPUT {
            debug!("the default output cannot be destroyed; a client assigned none needs it");
            return;
        }

        match self.outputs.destroy(&self.display, output) {
            Ok(()) => self.touch(),
            Err(error) => warn!(%error, "could not destroy an output"),
        }
    }

    /// Starts a process and attributes the clients it connects with.
    ///
    /// A spawn that fails is reported as an exit that never happened, because
    /// that is the one report a caller of `lunette.spawn` gets for a mistyped
    /// program name and there is nothing else to hang it on.
    fn spawn_process(&mut self, request: &SpawnCommand) {
        let plan = SpawnRequest {
            process: request.process,
            argv: &request.argv,
            env: &request.env,
            cwd: request.cwd.as_deref(),
            display: &self.environment,
        };

        if request.xwayland {
            debug!(
                process = %request.process,
                "an X11 client still reaches lunette through xwayland-satellite's own socket"
            );
        }

        match self.processes.spawn(self.spawner.as_mut(), plan) {
            Ok(()) => {
                self.assign_output(request.process, request.output);
                self.touch();
                self.watch_processes();
            }
            Err(error) => {
                warn!(%error, "could not start a process");
                self.report(Event::ProcessExited {
                    process: request.process,
                    outcome: ProcessOutcome::SpawnFailed {
                        message: error.message(),
                    },
                });
            }
        }
    }

    /// Records which output a spawned process's clients will be shown.
    ///
    /// An output that does not exist is refused rather than recorded: a client
    /// assigned one would see no monitor at all, which is a harder failure to
    /// diagnose than a warning naming the output. Falling back to the default
    /// is what an absent assignment already means.
    fn assign_output(&mut self, process: ProcessId, output: Option<OutputId>) {
        let Some(output) = output else {
            return;
        };
        if self.outputs.get(output).is_none() {
            warn!(
                %process,
                %output,
                "a spawn named an output that does not exist; showing the default output instead"
            );
            return;
        }
        self.assignments.insert(process, output);
    }

    fn signal_process(&mut self, process: ProcessId, signal: ProcessSignal) {
        self.processes.signal(process, signal);
    }

    /// Attributes a newly connected client to a process.
    ///
    /// The connecting pid first, then the token in the client's own
    /// environment, and failing both the client is adopted as external — which
    /// is the case a process started outside lunette with `WAYLAND_DISPLAY`
    /// pointing at its socket falls into.
    pub(crate) fn attach_client(&mut self, client: &Client) {
        let process = match client.get_credentials(&self.display) {
            Ok(credentials) => match Pid::new(credentials.pid) {
                Some(pid) => self.attribute(pid),
                None => {
                    warn!("a client connected with an impossible process id; not attributing it");
                    return;
                }
            },
            Err(error) => {
                warn!(%error, "could not read a connecting client's credentials");
                return;
            }
        };

        // Before any request from this client has been dispatched, because
        // `insert_client` does not dispatch: the client's `wl_registry` has not
        // been read yet, so the first advertisement sees the assignment.
        if let Some(state) = client.get_data::<ClientState>() {
            state.assign(self.assignments.get(&process).copied());
        }

        self.prune_clients();
        self.clients.insert(client.id(), process);
        self.touch();
        self.watch_processes();
    }

    /// Forgets clients that have gone away.
    ///
    /// There is no per-client destruction hook to hang this on:
    /// `ClientData::disconnected` is called on an `Arc` that knows nothing
    /// about the compositor, and `CompositorHandler` only reports surfaces. So
    /// the map is swept when a new client arrives, which bounds it at the
    /// number of clients that have connected since the last connection rather
    /// than at the number that have ever connected.
    fn prune_clients(&mut self) {
        let backend = self.display.backend_handle();
        self.clients.retain(|client, _| {
            backend
                .get_client_data(client.clone())
                .ok()
                .and_then(|data| data.downcast_arc::<ClientState>().ok())
                .is_some_and(|data| !data.disconnected())
        });
    }

    fn attribute(&mut self, pid: Pid) -> ProcessId {
        if let Some(process) = self.processes.identify(pid, self.inspector.as_ref()) {
            debug!(%pid, %process, "attributed a client to a process lunette started");
            return process;
        }

        let process = self.processes.adopt(pid);
        info!(
            %pid,
            %process,
            "a process lunette did not start connected to its socket; adopting it"
        );
        process
    }

    /// The output a surface's client is shown, which is the one it was assigned
    /// or the default when it was assigned none.
    pub(super) fn output_of(&self, surface: &WlSurface) -> OutputId {
        assigned_output(surface).unwrap_or(DEFAULT_OUTPUT)
    }

    /// The process a client was attributed to.
    pub(super) fn process_of(&self, surface: &WlSurface) -> Option<ProcessId> {
        let client = surface.client()?;
        self.clients.get(&client.id()).copied()
    }

    /// Starts the poll timer if it is not already running.
    ///
    /// One timer for every process rather than a source per pipe and a reaper
    /// besides: a child's output is diagnostic, so a fraction of a second of
    /// latency costs nothing, and a source registered per child would have to
    /// be unregistered from inside its own callback.
    fn watch_processes(&mut self) {
        if self.process_poll.is_some() {
            return;
        }

        let inserted = self.loop_handle.insert_source(
            Timer::from_duration(PROCESS_POLL_INTERVAL),
            |_now, _metadata, data: &mut LoopData| data.state.poll_processes(),
        );

        match inserted {
            Ok(token) => self.process_poll = Some(token),
            Err(error) => warn!(
                error = %error.error,
                "could not watch spawned processes; their output and exits will not be reported"
            ),
        }
    }

    /// Collects output and exits, and decides whether to keep watching.
    fn poll_processes(&mut self) -> TimeoutAction {
        self.satellite.poll();

        for report in self.processes.poll(self.inspector.as_ref()) {
            match report {
                Report::Output { id, stream, bytes } => self.report(Event::ProcessOutput {
                    process: id,
                    stream,
                    bytes,
                }),
                Report::Exited { id, outcome } => {
                    self.assignments.remove(&id);
                    self.touch();
                    self.report(Event::ProcessExited {
                        process: id,
                        outcome,
                    });
                }
            }
        }

        if self.processes.is_empty() && !self.satellite.is_running() {
            // Nothing left to reap. The timer is dropped rather than left to
            // wake an otherwise idle compositor ten times a second.
            self.process_poll = None;
            return TimeoutAction::Drop;
        }

        TimeoutAction::ToDuration(PROCESS_POLL_INTERVAL)
    }

    /// Asks a toplevel to close.
    ///
    /// A request, not a kill: the client may prompt the user, or refuse. The
    /// window disappears when the client destroys the toplevel, not here.
    fn close_window(&mut self, window: WindowId) {
        let Some(tracked) = self.windows.get(window) else {
            debug!(%window, "a close was asked for a window that is already gone");
            return;
        };
        tracked.toplevel().send_close();
    }

    /// Configures a toplevel's size and states.
    ///
    /// The client resizes at its own pace and the change is visible when it
    /// commits, so the snapshot keeps reporting the committed size until then.
    fn configure_window(
        &mut self,
        window: WindowId,
        size: Option<PixelSize>,
        states: &ToplevelStates,
    ) {
        let bounds = self.output_bounds(
            self.windows
                .get(window)
                .map_or(DEFAULT_OUTPUT, Window::output),
        );
        let Some(tracked) = self.windows.get_mut(window) else {
            debug!(%window, "a configure was asked for a window that is already gone");
            return;
        };

        // The states are applied first, because a client reads them alongside
        // the size in the same configure.
        tracked.toplevel().with_pending_state(|pending| {
            for state in states {
                pending.states.set(protocol_state(*state));
            }
        });
        tracked.request_size(size.map_or(bounds, logical_size), bounds);
    }

    /// Republishes the snapshot if anything changed since the last one.
    pub(crate) fn publish_if_dirty(&mut self) {
        if !self.dirty {
            return;
        }
        self.dirty = false;

        let windows = self.windows.mapped().map(Window::snapshot).collect();

        self.snapshots.publish(SnapshotParts {
            windows,
            processes: self.processes.snapshot(),
            outputs: self.outputs.snapshot(),
            seats: self.seats.snapshot(self.selection.seat()),
        });
    }

    /// Answers every frame callback a surface has accumulated.
    ///
    /// Called once a tick. A client that is not answered stops drawing, and
    /// most clients stop pumping their event loop with it, so this is what
    /// keeps a window responsive as well as animated.
    pub(crate) fn send_frame_callbacks(&mut self) {
        if self.frame_callbacks.is_empty() {
            return;
        }

        let now = self.millis();
        for (_, callbacks) in self.frame_callbacks.drain() {
            for callback in callbacks {
                callback.done(now);
            }
        }
    }

    /// Milliseconds since the compositor started, which is what the protocol's
    /// timestamps are measured in.
    ///
    /// Truncating to 32 bits is the protocol's own convention: `wl_callback
    /// .done` and every input event carry a `uint` that wraps, and clients
    /// compare timestamps as wrapping differences.
    pub(super) fn millis(&self) -> u32 {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "the protocol's timestamps are 32-bit and wrap by design"
        )]
        {
            self.started.elapsed().as_millis() as u32
        }
    }

    /// Marks the snapshot stale so the next tick republishes it.
    pub(super) fn touch(&mut self) {
        self.dirty = true;
    }

    /// Lets the importer release what the clients no longer hold.
    ///
    /// Called once per dispatch, because a dispatch is the only thing that can
    /// have made an import collectable: the strong reference to a client's
    /// dmabuf is the `wl_buffer` this side retains, and it is dropped either
    /// when the client destroys the buffer or when the compositor forgets the
    /// surface. Driving retirement from imports alone holds every image of a
    /// client that has disconnected or fallen quiet, since neither performs one.
    pub(crate) fn sweep_imports(&mut self) {
        self.importer.sweep();
    }

    pub(super) fn report(&self, event: Event) {
        if self.events.send(event).is_err() {
            debug!("the main thread is gone; dropping an event");
        }
    }

    /// Tells a newly created surface which output it is on and at what scale.
    pub(super) fn send_initial_surface_state(&mut self, surface: &WlSurface) {
        self.outputs.enter(surface);
        self.send_surface_scale(surface);
    }

    /// Tells one surface the scale of the output its client is shown.
    ///
    /// Both numbers, because a client is owed both. `wp_fractional_scale_v1`
    /// carries the exact scale in 120ths, which is what a client renders at;
    /// `wl_surface.preferred_buffer_scale` carries the whole number a client
    /// without the fractional protocol renders at, and it is the ceiling rather
    /// than the floor so that a client on a 1.5 scale is not told its monitor is
    /// unscaled. The matching logical size travels separately, as an xdg-toplevel
    /// configure; sending a scale without one produces sharp content at the
    /// wrong size, which reads as a bug in the client.
    ///
    /// Set whether or not the client has asked for a `wp_fractional_scale_v1`
    /// yet. smithay replays a pre-set value when the object is created
    /// (`fractional_scale/mod.rs:160-166`), so pre-setting is what avoids a
    /// first frame at the wrong scale.
    ///
    /// # Thread affinity
    ///
    /// `with_fractional_scale` inserts into the surface's user data with the
    /// non-threadsafe `get_or_insert` (`fractional_scale/mod.rs:253-263`), which
    /// records the calling thread and answers `None` to every other one — so a
    /// second thread would insert a second entry and the two would diverge in
    /// silence. Everything here runs on the compositor thread, which is the only
    /// thing that dispatches [`CompositorState`].
    pub(super) fn send_surface_scale(&self, surface: &WlSurface) {
        let mode = self.mode_of(self.output_of(surface));

        with_states(surface, |states| {
            send_surface_state(
                surface,
                states,
                integer_scale(mode.scale),
                Transform::Normal,
            );
            with_fractional_scale(states, |fractional| {
                fractional.set_preferred_scale(mode.scale.get());
            });
        });
    }

    /// Tells everything on an output that its mode changed.
    ///
    /// Three things travel together, and a client that gets only some of them
    /// renders at the wrong size: the scales, through
    /// [`CompositorState::send_surface_scale`]; the size limits, which are
    /// clamped against the output and so move with it; and a configure at the
    /// new logical bounds.
    ///
    /// Each window is reconfigured at the size it last committed, clamped into
    /// the new bounds. So an output that shrank — which is what raising the
    /// scale of a fixed resolution does — pulls its windows in, and an output
    /// that grew leaves them where Lua put them.
    fn rescale_output(&mut self, output: OutputId) {
        for surface in self.outputs.surfaces() {
            if self.output_of(&surface) == output {
                self.send_surface_scale(&surface);
            }
        }

        let bounds = self.output_bounds(output);
        for window in self.windows.on_output(output) {
            window.refresh_constraints(bounds);
            let size = logical_size(window.size());
            window.request_size(size, bounds);
        }
    }

    /// The mode an output is advertising, or the default output's when it has
    /// been destroyed, which is the fallback [`CompositorState::output_bounds`]
    /// takes for the same reason.
    fn mode_of(&self, output: OutputId) -> OutputMode {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or(self.config.output, OutputEntry::mode)
    }

    pub(super) fn popups_commit(&mut self, surface: &WlSurface) {
        self.popups.commit(surface);

        let Some(PopupKind::Xdg(popup)) = self.popups.find_popup(surface) else {
            return;
        };
        if popup.is_initial_configure_sent() {
            return;
        }

        self.send_surface_scale(surface);

        if let Err(error) = popup.send_configure() {
            warn!(%error, "could not send a popup's initial configure");
        }
    }

    /// Keeps a popup inside its root toplevel, as the positioner asks.
    pub(super) fn constrain_popup(&self, popup: &PopupSurface) {
        let kind = PopupKind::Xdg(popup.clone());

        let Ok(root) = find_popup_root_surface(&kind) else {
            warn!("could not find a popup's root surface; leaving it unconstrained");
            return;
        };

        let root_size = self
            .surfaces
            .get(&root)
            .and_then(|id| self.contents.get(&id))
            .map_or_else(
                || self.surface_bounds(&root),
                |content| logical_size(content.logical_size()),
            );

        let mut target = Rectangle::from_size(root_size);
        target.loc -= get_popup_toplevel_coords(&kind);

        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }

    /// The logical size a window on `output` is configured against.
    ///
    /// A window whose client was assigned no output is bounded by the default
    /// one, which is also the output that client is shown. So is a window whose
    /// assigned output has since been destroyed: the bounds have to be some
    /// size, and the one every unassigned client is already using is the least
    /// surprising.
    pub(super) fn output_bounds(&self, output: OutputId) -> Size<i32, Logical> {
        self.outputs
            .get(output)
            .or_else(|| self.outputs.get(DEFAULT_OUTPUT))
            .map_or_else(
                || logical_size(self.config.output.size),
                |entry| entry.logical_size(),
            )
    }

    /// The logical size a surface's client is configured against.
    ///
    /// For the paths that hold a surface and no window: a toplevel being
    /// created, a popup being constrained, a fullscreen request.
    pub(super) fn surface_bounds(&self, surface: &WlSurface) -> Size<i32, Logical> {
        self.output_bounds(self.output_of(surface))
    }
}

/// The output a surface's client was assigned, if it was assigned one.
fn assigned_output(surface: &WlSurface) -> Option<OutputId> {
    surface.client()?.get_data::<ClientState>()?.output()
}

#[cfg(any(test, feature = "test-fakes"))]
impl CompositorState {
    /// What a seat's focused client last asked its cursor to look like.
    ///
    /// Inspection for the test that holds per-seat cursor state honest, which is
    /// the property `SeatHandler::cursor_image` breaks by ignoring its seat
    /// argument. Nothing in the compositor renders a cursor.
    pub(crate) fn cursor_image(&self, seat: SeatId) -> Option<CursorImageStatus> {
        self.seats
            .get(seat)
            .map(|entry| crate::seat::cursor_image(entry.seat()))
    }

    /// Lets the next `skip` keymap uploads through and fails the `count` after
    /// them.
    ///
    /// The seam `lunette-v1.AC4.3`'s failure clause needs. A real upload fails
    /// only on a layout that does not compile, and the generator refuses to
    /// produce one, so the restore path has no other way to be exercised.
    /// `skip` is what picks out *which* upload fails, which is the whole
    /// question: failing the first leaves nothing loaded to restore.
    pub(crate) fn fail_keymap_uploads(&self, skip: usize, count: usize) {
        self.failing_uploads.set((skip, count));
    }

    /// Consumes one injected failure, if any are outstanding.
    pub(super) fn take_upload_failure(&self) -> bool {
        let (skip, remaining) = self.failing_uploads.get();
        if skip > 0 {
            self.failing_uploads.set((skip - 1, remaining));
            return false;
        }
        if remaining == 0 {
            return false;
        }
        self.failing_uploads.set((0, remaining - 1));
        true
    }
}

/// Everything [`CompositorState::new`] needs, bundled so the constructor takes
/// one argument rather than nine.
pub(crate) struct StateParts<'a> {
    pub(crate) display: &'a DisplayHandle,
    pub(crate) config: CompositorConfig,
    /// Where the host clipboard connection reports what it saw. Built by
    /// [`crate::thread::build`], which registers the reading end on the loop.
    pub(crate) host_selection: HostEvents,
    pub(crate) importer: Box<dyn BufferImporter>,
    pub(crate) spawner: Box<dyn ProcessSpawner>,
    pub(crate) inspector: Box<dyn ProcessInspector>,
    pub(crate) events: EventSender,
    pub(crate) snapshots: SnapshotPublisher,
    pub(crate) signal: LoopSignal,
    pub(crate) loop_handle: LoopHandle<'static, LoopData>,
}

/// What lunette attaches to each connected client.
///
/// The assigned output lives here rather than in [`CompositorState`] because
/// `GlobalDispatch::can_view` is handed a `Client` and no `&mut D`
/// (`wayland-server-0.31.14/src/global.rs:119-121`), so a filter keyed by
/// `ClientId` in compositor state would have nothing to look it up with.
#[derive(Default)]
pub struct ClientState {
    pub(crate) compositor: CompositorClientState,
    /// Set from the disconnect callback, which smithay may call from a
    /// different thread than the one dispatching, hence the lock.
    disconnected: Arc<Mutex<bool>>,
    /// The one output this client is shown, or `None` for a client that was
    /// assigned none — which is shown the default output instead.
    ///
    /// Locked for the reason `disconnected` is: `ClientData` is `Send + Sync`,
    /// so nothing here may assume the dispatching thread.
    output: Mutex<Option<OutputId>>,
}

impl ClientState {
    /// Whether the client has gone away.
    #[must_use]
    pub fn disconnected(&self) -> bool {
        self.disconnected
            .lock()
            .map_or(true, |disconnected| *disconnected)
    }

    /// The output this client was assigned, if it was assigned one.
    #[must_use]
    pub(crate) fn output(&self) -> Option<OutputId> {
        self.output.lock().ok().and_then(|output| *output)
    }

    /// Records which output this client is shown.
    ///
    /// Called from [`CompositorState::attach_client`], before any request from
    /// the client has been dispatched: `insert_client` does not dispatch, so the
    /// client's `wl_registry` has not been read yet and the first advertisement
    /// sees the assignment already in place.
    pub(crate) fn assign(&self, output: Option<OutputId>) {
        if let Ok(mut held) = self.output.lock() {
            *held = output;
        }
    }

    /// Whether this client may see and bind an output's global.
    ///
    /// A client assigned an output sees exactly that one. A client assigned
    /// none sees the default output, which is what every client adopted from
    /// outside lunette is: nothing spawned it, so nothing named an output for
    /// it, and a client with no `wl_output` at all cannot pick a scale.
    #[must_use]
    pub(crate) fn sees_output(&self, output: OutputId) -> bool {
        self.output()
            .map_or(output == DEFAULT_OUTPUT, |assigned| assigned == output)
    }
}

impl ClientData for ClientState {
    fn initialized(&self, client_id: ClientId) {
        debug!(?client_id, "a client connected");
    }

    fn disconnected(&self, client_id: ClientId, reason: DisconnectReason) {
        if let Ok(mut disconnected) = self.disconnected.lock() {
            *disconnected = true;
        }
        debug!(?client_id, ?reason, "a client disconnected");
    }
}

/// Maps a reported toplevel state back onto the protocol's.
pub(super) const fn protocol_state(state: ToplevelState) -> xdg_toplevel::State {
    match state {
        ToplevelState::Maximized => xdg_toplevel::State::Maximized,
        ToplevelState::Fullscreen => xdg_toplevel::State::Fullscreen,
        ToplevelState::Resizing => xdg_toplevel::State::Resizing,
        ToplevelState::Activated => xdg_toplevel::State::Activated,
        ToplevelState::TiledLeft => xdg_toplevel::State::TiledLeft,
        ToplevelState::TiledRight => xdg_toplevel::State::TiledRight,
        ToplevelState::TiledTop => xdg_toplevel::State::TiledTop,
        ToplevelState::TiledBottom => xdg_toplevel::State::TiledBottom,
        ToplevelState::Suspended => xdg_toplevel::State::Suspended,
    }
}

/// Maps the protocol's toplevel states onto the ones the snapshot reports.
///
/// `xdg_toplevel::State` is non-exhaustive, so a state from a later protocol
/// version has no counterpart and is reported as absent rather than guessed at.
pub(super) fn toplevel_state(state: xdg_toplevel::State) -> Option<ToplevelState> {
    match state {
        xdg_toplevel::State::Maximized => Some(ToplevelState::Maximized),
        xdg_toplevel::State::Fullscreen => Some(ToplevelState::Fullscreen),
        xdg_toplevel::State::Resizing => Some(ToplevelState::Resizing),
        xdg_toplevel::State::Activated => Some(ToplevelState::Activated),
        xdg_toplevel::State::TiledLeft => Some(ToplevelState::TiledLeft),
        xdg_toplevel::State::TiledRight => Some(ToplevelState::TiledRight),
        xdg_toplevel::State::TiledTop => Some(ToplevelState::TiledTop),
        xdg_toplevel::State::TiledBottom => Some(ToplevelState::TiledBottom),
        xdg_toplevel::State::Suspended => Some(ToplevelState::Suspended),
        _ => None,
    }
}

/// Creates the `zwp_linux_dmabuf_v1` global, preferring version 4.
///
/// Version 4 lets a client learn which modifiers lunette can import and
/// renegotiate when the answer changes, which is what a client needs to avoid
/// falling back to shared memory. It needs feedback, feedback needs the render
/// node, and the render node comes from the graphics device — so a caller
/// without one gets the version 3 global, exactly as WayVR falls back at
/// `mod.rs:242-249`.
fn create_dmabuf_global(
    display: &DisplayHandle,
    support: &DmabufSupport,
) -> (DmabufState, DmabufGlobal, Option<DmabufFeedback>) {
    let mut state = DmabufState::new();

    let feedback = support.main_device.and_then(|device| {
        DmabufFeedbackBuilder::new(device.get(), support.formats.iter().copied())
            .build()
            .inspect_err(|error| {
                warn!(%error, "could not build dmabuf feedback; falling back to version 3");
            })
            .ok()
    });

    match feedback {
        Some(feedback) => {
            let global =
                state.create_global_with_default_feedback::<CompositorState>(display, &feedback);
            (state, global, Some(feedback))
        }
        None => {
            let global =
                state.create_global::<CompositorState>(display, support.formats.iter().copied());
            (state, global, None)
        }
    }
}

/// Reads one of a toplevel's role attributes.
///
/// Title and app id are not part of the pending configure state a client can be
/// told about; they are role attributes the client sets and the compositor
/// reads. `XdgToplevelSurfaceData` is a `Mutex`, and a poisoned one means a
/// panic already happened elsewhere, in which case the attribute is reported as
/// absent rather than propagating the panic through the dispatch loop.
pub(super) fn toplevel_attribute<T>(
    surface: &ToplevelSurface,
    read: impl FnOnce(&XdgToplevelSurfaceRoleAttributes) -> T,
) -> Option<T> {
    with_states(surface.wl_surface(), |states| {
        let attributes = states.data_map.get::<XdgToplevelSurfaceData>()?;
        let guard = attributes.lock().ok()?;
        Some(read(&guard))
    })
}

/// Converts a pixel size to smithay's logical coordinate space.
///
/// The two are the same at scale one, which is the only scale Phase 2 uses;
/// Phase 8 is what makes the distinction real.
fn logical_size(size: PixelSize) -> Size<i32, Logical> {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a size beyond two billion pixels is not a mode any hardware or protocol carries"
    )]
    Size::new(size.width as i32, size.height as i32)
}
