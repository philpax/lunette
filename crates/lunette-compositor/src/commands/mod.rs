//! Applies the commands from the main thread and drains the tasks the
//! protocol handlers queue.
//!
//! [`Application::handle`] dispatches each [`Command`]. The seat and input
//! commands are in `input.rs`, and the process commands with their poll timer
//! are in `processes.rs`. The output, pacing, selection, and graphics commands
//! are beside the state they change, in `src/output.rs`, `src/pacing.rs`,
//! `src/selection/seat.rs`, and `src/graphics.rs`.
//!
//! [`Application::tick_events`] takes the place of upstream's `tick_events`.
//! It runs after each dispatch, before the clients are flushed, and turns the
//! handlers' [`WayVRTask`]s into lunette's window bookkeeping and events. A
//! new toplevel therefore receives its initial configure in the same loop
//! iteration that created it.

mod input;
mod processes;
#[cfg(test)]
mod tests;

use std::rc::Rc;

#[cfg(any(test, feature = "test-fakes"))]
use smithay::input::pointer::CursorImageStatus;
use smithay::{
    reexports::wayland_protocols::xdg::shell::server::xdg_toplevel,
    wayland::{
        compositor::with_states,
        shell::xdg::{ToplevelSurface, XdgToplevelSurfaceData, XdgToplevelSurfaceRoleAttributes},
    },
};
use tracing::{debug, info};

pub(crate) use crate::commands::input::KeymapUploadError;
#[cfg(any(test, feature = "test-fakes"))]
use crate::protocol::SeatId;
use crate::{
    config::DEFAULT_OUTPUT,
    output::logical_size,
    protocol::{Command, Event, PixelSize, ToplevelState, ToplevelStates, WindowId},
    spawn,
    thread::SnapshotParts,
    wayvr::{WayVRTask, comp::Application, window::CreateWindowParams},
    window::size_constraints,
};

impl Application {
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

    /// Drains the tasks the protocol handlers queued during dispatch.
    pub(crate) fn tick_events(&mut self) {
        while let Some(task) = self.wayvr_tasks.read() {
            match task {
                WayVRTask::NewToplevel(_client_id, toplevel) => self.create_window(toplevel),
                WayVRTask::DropToplevel(_client_id, toplevel) => self.drop_window(&toplevel),
                WayVRTask::MinimizeRequest(_client_id, _toplevel) => {
                    debug!("a client asked to be minimized; lunette leaves its panel to Lua");
                }
                WayVRTask::TitleChange(_client_id, toplevel) => self.remember_title(&toplevel),
                WayVRTask::DndStarted { icon, pointer } => {
                    debug!(seat = %pointer, icon = icon.is_some(), "a client started a drag");
                }
                WayVRTask::DndDropped => debug!("a client's drag ended"),
            }
        }
    }

    /// Registers a new toplevel as a window and sends its initial configure.
    /// A client cannot attach a buffer before it receives one.
    fn create_window(&mut self, toplevel: ToplevelSurface) {
        // A toplevel destroyed in the same dispatch is never a window.
        if !toplevel.alive() {
            return;
        }
        let wl_surface = toplevel.wl_surface().clone();
        let output_bounds = self.output_logical_size(&wl_surface);

        toplevel.with_pending_state(|state| {
            state.bounds = Some(output_bounds);
        });
        toplevel.send_configure();

        let (min_size, max_size) = size_constraints(&toplevel, output_bounds);
        let surface = self.surfaces.id_for(&wl_surface);
        let process = self.process_of(&wl_surface);
        let output = self.output_of(&wl_surface);
        let handle = self.windows.create_window(CreateWindowParams {
            toplevel: Rc::new(toplevel.clone()),
            process,
            bounds: output_bounds,
            min_size,
            max_size,
            size_x: 0,
            size_y: 0,
            surface,
            output,
        });

        let title = toplevel_attribute(&toplevel, |attributes| attributes.title.clone()).flatten();
        let app_id =
            toplevel_attribute(&toplevel, |attributes| attributes.app_id.clone()).flatten();
        let window = &mut self.windows.windows[handle];
        window.set_title(title);
        window.set_app_id(app_id);
        info!(window = %window.id, "a toplevel was created");
    }

    pub(crate) fn drop_window(&mut self, toplevel: &ToplevelSurface) {
        let Some(removed) = self
            .windows
            .find_window_handle(toplevel)
            .and_then(|handle| self.windows.remove_window(handle))
        else {
            return;
        };
        self.touch();
        if removed.mapped {
            self.report(Event::WindowClosed { window: removed.id });
        }
    }

    fn remember_title(&mut self, toplevel: &ToplevelSurface) {
        let title = toplevel_attribute(toplevel, |attributes| attributes.title.clone()).flatten();
        let Some(tracked) = self.windows.by_toplevel_mut(toplevel) else {
            return;
        };
        if !tracked.set_title(title) {
            return;
        }

        let window = tracked.id;
        let title = tracked.title.clone().unwrap_or_default();
        self.touch();
        self.report(Event::TitleChanged { window, title });
    }

    /// Records a changed app id. A toplevel that is not yet a window reads its
    /// app id when the window is created.
    pub(crate) fn remember_app_id(&mut self, toplevel: &ToplevelSurface) {
        let app_id = toplevel_attribute(toplevel, |attributes| attributes.app_id.clone()).flatten();
        if let Some(tracked) = self.windows.by_toplevel_mut(toplevel)
            && tracked.set_app_id(app_id)
        {
            self.touch();
        }
    }

    /// Records a fullscreen or maximized state the compositor granted, for the
    /// snapshot.
    pub(crate) fn remember_toplevel_state(
        &mut self,
        toplevel: &ToplevelSurface,
        state: xdg_toplevel::State,
        held: bool,
    ) {
        if let Some(state) = toplevel_state(state)
            && let Some(tracked) = self.windows.by_toplevel_mut(toplevel)
            && tracked.set_state(state, held)
        {
            self.touch();
        }
    }

    /// Sends a close request without killing the client or removing the window.
    ///
    /// The client may refuse the request. The window disappears after the
    /// client destroys the toplevel.
    fn close_window(&mut self, window: WindowId) {
        let Some(tracked) = self.windows.get(window) else {
            debug!(%window, "a close was asked for a window that is already gone");
            return;
        };
        tracked.toplevel.send_close();
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
                .map_or(DEFAULT_OUTPUT, |window| window.output),
        );
        let Some(tracked) = self.windows.get_mut(window) else {
            debug!(%window, "a configure was asked for a window that is already gone");
            return;
        };

        // Set the pending states before requesting the size, so both are sent
        // in the same configure.
        tracked.toplevel.with_pending_state(|pending| {
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

        let windows = self
            .windows
            .mapped()
            .map(|window| {
                window.snapshot(self.has_server_side_decorations(window.toplevel.wl_surface()))
            })
            .collect();

        self.snapshots.publish(SnapshotParts {
            windows,
            processes: spawn::snapshot(&self.processes),
            outputs: self.outputs.snapshot(),
            seats: self.seats.snapshot(self.selection.seat()),
        });
    }

    pub(crate) fn touch(&mut self) {
        self.dirty = true;
    }

    /// Sweeps imported images after dispatch may have dropped a client's `wl_buffer`
    /// reference.
    ///
    /// Sweeping on a new import alone retains images from clients that have
    /// disconnected or stopped sending requests.
    pub(crate) fn sweep_imports(&mut self) {
        self.image_importer.sweep();
    }

    pub(crate) fn report(&self, event: Event) {
        if self.events.send(event).is_err() {
            debug!("the main thread is gone; dropping an event");
        }
    }
}

#[cfg(any(test, feature = "test-fakes"))]
impl Application {
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
    /// The normal upload path rejects invalid layouts alone, so tests cannot
    /// provoke a failure at the point needed to exercise restoration of an
    /// existing keymap.
    pub(crate) fn fail_keymap_uploads(&self, skip: usize, count: usize) {
        self.failing_uploads.set((skip, count));
    }

    pub(crate) fn take_upload_failure(&self) -> bool {
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

/// Reads a role attribute that the client sets, such as its title or app id.
///
/// A poisoned role-attribute mutex yields `None`; an earlier panic is not
/// propagated through the dispatch loop.
pub(crate) fn toplevel_attribute<T>(
    surface: &ToplevelSurface,
    read: impl FnOnce(&XdgToplevelSurfaceRoleAttributes) -> T,
) -> Option<T> {
    with_states(surface.wl_surface(), |states| {
        let attributes = states.data_map.get::<XdgToplevelSurfaceData>()?;
        let guard = attributes.lock().ok()?;
        Some(read(&guard))
    })
}

pub(crate) const fn protocol_state(state: ToplevelState) -> xdg_toplevel::State {
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
/// version has no counterpart and is reported as absent.
pub(crate) fn toplevel_state(state: xdg_toplevel::State) -> Option<ToplevelState> {
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
