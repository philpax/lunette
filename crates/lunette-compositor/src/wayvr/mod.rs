//! Adapted from WayVR's `backend/wayvr/mod.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The files under this directory keep upstream's names and as much of its
//! text as lunette can, so that they diff against `backend/wayvr`.
//!
//! This file keeps upstream's fragments that lunette uses: the state's
//! construction from `WvrServerState::new`, the task queue the handlers fill,
//! and the per-surface buffer record. The drag-and-drop pointer tracking is
//! replaced by the per-seat record in `crate::drag`, because lunette's seats
//! are smithay's. lunette's compositor thread drains the task queue after
//! each dispatch, in `crate::commands`, where upstream's `tick_events` drained
//! it into overlays. The overlay, IPC, input-capture, and process-spawning parts of
//! `WvrServerState`, `image_importer.rs`, `input_capture.rs`, and `time.rs`
//! are left out; `crate::spawn` and the compositor clock replace the last
//! two that lunette needs.

pub mod client;
pub(crate) mod comp;
pub(crate) mod hit_test;
pub(crate) mod process;
pub(crate) mod window;

use comp::Application;
use smithay::{
    desktop::PopupManager,
    input::SeatState,
    reexports::{
        calloop::{LoopHandle, LoopSignal},
        wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration_manager as kde_decoration,
        wayland_server::{
            self, DisplayHandle,
            backend::ClientId,
            protocol::wl_buffer,
        },
    },
    utils::{Logical, Size},
    wayland::{
        compositor::{self, SurfaceData},
        content_type::ContentTypeState,
        dmabuf::{DmabufFeedbackBuilder, DmabufState},
        fractional_scale::FractionalScaleManagerState,
        relative_pointer::RelativePointerManagerState,
        selection::{
            data_device::DataDeviceState, ext_data_control as selection_ext,
            primary_selection::PrimarySelectionState, wlr_data_control as selection_wlr,
        },
        shell::{
            kde::decoration::KdeDecorationState,
            xdg::{ToplevelSurface, XdgShellState, decoration::XdgDecorationState},
        },
        shm::ShmState,
        single_pixel_buffer::SinglePixelBufferState,
        viewporter::ViewporterState,
    },
};
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet, VecDeque},
    time::Instant,
};
use tracing as log;

use crate::{
    config::{CompositorConfig, DEFAULT_OUTPUT, DEFAULT_SEAT, SEAT_NAME},
    output::OutputRegistry,
    pacing::FramePacer,
    protocol::{KeyboardConfig, PixelSize},
    seat::SeatRegistry,
    selection::{HostEvents, SelectionBridge},
    spawn::{AdoptedIds, ProcessInspector, ProcessSpawner},
    surface::{BufferImporter, BufferTransform, SurfaceRegistry},
    thread::{EventSender, LoopData, SnapshotPublisher},
    wayvr::{
        client::{Satellite, WaylandEnv},
        window::WindowManager,
    },
};

#[derive(Clone)]
pub enum WayVRTask {
    NewToplevel(ClientId, ToplevelSurface),
    DropToplevel(ClientId, ToplevelSurface),
    MinimizeRequest(ClientId, ToplevelSurface),
    TitleChange(ClientId, ToplevelSurface),
}

/// The tasks the handlers queue for the drain after dispatch.
///
/// Upstream's `SyncEventQueue` is shared with the overlay thread. lunette's
/// state owns its queue, and only the compositor thread touches it.
#[derive(Debug)]
pub struct TaskQueue<T> {
    queue: VecDeque<T>,
}

impl<T> Default for TaskQueue<T> {
    fn default() -> Self {
        Self {
            queue: VecDeque::new(),
        }
    }
}

impl<T> TaskQueue<T> {
    pub fn send(&mut self, task: T) {
        self.queue.push_back(task);
    }

    pub fn read(&mut self) -> Option<T> {
        self.queue.pop_front()
    }
}

/// What the compositor thread is given when it starts.
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

impl Application {
    /// Advertises the supported globals and returns their compositor state.
    ///
    /// Smithay also advertises `wl_subcompositor` when creating the compositor
    /// state, so this constructor cannot omit it.
    pub(crate) fn new(parts: StateParts<'_>) -> Self {
        const fn filter_allow_any(_: &wayland_server::Client) -> bool {
            true
        }
        let StateParts {
            display: dh,
            mut config,
            importer,
            mut spawner,
            inspector,
            events,
            snapshots,
            signal,
            loop_handle,
            host_selection,
        } = parts;
        log::info!("Initializing WayVR server");
        // Version 6 carries `wl_surface.preferred_buffer_scale`, which lets a
        // client learn its output's whole-number scale without binding a
        // `wl_output`. Lunette may deny that binding.
        let compositor = compositor::CompositorState::new_v6::<Application>(dh);
        let xdg_shell = XdgShellState::new::<Application>(dh);
        let mut seat_state = SeatState::new();
        // Advertise only `wl_shm`'s two mandatory formats. Supporting another
        // format requires corresponding importer support.
        let shm = ShmState::new::<Application>(dh, Vec::new());
        let data_device = DataDeviceState::new::<Application>(dh);
        let primary_selection_state = PrimarySelectionState::new::<Application>(dh);
        let mut seats = SeatRegistry::default();
        if let Err(error) = seats.create(
            &mut seat_state,
            dh,
            DEFAULT_SEAT,
            SEAT_NAME,
            &KeyboardConfig::default(),
            &config.keymap_defaults,
        ) {
            log::warn!(
                %error,
                "could not create the default seat; input will reach no client until one is made"
            );
        }

        // Every client may read and write both selections. The compositor hosts
        // the user's applications and does not impose a selection privilege
        // boundary.
        let ext_data_control_state = selection_ext::DataControlState::new::<Application, _>(
            dh,
            Some(&primary_selection_state),
            filter_allow_any,
        );
        let wlr_data_control_state = selection_wlr::DataControlState::new::<Application, _>(
            dh,
            Some(&primary_selection_state),
            filter_allow_any,
        );

        let xdg_decoration_state = XdgDecorationState::new::<Application>(dh);
        let kde_decoration_state =
            KdeDecorationState::new::<Application>(dh, kde_decoration::Mode::Server);
        let relative_pointer_state = RelativePointerManagerState::new::<Application>(dh);
        let viewporter = ViewporterState::new::<Application>(dh);
        // Fractional scale support requires the viewporter. Clients use an
        // integer buffer scale with a corrected logical destination.
        let fractional_scale = FractionalScaleManagerState::new::<Application>(dh);
        // Report content type without applying throttling policy in the compositor.
        let content_type = ContentTypeState::new::<Application>(dh);
        // WayVR handles single-pixel buffers but never advertises the global.
        let single_pixel_buffer = SinglePixelBufferState::new::<Application>(dh);

        let mut outputs = OutputRegistry::default();
        if let Err(error) = outputs.create(dh, DEFAULT_OUTPUT, config.output) {
            log::warn!(
                %error,
                "could not create the default output; a client assigned none will see no monitor"
            );
        }

        let formats = config.dmabuf.formats.clone();

        let dmabuf_state = config
            .dmabuf
            .main_device
            .and_then(|main_device| {
                DmabufFeedbackBuilder::new(main_device.get(), formats.iter().copied())
                    .build()
                    .ok()
            })
            .map_or_else(
                || {
                    log::info!("Falling back to zwp_linux_dmabuf_v1 version 3.");
                    let mut dmabuf_state = DmabufState::new();
                    let dmabuf_global = dmabuf_state.create_global::<Application>(dh, formats);
                    (dmabuf_state, dmabuf_global, None)
                },
                |default_feedback| {
                    let mut dmabuf_state = DmabufState::new();
                    let dmabuf_global = dmabuf_state
                        .create_global_with_default_feedback::<Application>(
                            dh,
                            &default_feedback,
                        );
                    (dmabuf_state, dmabuf_global, Some(default_feedback))
                },
            );

        let host = config.host_selection.take().and_then(|source| {
            source
                .open(host_selection)
                .inspect_err(|error| {
                    log::warn!(%error, "the host clipboard will not be bridged this session");
                })
                .ok()
        });

        let satellite = match config.display {
            Some(name) => Satellite::start(spawner.as_mut(), config.satellite.as_ref(), name),
            None => {
                log::debug!("no wayland socket was bound, so no x11 bridge is started");
                Satellite::default()
            }
        };

        let mut state = Application {
            outputs,
            image_importer: importer,
            display_handle: dh.clone(),
            compositor,
            xdg_shell,
            seats,
            seat_state,
            shm,
            data_device,
            primary_selection_state,
            wlr_data_control_state,
            ext_data_control_state,
            xdg_decoration_state,
            kde_decoration_state,
            relative_pointer_state,
            wayvr_tasks: TaskQueue::default(),
            dmabuf_state,
            popup_manager: PopupManager::default(),
            viewporter,
            no_server_decorations: HashSet::new(),
            pending_frame_callbacks: HashMap::new(),

            environment: config
                .display
                .map(WaylandEnv::environment)
                .unwrap_or_default(),
            config,
            selection: SelectionBridge::new(Some(DEFAULT_SEAT), host),
            content_type,
            fractional_scale,
            single_pixel_buffer,
            spawner,
            inspector,
            surfaces: SurfaceRegistry::default(),
            windows: WindowManager::new(),
            processes: Default::default(),
            adopted_ids: AdoptedIds::default(),
            clients: Vec::new(),
            assignments: HashMap::new(),
            process_poll: None,
            loop_handle,
            satellite,
            pacing: FramePacer::default(),
            pacing_wakeup: None,
            #[cfg(any(test, feature = "test-fakes"))]
            failing_uploads: std::cell::Cell::new((0, 0)),
            started: Instant::now(),
            #[cfg(any(test, feature = "test-fakes"))]
            clock_offset: std::time::Duration::ZERO,
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
}

/// The size of an image lunette imported from a client buffer.
///
/// Upstream keeps the image itself. lunette's images belong to the frame
/// thread, which receives each one in `Event::BufferImported`, so the
/// compositor keeps only the extent it needs for sizes and hit tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImportedExtent {
    pub size: PixelSize,
}

impl ImportedExtent {
    pub const fn extent_2d(&self) -> [u32; 2] {
        [self.size.width, self.size.height]
    }
}

struct SurfaceBufWithImageContainer {
    inner: RefCell<Option<SurfaceBufWithImage>>,
    retained_dmabuf_buffer: RefCell<Option<wl_buffer::WlBuffer>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(dead_code)]
pub struct SurfaceBufWithImage {
    pub image: ImportedExtent,
    pub transform: BufferTransform,
    pub scale: i32,
    pub dmabuf: bool,
    pub has_alpha: bool,
}

impl SurfaceBufWithImage {
    /// Logical size of wl_surface after buffer transform, scaling and wp_viewport
    pub fn logical_size(&self, surface_data: &SurfaceData) -> Size<i32, Logical> {
        use smithay::wayland::viewporter::ViewportCachedState;

        let extent = self.oriented_extent();
        let scale = self.scale.max(1) as u32;
        let buffer_size = Size::new(
            (extent[0] / scale).max(1) as i32,
            (extent[1] / scale).max(1) as i32,
        );

        let mut guard = surface_data.cached_state.get::<ViewportCachedState>();
        guard.current().size().unwrap_or(buffer_size)
    }

    /// Normalized source rectangle in backing image cropped by wp_viewport
    pub fn source_uv(&self, surface_data: &SurfaceData) -> [f32; 4] {
        use smithay::wayland::viewporter::ViewportCachedState;

        let extent = self.oriented_extent();
        let scale = self.scale.max(1) as f64;
        let buffer_w = (extent[0] as f64 / scale).max(1.0);
        let buffer_h = (extent[1] as f64 / scale).max(1.0);

        let mut guard = surface_data.cached_state.get::<ViewportCachedState>();
        let viewport = *guard.current();
        let Some(src) = viewport.src else {
            return [0.0, 0.0, 1.0, 1.0];
        };

        let u0 = (src.loc.x / buffer_w).clamp(0.0, 1.0) as f32;
        let v0 = (src.loc.y / buffer_h).clamp(0.0, 1.0) as f32;
        let u1 = ((src.loc.x + src.size.w) / buffer_w).clamp(0.0, 1.0) as f32;
        let v1 = ((src.loc.y + src.size.h) / buffer_h).clamp(0.0, 1.0) as f32;
        [u0, v0, u1, v1]
    }

    /// The image's extent in surface axes. A quarter turn exchanges the
    /// buffer's axes, which upstream does not account for.
    pub const fn oriented_extent(&self) -> [u32; 2] {
        let extent = self.image.extent_2d();
        if self.transform.swaps_axes() {
            [extent[1], extent[0]]
        } else {
            extent
        }
    }

    fn apply_to_surface(
        self,
        surface_data: &SurfaceData,
        retained_buffer: Option<wl_buffer::WlBuffer>,
    ) -> Option<wl_buffer::WlBuffer> {
        if let Some(container) = surface_data.data_map.get::<SurfaceBufWithImageContainer>() {
            container.inner.replace(Some(self));
            container.retained_dmabuf_buffer.replace(retained_buffer)
        } else {
            surface_data
                .data_map
                .insert_if_missing(|| SurfaceBufWithImageContainer {
                    inner: RefCell::new(Some(self)),
                    retained_dmabuf_buffer: RefCell::new(retained_buffer),
                });
            None
        }
    }

    pub fn get_from_surface(surface_data: &SurfaceData) -> Option<Self> {
        surface_data
            .data_map
            .get::<SurfaceBufWithImageContainer>()
            .and_then(|x| x.inner.borrow().clone())
    }

    /// Clears the surface's content after a null-buffer commit or its
    /// destruction, and returns the retained buffer for the caller to release.
    pub fn remove_from_surface(surface_data: &SurfaceData) -> Option<wl_buffer::WlBuffer> {
        let container = surface_data
            .data_map
            .get::<SurfaceBufWithImageContainer>()?;
        container.inner.replace(None);
        container.retained_dmabuf_buffer.replace(None)
    }

    /// The dmabuf the surface still samples, which a graphics restart imports
    /// again without a client commit.
    pub fn retained_buffer(surface_data: &SurfaceData) -> Option<wl_buffer::WlBuffer> {
        surface_data
            .data_map
            .get::<SurfaceBufWithImageContainer>()
            .and_then(|x| x.retained_dmabuf_buffer.borrow().clone())
    }

    /// Stops retaining the surface's dmabuf, keeping its recorded size, and
    /// returns the buffer for the caller to release.
    pub fn take_retained_buffer(surface_data: &SurfaceData) -> Option<wl_buffer::WlBuffer> {
        surface_data
            .data_map
            .get::<SurfaceBufWithImageContainer>()
            .and_then(|x| x.retained_dmabuf_buffer.replace(None))
    }
}
