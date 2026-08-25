//! Adapted from the global and output fragments in WayVR (https://github.com/wayvr-org/wayvr),
//! backend/wayvr/comp.rs and backend/wayvr/mod.rs, at commit
//! 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! This module owns the Smithay globals and the compositor-thread state that
//! serves them. It also applies commands received from the main thread.
//!
//! Output management, process tracking, and frame pacing add methods to
//! [`CompositorState`] in [`crate::state::outputs`],
//! [`crate::state::processes`], and [`crate::state::pacing`].

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

/// The default seat exists before callers create additional seats.
/// Additional seats are created through [`Command::CreateSeat`].
pub const DEFAULT_SEAT: SeatId = match SeatId::new(1) {
    Some(seat) => seat,
    None => unreachable!(),
};

/// The default output displays clients without an explicit output assignment.
/// It must remain available because adopted clients and clients without an assignment
/// use it. Additional outputs are created through [`Command::CreateOutput`].
pub const DEFAULT_OUTPUT: OutputId = match OutputId::new(1) {
    Some(output) => output,
    None => unreachable!(),
};

/// The name that clients receive through `wl_seat.name`.
const SEAT_NAME: &str = "lunette";

/// The default virtual output mode and the buffer formats that lunette advertises.
#[derive(Debug)]
pub struct CompositorConfig {
    pub output: OutputMode,
    pub dmabuf: DmabufSupport,
    /// How the host desktop's clipboard is reached. When absent, selections stay
    /// inside lunette, as in a session with no host Wayland socket.
    pub host_selection: Option<Box<dyn HostSelectionSource>>,
    /// The display name spawned clients receive. It is absent when no socket is
    /// bound, which happens in a test: a spawned client is then told nothing
    /// about where to connect, because there is nowhere to connect.
    pub display: Option<DisplayName>,
    /// Where to find xwayland-satellite. When absent, X11 clients are not
    /// served, and the rest of the session runs normally.
    pub satellite: Option<XwaylandSatellite>,
    /// The desktop's own keyboard layout, which a seat that names none
    /// inherits. The binary reads it from the environment; nothing else in this
    /// crate does.
    pub keymap_defaults: KeymapDefaults,
}

impl Default for CompositorConfig {
    fn default() -> Self {
        Self {
            output: OutputMode {
                // Kept from WayVR's `WAYVR_SCREEN_RES`. A size that suits a
                // panel read at arm's length rather than a monitor viewed from
                // across a desk.
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

/// The render-node and pixel formats used to advertise `zwp_linux_dmabuf_v1`.
/// An absent render node prevents version 4 feedback, so clients use shared memory
/// when no import-capable graphics device is available.
#[derive(Clone, Debug, Default)]
pub struct DmabufSupport {
    /// The DRM render node the formats belong to. Version 4 feedback cannot be
    /// built without it: `DmabufFeedbackBuilder::new` takes the device
    /// unconditionally.
    pub main_device: Option<RenderNode>,
    pub formats: Vec<Format>,
}

/// A DRM render node represented by its device number.
/// The newtype prevents callers from passing a major or minor number separately.
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

/// The state owned by the compositor thread besides the display handle.
/// Smithay dispatches protocol requests into this type. It corresponds to WayVR's
/// `Application` type and is named by the `delegate_*!` macros.
pub(crate) struct CompositorState {
    pub(super) display: DisplayHandle,
    pub(super) config: CompositorConfig,
    /// What a spawned client is told about how to reach lunette, derived once
    /// from the display name rather than rebuilt per spawn.
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

    // These handles must remain alive because dropping one withdraws its global.
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
    /// Which process each connected client was attributed to.
    pub(super) clients: HashMap<ClientId, ProcessId>,
    /// Which output each spawned process's clients are shown. Only processes
    /// whose spawn named one appear; the rest fall back to the default output.
    pub(super) assignments: HashMap<ProcessId, OutputId>,
    /// The timer that reaps children and collects their output, present only
    /// while there is something to reap.
    pub(super) process_poll: Option<RegistrationToken>,
    pub(super) loop_handle: LoopHandle<'static, LoopData>,
    /// Polled together with the spawned processes, and dropped when this state
    /// is dropped. Dropping it stops the bridge's process group, which reaps
    /// xwayland-satellite and the `Xwayland` process it started.
    pub(super) satellite: Satellite,
    /// The frame callbacks each surface has accumulated and not yet answered.
    ///
    /// Keyed by [`SurfaceId`] rather than by protocol object, so that the
    /// pacing Lua requests per surface and the callbacks withheld under that
    /// pacing share one key.
    pub(super) frame_callbacks: HashMap<SurfaceId, Vec<WlCallback>>,
    /// How often each surface is answered.
    pub(super) pacing: FramePacer,
    /// The timer that wakes the loop to answer a withheld surface, paired with
    /// the moment it is armed for.
    ///
    /// A client waiting on a frame callback sends nothing, and the event loop
    /// runs without a timeout. Without this timer, a withheld callback waits
    /// for unrelated traffic to wake the compositor, which may not happen at
    /// all for an idle throttled window.
    pub(super) pacing_wakeup: Option<(RegistrationToken, Duration)>,
    /// How many keymap uploads to let through, and how many to fail after
    /// them. Always `(0, 0)` in production; see
    /// [`CompositorState::fail_keymap_uploads`].
    #[cfg(any(test, feature = "test-fakes"))]
    failing_uploads: std::cell::Cell<(usize, usize)>,

    /// Started from the instant the compositor begins running, because Wayland
    /// requires monotonic timestamps and a wall clock does not provide them: a
    /// clock stepped backwards makes a client observe time running in reverse,
    /// and NTP corrections do step clocks. Tests drive a virtual clock
    /// instead, so no test build reads this field. Both builds construct it so
    /// their state matches.
    #[cfg_attr(
        any(test, feature = "test-fakes"),
        expect(
            dead_code,
            reason = "the test clock is virtual and reads clock_offset alone"
        )
    )]
    pub(super) started: Instant,
    /// The compositor's clock under test, which advances only when a test
    /// advances it. Production builds have none, and take time from `started`;
    /// see [`CompositorState::advance_clock`].
    #[cfg(any(test, feature = "test-fakes"))]
    pub(super) clock_offset: Duration,

    events: EventSender,
    snapshots: SnapshotPublisher,
    signal: LoopSignal,
    dirty: bool,
}

impl CompositorState {
    /// Advertises every global and returns the state that serves them.
    ///
    /// This function creates nine globals directly. Smithay creates
    /// `wl_subcompositor` unconditionally alongside `wl_compositor`, so the
    /// display carries a tenth global that clients expect to find.
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
        // Version 6 sends `wl_surface.preferred_buffer_scale`, including to clients
        // that cannot bind a `wl_output`. Older compositor versions omit this state.
        let compositor = compositor::CompositorState::new_v6::<Self>(display);
        let xdg_shell = XdgShellState::new::<Self>(display);
        // Advertise only the two mandatory `wl_shm` formats until the importer
        // supports additional formats.
        let shm = ShmState::new::<Self>(display, Vec::new());
        let viewporter = ViewporterState::new::<Self>(display);
        // The fractional-scale manager complements the viewporter. The client uses
        // the integer buffer scale and viewport destination to produce the logical size.
        let fractional_scale = FractionalScaleManagerState::new::<Self>(display);
        // Content type is a hint. Report it to Lua so policy stays outside the
        // compositor mechanism.
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

        // Every connected client may access both selection protocols: this
        // compositor draws no privilege boundary between clients.
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

        // The X11 bridge is a child process, so start process polling when it runs.
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
    /// The match is exhaustive on purpose: a command added to the protocol
    /// fails to compile here until it gains a handler.
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

    /// Asks a toplevel to close.
    ///
    /// The close is a request rather than a kill, and the client may prompt the
    /// user or refuse. The window disappears when the client destroys the
    /// toplevel, not when lunette sends the request.
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

        // Clients read the states and size from the same configure event.
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

    /// Marks the snapshot stale so the next tick republishes it.
    pub(super) fn touch(&mut self) {
        self.dirty = true;
    }

    /// Lets the importer release buffers that clients no longer hold.
    ///
    /// Called once per dispatch, because only a dispatch can make a buffer
    /// collectable. The last strong reference to a client's dmabuf is the
    /// `wl_buffer` this side retains, and dispatch drops it when the client
    /// destroys the buffer or when the compositor forgets the surface. Sweeping
    /// at any other point pins the images of a client that has disconnected or
    /// fallen silent, since neither performs another dispatch.
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
}

#[cfg(any(test, feature = "test-fakes"))]
impl CompositorState {
    /// What a seat's focused client last asked its cursor to look like.
    ///
    /// Exists for test inspection only; nothing in the compositor renders a
    /// cursor. Smithay's own cursor-image handler ignores its seat argument,
    /// and the tests using this accessor check that per-seat cursor state stays
    /// correct despite that.
    pub(crate) fn cursor_image(&self, seat: SeatId) -> Option<CursorImageStatus> {
        self.seats
            .get(seat)
            .map(|entry| crate::seat::cursor_image(entry.seat()))
    }

    /// Lets the next `skip` keymap uploads through and fails the following
    /// `count`.
    ///
    /// A real upload fails only on a layout that does not compile, and the
    /// generator refuses to produce one, so this seam is the only way to
    /// exercise the restore path. `skip` selects which upload fails: failing
    /// the first upload would leave no temporary layout loaded to restore.
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

/// The dependencies required to construct [`CompositorState`].
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

/// Per-client state used by protocol dispatch and output visibility checks.
/// Smithay hands this data to its visibility filter along with the client, so
/// the output assignment lives here rather than in compositor state keyed by
/// client id.
#[derive(Default)]
pub struct ClientState {
    pub(crate) compositor: CompositorClientState,
    /// Set from the disconnect callback, which Smithay may call from a
    /// different thread than the one dispatching requests, hence the lock.
    disconnected: Arc<Mutex<bool>>,
    /// The one output this client is shown, or none for a client that was
    /// assigned no output. Such a client sees the default output instead.
    ///
    /// Locked for the same reason as `disconnected`: `ClientData` is
    /// `Send + Sync`, so nothing here may assume which thread calls it.
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
    /// [`CompositorState::attach_client`] calls this before dispatching any
    /// request from the client: `insert_client` does not dispatch, so the
    /// client has not yet read `wl_registry`, and the first global
    /// advertisement already reflects the assignment.
    pub(crate) fn assign(&self, output: Option<OutputId>) {
        if let Ok(mut held) = self.output.lock() {
            *held = output;
        }
    }

    /// Whether this client may see and bind an output's global.
    ///
    /// A client assigned an output sees exactly that output. A client assigned
    /// none sees the default output. Clients adopted from outside lunette are
    /// always in the second group: nothing spawned them, so nothing named an
    /// output for them, and a client with no `wl_output` at all cannot choose a
    /// scale.
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

/// Converts a snapshot toplevel state to its protocol representation.
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

/// Converts a protocol toplevel state to its snapshot representation.
/// Unknown non-exhaustive protocol states are omitted from snapshots.
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

/// Creates the `zwp_linux_dmabuf_v1` global.
/// Version 4 includes modifier feedback and requires a render node. Without one,
/// lunette creates the version 3 global.
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

/// Reads a role attribute while holding Smithay's role-data lock.
/// A poisoned lock yields no attribute so the dispatch loop does not propagate a
/// panic from another thread.
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
