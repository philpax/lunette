//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/comp.rs and backend/wayvr/mod.rs (the globals and output fragments), at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! The protocol handlers, and the `delegate_*!` macros that route into them.
//!
//! Split from [`crate::state::compositor`] rather than left beside it: the two
//! answer different questions, and together they are more than one file's worth.
//! Nothing here decides anything — each handler translates a protocol request
//! into a call on [`CompositorState`] and reports what happened.

use smithay::{
    backend::allocator::dmabuf::Dmabuf,
    delegate_compositor, delegate_dmabuf, delegate_kde_decoration, delegate_output, delegate_seat,
    delegate_shm, delegate_viewporter, delegate_xdg_decoration, delegate_xdg_shell,
    desktop::{
        PopupKeyboardGrab, PopupKind, PopupPointerGrab, PopupUngrabStrategy,
        find_popup_root_surface,
    },
    input::{
        Seat, SeatHandler, SeatState,
        pointer::{CursorImageStatus, Focus},
    },
    reexports::{
        wayland_protocols::xdg::{
            decoration::zv1::server::zxdg_toplevel_decoration_v1, shell::server::xdg_toplevel,
        },
        wayland_protocols_misc::server_decoration::server::org_kde_kwin_server_decoration,
        wayland_server::{
            Client, WEnum,
            protocol::{wl_buffer::WlBuffer, wl_seat, wl_surface::WlSurface},
        },
    },
    utils::Serial,
    wayland::{
        buffer::BufferHandler,
        compositor::{self, CompositorClientState},
        dmabuf::{DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier},
        output::OutputHandler,
        shell::{
            kde::decoration::{KdeDecorationHandler, KdeDecorationState},
            xdg::{
                PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
                decoration::XdgDecorationHandler,
            },
        },
        shm::{ShmHandler, ShmState},
    },
};
use tracing::{debug, info, warn};

use crate::{
    protocol::Event,
    state::compositor::{ClientState, CompositorState, toplevel_attribute, toplevel_state},
};

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
        let bounds = self.output_logical_size();
        let process = self.process_of(&wl_surface);
        let window = self.windows.insert(surface, id, process, bounds);
        info!(%window, "a toplevel was created");
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        self.output.leave(surface.wl_surface());
        self.forget_surface(surface.wl_surface());

        let Some(removed) = self.windows.remove(&surface) else {
            return;
        };
        self.touch();
        if removed.is_mapped() {
            self.report(Event::WindowClosed {
                window: removed.id(),
            });
        }
    }

    fn title_changed(&mut self, surface: ToplevelSurface) {
        let title = toplevel_attribute(&surface, |attributes| attributes.title.clone()).flatten();
        let Some(tracked) = self.windows.by_toplevel_mut(&surface) else {
            return;
        };
        if !tracked.set_title(title) {
            return;
        }

        let window = tracked.id();
        let title = tracked.title().unwrap_or_default().to_owned();
        self.touch();
        self.report(Event::TitleChanged { window, title });
    }

    fn app_id_changed(&mut self, surface: ToplevelSurface) {
        let app_id = toplevel_attribute(&surface, |attributes| attributes.app_id.clone()).flatten();
        if let Some(tracked) = self.windows.by_toplevel_mut(&surface)
            && tracked.set_app_id(app_id)
        {
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

        if let Some(state) = toplevel_state(state)
            && let Some(tracked) = self.windows.by_toplevel_mut(surface)
            && tracked.set_state(state, true)
        {
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

        if let Some(state) = toplevel_state(state)
            && let Some(tracked) = self.windows.by_toplevel_mut(surface)
            && tracked.set_state(state, false)
        {
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
