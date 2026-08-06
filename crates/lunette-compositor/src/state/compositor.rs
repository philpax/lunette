//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs and backend/wayvr/mod.rs (the globals and output fragments), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The state every global is served from, and the commit path underneath it.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use smithay::{
    backend::{allocator::Format, input::ButtonState},
    desktop::{PopupKind, PopupManager, find_popup_root_surface, get_popup_toplevel_coords},
    input::{
        Seat, SeatState,
        pointer::{ButtonEvent, CursorImageStatus, MotionEvent, PointerHandle},
    },
    output::{Mode, Output, PhysicalProperties, Subpixel},
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
    utils::{Logical, Physical, Point, Rectangle, SerialCounter, Size, Transform},
    wayland::{
        compositor::{self, CompositorClientState, send_surface_state, with_states},
        dmabuf::{DmabufFeedback, DmabufFeedbackBuilder, DmabufGlobal, DmabufState},
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
    process::{
        DisplayEnvironment, ProcessInspector, ProcessRegistry, ProcessSpawner, Report, SpawnRequest,
    },
    protocol::{
        Command, Event, OutputId, OutputMode, OutputScale, OutputSnapshot, Pid, PixelPoint,
        PixelSize, PointerButton, ProcessId, ProcessOutcome, ProcessSignal, RefreshRate, SeatId,
        SinkId, SpawnRequest as SpawnCommand, SurfaceId, ToplevelState, ToplevelStates, WindowId,
    },
    surface::{BufferImporter, RetainedBuffers, SurfaceContent, SurfaceRegistry},
    thread::{EventSender, LoopData, SnapshotPublisher},
    window::{MouseState, Window, WindowManager},
};

/// The one seat Phase 2 has. Multi-seat is Phase 5, and the identifier is fixed
/// rather than allocated so nothing has to be rewritten when it stops being.
pub const DEFAULT_SEAT: SeatId = match SeatId::new(1) {
    Some(seat) => seat,
    None => unreachable!(),
};

/// The one output Phase 2 has. Outputs become configurable in Phase 8.
pub const DEFAULT_OUTPUT: OutputId = match OutputId::new(1) {
    Some(output) => output,
    None => unreachable!(),
};

/// The seat's name, which clients see on `wl_seat.name`.
const SEAT_NAME: &str = "lunette";

/// The output's name, which clients see on `wl_output.name`.
const OUTPUT_NAME: &str = "lunette-0";

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
#[derive(Clone, Debug)]
pub struct CompositorConfig {
    pub output: OutputMode,
    pub dmabuf: DmabufSupport,
    /// Which display lunette is. Absent when no socket was bound, which is the
    /// case in a test: a spawned client is then told nothing about where to
    /// connect, because there is nowhere to connect to.
    pub display: Option<DisplayName>,
    /// Where to find xwayland-satellite. Absent means X11 clients are not
    /// served, which is a session worth having.
    pub satellite: Option<XwaylandSatellite>,
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
            display: None,
            satellite: None,
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
    display: DisplayHandle,
    config: CompositorConfig,
    /// What a spawned client is told about how to reach lunette, derived once
    /// from the display name rather than rebuilt per spawn.
    environment: DisplayEnvironment,

    pub(super) compositor: compositor::CompositorState,
    pub(super) xdg_shell: XdgShellState,
    pub(super) shm: ShmState,
    pub(super) seat_state: SeatState<Self>,
    /// Held for its lifetime: dropping the seat withdraws the `wl_seat` global.
    #[expect(dead_code, reason = "held so the global stays advertised")]
    seat: Seat<Self>,
    pointer: PointerHandle<Self>,
    pub(super) dmabuf: DmabufState,
    pub(super) kde_decoration: KdeDecorationState,
    pub(super) popups: PopupManager,
    pub(super) output: Output,

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
    output_global: smithay::reexports::wayland_server::backend::GlobalId,

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
    /// The timer that reaps children and collects their output, present only
    /// while there is something to reap.
    process_poll: Option<RegistrationToken>,
    loop_handle: LoopHandle<'static, LoopData>,
    /// Held for its lifetime: dropping it asks the bridge's process group to
    /// stop, which is how xwayland-satellite and the `Xwayland` it started are
    /// reaped.
    #[expect(dead_code, reason = "held so the x11 bridge stops when lunette does")]
    satellite: Satellite,
    pub(super) frame_callbacks: HashMap<ObjectId, Vec<WlCallback>>,
    pub(super) cursor_image: CursorImageStatus,
    serials: SerialCounter,

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
            config,
            importer,
            spawner,
            inspector,
            events,
            snapshots,
            signal,
            loop_handle,
        } = parts;
        let compositor = compositor::CompositorState::new::<Self>(display);
        let xdg_shell = XdgShellState::new::<Self>(display);
        // An empty extra-format list, as WayVR passes at `mod.rs:185`, so only
        // `wl_shm`'s two mandatory formats are advertised. Anything further is
        // a format the importer would have to be taught.
        let shm = ShmState::new::<Self>(display, Vec::new());
        let viewporter = ViewporterState::new::<Self>(display);
        let xdg_decoration = XdgDecorationState::new::<Self>(display);
        let kde_decoration = KdeDecorationState::new::<Self>(
            display,
            smithay::reexports::wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration_manager::Mode::Server,
        );

        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(display, SEAT_NAME);
        // Pointer only. The keyboard, and the keymap it needs, are Phase 5.
        let pointer = seat.add_pointer();

        let output = Output::new(
            OUTPUT_NAME.to_owned(),
            PhysicalProperties {
                // A plausible physical size for the default mode. Clients
                // divide by it to guess a DPI, and a zero would be divided by.
                size: (530, 300).into(),
                subpixel: Subpixel::Unknown,
                make: "lunette".to_owned(),
                model: "virtual display".to_owned(),
            },
        );
        let output_global = output.create_global::<Self>(display);
        let mode = output_mode(&config.output);
        output.change_current_state(Some(mode), Some(Transform::Normal), None, None);
        output.set_preferred(mode);

        let (dmabuf, dmabuf_global, dmabuf_feedback) =
            create_dmabuf_global(display, &config.dmabuf);

        let mut spawner = spawner;
        let satellite = match config.display {
            Some(name) => Satellite::start(spawner.as_mut(), config.satellite.as_ref(), name),
            None => {
                debug!("no wayland socket was bound, so no x11 bridge is started");
                Satellite::default()
            }
        };

        Self {
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
            seat,
            pointer,
            dmabuf,
            kde_decoration,
            popups: PopupManager::default(),
            output,
            dmabuf_global,
            dmabuf_feedback,
            xdg_decoration,
            viewporter,
            output_global,
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
            process_poll: None,
            loop_handle,
            frame_callbacks: HashMap::new(),
            cursor_image: CursorImageStatus::default_named(),
            serials: SerialCounter::new(),
            started: Instant::now(),
            events,
            snapshots,
            signal,
            dirty: true,
        }
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
            Command::Scroll { .. }
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
        for report in self.processes.poll(self.inspector.as_ref()) {
            match report {
                Report::Output { id, stream, bytes } => self.report(Event::ProcessOutput {
                    process: id,
                    stream,
                    bytes,
                }),
                Report::Exited { id, outcome } => {
                    self.touch();
                    self.report(Event::ProcessExited {
                        process: id,
                        outcome,
                    });
                }
            }
        }

        if self.processes.is_empty() {
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
        let bounds = self.output_logical_size();
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

    /// Moves a seat's pointer onto a sink, or withdraws it.
    ///
    /// Phase 2 delivers to the window's own surface at the position given.
    /// Descending into subsurfaces and popups needs the hit test, which is
    /// Phase 5; until then a click lands on the toplevel, which is what the
    /// milestone gate asks for.
    fn move_pointer(&mut self, seat: SeatId, target: Option<(SinkId, PixelPoint)>) {
        if !self.check_seat(seat) {
            return;
        }

        // The focus origin is where the surface sits in the coordinate space
        // `location` is measured in. Delivering straight to the toplevel puts
        // it at the origin, so the surface-local position is the position given.
        let focus = target.and_then(|(sink, _)| {
            let surface = self.windows.by_sink(sink)?.toplevel().wl_surface().clone();
            Some((surface, Point::from((0.0, 0.0))))
        });

        let hovered = target.and_then(|(sink, position)| {
            Some(MouseState {
                hovered: self.windows.by_sink(sink)?.id(),
                position,
            })
        });
        self.windows.set_mouse(hovered);

        let location = target.map_or_else(
            || Point::from((-1.0, -1.0)),
            |(_, position)| Point::from((position.x, position.y)),
        );

        let event = MotionEvent {
            location,
            serial: self.serials.next_serial(),
            time: self.millis(),
        };

        let pointer = self.pointer.clone();
        pointer.motion(self, focus, &event);
        pointer.frame(self);
    }

    /// Presses or releases a pointer button over a sink.
    fn press_button(&mut self, seat: SeatId, sink: SinkId, button: PointerButton, pressed: bool) {
        if !self.check_seat(seat) {
            return;
        }
        let Some(window) = self.windows.by_sink(sink).map(Window::id) else {
            debug!(%sink, "a button was pressed over a sink that is already gone");
            return;
        };

        // A button goes to whatever the pointer is over, which the protocol
        // requires and a caller can get wrong by naming a sink it never moved
        // the pointer onto.
        match self.windows.mouse() {
            Some(mouse) if mouse.hovered == window => {}
            _ => {
                warn!(
                    %sink,
                    "a button was pressed over a sink the pointer is not on; move it first"
                );
                return;
            }
        }

        let event = ButtonEvent {
            serial: self.serials.next_serial(),
            time: self.millis(),
            button: evdev_button(button),
            state: if pressed {
                ButtonState::Pressed
            } else {
                ButtonState::Released
            },
        };

        let pointer = self.pointer.clone();
        pointer.button(self, &event);
        pointer.frame(self);
    }

    /// Whether the seat named is the one that exists.
    fn check_seat(&self, seat: SeatId) -> bool {
        if seat == DEFAULT_SEAT {
            return true;
        }
        warn!(%seat, "input was addressed to a seat that does not exist");
        false
    }

    /// Republishes the snapshot if anything changed since the last one.
    pub(crate) fn publish_if_dirty(&mut self) {
        if !self.dirty {
            return;
        }
        self.dirty = false;

        let windows = self.windows.mapped().map(Window::snapshot).collect();

        self.snapshots.publish(
            windows,
            self.processes.snapshot(),
            vec![OutputSnapshot {
                output: DEFAULT_OUTPUT,
                mode: self.config.output,
            }],
        );
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
    fn millis(&self) -> u32 {
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

    pub(super) fn report(&self, event: Event) {
        if self.events.send(event).is_err() {
            debug!("the main thread is gone; dropping an event");
        }
    }

    /// Tells a newly created surface which output it is on and at what scale.
    ///
    /// WayVR also calls `with_fractional_scale` here (`comp.rs:145`). That is
    /// not ported: see this module's documentation.
    pub(super) fn send_initial_surface_state(&self, surface: &WlSurface) {
        self.output.enter(surface);

        with_states(surface, |states| {
            send_surface_state(surface, states, 1, Transform::Normal);
        });
    }

    pub(super) fn popups_commit(&mut self, surface: &WlSurface) {
        self.popups.commit(surface);

        let Some(PopupKind::Xdg(popup)) = self.popups.find_popup(surface) else {
            return;
        };
        if popup.is_initial_configure_sent() {
            return;
        }

        with_states(surface, |states| {
            send_surface_state(surface, states, 1, Transform::Normal);
        });

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
                || self.output_logical_size(),
                |content| logical_size(content.logical_size()),
            );

        let mut target = Rectangle::from_size(root_size);
        target.loc -= get_popup_toplevel_coords(&kind);

        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }

    pub(super) fn output_logical_size(&self) -> Size<i32, Logical> {
        logical_size(self.config.output.size)
    }
}

/// Everything [`CompositorState::new`] needs, bundled so the constructor takes
/// one argument rather than nine.
pub(crate) struct StateParts<'a> {
    pub(crate) display: &'a DisplayHandle,
    pub(crate) config: CompositorConfig,
    pub(crate) importer: Box<dyn BufferImporter>,
    pub(crate) spawner: Box<dyn ProcessSpawner>,
    pub(crate) inspector: Box<dyn ProcessInspector>,
    pub(crate) events: EventSender,
    pub(crate) snapshots: SnapshotPublisher,
    pub(crate) signal: LoopSignal,
    pub(crate) loop_handle: LoopHandle<'static, LoopData>,
}

/// What lunette attaches to each connected client.
#[derive(Default)]
pub struct ClientState {
    pub(crate) compositor: CompositorClientState,
    /// Set from the disconnect callback, which smithay may call from a
    /// different thread than the one dispatching, hence the lock.
    disconnected: Arc<Mutex<bool>>,
}

impl ClientState {
    /// Whether the client has gone away.
    #[must_use]
    pub fn disconnected(&self) -> bool {
        self.disconnected
            .lock()
            .map_or(true, |disconnected| *disconnected)
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

/// Maps a pointer button onto the evdev code `wl_pointer.button` carries.
///
/// The side and extra buttons are what libinput reports for back and forward,
/// which is what applications listen for; `BTN_BACK` and `BTN_FORWARD` exist
/// but are sent by almost nothing.
pub(super) const fn evdev_button(button: PointerButton) -> u32 {
    match button {
        PointerButton::Left => 0x110,
        PointerButton::Right => 0x111,
        PointerButton::Middle => 0x112,
        PointerButton::Back => 0x113,
        PointerButton::Forward => 0x114,
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

fn output_mode(mode: &OutputMode) -> Mode {
    Mode {
        size: physical_size(mode.size),
        #[expect(
            clippy::cast_possible_wrap,
            reason = "a refresh rate in millihertz is far below the sign bit, and the protocol \
                      carries it as a signed integer"
        )]
        refresh: mode.refresh.millihertz() as i32,
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

/// Converts a pixel size to smithay's physical coordinate space, which is what
/// an output mode is measured in.
fn physical_size(size: PixelSize) -> Size<i32, Physical> {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a size beyond two billion pixels is not a mode any hardware or protocol carries"
    )]
    Size::new(size.width as i32, size.height as i32)
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
