//! Adapted from WayVR's `backend/wayvr/comp.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The compositor state and every protocol handler that dispatches to it.
//!
//! lunette's state also holds what its own features need: several seats and
//! outputs, the host clipboard bridge, frame pacing, process attribution, and
//! the compositor-thread ends of the event and snapshot transports. Imported
//! images live on the frame thread, so a commit reports each import as an
//! event and keeps only its size in the surface's data map. The `wl_shm` path
//! copies the committed buffer from its offset in the pool. A retained dmabuf
//! is released when a surface replaces it with anything else, and never when
//! the same buffer is committed again. Unknown buffers are released.
//! `wl_output` is lunette's own global, filtered per client, so smithay's
//! `Output` and `delegate_output!` are left out, along with
//! `set_clipboard_text`, the redraw requests, `wp_single_pixel_buffer_v1`, and
//! the relative pointer. lunette adds `new_surface`, `destroyed`,
//! `app_id_changed`, the fractional-scale and content-type globals, and the
//! state lunette tracks for windows in each handler.

use smithay::backend::allocator::Buffer;
use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::renderer::{BufferType, buffer_type};
use smithay::desktop::{
    PopupKeyboardGrab, PopupKind, PopupManager, PopupPointerGrab, PopupUngrabStrategy,
    find_popup_root_surface, get_popup_toplevel_coords,
};
use smithay::input::pointer::{CursorImageStatus, Focus};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::reexports::calloop::{LoopHandle, LoopSignal, RegistrationToken};
use smithay::reexports::wayland_protocols::wp::content_type::v1::server::wp_content_type_v1;
use smithay::reexports::wayland_protocols::xdg::decoration::zv1::server::zxdg_toplevel_decoration_v1;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration;
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::reexports::wayland_server::protocol::{
    wl_buffer, wl_callback, wl_data_source, wl_output, wl_seat,
};
use smithay::reexports::wayland_server::{self, DisplayHandle};
use smithay::utils::{Logical, Rectangle, Serial, Size};
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{self, BufferAssignment, SurfaceAttributes};
use smithay::wayland::content_type::{ContentTypeState, ContentTypeSurfaceCachedState};
use smithay::wayland::dmabuf::{
    DmabufFeedback, DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier, get_dmabuf,
};
use smithay::wayland::fractional_scale::{FractionalScaleHandler, FractionalScaleManagerState};
use smithay::wayland::selection::data_device::{
    ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, ServerDndGrabHandler,
    set_data_device_focus,
};
use smithay::wayland::selection::{self, SelectionHandler};
use smithay::wayland::selection::{
    ext_data_control as selection_ext,
    primary_selection::{PrimarySelectionHandler, PrimarySelectionState, set_primary_focus},
    wlr_data_control as selection_wlr,
};
use smithay::wayland::shell::kde::decoration::{KdeDecorationHandler, KdeDecorationState};
use smithay::wayland::shell::xdg::decoration::{XdgDecorationHandler, XdgDecorationState};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
};
use smithay::wayland::shm::{ShmHandler, ShmState, with_buffer_contents};
use smithay::wayland::viewporter::ViewporterState;
use smithay::{
    delegate_compositor, delegate_content_type, delegate_data_control, delegate_data_device,
    delegate_dmabuf, delegate_ext_data_control, delegate_fractional_scale, delegate_kde_decoration,
    delegate_primary_selection, delegate_seat, delegate_shm, delegate_viewporter,
    delegate_xdg_decoration, delegate_xdg_shell,
};
use std::collections::{HashMap, HashSet};
use std::os::fd::OwnedFd;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tracing as log;
use wayland_server::Client;
use wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use wayland_server::protocol::wl_surface::WlSurface;

use crate::{
    config::{CompositorConfig, DEFAULT_OUTPUT},
    output::OutputRegistry,
    pacing::FramePacer,
    protocol::{
        ContentType, Event, ImportedBuffer, OutputId, PixelSize, ProcessId, SeatId, SurfaceId,
    },
    seat::{self, SeatRegistry},
    selection::{HostOffer, SelectionBridge, SelectionKind},
    spawn::{AdoptedIds, DisplayEnvironment, ProcessInspector, ProcessSpawner},
    surface::{BufferImporter, BufferTransform, ShmFormat, ShmLayout, SurfaceRegistry},
    thread::{EventSender, LoopData, SnapshotPublisher},
    wayvr::{
        client::{Satellite, WayVRClient},
        process::{Process, ProcessHandle},
        window::WindowManager,
    },
};
use slotmap::DenseSlotMap;

use super::{ImportedExtent, SurfaceBufWithImage, TaskQueue, WayVRTask};

pub struct Application {
    /// Every virtual monitor lunette advertises. Holding an entry keeps its
    /// `wl_output` global advertised.
    pub outputs: OutputRegistry,
    pub image_importer: Box<dyn BufferImporter>,
    pub dmabuf_state: (DmabufState, DmabufGlobal, Option<DmabufFeedback>),
    pub compositor: compositor::CompositorState,
    pub xdg_shell: XdgShellState,
    /// Every seat lunette serves. Holding an entry keeps its `wl_seat` global
    /// advertised.
    pub seats: SeatRegistry,
    pub seat_state: SeatState<Application>,
    pub shm: ShmState,
    pub data_device: DataDeviceState,
    pub primary_selection_state: PrimarySelectionState,
    pub ext_data_control_state: selection_ext::DataControlState,
    pub wlr_data_control_state: selection_wlr::DataControlState,
    #[allow(dead_code)]
    pub xdg_decoration_state: XdgDecorationState,
    pub kde_decoration_state: KdeDecorationState,
    pub wayvr_tasks: TaskQueue<WayVRTask>,
    pub popup_manager: PopupManager,
    #[allow(dead_code)]
    pub viewporter: ViewporterState,
    pub display_handle: DisplayHandle,
    pub(super) no_server_decorations: HashSet<ObjectId>,
    /// The unanswered callbacks of each surface, keyed by the identifier that
    /// frame pacing uses.
    pub pending_frame_callbacks: HashMap<SurfaceId, Vec<wl_callback::WlCallback>>,
    /// pointer that last drove the wvr_server mouse. used for DND
    pub vr_pointer: SeatId,
    /// pointer that produced the button press that correlates to DND serial
    pub pointer_button_owner: Option<SeatId>,
    /// pointer currently owning a DND grab
    pub dnd_pointer: Option<SeatId>,

    pub config: CompositorConfig,
    /// Environment values passed to every spawned client.
    pub environment: DisplayEnvironment,
    /// Which seat's selections are the host's, and what the host is offering.
    pub selection: SelectionBridge,
    #[allow(dead_code)]
    pub content_type: ContentTypeState,
    #[allow(dead_code)]
    pub fractional_scale: FractionalScaleManagerState,
    pub spawner: Box<dyn ProcessSpawner>,
    pub inspector: Box<dyn ProcessInspector>,
    pub surfaces: SurfaceRegistry,
    pub windows: WindowManager,
    pub processes: DenseSlotMap<ProcessHandle, Process>,
    pub adopted_ids: AdoptedIds,
    /// Each connected client and the process it is attributed to.
    pub clients: Vec<WayVRClient>,
    pub assignments: HashMap<ProcessId, OutputId>,
    /// The timer that reaps children and collects their output, present only
    /// while there is something to reap.
    pub process_poll: Option<RegistrationToken>,
    pub loop_handle: LoopHandle<'static, LoopData>,
    /// Polled with the spawned processes, and dropped with the state. Dropping
    /// it stops the bridge's process group, which reaps xwayland-satellite and
    /// the `Xwayland` it started.
    pub satellite: Satellite,
    pub pacing: FramePacer,
    /// The timer that wakes the loop to answer a withheld surface, with its
    /// scheduled deadline. Without it, an idle client waiting on a frame callback
    /// cannot wake the event loop to receive its answer.
    pub pacing_wakeup: Option<(RegistrationToken, Duration)>,
    /// How many keymap uploads to let through, and how many to fail after
    /// them. Always `(0, 0)` in production; see
    /// [`Application::fail_keymap_uploads`].
    #[cfg(any(test, feature = "test-fakes"))]
    pub failing_uploads: std::cell::Cell<(usize, usize)>,
    /// The baseline for the protocol's monotonic millisecond timestamps.
    ///
    /// The wall clock can move backwards, so production timestamps use elapsed
    /// time from this instant. Tests use [`Application::clock_offset`].
    #[cfg_attr(
        any(test, feature = "test-fakes"),
        expect(
            dead_code,
            reason = "the test clock is virtual and reads clock_offset alone"
        )
    )]
    pub started: Instant,
    /// The virtual compositor clock used by tests. Production uses `started`.
    #[cfg(any(test, feature = "test-fakes"))]
    pub clock_offset: Duration,
    pub events: EventSender,
    pub snapshots: SnapshotPublisher,
    pub signal: LoopSignal,
    pub dirty: bool,
}

impl Application {
    fn popups_commit(&mut self, surface: &WlSurface) {
        self.popup_manager.commit(surface);

        if let Some(popup) = self.popup_manager.find_popup(surface) {
            match popup {
                PopupKind::Xdg(ref popup) => {
                    if !popup.is_initial_configure_sent() {
                        self.send_surface_scale(surface);
                        if let Err(error) = popup.send_configure() {
                            log::warn!(%error, "could not send a popup's initial configure");
                        }
                    }
                }
                PopupKind::InputMethod(_) => {
                    // TODO?
                }
            }
        }
    }

    fn send_initial_surface_state(&mut self, surface: &WlSurface) {
        self.outputs.enter(surface, self.output_of(surface));

        self.send_surface_scale(surface);
    }

    #[expect(
        dead_code,
        reason = "the window snapshot does not report decorations yet"
    )]
    pub fn has_server_side_decorations(&self, surface: &WlSurface) -> bool {
        !self.no_server_decorations.contains(&surface.id())
    }

    fn set_server_side_decorations(&mut self, surface: &WlSurface, enabled: bool) {
        let id = surface.id();
        let changed = if enabled {
            self.no_server_decorations.remove(&id)
        } else {
            self.no_server_decorations.insert(id.clone())
        };

        if changed {
            self.touch();
        }
    }

    pub fn output_logical_size(&self, surface: &WlSurface) -> Size<i32, Logical> {
        self.surface_bounds(surface)
    }

    fn surface_logical_size(surface: &WlSurface) -> Option<Size<i32, Logical>> {
        smithay::wayland::compositor::with_states(surface, |states| {
            SurfaceBufWithImage::get_from_surface(states).map(|buf| buf.logical_size(states))
        })
    }

    fn constrain_popup(&self, popup: &PopupSurface) {
        let popup_kind = PopupKind::Xdg(popup.clone());

        let Ok(root_surface) = find_popup_root_surface(&popup_kind) else {
            log::warn!(
                "constrain_popup: could not find popup root surface {:?}",
                popup.wl_surface().id()
            );
            return;
        };

        let root_size = Self::surface_logical_size(&root_surface)
            .unwrap_or_else(|| self.output_logical_size(&root_surface));

        let mut target = Rectangle::from_size(root_size);
        target.loc -= get_popup_toplevel_coords(&popup_kind);

        popup.with_pending_state(|state| {
            state.geometry = state.positioner.get_unconstrained_geometry(target);
        });
    }
}

fn drm_format_has_alpha(format: smithay::backend::allocator::Fourcc) -> bool {
    use smithay::backend::allocator::Fourcc as DrmFourcc;
    matches!(
        format,
        DrmFourcc::Abgr8888 | DrmFourcc::Argb8888 | DrmFourcc::Abgr2101010
    )
}

impl compositor::CompositorHandler for Application {
    fn compositor_state(&mut self) -> &mut compositor::CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(
        &self,
        client: &'a Client,
    ) -> &'a compositor::CompositorClientState {
        &client.get_data::<ClientState>().unwrap().compositor_state
    }

    fn new_surface(&mut self, surface: &WlSurface) {
        self.send_initial_surface_state(surface);
    }

    fn destroyed(&mut self, surface: &WlSurface) {
        self.outputs.leave(surface);
        self.forget_surface(surface);
    }

    #[allow(clippy::significant_drop_tightening)]
    fn commit(&mut self, surface: &WlSurface) {
        self.popups_commit(surface);

        let id = self.surfaces.id_for(surface);
        let mut imported = None;
        let mut unmapped = false;
        let mut content_type = ContentType::None;
        let mut changed = false;

        smithay::wayland::compositor::with_states(surface, |states| {
            // Content-type is double-buffered; read the value this commit promoted.
            content_type = protocol_content_type(
                *states
                    .cached_state
                    .get::<ContentTypeSurfaceCachedState>()
                    .current()
                    .content_type(),
            );
            let previous = SurfaceBufWithImage::get_from_surface(states);

            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attrs = guard.current();

            match attrs.buffer.take() {
                Some(BufferAssignment::NewBuffer(buffer)) => {
                    match buffer_type(&buffer) {
                        _ if BufferTransform::from_protocol(attrs.buffer_transform).is_none() => {
                            log::warn!(
                                "Unsupported wl_buffer transform: {:?}",
                                attrs.buffer_transform
                            );
                            buffer.release();
                        }
                        Some(BufferType::Dma) => {
                            let dmabuf = get_dmabuf(&buffer).unwrap(); // always Ok due to buffer_type

                            if let Ok(image) =
                                self.image_importer.import_dmabuf(dmabuf).inspect_err(|e| {
                                    log::warn!("wayland_server failed to import DMA-buf: {e:?}");
                                })
                            {
                                let sbwi = SurfaceBufWithImage {
                                    image: ImportedExtent { size: image.size },
                                    transform: wl_transform_to_frame_transform(
                                        attrs.buffer_transform,
                                    ),
                                    scale: attrs.buffer_scale,
                                    dmabuf: true,
                                    has_alpha: drm_format_has_alpha(dmabuf.format().code),
                                };
                                imported = Some(ImportedBuffer::Image(image));

                                // Committing the retained buffer again keeps it retained.
                                if let Some(old_buffer) =
                                    sbwi.apply_to_surface(states, Some(buffer.clone()))
                                    && old_buffer != buffer
                                {
                                    old_buffer.release();
                                }
                            } else {
                                buffer.release();
                            }
                        }
                        Some(BufferType::Shm) => {
                            if let Ok((data, buf)) = copy_shm(&buffer).inspect_err(|e| {
                                log::warn!("wayland_server rejected SHM: {e}");
                            }) && let Ok(image) =
                                self.image_importer.import_shm(&data, buf).inspect_err(|e| {
                                    log::warn!("wayland_server failed to import SHM: {e:?}");
                                })
                            {
                                let sbwi = SurfaceBufWithImage {
                                    image: ImportedExtent { size: buf.size },
                                    transform: wl_transform_to_frame_transform(
                                        attrs.buffer_transform,
                                    ),
                                    scale: attrs.buffer_scale,
                                    dmabuf: false,
                                    has_alpha: buf.format == ShmFormat::Argb8888,
                                };
                                imported = Some(ImportedBuffer::Pixels(image));
                                // The copied pixels no longer depend on a retained dmabuf.
                                if let Some(old_buffer) = sbwi.apply_to_surface(states, None) {
                                    old_buffer.release();
                                }
                            }
                            buffer.release();
                        }
                        Some(other) => {
                            log::warn!("Unsupported wl_buffer format: {other:?}");
                            buffer.release();
                        }
                        None => {
                            /* don't draw anything */
                            buffer.release();
                        }
                    }
                }
                Some(BufferAssignment::Removed) => {
                    if let Some(old_buffer) = SurfaceBufWithImage::remove_from_surface(states) {
                        old_buffer.release();
                    }
                    unmapped = true;
                }
                None => {}
            }

            let callbacks = std::mem::take(&mut attrs.frame_callbacks);
            if !callbacks.is_empty() {
                self.pending_frame_callbacks
                    .entry(id)
                    .or_default()
                    .extend(callbacks);
            }

            changed = previous != SurfaceBufWithImage::get_from_surface(states);
        });

        if let Some(buffer) = imported {
            self.report(Event::BufferImported {
                surface: id,
                buffer,
            });
            self.report(Event::SurfaceDamaged { surface: id });
        }
        if changed {
            self.touch();
        }
        if unmapped {
            self.unmap_surface(id);
        }

        self.remember_content_type(id, content_type);
        self.remember_committed_size(surface, id);
    }
}

impl SeatHandler for Application {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let dh = &self.display_handle;
        let client = focused.and_then(|s| dh.get_client(s.id()).ok());
        set_data_device_focus(dh, seat, client.clone());
        set_primary_focus(dh, seat, client);
    }

    fn cursor_image(&mut self, seat: &Seat<Self>, image: CursorImageStatus) {
        seat::set_cursor_image(seat, image);
    }
}

impl BufferHandler for Application {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
}

impl ClientDndGrabHandler for Application {
    fn started(
        &mut self,
        _source: Option<wl_data_source::WlDataSource>,
        icon: Option<WlSurface>,
        _seat: Seat<Self>,
    ) {
        let pointer = self.pointer_button_owner.unwrap_or(self.vr_pointer);
        self.dnd_pointer = Some(pointer);
        self.wayvr_tasks
            .send(WayVRTask::DndStarted { icon, pointer });
    }

    fn dropped(&mut self, _target: Option<WlSurface>, _validated: bool, _seat: Seat<Self>) {
        self.dnd_pointer = None;
        self.pointer_button_owner = None;
        self.wayvr_tasks.send(WayVRTask::DndDropped);
    }
}

impl ServerDndGrabHandler for Application {
    fn send(&mut self, _mime_type: String, _fd: OwnedFd, _seat: Seat<Self>) {}
}

impl DataDeviceHandler for Application {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device
    }
}

/// [`Self::SelectionUserData`] is a [`HostOffer`]. The only selection lunette
/// itself owns is one it took from the host; a selection a client owns is
/// served by that client, and smithay routes those without asking here.
/// Carrying the offer identifier in the user data distinguishes a read that
/// outlived its selection from a current one.
impl SelectionHandler for Application {
    type SelectionUserData = HostOffer;

    fn send_selection(
        &mut self,
        _ty: selection::SelectionTarget,
        mime_type: String,
        fd: OwnedFd,
        _seat: Seat<Self>,
        user_data: &Self::SelectionUserData,
    ) {
        self.serve_selection(&mime_type, fd, &user_data.clone());
    }

    fn new_selection(
        &mut self,
        ty: selection::SelectionTarget,
        source: Option<selection::SelectionSource>,
        seat: Seat<Self>,
    ) {
        self.client_selection(SelectionKind::from_target(ty), source.as_ref(), &seat);
    }
}

/// What lunette attaches to each connected client.
///
/// Stores the client output assignment because `GlobalDispatch::can_view`
/// receives client data without compositor state.
#[derive(Default)]
pub struct ClientState {
    compositor_state: compositor::CompositorClientState,
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
        log::debug!("Client ID {client_id:?} connected");
    }

    fn disconnected(&self, client_id: ClientId, reason: DisconnectReason) {
        if let Ok(mut disconnected) = self.disconnected.lock() {
            *disconnected = true;
        }
        log::debug!("Client ID {client_id:?} disconnected. Reason: {reason:?}");
    }
}

impl AsMut<compositor::CompositorState> for Application {
    fn as_mut(&mut self) -> &mut compositor::CompositorState {
        &mut self.compositor
    }
}

impl XdgShellHandler for Application {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let wl_surface = surface.wl_surface();
        self.send_initial_surface_state(wl_surface);
        if let Some(client) = wl_surface.client() {
            self.wayvr_tasks
                .send(WayVRTask::NewToplevel(client.id(), surface.clone()));
        }
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        self.outputs.leave(surface.wl_surface());
        self.forget_surface(surface.wl_surface());
        self.no_server_decorations
            .remove(&surface.wl_surface().id());

        if let Some(client) = surface.wl_surface().client() {
            self.wayvr_tasks
                .send(WayVRTask::DropToplevel(client.id(), surface.clone()));
        } else {
            // A disconnecting client has no id left to queue the task with.
            self.drop_window(&surface);
        }
    }

    fn new_popup(&mut self, surface: PopupSurface, _positioner: PositionerState) {
        self.constrain_popup(&surface);

        let _ = self
            .popup_manager
            .track_popup(PopupKind::Xdg(surface))
            .inspect_err(|e| log::warn!("Could not track xdg_popup: {e:?}"));
    }

    fn popup_destroyed(&mut self, _surface: PopupSurface) {
        self.popup_manager.cleanup();
    }

    fn grab(&mut self, surface: PopupSurface, seat: wl_seat::WlSeat, serial: Serial) {
        log::debug!(
            "xdg_popup.grab: surface={:?} serial={:?}",
            surface.wl_surface().id(),
            serial
        );

        let popup = PopupKind::Xdg(surface);

        let Ok(root_surface) = find_popup_root_surface(&popup) else {
            log::warn!("xdg_popup.grab: could not find popup root surface");
            return;
        };

        let Some(seat) = Seat::<Application>::from_resource(&seat) else {
            log::warn!("xdg_popup.grab: unknown seat");
            return;
        };

        let root_focus = root_surface;

        let Ok(mut grab) = self
            .popup_manager
            .grab_popup::<Application>(root_focus, popup, &seat, serial)
        else {
            log::debug!("xdg_popup.grab denied");
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

    // If the app requests fullscreen, make it fill the virtual output
    fn fullscreen_request(
        &mut self,
        surface: ToplevelSurface,
        _output: Option<wl_output::WlOutput>,
    ) {
        let size = self.output_logical_size(surface.wl_surface());

        surface.with_pending_state(|state| {
            state.bounds = Some(size);
            state.size = Some(size);
            state.states.set(xdg_toplevel::State::Fullscreen);
        });

        surface.send_configure();
        self.remember_toplevel_state(&surface, xdg_toplevel::State::Fullscreen, true);
    }

    // If the app requests maximize, make it fill the virtual output
    fn maximize_request(&mut self, surface: ToplevelSurface) {
        let size = self.output_logical_size(surface.wl_surface());

        surface.with_pending_state(|state| {
            state.bounds = Some(size);
            state.size = Some(size);
            state.states.set(xdg_toplevel::State::Maximized);
        });

        surface.send_configure();
        self.remember_toplevel_state(&surface, xdg_toplevel::State::Maximized, true);
    }

    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        let bounds = self.output_logical_size(surface.wl_surface());

        surface.with_pending_state(|state| {
            state.bounds = Some(bounds);
            state.size = None;
            state.states.unset(xdg_toplevel::State::Fullscreen);
        });

        surface.send_configure();
        self.remember_toplevel_state(&surface, xdg_toplevel::State::Fullscreen, false);
    }

    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        let bounds = self.output_logical_size(surface.wl_surface());

        surface.with_pending_state(|state| {
            state.bounds = Some(bounds);
            state.size = None;
            state.states.unset(xdg_toplevel::State::Maximized);
        });

        surface.send_configure();
        self.remember_toplevel_state(&surface, xdg_toplevel::State::Maximized, false);
    }

    // If the app requests minimize, hide its window
    fn minimize_request(&mut self, surface: ToplevelSurface) {
        if let Some(client) = surface.wl_surface().client() {
            self.wayvr_tasks
                .send(WayVRTask::MinimizeRequest(client.id(), surface.clone()));
        }
    }

    fn title_changed(&mut self, surface: ToplevelSurface) {
        if let Some(client) = surface.wl_surface().client() {
            self.wayvr_tasks
                .send(WayVRTask::TitleChange(client.id(), surface.clone()));
        }
    }

    fn app_id_changed(&mut self, surface: ToplevelSurface) {
        self.remember_app_id(&surface);
    }
}

impl ShmHandler for Application {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

impl FractionalScaleHandler for Application {
    /// Sends the scale currently advertised by the surface's output. The value
    /// is pre-set for newly created surfaces and replayed when the client creates
    /// the fractional-scale object; this call also covers reassigned surfaces.
    fn new_fractional_scale(&mut self, surface: WlSurface) {
        self.send_surface_scale(&surface);
    }
}

impl DmabufHandler for Application {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf_state.0
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        // Accept the buffer while a restart has no graphics device. Rejecting
        // the import here would disconnect the client; a commit made while the
        // device is unavailable releases that buffer so the client can redraw.
        if !self.image_importer.accepts_imports() {
            let _ = notifier.successful::<Self>();
            return;
        }

        match self.image_importer.import_dmabuf(&dmabuf) {
            Ok(_) => {
                let _ = notifier.successful::<Self>();
            }
            Err(e) => {
                log::warn!("wayland_server rejected DMA-buf import: {e:?}");
                notifier.failed();
            }
        }
    }
}

impl PrimarySelectionHandler for Application {
    fn primary_selection_state(&self) -> &PrimarySelectionState {
        &self.primary_selection_state
    }
}

impl selection_wlr::DataControlHandler for Application {
    fn data_control_state(&self) -> &selection_wlr::DataControlState {
        &self.wlr_data_control_state
    }
}

impl selection_ext::DataControlHandler for Application {
    fn data_control_state(&self) -> &selection_ext::DataControlState {
        &self.ext_data_control_state
    }
}
impl XdgDecorationHandler for Application {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        self.set_server_side_decorations(toplevel.wl_surface(), true);
        toplevel.with_pending_state(|state| {
            state.decoration_mode = Some(zxdg_toplevel_decoration_v1::Mode::ServerSide);
        });
        toplevel.send_configure();
    }

    fn request_mode(&mut self, toplevel: ToplevelSurface, mode: zxdg_toplevel_decoration_v1::Mode) {
        self.set_server_side_decorations(
            toplevel.wl_surface(),
            matches!(mode, zxdg_toplevel_decoration_v1::Mode::ServerSide),
        );
        toplevel.with_pending_state(|state| {
            state.decoration_mode = Some(mode);
        });
        toplevel.send_configure();
    }

    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        self.set_server_side_decorations(toplevel.wl_surface(), true);
        toplevel.with_pending_state(|state| {
            state.decoration_mode = Some(zxdg_toplevel_decoration_v1::Mode::ServerSide);
        });
        toplevel.send_configure();
    }
}

impl KdeDecorationHandler for Application {
    fn kde_decoration_state(&self) -> &KdeDecorationState {
        &self.kde_decoration_state
    }

    fn request_mode(
        &mut self,
        surface: &WlSurface,
        decoration: &org_kde_kwin_server_decoration::OrgKdeKwinServerDecoration,
        mode: wayland_server::WEnum<org_kde_kwin_server_decoration::Mode>,
    ) {
        let wayland_server::WEnum::Value(mode) = mode else {
            return;
        };

        self.set_server_side_decorations(
            surface,
            matches!(mode, org_kde_kwin_server_decoration::Mode::Server),
        );
        decoration.mode(mode);
    }
}

delegate_dmabuf!(Application);
delegate_xdg_shell!(Application);
delegate_compositor!(Application);
delegate_viewporter!(Application);
delegate_shm!(Application);
delegate_seat!(Application);
delegate_data_device!(Application);
// Do not use `delegate_output!`: smithay's `OutputManagerState` does not expose
// the output identity the per-client visibility filter needs, so
// `crate::output` dispatches `wl_output`. The macro also advertises xdg-output
// globals, which lunette does not expose.
delegate_primary_selection!(Application);
delegate_data_control!(Application);
delegate_ext_data_control!(Application);
delegate_xdg_decoration!(Application);
delegate_kde_decoration!(Application);
delegate_fractional_scale!(Application);
delegate_content_type!(Application);

/// The commit refuses a buffer whose transform is unknown before it gets here.
fn wl_transform_to_frame_transform(transform: wl_output::Transform) -> BufferTransform {
    BufferTransform::from_protocol(transform).unwrap_or_default()
}

/// Converts the protocol's non-exhaustive content-type hint to lunette's closed
/// set. Unknown future variants become [`ContentType::None`].
fn protocol_content_type(reported: wp_content_type_v1::Type) -> ContentType {
    match reported {
        wp_content_type_v1::Type::Photo => ContentType::Photo,
        wp_content_type_v1::Type::Video => ContentType::Video,
        wp_content_type_v1::Type::Game => ContentType::Game,
        _ => ContentType::None,
    }
}

/// Copies a `wl_shm` buffer's own pixels out of the client's pool.
///
/// The buffer starts at its offset in the pool, and the pool must hold its
/// whole stride and height from there. Only the buffer is copied, not the rest
/// of the pool.
fn copy_shm(buffer: &wl_buffer::WlBuffer) -> Result<(Vec<u8>, ShmLayout), String> {
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
            .and_then(|bytes| bytes.checked_add(offset))
            .filter(|needed| *needed <= length);
        let Some(needed) = needed else {
            return Err("a wl_shm buffer is smaller than its own stride implies".to_owned());
        };

        // SAFETY: `with_buffer_contents` guarantees the pointer addresses
        // `length` readable bytes of the client's pool for the duration of
        // this call, and the bounds check above keeps the slice inside it.
        let pixels = unsafe { std::slice::from_raw_parts(pointer.add(offset), needed - offset) };

        Ok((
            pixels.to_vec(),
            ShmLayout {
                size,
                stride,
                format,
            },
        ))
    });

    match outcome {
        Ok(gathered) => gathered,
        Err(error) => Err(format!("could not read a shared-memory buffer: {error}")),
    }
}
