//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs and backend/wayvr/mod.rs (the globals and output fragments), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The smithay state and the protocol handlers hung off it.
//!
//! [`CompositorState`] is what WayVR calls `Application` (`comp.rs:68-94`): the
//! one struct every `delegate_*!` macro dispatches into. It owns the delegate
//! state for each global lunette advertises, the surface bookkeeping from
//! [`crate::surface`], and the two ends of the transports in [`crate::thread`]
//! that report outwards.
//!
//! # What is deliberately not here
//!
//! - **The single-pixel-buffer path.** WayVR handles `BufferType::SinglePixel`
//!   at `comp.rs:285-304` and delegates the global at `:693`, but never
//!   constructs `SinglePixelBufferState`, so no client can ever bind it and the
//!   branch is unreachable. Porting dead code carries its bugs forward.
//! - **`wp_fractional_scale_v1`.** WayVR calls `with_fractional_scale` at
//!   `comp.rs:125` and `:145`. Those calls write to surface user data no client
//!   can read, because `FractionalScaleManagerState` is never constructed
//!   there either, and the write is thread-affine besides
//!   (`smithay-0.7.0/src/wayland/fractional_scale/mod.rs:253-263` is a
//!   `get_or_insert`, which records the calling thread). Phase 8 implements
//!   fractional scale properly and owns the question.
//! - **Clipboard, selection, and the keyboard.** `wl_data_device`,
//!   `zwp_primary_selection`, both data-control protocols, and
//!   `zwp_relative_pointer` are Phase 5. The seat here has a pointer and no
//!   keyboard.
//! - **Popup input routing.** Popup *tracking* is not separable — `PopupManager`
//!   is committed to on every surface commit — so it is here. Routing input into
//!   a popup needs the hit test, which is Phase 5.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Instant,
};

use smithay::{
    backend::{
        allocator::{Format, dmabuf::Dmabuf},
        input::ButtonState,
        renderer::{BufferType, buffer_type},
    },
    delegate_compositor, delegate_dmabuf, delegate_kde_decoration, delegate_output, delegate_seat,
    delegate_shm, delegate_viewporter, delegate_xdg_decoration, delegate_xdg_shell,
    desktop::{
        PopupKeyboardGrab, PopupKind, PopupManager, PopupPointerGrab, PopupUngrabStrategy,
        find_popup_root_surface, get_popup_toplevel_coords,
    },
    input::{
        Seat, SeatHandler, SeatState,
        pointer::{ButtonEvent, CursorImageStatus, Focus, MotionEvent, PointerHandle},
    },
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::{
        calloop::LoopSignal,
        wayland_protocols::xdg::{
            decoration::zv1::server::zxdg_toplevel_decoration_v1, shell::server::xdg_toplevel,
        },
        wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration,
        wayland_server::{
            Client, DisplayHandle, Resource, WEnum,
            backend::{ClientData, ClientId, DisconnectReason, ObjectId},
            protocol::{
                wl_buffer::WlBuffer, wl_callback::WlCallback, wl_seat, wl_surface::WlSurface,
            },
        },
    },
    utils::{Point, Rectangle, Serial, SerialCounter, Size, Transform},
    wayland::{
        buffer::BufferHandler,
        compositor::{
            self, BufferAssignment, CompositorClientState, SurfaceAttributes, send_surface_state,
            with_states,
        },
        dmabuf::{
            DmabufFeedback, DmabufFeedbackBuilder, DmabufGlobal, DmabufHandler, DmabufState,
            ImportNotifier, get_dmabuf,
        },
        output::OutputHandler,
        shell::{
            kde::decoration::{KdeDecorationHandler, KdeDecorationState},
            xdg::{
                PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
                XdgToplevelSurfaceData, XdgToplevelSurfaceRoleAttributes,
                decoration::{XdgDecorationHandler, XdgDecorationState},
            },
        },
        shm::{ShmHandler, ShmState, with_buffer_contents},
        viewporter::ViewporterState,
    },
};
use tracing::{debug, info, warn};

use crate::{
    protocol::{
        Command, Event, OutputId, OutputMode, OutputScale, OutputSnapshot, PixelPoint, PixelSize,
        PointerButton, ProcessId, RefreshRate, SeatId, SinkId, SurfaceId, ToplevelState,
        ToplevelStates, WindowId, WindowSnapshot,
    },
    surface::{
        BufferImporter, BufferScale, BufferTransform, RetainedBuffers, ShmFormat, ShmLayout,
        SurfaceContent, SurfaceRegistry,
    },
    thread::{EventSender, SnapshotPublisher},
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

/// How lunette configures its virtual monitor and its buffer support.
///
/// WayVR fixes the resolution at `mod.rs:172` as `WAYVR_SCREEN_RES`. Lunette's
/// outputs are configurable from Phase 8, so this is a value with a default
/// rather than a constant.
#[derive(Clone, Debug)]
pub struct CompositorConfig {
    pub output: OutputMode,
    pub dmabuf: DmabufSupport,
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
    config: CompositorConfig,

    compositor: compositor::CompositorState,
    xdg_shell: XdgShellState,
    shm: ShmState,
    seat_state: SeatState<Self>,
    /// Held for its lifetime: dropping the seat withdraws the `wl_seat` global.
    #[expect(dead_code, reason = "held so the global stays advertised")]
    seat: Seat<Self>,
    pointer: PointerHandle<Self>,
    dmabuf: DmabufState,
    kde_decoration: KdeDecorationState,
    popups: PopupManager,
    output: Output,

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

    importer: Box<dyn BufferImporter>,
    surfaces: SurfaceRegistry,
    buffers: RetainedBuffers<WlBuffer>,
    contents: HashMap<SurfaceId, SurfaceContent>,
    toplevels: Toplevels,
    frame_callbacks: HashMap<ObjectId, Vec<WlCallback>>,
    cursor_image: CursorImageStatus,
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
    pub(crate) fn new(
        display: &DisplayHandle,
        config: CompositorConfig,
        importer: Box<dyn BufferImporter>,
        events: EventSender,
        snapshots: SnapshotPublisher,
        signal: LoopSignal,
    ) -> Self {
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

        Self {
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
            surfaces: SurfaceRegistry::default(),
            buffers: RetainedBuffers::default(),
            contents: HashMap::new(),
            toplevels: Toplevels::default(),
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
            Command::Spawn(_)
            | Command::SignalProcess { .. }
            | Command::Scroll { .. }
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

    /// Asks a toplevel to close.
    ///
    /// A request, not a kill: the client may prompt the user, or refuse. The
    /// window disappears when the client destroys the toplevel, not here.
    fn close_window(&mut self, window: WindowId) {
        let Some(toplevel) = self.toplevels.find(window) else {
            debug!(%window, "a close was asked for a window that is already gone");
            return;
        };
        toplevel.toplevel.send_close();
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
        let Some(toplevel) = self.toplevels.find(window) else {
            debug!(%window, "a configure was asked for a window that is already gone");
            return;
        };

        let requested = size.map(logical_size);
        toplevel.toplevel.with_pending_state(|pending| {
            pending.bounds = Some(bounds);
            if let Some(requested) = requested {
                pending.size = Some(requested);
            }
            for state in states {
                pending.states.set(protocol_state(*state));
            }
        });
        toplevel.toplevel.send_configure();
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
            let surface = self
                .toplevels
                .find_sink(sink)?
                .toplevel
                .wl_surface()
                .clone();
            Some((surface, Point::from((0.0, 0.0))))
        });
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
        if self.toplevels.find_sink(sink).is_none() {
            debug!(%sink, "a button was pressed over a sink that is already gone");
            return;
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

        let windows = self
            .toplevels
            .iter()
            .filter(|toplevel| toplevel.mapped)
            .map(|toplevel| toplevel.snapshot(self.config.output.size))
            .collect();

        self.snapshots.publish(
            windows,
            Vec::new(),
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
    fn touch(&mut self) {
        self.dirty = true;
    }

    fn report(&self, event: Event) {
        if self.events.send(event).is_err() {
            debug!("the main thread is gone; dropping an event");
        }
    }

    /// Tells a newly created surface which output it is on and at what scale.
    ///
    /// WayVR also calls `with_fractional_scale` here (`comp.rs:145`). That is
    /// not ported: see this module's documentation.
    fn send_initial_surface_state(&self, surface: &WlSurface) {
        self.output.enter(surface);

        with_states(surface, |states| {
            send_surface_state(surface, states, 1, Transform::Normal);
        });
    }

    fn popups_commit(&mut self, surface: &WlSurface) {
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
    fn constrain_popup(&self, popup: &PopupSurface) {
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

    fn output_logical_size(&self) -> Size<i32, smithay::utils::Logical> {
        logical_size(self.config.output.size)
    }

    /// Applies one client commit.
    ///
    /// The state is gathered under the surface's lock and acted on outside it,
    /// so nothing that can block — an import, a send into a bounded channel —
    /// happens while the lock is held.
    fn apply_commit(&mut self, surface: &WlSurface) {
        let committed = with_states(surface, |states| {
            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attributes = guard.current();
            Committed {
                buffer: attributes.buffer.take(),
                transform: attributes.buffer_transform,
                scale: attributes.buffer_scale,
                callbacks: std::mem::take(&mut attributes.frame_callbacks),
            }
        });

        let id = self.surfaces.id_for(surface);

        if !committed.callbacks.is_empty() {
            self.frame_callbacks
                .entry(surface.id())
                .or_default()
                .extend(committed.callbacks);
        }

        match committed.buffer {
            Some(BufferAssignment::NewBuffer(buffer)) => {
                self.attach_buffer(id, &buffer, committed.transform, committed.scale);
            }
            Some(BufferAssignment::Removed) => {
                self.buffers.forget(id);
                self.contents.remove(&id);
                self.touch();
            }
            None => {}
        }

        self.remember_committed_size(surface, id);
    }

    /// Imports a newly attached buffer and takes ownership of it.
    fn attach_buffer(
        &mut self,
        id: SurfaceId,
        buffer: &WlBuffer,
        transform: smithay::reexports::wayland_server::protocol::wl_output::Transform,
        scale: i32,
    ) {
        let Some(transform) = BufferTransform::from_protocol(transform) else {
            warn!(
                ?transform,
                "unrecognised buffer transform; releasing the buffer"
            );
            buffer.release();
            return;
        };
        let Some(scale) = BufferScale::from_protocol(scale) else {
            warn!(
                scale,
                "a buffer scale below one is a protocol error; releasing the buffer"
            );
            buffer.release();
            return;
        };

        let imported = match buffer_type(buffer) {
            Some(BufferType::Dma) => self.import_dmabuf(id, buffer, transform, scale),
            Some(BufferType::Shm) => self.import_shm(id, buffer, transform, scale),
            Some(other) => {
                warn!(?other, "unsupported buffer type; releasing the buffer");
                false
            }
            None => {
                warn!("a buffer of no recognised type was attached; releasing it");
                false
            }
        };

        if !imported {
            buffer.release();
        }
    }

    /// Imports a dmabuf and retains its `wl_buffer` until the next one arrives.
    ///
    /// Returns whether the caller still owns the buffer. A dmabuf is held for
    /// as long as lunette samples it, which is the rule
    /// `SurfaceBufWithImageContainer` implements upstream; shared memory is
    /// copied out and released immediately.
    fn import_dmabuf(
        &mut self,
        id: SurfaceId,
        buffer: &WlBuffer,
        transform: BufferTransform,
        scale: BufferScale,
    ) -> bool {
        let Ok(dmabuf) = get_dmabuf(buffer) else {
            warn!("a buffer reported as a dmabuf carried no dmabuf");
            return false;
        };

        let image = match self.importer.import_dmabuf(dmabuf) {
            Ok(image) => image,
            Err(error) => {
                warn!(%error, "could not import a client dmabuf");
                return false;
            }
        };

        self.buffers.retain(id, buffer.clone());
        self.record_content(
            id,
            SurfaceContent {
                size: image.size,
                transform,
                scale,
            },
        );
        self.report(Event::BufferImported { surface: id, image });
        self.report(Event::SurfaceDamaged { surface: id });
        true
    }

    /// Imports a shared-memory buffer, which is copied and released at once.
    fn import_shm(
        &mut self,
        id: SurfaceId,
        buffer: &WlBuffer,
        transform: BufferTransform,
        scale: BufferScale,
    ) -> bool {
        let outcome = with_buffer_contents(buffer, |pointer, length, data| {
            let Some(format) = ShmFormat::from_protocol(data.format) else {
                return Err(format!("unsupported wl_shm format {:?}", data.format));
            };

            let size = match (u32::try_from(data.width), u32::try_from(data.height)) {
                (Ok(width), Ok(height)) => PixelSize::new(width, height),
                _ => return Err("a wl_shm buffer declared a negative size".to_owned()),
            };
            let Ok(stride) = u32::try_from(data.stride) else {
                return Err("a wl_shm buffer declared a negative stride".to_owned());
            };
            let Ok(offset) = usize::try_from(data.offset) else {
                return Err("a wl_shm buffer declared a negative offset".to_owned());
            };

            let needed = usize::try_from(stride)
                .ok()
                .and_then(|stride| stride.checked_mul(size.height as usize))
                .and_then(|bytes| bytes.checked_add(offset));
            match needed {
                Some(needed) if needed <= length => {}
                _ => {
                    return Err("a wl_shm buffer is smaller than its own stride implies".to_owned());
                }
            }

            // SAFETY: `with_buffer_contents` guarantees the pointer addresses
            // `length` readable bytes of the client's pool for the duration of
            // this call, and the bounds check above keeps the slice inside it.
            let pixels =
                unsafe { std::slice::from_raw_parts(pointer.add(offset), length - offset) };

            Ok((
                pixels.to_vec(),
                ShmLayout {
                    size,
                    stride,
                    format,
                },
            ))
        });

        let (pixels, layout) = match outcome {
            Ok(Ok(gathered)) => gathered,
            Ok(Err(reason)) => {
                warn!(reason, "rejected a shared-memory buffer");
                return false;
            }
            Err(error) => {
                warn!(%error, "could not read a shared-memory buffer");
                return false;
            }
        };

        let image = match self.importer.import_shm(&pixels, layout) {
            Ok(image) => image,
            Err(error) => {
                warn!(%error, "could not import a client's shared-memory buffer");
                return false;
            }
        };

        self.record_content(
            id,
            SurfaceContent {
                size: layout.size,
                transform,
                scale,
            },
        );
        self.report(Event::BufferImported { surface: id, image });
        self.report(Event::SurfaceDamaged { surface: id });
        // The copy is taken, so the client may reuse the buffer at once.
        false
    }

    fn record_content(&mut self, id: SurfaceId, content: SurfaceContent) {
        if self.contents.insert(id, content) != Some(content) {
            self.touch();
        }
    }

    /// Notices a toplevel's first mapped buffer and its size changes.
    fn remember_committed_size(&mut self, surface: &WlSurface, id: SurfaceId) {
        let Some(content) = self.contents.get(&id).copied() else {
            return;
        };
        let Some(index) = self.toplevels.index_of_surface(surface) else {
            return;
        };

        let size = content.logical_size();
        let toplevel = &mut self.toplevels.entries[index];
        let opened = !toplevel.mapped;
        let changed = toplevel.size != size;

        toplevel.mapped = true;
        toplevel.size = size;

        if opened {
            let window = toplevel.window;
            self.touch();
            self.report(Event::WindowOpened { window });
        } else if changed {
            self.touch();
        }
    }

    /// Forgets everything keyed on a surface that is going away.
    fn forget_surface(&mut self, surface: &WlSurface) {
        self.frame_callbacks.remove(&surface.id());
        if let Some(id) = self.surfaces.forget(surface) {
            self.buffers.forget(id);
            self.contents.remove(&id);
        }
    }
}

/// What one commit carried, gathered under the surface's lock.
struct Committed {
    buffer: Option<BufferAssignment>,
    transform: smithay::reexports::wayland_server::protocol::wl_output::Transform,
    scale: i32,
    callbacks: Vec<WlCallback>,
}

/// The toplevels lunette knows about, in the order they were created.
///
/// A `Vec` rather than a map because it is walked far more often than it is
/// searched by identifier, and a panel count is in the tens.
#[derive(Debug, Default)]
pub(crate) struct Toplevels {
    entries: Vec<TrackedToplevel>,
    minted: u64,
}

impl Toplevels {
    fn insert(&mut self, toplevel: ToplevelSurface, process: Option<ProcessId>) -> WindowId {
        self.minted += 1;
        let raw = self.minted;
        let window = WindowId::new(raw)
            .unwrap_or_else(|| unreachable!("the counter starts at one and only increases"));
        let sink = SinkId::new(raw)
            .unwrap_or_else(|| unreachable!("the counter starts at one and only increases"));

        self.entries.push(TrackedToplevel {
            window,
            sink,
            surface: None,
            process,
            toplevel,
            title: None,
            app_id: None,
            size: PixelSize::default(),
            states: ToplevelStates::new(),
            mapped: false,
        });
        window
    }

    fn index_of_surface(&self, surface: &WlSurface) -> Option<usize> {
        self.entries
            .iter()
            .position(|entry| entry.toplevel.wl_surface() == surface)
    }

    fn index_of(&self, toplevel: &ToplevelSurface) -> Option<usize> {
        self.entries
            .iter()
            .position(|entry| &entry.toplevel == toplevel)
    }

    fn find(&self, window: WindowId) -> Option<&TrackedToplevel> {
        self.entries.iter().find(|entry| entry.window == window)
    }

    fn find_sink(&self, sink: SinkId) -> Option<&TrackedToplevel> {
        self.entries.iter().find(|entry| entry.sink == sink)
    }

    fn iter(&self) -> impl Iterator<Item = &TrackedToplevel> {
        self.entries.iter()
    }
}

/// One toplevel, as much of it as Phase 2 reports.
///
/// Geometry bookkeeping — minimum and maximum sizes, pending configures, the
/// clamping rules — arrives with the window manager.
#[derive(Debug)]
pub(crate) struct TrackedToplevel {
    window: WindowId,
    sink: SinkId,
    surface: Option<SurfaceId>,
    process: Option<ProcessId>,
    pub(crate) toplevel: ToplevelSurface,
    title: Option<String>,
    app_id: Option<String>,
    size: PixelSize,
    states: ToplevelStates,
    /// Whether a buffer has ever been committed. A toplevel exists from its
    /// creation, but it is not a window until it has content.
    mapped: bool,
}

impl TrackedToplevel {
    fn snapshot(&self, output: PixelSize) -> WindowSnapshot {
        let _ = output;
        WindowSnapshot {
            window: self.window,
            surface: self.surface.unwrap_or_else(|| {
                unreachable!("a mapped toplevel has committed, so its surface has an identifier")
            }),
            sink: self.sink,
            process: self.process,
            output: Some(DEFAULT_OUTPUT),
            title: self.title.clone(),
            app_id: self.app_id.clone(),
            size: self.size,
            min_size: None,
            max_size: None,
            parent: None,
            states: self.states.clone(),
        }
    }
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

impl compositor::CompositorHandler for CompositorState {
    fn compositor_state(&mut self) -> &mut compositor::CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        client
            .get_data::<ClientState>()
            .map(|data| &data.compositor)
            .unwrap_or_else(|| {
                unreachable!("every client is inserted with a ClientState of lunette's own")
            })
    }

    fn new_surface(&mut self, surface: &WlSurface) {
        self.send_initial_surface_state(surface);
    }

    fn destroyed(&mut self, surface: &WlSurface) {
        self.forget_surface(surface);
    }

    fn commit(&mut self, surface: &WlSurface) {
        self.popups_commit(surface);
        self.apply_commit(surface);
    }
}

impl BufferHandler for CompositorState {
    fn buffer_destroyed(&mut self, _buffer: &WlBuffer) {}
}

impl SeatHandler for CompositorState {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn focus_changed(&mut self, _seat: &Seat<Self>, _focused: Option<&WlSurface>) {
        // WayVR moves the data-device and primary-selection focus here
        // (`comp.rs:334-339`). Both protocols are Phase 5, so there is nothing
        // to move yet.
    }

    fn cursor_image(&mut self, _seat: &Seat<Self>, image: CursorImageStatus) {
        self.cursor_image = image;
    }
}

impl ShmHandler for CompositorState {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

impl OutputHandler for CompositorState {}

impl DmabufHandler for CompositorState {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        // `ImportNotifier` is `#[must_use]` and one-shot: exactly one of its
        // methods must be called, and dropping it logs a compositor bug.
        match self.importer.import_dmabuf(&dmabuf) {
            Ok(_) => {
                if notifier.successful::<Self>().is_err() {
                    debug!("a client withdrew a dmabuf before its import was answered");
                }
            }
            Err(error) => {
                warn!(%error, "rejecting a client dmabuf");
                notifier.failed();
            }
        }
    }
}

impl XdgShellHandler for CompositorState {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let wl_surface = surface.wl_surface().clone();
        self.send_initial_surface_state(&wl_surface);

        // The initial configure. A client may not attach a buffer until it has
        // one, so a toplevel that is never configured never maps. WayVR sends
        // it indirectly, from the window manager's first size configure
        // (`window.rs:68-84`); sending it here means a toplevel is configured
        // even when no policy has an opinion about its size yet.
        let bounds = self.output_logical_size();
        surface.with_pending_state(|pending| {
            pending.bounds = Some(bounds);
        });
        surface.send_configure();

        let id = self.surfaces.id_for(&wl_surface);
        let window = self.toplevels.insert(surface, None);
        if let Some(index) = self.toplevels.index_of_surface(&wl_surface) {
            self.toplevels.entries[index].surface = Some(id);
        }
        info!(%window, "a toplevel was created");
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        self.output.leave(surface.wl_surface());
        self.forget_surface(surface.wl_surface());

        let Some(index) = self.toplevels.index_of(&surface) else {
            return;
        };
        let removed = self.toplevels.entries.remove(index);
        self.touch();
        if removed.mapped {
            self.report(Event::WindowClosed {
                window: removed.window,
            });
        }
    }

    fn title_changed(&mut self, surface: ToplevelSurface) {
        let title = toplevel_attribute(&surface, |attributes| attributes.title.clone()).flatten();
        let Some(index) = self.toplevels.index_of(&surface) else {
            return;
        };
        if self.toplevels.entries[index].title == title {
            return;
        }
        self.toplevels.entries[index].title.clone_from(&title);
        let window = self.toplevels.entries[index].window;
        self.touch();
        self.report(Event::TitleChanged {
            window,
            title: title.unwrap_or_default(),
        });
    }

    fn app_id_changed(&mut self, surface: ToplevelSurface) {
        let app_id = toplevel_attribute(&surface, |attributes| attributes.app_id.clone()).flatten();
        if let Some(index) = self.toplevels.index_of(&surface) {
            self.toplevels.entries[index].app_id = app_id;
            self.touch();
        }
    }

    fn new_popup(&mut self, surface: PopupSurface, _positioner: PositionerState) {
        self.constrain_popup(&surface);

        if let Err(error) = self.popups.track_popup(PopupKind::Xdg(surface)) {
            warn!(%error, "could not track an xdg_popup");
        }
    }

    fn popup_destroyed(&mut self, _surface: PopupSurface) {
        self.popups.cleanup();
    }

    fn grab(&mut self, surface: PopupSurface, seat: wl_seat::WlSeat, serial: Serial) {
        let popup = PopupKind::Xdg(surface);

        let Ok(root) = find_popup_root_surface(&popup) else {
            warn!("a popup asked for a grab but has no root surface");
            return;
        };
        let Some(seat) = Seat::<Self>::from_resource(&seat) else {
            warn!("a popup asked for a grab on a seat lunette does not own");
            return;
        };
        let Ok(mut grab) = self.popups.grab_popup::<Self>(root, popup, &seat, serial) else {
            debug!("a popup grab was denied");
            return;
        };

        if let Some(keyboard) = seat.get_keyboard() {
            if keyboard.is_grabbed()
                && !(keyboard.has_grab(serial)
                    || keyboard.has_grab(grab.previous_serial().unwrap_or(serial)))
            {
                grab.ungrab(PopupUngrabStrategy::All);
                return;
            }

            keyboard.set_focus(self, grab.current_grab(), serial);
            keyboard.set_grab(self, PopupKeyboardGrab::new(&grab), serial);
        }

        if let Some(pointer) = seat.get_pointer() {
            if pointer.is_grabbed()
                && !(pointer.has_grab(serial)
                    || pointer.has_grab(grab.previous_serial().unwrap_or_else(|| grab.serial())))
            {
                grab.ungrab(PopupUngrabStrategy::All);
                return;
            }

            pointer.set_grab(self, PopupPointerGrab::new(&grab), serial, Focus::Keep);
        }
    }

    fn reposition_request(
        &mut self,
        surface: PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        surface.with_pending_state(|state| {
            state.geometry = positioner.get_geometry();
            state.positioner = positioner;
        });

        self.constrain_popup(&surface);
        surface.send_repositioned(token);
    }

    fn fullscreen_request(
        &mut self,
        surface: ToplevelSurface,
        _output: Option<smithay::reexports::wayland_server::protocol::wl_output::WlOutput>,
    ) {
        self.fill_output(&surface, xdg_toplevel::State::Fullscreen);
    }

    fn maximize_request(&mut self, surface: ToplevelSurface) {
        self.fill_output(&surface, xdg_toplevel::State::Maximized);
    }

    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        self.restore_from_output(&surface, xdg_toplevel::State::Fullscreen);
    }

    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        self.restore_from_output(&surface, xdg_toplevel::State::Maximized);
    }
}

impl CompositorState {
    /// Grants a client's request to fill the virtual output.
    ///
    /// A panel has one window in it, so a request to fill the screen is a
    /// request to fill the panel, and refusing it leaves clients that expect a
    /// fullscreen surface — video players, games — drawing at the wrong size.
    fn fill_output(&mut self, surface: &ToplevelSurface, state: xdg_toplevel::State) {
        let size = self.output_logical_size();

        surface.with_pending_state(|pending| {
            pending.bounds = Some(size);
            pending.size = Some(size);
            pending.states.set(state);
        });
        surface.send_configure();

        if let Some(index) = self.toplevels.index_of(surface)
            && let Some(state) = toplevel_state(state)
        {
            self.toplevels.entries[index].states.insert(state);
            self.touch();
        }
    }

    fn restore_from_output(&mut self, surface: &ToplevelSurface, state: xdg_toplevel::State) {
        let bounds = self.output_logical_size();

        surface.with_pending_state(|pending| {
            pending.bounds = Some(bounds);
            pending.size = None;
            pending.states.unset(state);
        });
        surface.send_configure();

        if let Some(index) = self.toplevels.index_of(surface)
            && let Some(state) = toplevel_state(state)
        {
            self.toplevels.entries[index].states.remove(&state);
            self.touch();
        }
    }
}

impl XdgDecorationHandler for CompositorState {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        force_server_side(&toplevel);
    }

    fn request_mode(
        &mut self,
        toplevel: ToplevelSurface,
        _mode: zxdg_toplevel_decoration_v1::Mode,
    ) {
        force_server_side(&toplevel);
    }

    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        force_server_side(&toplevel);
    }
}

impl KdeDecorationHandler for CompositorState {
    fn kde_decoration_state(&self) -> &KdeDecorationState {
        &self.kde_decoration
    }

    fn request_mode(
        &mut self,
        _surface: &WlSurface,
        decoration: &org_kde_kwin_server_decoration::OrgKdeKwinServerDecoration,
        _mode: WEnum<org_kde_kwin_server_decoration::Mode>,
    ) {
        decoration.mode(org_kde_kwin_server_decoration::Mode::Server);
    }
}

delegate_compositor!(CompositorState);
delegate_dmabuf!(CompositorState);
delegate_kde_decoration!(CompositorState);
delegate_output!(CompositorState);
delegate_seat!(CompositorState);
delegate_shm!(CompositorState);
delegate_viewporter!(CompositorState);
delegate_xdg_decoration!(CompositorState);
delegate_xdg_shell!(CompositorState);

/// Forces server-side decorations, as WayVR does in all three
/// `XdgDecorationHandler` methods (`comp.rs:638-663`).
///
/// A client that draws its own titlebar draws it inside lunette's panel, where
/// it is decoration for a window that has no frame to decorate. GTK and Qt both
/// do so unless told otherwise.
fn force_server_side(toplevel: &ToplevelSurface) {
    toplevel.with_pending_state(|state| {
        state.decoration_mode = Some(zxdg_toplevel_decoration_v1::Mode::ServerSide);
    });
    toplevel.send_configure();
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
fn toplevel_attribute<T>(
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
fn physical_size(size: PixelSize) -> Size<i32, smithay::utils::Physical> {
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
fn logical_size(size: PixelSize) -> Size<i32, smithay::utils::Logical> {
    #[expect(
        clippy::cast_possible_wrap,
        reason = "a size beyond two billion pixels is not a mode any hardware or protocol carries"
    )]
    Size::new(size.width as i32, size.height as i32)
}

/// Maps a pointer button onto the evdev code `wl_pointer.button` carries.
///
/// The side and extra buttons are what libinput reports for back and forward,
/// which is what applications listen for; `BTN_BACK` and `BTN_FORWARD` exist
/// but are sent by almost nothing.
const fn evdev_button(button: PointerButton) -> u32 {
    match button {
        PointerButton::Left => 0x110,
        PointerButton::Right => 0x111,
        PointerButton::Middle => 0x112,
        PointerButton::Back => 0x113,
        PointerButton::Forward => 0x114,
    }
}

/// Maps a reported toplevel state back onto the protocol's.
const fn protocol_state(state: ToplevelState) -> xdg_toplevel::State {
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
fn toplevel_state(state: xdg_toplevel::State) -> Option<ToplevelState> {
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

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::{
        protocol::{PixelPoint, PointerButton},
        test_client::TestClient,
        testing::TestCompositor,
    };

    /// Every global lunette advertises, in the order `globals()` sorts them.
    ///
    /// `wl_subcompositor` is here because `CompositorState::new` creates it
    /// unconditionally, and `wp_viewporter` because xwayland-satellite refuses
    /// to start without it. Both decoration managers are here so GTK and Qt
    /// clients do not draw their own titlebars inside a panel.
    const EXPECTED_GLOBALS: [&str; 10] = [
        "org_kde_kwin_server_decoration_manager",
        "wl_compositor",
        "wl_output",
        "wl_seat",
        "wl_shm",
        "wl_subcompositor",
        "wp_viewporter",
        "xdg_wm_base",
        "zwp_linux_dmabuf_v1",
        "zxdg_decoration_manager_v1",
    ];

    /// A compositor with one mapped window, and the client that owns it.
    fn with_one_window() -> (TestCompositor, TestClient) {
        let mut compositor = TestCompositor::new();
        let mut client = TestClient::connect(&mut compositor);
        client.open_toplevel(&mut compositor);
        client.attach_buffer(&mut compositor, 640, 480);
        (compositor, client)
    }

    fn only_window(compositor: &TestCompositor) -> WindowSnapshot {
        let snapshot = compositor.snapshot();
        assert_eq!(snapshot.windows.len(), 1, "expected exactly one window");
        snapshot.windows[0].clone()
    }

    #[test]
    fn a_client_sees_every_global_lunette_advertises() {
        let mut compositor = TestCompositor::new();
        let client = TestClient::connect(&mut compositor);

        assert_eq!(client.globals(), EXPECTED_GLOBALS);
    }

    #[test]
    fn a_toplevel_with_no_buffer_is_not_yet_a_window() {
        let mut compositor = TestCompositor::new();
        let mut client = TestClient::connect(&mut compositor);
        client.open_toplevel(&mut compositor);

        assert!(
            compositor.snapshot().windows.is_empty(),
            "a toplevel that has never committed content has nothing to show"
        );
        assert!(
            !compositor
                .drain_events()
                .iter()
                .any(|event| matches!(event, Event::WindowOpened { .. })),
            "nothing opened, because nothing was drawn"
        );
    }

    #[test]
    fn a_mapped_toplevel_is_reported_and_appears_in_the_snapshot() {
        let (compositor, _client) = with_one_window();

        let events = compositor.drain_events();
        let opened: Vec<WindowId> = events
            .iter()
            .filter_map(|event| match event {
                Event::WindowOpened { window } => Some(*window),
                _ => None,
            })
            .collect();
        assert_eq!(opened.len(), 1, "exactly one window opened: {events:?}");

        let window = only_window(&compositor);
        assert_eq!(window.window, opened[0]);
        assert_eq!(window.size, PixelSize::new(640, 480));
        assert_eq!(window.output, Some(DEFAULT_OUTPUT));
    }

    #[test]
    fn a_shm_commit_reaches_the_importer_with_the_layout_the_client_declared() {
        let (compositor, _client) = with_one_window();

        let layouts = compositor.imports().shm_layouts();
        assert_eq!(layouts.len(), 1, "one commit, one import");
        assert_eq!(layouts[0].size, PixelSize::new(640, 480));
        assert_eq!(layouts[0].stride, 640 * 4);
        assert_eq!(layouts[0].format, ShmFormat::Argb8888);
        assert_eq!(
            compositor.imports().dmabuf_count(),
            0,
            "a shared-memory client must not reach the dmabuf path"
        );
    }

    #[test]
    fn a_buffer_the_importer_refuses_leaves_the_window_unmapped() {
        let mut compositor = TestCompositor::new();
        compositor.imports().refuse("no graphics device");
        let mut client = TestClient::connect(&mut compositor);
        client.open_toplevel(&mut compositor);
        client.attach_buffer(&mut compositor, 640, 480);

        assert!(
            compositor.snapshot().windows.is_empty(),
            "a window with no importable content is not shown"
        );
    }

    #[test]
    fn a_title_change_is_reported_once_per_change() {
        let (mut compositor, mut client) = with_one_window();
        drop(compositor.drain_events());

        client.set_title(&mut compositor, "a terminal");
        client.set_title(&mut compositor, "a terminal");

        let titles: Vec<String> = compositor
            .drain_events()
            .into_iter()
            .filter_map(|event| match event {
                Event::TitleChanged { title, .. } => Some(title),
                _ => None,
            })
            .collect();
        assert_eq!(
            titles,
            ["a terminal"],
            "setting the same title twice is not a change"
        );
        assert_eq!(
            only_window(&compositor).title.as_deref(),
            Some("a terminal")
        );
    }

    #[test]
    fn destroying_a_toplevel_reports_the_window_closed_and_removes_it() {
        let (mut compositor, mut client) = with_one_window();
        let window = only_window(&compositor).window;
        drop(compositor.drain_events());

        client.close_toplevel(&mut compositor);

        assert!(
            compositor.drain_events().iter().any(
                |event| matches!(event, Event::WindowClosed { window: closed } if *closed == window)
            ),
            "the window that went away is the one reported"
        );
        assert!(compositor.snapshot().windows.is_empty());
    }

    #[test]
    fn a_disconnecting_client_takes_its_window_with_it() {
        let (mut compositor, client) = with_one_window();
        assert_eq!(compositor.snapshot().windows.len(), 1);

        client.disconnect(&mut compositor);

        assert!(
            compositor.snapshot().windows.is_empty(),
            "a client that is gone leaves no windows behind"
        );
    }

    #[test]
    fn closing_a_window_asks_the_client_rather_than_removing_it() {
        let (mut compositor, mut client) = with_one_window();
        let window = only_window(&compositor).window;

        compositor.send(Command::CloseWindow { window });
        client.settle(&mut compositor, |driver| driver.closed);

        assert_eq!(
            compositor.snapshot().windows.len(),
            1,
            "a close is a request; the window stays until the client acts on it"
        );
    }

    #[test]
    fn configuring_a_window_sizes_the_toplevel_without_changing_the_snapshot() {
        let (mut compositor, mut client) = with_one_window();
        let window = only_window(&compositor).window;

        compositor.send(Command::ConfigureWindow {
            window,
            size: Some(PixelSize::new(800, 600)),
            states: ToplevelStates::new(),
        });
        client.settle(&mut compositor, |driver| {
            driver.toplevel_size == Some((800, 600))
        });

        assert_eq!(
            only_window(&compositor).size,
            PixelSize::new(640, 480),
            "the snapshot reports what the client committed, not what it was asked for"
        );
    }

    #[test]
    fn closing_a_window_that_is_already_gone_is_not_an_error() {
        let (mut compositor, mut client) = with_one_window();
        let window = only_window(&compositor).window;
        client.close_toplevel(&mut compositor);

        compositor.send(Command::CloseWindow { window });
        client.settle_quiet(&mut compositor);
    }

    #[test]
    fn input_addressed_to_a_seat_that_does_not_exist_is_refused() {
        let (mut compositor, mut client) = with_one_window();
        let sink = only_window(&compositor).sink;
        let absent = SeatId::new(99).expect("non-zero");

        compositor.send(Command::Pointer {
            seat: absent,
            sink,
            position: PixelPoint::new(1.0, 1.0),
        });
        compositor.send(Command::Button {
            seat: absent,
            sink,
            button: PointerButton::Left,
            pressed: true,
        });
        client.settle_quiet(&mut compositor);
    }

    #[test]
    fn a_pointer_over_a_window_is_delivered_to_its_surface() {
        let (mut compositor, mut client) = with_one_window();
        let sink = only_window(&compositor).sink;

        compositor.send(Command::Pointer {
            seat: DEFAULT_SEAT,
            sink,
            position: PixelPoint::new(12.0, 34.0),
        });
        compositor.send(Command::Button {
            seat: DEFAULT_SEAT,
            sink,
            button: PointerButton::Left,
            pressed: true,
        });
        compositor.send(Command::Button {
            seat: DEFAULT_SEAT,
            sink,
            button: PointerButton::Left,
            pressed: false,
        });
        compositor.send(Command::PointerLeave { seat: DEFAULT_SEAT });
        client.settle_quiet(&mut compositor);
    }

    #[test]
    fn the_default_output_is_reported_with_the_configured_mode() {
        let compositor = TestCompositor::new();
        let snapshot = compositor.snapshot();

        assert_eq!(snapshot.outputs.len(), 1);
        assert_eq!(snapshot.outputs[0].output, DEFAULT_OUTPUT);
        assert_eq!(
            snapshot.outputs[0].mode.size,
            CompositorConfig::default().output.size
        );
    }

    #[test]
    fn every_pointer_button_maps_to_a_distinct_evdev_code() {
        let buttons = [
            PointerButton::Left,
            PointerButton::Right,
            PointerButton::Middle,
            PointerButton::Back,
            PointerButton::Forward,
        ];
        let mut codes: Vec<u32> = buttons.into_iter().map(evdev_button).collect();
        codes.sort_unstable();
        codes.dedup();

        assert_eq!(codes.len(), buttons.len(), "two buttons share a code");
        assert_eq!(evdev_button(PointerButton::Left), 0x110, "BTN_LEFT");
    }

    #[test]
    fn every_reported_toplevel_state_round_trips_through_the_protocol() {
        for state in [
            ToplevelState::Maximized,
            ToplevelState::Fullscreen,
            ToplevelState::Resizing,
            ToplevelState::Activated,
            ToplevelState::TiledLeft,
            ToplevelState::TiledRight,
            ToplevelState::TiledTop,
            ToplevelState::TiledBottom,
            ToplevelState::Suspended,
        ] {
            assert_eq!(
                toplevel_state(protocol_state(state)),
                Some(state),
                "{state:?} did not survive the round trip"
            );
        }
    }
}
