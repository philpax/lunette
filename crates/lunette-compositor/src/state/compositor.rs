//! Adapted from the globals and output fragments in WayVR's `backend/wayvr/comp.rs`
//! and `backend/wayvr/mod.rs` (https://github.com/wayvr-org/wayvr), at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Owns the Wayland globals and the state used to dispatch their requests.

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
        calloop::{LoopHandle, LoopSignal, RegistrationToken},
        wayland_protocols::xdg::shell::server::xdg_toplevel,
        wayland_server::{
            DisplayHandle,
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::{wl_buffer::WlBuffer, wl_callback::WlCallback, wl_surface::WlSurface},
        },
    },
    utils::Rectangle,
    wayland::{
        compositor::{self, CompositorClientState, with_states},
        content_type::ContentTypeState,
        dmabuf::{DmabufFeedback, DmabufFeedbackBuilder, DmabufGlobal, DmabufState},
        fractional_scale::FractionalScaleManagerState,
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
use tracing::{debug, warn};

use crate::{
    client::{DisplayName, Satellite, XwaylandSatellite},
    output::OutputRegistry,
    pacing::FramePacer,
    process::{DisplayEnvironment, ProcessInspector, ProcessRegistry, ProcessSpawner},
    protocol::{
        Command, Event, KeyboardConfig, KeymapDefaults, OutputId, OutputMode, OutputScale,
        PixelSize, ProcessId, RefreshRate, SeatId, SurfaceId, ToplevelState, ToplevelStates,
        WindowId,
    },
    seat::SeatRegistry,
    selection::{HostEvents, HostSelectionSource, SelectionBridge},
    state::outputs::logical_size,
    surface::{BufferImporter, RetainedBuffers, SurfaceContent, SurfaceRegistry},
    thread::{EventSender, LoopData, SnapshotParts, SnapshotPublisher},
    window::{Window, WindowManager},
};

/// The seat used when a command does not name a specific seat.
///
/// Further seats use identifiers supplied through [`Command::CreateSeat`].
pub const DEFAULT_SEAT: SeatId = match SeatId::new(1) {
    Some(seat) => seat,
    None => unreachable!(),
};

/// The output used when a client has no output assignment.
///
/// Further outputs use identifiers supplied through [`Command::CreateOutput`].
pub const DEFAULT_OUTPUT: OutputId = match OutputId::new(1) {
    Some(output) => output,
    None => unreachable!(),
};

/// The default seat's name, which clients see on `wl_seat.name`.
const SEAT_NAME: &str = "lunette";

/// Configuration for the virtual monitor, buffer support, host selection, X11
/// bridge, and default keymap.
///
/// The output size is configurable, so this value provides defaults rather than
/// a fixed constant.
#[derive(Debug)]
pub struct CompositorConfig {
    pub output: OutputMode,
    pub dmabuf: DmabufSupport,
    /// How the host desktop's clipboard is reached. Absent keeps selections
    /// inside lunette.
    pub host_selection: Option<Box<dyn HostSelectionSource>>,
    /// The display lunette uses. Absent when no socket was bound.
    pub display: Option<DisplayName>,
    /// Where to find xwayland-satellite. Absent disables X11 clients.
    pub satellite: Option<XwaylandSatellite>,
    /// The desktop's own keyboard layout, which a seat that names none inherits.
    /// The binary reads it from the environment; nothing in this crate does.
    pub keymap_defaults: KeymapDefaults,
}

impl Default for CompositorConfig {
    fn default() -> Self {
        Self {
            output: OutputMode {
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
    /// The DRM render node for these formats. Version 4 feedback requires it.
    pub main_device: Option<RenderNode>,
    pub formats: Vec<Format>,
}

/// A DRM render node, as the `st_rdev` of its device file.
///
/// Wrapping `libc::dev_t` prevents confusing a device number with its major or
/// minor component.
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

/// State owned by the compositor thread for dispatching Wayland requests.
///
/// Smithay invokes the delegate implementations for those requests.
pub(crate) struct CompositorState {
    pub(super) display: DisplayHandle,
    pub(super) config: CompositorConfig,
    /// Environment values passed to every spawned client.
    pub(super) environment: DisplayEnvironment,

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

    #[expect(dead_code, reason = "held so the global stays advertised")]
    dmabuf_global: DmabufGlobal,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    dmabuf_feedback: Option<DmabufFeedback>,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    xdg_decoration: XdgDecorationState,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    viewporter: ViewporterState,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    content_type: ContentTypeState,
    #[expect(dead_code, reason = "held so the global stays advertised")]
    fractional_scale: FractionalScaleManagerState,

    pub(super) importer: Box<dyn BufferImporter>,
    pub(super) spawner: Box<dyn ProcessSpawner>,
    pub(super) inspector: Box<dyn ProcessInspector>,
    pub(super) surfaces: SurfaceRegistry,
    pub(super) buffers: RetainedBuffers<WlBuffer>,
    pub(super) contents: HashMap<SurfaceId, SurfaceContent>,
    pub(super) windows: WindowManager,
    pub(super) processes: ProcessRegistry,
    /// The process attributed to each connected client.
    pub(super) clients: HashMap<ClientId, ProcessId>,
    pub(super) assignments: HashMap<ProcessId, OutputId>,
    /// The timer that reaps children and collects their output, present only
    /// while there is something to reap.
    pub(super) process_poll: Option<RegistrationToken>,
    pub(super) loop_handle: LoopHandle<'static, LoopData>,
    /// Polled with the spawned processes, and dropped with the state: dropping
    /// it asks the bridge's process group to stop, which is how
    /// xwayland-satellite and the `Xwayland` it started are reaped.
    pub(super) satellite: Satellite,
    /// The unanswered callbacks accumulated by each surface.
    ///
    /// The key matches the surface identifier used by frame-pacing requests.
    pub(super) frame_callbacks: HashMap<SurfaceId, Vec<WlCallback>>,
    pub(super) pacing: FramePacer,
    /// The timer that wakes the loop to answer a withheld surface, with its
    /// scheduled deadline. Without it, an idle client waiting on a frame callback
    /// cannot wake the event loop to receive its answer.
    pub(super) pacing_wakeup: Option<(RegistrationToken, Duration)>,
    /// How many keymap uploads to let through, and how many to fail after
    /// them. Always `(0, 0)` in production; see
    /// [`CompositorState::fail_keymap_uploads`].
    #[cfg(any(test, feature = "test-fakes"))]
    failing_uploads: std::cell::Cell<(usize, usize)>,

    /// The baseline for the protocol's monotonic millisecond timestamps.
    ///
    /// The wall clock can move backwards, so production timestamps use elapsed
    /// time from this instant. Tests use [`CompositorState::clock_offset`].
    #[cfg_attr(
        any(test, feature = "test-fakes"),
        expect(
            dead_code,
            reason = "the test clock is virtual and reads clock_offset alone"
        )
    )]
    pub(super) started: Instant,
    /// The virtual compositor clock used by tests. Production uses `started`.
    #[cfg(any(test, feature = "test-fakes"))]
    pub(super) clock_offset: Duration,

    events: EventSender,
    snapshots: SnapshotPublisher,
    signal: LoopSignal,
    dirty: bool,
}

impl CompositorState {
    /// Advertises the supported globals and returns their compositor state.
    ///
    /// Smithay also advertises `wl_subcompositor` when creating the compositor
    /// state, so this constructor cannot omit it.
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
        // Version 6 carries `wl_surface.preferred_buffer_scale`, which lets a
        // client learn its output's whole-number scale without binding a
        // `wl_output`. Lunette may deny that binding.
        let compositor = compositor::CompositorState::new_v6::<Self>(display);
        let xdg_shell = XdgShellState::new::<Self>(display);
        // Advertise only `wl_shm`'s two mandatory formats. Supporting another
        // format requires corresponding importer support.
        let shm = ShmState::new::<Self>(display, Vec::new());
        let viewporter = ViewporterState::new::<Self>(display);
        // Fractional scale support requires the viewporter so clients can use
        // an integer buffer scale with a corrected logical destination.
        let fractional_scale = FractionalScaleManagerState::new::<Self>(display);
        // Report content type without applying throttling policy in the compositor.
        let content_type = ContentTypeState::new::<Self>(display);
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

        // Every client may read and write both selections. The compositor hosts
        // the user's applications and does not impose a selection privilege
        // boundary.
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
            content_type,
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
            pacing: FramePacer::default(),
            pacing_wakeup: None,
            #[cfg(any(test, feature = "test-fakes"))]
            failing_uploads: std::cell::Cell::new((0, 0)),
            started: Instant::now(),
            #[cfg(any(test, feature = "test-fakes"))]
            clock_offset: Duration::ZERO,
            events,
            snapshots,
            signal,
            dirty: true,
        };

        // Poll the bridge as soon as it starts so it can be reaped independently
        // of later application spawns.
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
    /// Keep this match exhaustive so adding a command requires a handler here.
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
            Command::SetFramePacing { surface, pacing } => {
                self.set_frame_pacing(surface, pacing);
            }
        }
    }

    /// Sends a close request without killing the client or removing the window.
    ///
    /// The client may refuse the request; the window disappears only after the
    /// client destroys the toplevel.
    fn close_window(&mut self, window: WindowId) {
        let Some(tracked) = self.windows.get(window) else {
            debug!(%window, "a close was asked for a window that is already gone");
            return;
        };
        tracked.toplevel().send_close();
    }

    /// Queues a toplevel size and state change.
    ///
    /// The snapshot keeps reporting the committed size until the client commits
    /// the requested change.
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

        // Set the pending states before requesting the size so both are sent in
        // the same configure.
        tracked.toplevel().with_pending_state(|pending| {
            for state in states {
                pending.states.set(protocol_state(*state));
            }
        });
        tracked.request_size(size.map_or(bounds, logical_size), bounds);
    }

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

    pub(super) fn touch(&mut self) {
        self.dirty = true;
    }

    /// Sweeps imported images after dispatch may have dropped a client's `wl_buffer`
    /// reference.
    ///
    /// Sweeping only when a new import arrives retains images from clients that
    /// have disconnected or stopped sending requests.
    pub(crate) fn sweep_imports(&mut self) {
        self.importer.sweep();
    }

    pub(super) fn report(&self, event: Event) {
        if self.events.send(event).is_err() {
            debug!("the main thread is gone; dropping an event");
        }
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

    /// Applies the positioner's unconstrained geometry relative to the root toplevel.
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
}

#[cfg(any(test, feature = "test-fakes"))]
impl CompositorState {
    /// Returns the per-seat cursor state recorded by `SeatHandler::cursor_image`.
    ///
    /// The compositor does not render cursors, so tests read this state directly.
    pub(crate) fn cursor_image(&self, seat: SeatId) -> Option<CursorImageStatus> {
        self.seats
            .get(seat)
            .map(|entry| crate::seat::cursor_image(entry.seat()))
    }

    /// Injects failures after `skip` successful keymap uploads for restoration tests.
    ///
    /// The normal upload path rejects only invalid layouts, so tests cannot provoke
    /// a failure at the point needed to exercise restoration of an existing keymap.
    pub(crate) fn fail_keymap_uploads(&self, skip: usize, count: usize) {
        self.failing_uploads.set((skip, count));
    }

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

pub(crate) struct StateParts<'a> {
    pub(crate) display: &'a DisplayHandle,
    pub(crate) config: CompositorConfig,
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
/// Stores the client output assignment because `GlobalDispatch::can_view`
/// receives client data without compositor state.
#[derive(Default)]
pub struct ClientState {
    pub(crate) compositor: CompositorClientState,
    /// Set by the disconnect callback, which may run on another thread.
    disconnected: Arc<Mutex<bool>>,
    /// The output this client is shown. `None` means the default output.
    ///
    /// `ClientData` is `Send + Sync`, so access is synchronized for callbacks
    /// that may run outside the dispatching thread.
    output: Mutex<Option<OutputId>>,
}

impl ClientState {
    #[must_use]
    pub fn disconnected(&self) -> bool {
        self.disconnected
            .lock()
            .map_or(true, |disconnected| *disconnected)
    }

    #[must_use]
    pub(crate) fn output(&self) -> Option<OutputId> {
        self.output.lock().ok().and_then(|output| *output)
    }

    /// Records the assignment before the client's first registry advertisement;
    /// registry dispatch can then filter the initial globals by that assignment.
    pub(crate) fn assign(&self, output: Option<OutputId>) {
        if let Ok(mut held) = self.output.lock() {
            *held = output;
        }
    }

    /// Whether this client may see and bind an output's global.
    ///
    /// An assigned client sees exactly its assigned output. An unassigned client
    /// sees the default output.
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

/// Creates the `zwp_linux_dmabuf_v1` global with version 4 feedback when the
/// render node and format support can build it; otherwise uses version 3.
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

/// Reads a role attribute that the client sets, such as its title or app id.
///
/// A poisoned role-attribute mutex yields `None` instead of propagating an
/// earlier panic through the dispatch loop.
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
