//! Applies the commands from the main thread and drains the tasks the
//! protocol handlers queue.
//!
//! Each command resolves its [`SeatId`] before delivery. An unknown seat is
//! refused; it is not routed to another seat. The delivery itself runs
//! through WayVR's input methods on [`WayVRCompositor`], one seat's view of
//! the state, in `src/wayvr/client.rs`. This module adds what lunette's
//! commands need beyond them: per-seat hover, keyboard focus, explicit
//! modifier state, typing text through a synthetic layout, and continuous
//! scrolling.
//!
//! [`Application::tick_events`] takes the place of upstream's `tick_events`.
//! It runs after each dispatch, before the clients are flushed, and turns the
//! handlers' [`WayVRTask`]s into lunette's window bookkeeping and events. A
//! new toplevel therefore receives its initial configure in the same loop
//! iteration that created it.

use std::{error::Error, fmt, rc::Rc, sync::Arc};

use glam::{DVec2, Vec2};
#[cfg(any(test, feature = "test-fakes"))]
use smithay::input::pointer::CursorImageStatus;
use smithay::{
    backend::input::{Axis, AxisSource},
    input::{Seat, keyboard::KeyboardTarget, pointer::AxisFrame},
    reexports::{
        wayland_protocols::xdg::shell::server::xdg_toplevel,
        wayland_server::protocol::wl_surface::WlSurface,
    },
    utils::SERIAL_COUNTER,
    wayland::{
        compositor::with_states,
        shell::xdg::{ToplevelSurface, XdgToplevelSurfaceData, XdgToplevelSurfaceRoleAttributes},
    },
};
use tracing::{debug, info, warn};

use crate::{
    config::DEFAULT_OUTPUT,
    keymap::XKB_KEYCODE_OFFSET,
    protocol::{
        Command, Event, KeyboardConfig, Keycode, KeymapText, ModifierState, PixelPoint, PixelSize,
        PointerButton, ScrollAxis, ScrollDelta, SeatId, SinkId, ToplevelState, ToplevelStates,
        WindowId,
    },
    seat::{self, MouseState},
    spawn,
    state::logical_size,
    thread::SnapshotParts,
    type_text::{self, TypePlan, TypeStep},
    wayvr::{
        WayVRTask,
        client::{WayVRCompositor, WheelDelta},
        comp::Application,
        hit_test::{self, WvrHitTarget},
        window::{CreateWindowParams, Window, size_constraints},
    },
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

        let windows = self.windows.mapped().map(Window::snapshot).collect();

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

impl Application {
    pub(crate) fn create_seat(&mut self, seat: SeatId, name: &str, keyboard: &KeyboardConfig) {
        match self.seats.create(
            &mut self.seat_state,
            &self.display_handle,
            seat,
            name,
            keyboard,
            &self.config.keymap_defaults,
        ) {
            Ok(entry) => {
                info!(seat = %entry.id(), name, "a seat was created");
                self.touch();
            }
            Err(error) => warn!(%error, "could not create a seat"),
        }
    }

    /// The compositor forwards every key event. Binding policy belongs to Lua,
    /// and the compositor must not swallow a key before the configuration sees
    /// it.
    pub(crate) fn press_key(&mut self, seat: SeatId, key: Keycode, pressed: bool) {
        let Some(mut compositor) = self.seat_view(seat) else {
            warn!(%seat, "a key was addressed to a seat that does not exist");
            return;
        };

        compositor.send_key(xkb_keycode(key), pressed);
        self.touch();
    }

    /// A key sent to a seat without focus reaches no client.
    pub(crate) fn set_focus(&mut self, seat: SeatId, sink: Option<SinkId>) {
        let Some(keyboard) = self
            .seats
            .get(seat)
            .map(|entry| entry.seat_keyboard.clone())
        else {
            warn!(%seat, "focus was addressed to a seat that does not exist");
            return;
        };

        let surface = match sink {
            Some(sink) => match self.windows.by_sink(sink) {
                Some(window) => Some(window.toplevel.wl_surface().clone()),
                None => {
                    debug!(%sink, "focus was asked for a sink that is already gone");
                    return;
                }
            },
            None => None,
        };

        let serial = SERIAL_COUNTER.next_serial();
        keyboard.set_focus(self, surface, serial);
    }

    /// Updates the modifier mask without synthesising key presses, which would
    /// misreport the state and send unsolicited key events.
    pub(crate) fn set_modifiers(&mut self, seat: SeatId, modifiers: &ModifierState) {
        let Some(handle) = self.seats.get(seat).map(|entry| entry.seat().clone()) else {
            warn!(%seat, "modifiers were addressed to a seat that does not exist");
            return;
        };
        let Some(mut compositor) = self.seat_view(seat) else {
            return;
        };

        compositor.apply_modifiers(&handle, modifiers);
        self.touch();
    }

    /// Types text the seat's layout may not be able to express.
    ///
    /// This method may upload a synthetic layout and attempts to restore the
    /// seat's layout before it returns. Do not interleave it with key events on
    /// the same seat.
    ///
    /// After a failure while typing, the method attempts to restore any
    /// synthetic layout already loaded. If that restore fails, the synthetic
    /// layout remains tracked, so later requests can repair it before native
    /// typing.
    pub(crate) fn type_text(&mut self, seat: SeatId, text: &str) {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "text was addressed to a seat that does not exist");
            return;
        };
        let handle = entry.seat().clone();
        let original = Arc::clone(entry.keymap().text());
        let held = seat::held(entry.seat_keyboard.modifier_state());

        // Track smithay's actual layout, including one left by a failed restore,
        // so native chunks are not typed against a stale synthetic layout.
        let mut loaded: Option<Arc<KeymapText>> = entry.uploaded().map(Arc::clone);

        let plan = match type_text::plan(text, entry.keymap(), type_text::SPARE_KEYCODES) {
            Ok(plan) => (!plan.is_empty()).then_some(plan),
            Err(error) => {
                warn!(%seat, %error, "text could not be typed");
                None
            }
        };

        // A failed restore can leave a synthetic layout loaded even when this
        // request produces no typing plan, so keep running to repair it.
        if plan.is_none() && loaded.is_none() {
            return;
        }

        let Some(mut compositor) = self.seat_view(seat) else {
            return;
        };

        for chunk in plan.iter().flat_map(TypePlan::chunks) {
            let wanted = chunk.keymap().map(|text| Arc::new(text.clone()));
            if loaded != wanted {
                let text = wanted.as_deref().unwrap_or(&original);
                match compositor.upload_keymap(text) {
                    Ok(()) => loaded = wanted,
                    Err(error) => {
                        warn!(%seat, %error, "a layout could not be uploaded while typing");
                        break;
                    }
                }
            }

            for step in chunk.steps() {
                match step {
                    TypeStep::Modifiers(modifiers) => {
                        compositor.apply_modifiers(&handle, modifiers);
                    }
                    TypeStep::Tap(key) => compositor.tap(*key),
                }
            }
        }

        if loaded.is_some() {
            match compositor.upload_keymap(&original) {
                Ok(()) => loaded = None,
                Err(error) => {
                    warn!(%seat, %error, "the seat's own layout could not be restored");
                }
            }
        }

        compositor.apply_modifiers(&handle, &held);
        if let Some(entry) = self.seats.get_mut(seat) {
            entry.set_uploaded(loaded);
        }
        self.touch();
    }

    /// Sends pointer and keyboard leave events before destroying the seat.
    /// Removing the keyboard capability alone does not send `wl_keyboard.leave`.
    pub(crate) fn destroy_seat(&mut self, seat: SeatId) {
        if self.seats.get(seat).is_none() {
            warn!(%seat, "a destroy was asked for a seat that does not exist");
            return;
        }

        self.move_pointer(seat, None);
        self.set_focus(seat, None);
        match self.seats.destroy(&self.display_handle, seat) {
            Ok(()) => {
                info!(%seat, "a seat was destroyed");
                self.touch();
            }
            Err(error) => warn!(%error, "could not destroy a seat"),
        }
    }

    /// Moves the seat's pointer onto a sink, or withdraws it.
    ///
    /// The relative motion is the distance from the seat's last position on the
    /// same window, and nothing when the pointer arrives from elsewhere, as
    /// upstream's `get_mouse_relative` has it.
    pub(crate) fn move_pointer(&mut self, seat: SeatId, target: Option<(SinkId, PixelPoint)>) {
        let Some(previous) = self.seats.get(seat).map(seat::SeatEntry::mouse) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return;
        };

        let focus = target.and_then(|(sink, position)| self.focus_at(sink, position));

        let hovered = target.and_then(|(sink, position)| {
            Some(MouseState {
                hovered: self.windows.by_sink(sink)?.id,
                position,
            })
        });
        let delta = match (previous, hovered) {
            (Some(previous), Some(hovered)) if previous.hovered == hovered.hovered => DVec2::new(
                hovered.position.x - previous.position.x,
                hovered.position.y - previous.position.y,
            ),
            _ => DVec2::ZERO,
        };
        if let Some(entry) = self.seats.get_mut(seat) {
            entry.set_mouse(hovered);
        }
        self.set_vr_pointer(seat);

        let global_pos = target.map_or(DVec2::new(-1.0, -1.0), |(_, position)| {
            DVec2::new(position.x, position.y)
        });

        if let Some(mut compositor) = self.seat_view(seat) {
            compositor.send_mouse_move(focus, global_pos, delta, delta);
        }
    }

    /// Returns the pointer target and its origin for the given point. smithay
    /// subtracts the origin for surface-local coordinates, so popup and
    /// subsurface events use their own frame.
    fn focus_at(&self, sink: SinkId, position: PixelPoint) -> Option<(WlSurface, Vec2)> {
        let window = self.windows.by_sink(sink)?;
        let toplevel = window.toplevel.wl_surface().clone();

        let size = window.size();
        let context =
            hit_test::build_hit_context(&toplevel, &self.popup_manager, [size.width, size.height]);

        #[expect(
            clippy::cast_possible_truncation,
            reason = "upstream's hit test works in f32, which is exact for any point on a window"
        )]
        let client_pos = Vec2::new(position.x as f32, position.y as f32);

        match context.hit_target_at(client_pos)? {
            WvrHitTarget::Toplevel { .. } => Some((toplevel, Vec2::ZERO)),
            WvrHitTarget::Surface {
                surface, origin, ..
            }
            | WvrHitTarget::Popup {
                surface, origin, ..
            } => Some((surface, origin)),
        }
    }

    pub(crate) fn press_button(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        button: PointerButton,
        pressed: bool,
    ) {
        if !self.pointer_over(seat, sink, "a button was pressed") {
            return;
        }
        self.set_vr_pointer_button(seat, pressed);
        if let Some(mut compositor) = self.seat_view(seat) {
            compositor.send_pointer_button(button, pressed);
        }
    }

    /// Sends one axis event in one `wl_pointer.frame`. A diagonal delta uses a
    /// separate call for each axis, so clients accumulate the components.
    ///
    /// Continuous and discrete deltas remain distinct. Clients use the
    /// difference for kinetic scrolling. A discrete delta carries both a
    /// distance and a step count, because clients older than version 5 receive
    /// `wl_pointer.axis` only.
    pub(crate) fn scroll(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        axis: ScrollAxis,
        delta: ScrollDelta,
    ) {
        if !self.pointer_over(seat, sink, "a scroll was sent") {
            return;
        }
        let Some(mut compositor) = self.seat_view(seat) else {
            return;
        };

        match delta {
            ScrollDelta::Continuous(distance) => {
                compositor.send_pointer_axis_continuous(axis, distance);
            }
            ScrollDelta::Discrete(steps) => {
                // smithay accumulates the v120 units and emits `axis_discrete`
                // for a client older than version 8. A partial detent is
                // preserved; it is not rounded away.
                let v120 = steps.saturating_mul(V120_PER_DETENT);
                compositor.send_pointer_axis_wheel_raw(match axis {
                    ScrollAxis::Vertical => WheelDelta { x: 0, y: v120 },
                    ScrollAxis::Horizontal => WheelDelta { x: v120, y: 0 },
                });
            }
        }
    }

    /// Whether the seat's pointer is over the named sink. The sink must be the
    /// surface currently under this seat's pointer; another seat's pointer
    /// does not qualify.
    fn pointer_over(&self, seat: SeatId, sink: SinkId, what: &'static str) -> bool {
        let Some(entry) = self.seats.get(seat) else {
            warn!(%seat, "input was addressed to a seat that does not exist");
            return false;
        };

        let Some(window) = self.windows.by_sink(sink).map(|window| window.id) else {
            debug!(%sink, "{what} over a sink that is already gone");
            return false;
        };

        match entry.mouse() {
            Some(mouse) if mouse.hovered == window => true,
            _ => {
                warn!(
                    %seat,
                    %sink,
                    "{what} over a sink the seat's pointer is not on; move it first"
                );
                false
            }
        }
    }

    /// Takes the named seat's view of the state, which the input methods run
    /// against, with the compositor clock read once for its timestamps.
    fn seat_view(&mut self, seat: SeatId) -> Option<WayVRCompositor<'_>> {
        let entry = self.seats.get(seat)?;
        let seat_keyboard = entry.seat_keyboard.clone();
        let seat_pointer = entry.seat_pointer.clone();
        let millis = self.millis();
        let micros = u64::try_from(self.elapsed().as_micros()).unwrap_or(u64::MAX);

        Some(WayVRCompositor {
            state: self,
            seat_keyboard,
            seat_pointer,
            serial_counter: &SERIAL_COUNTER,
            millis,
            micros,
        })
    }
}

impl WayVRCompositor<'_> {
    /// Routes all keymap changes through one path so the tracked layout stays
    /// synchronized with smithay's keyboard. Tests can inject a failure here
    /// because smithay normally rejects only an invalid layout, which the
    /// generator does not produce.
    fn upload_keymap(&mut self, text: &KeymapText) -> Result<(), KeymapUploadError> {
        #[cfg(any(test, feature = "test-fakes"))]
        if self.state.take_upload_failure() {
            return Err(KeymapUploadError::Injected);
        }

        self.set_keymap(text)
    }

    /// The press and release use different serials because a serial identifies
    /// an event. Reusing one would make them indistinguishable when a client
    /// quotes it back.
    fn tap(&mut self, key: Keycode) {
        self.send_key(xkb_keycode(key), true);
        self.send_key(xkb_keycode(key), false);
    }

    /// smithay updates its own modifier state without notifying the focused
    /// surface, so this sends the update separately.
    fn apply_modifiers(&mut self, handle: &Seat<Application>, modifiers: &ModifierState) {
        let keyboard = &self.seat_keyboard;
        if keyboard.set_modifier_state(seat::modifiers_state(modifiers)) == 0 {
            return;
        }
        if let Some(focus) = keyboard.current_focus() {
            let serial = self.serial_counter.next_serial();
            KeyboardTarget::modifiers(
                &focus,
                handle,
                self.state,
                keyboard.modifier_state(),
                serial,
            );
        }
    }

    /// A thumbstick has no release event, so `AxisSource::Finger` cannot
    /// represent its lifecycle, and a continuous scroll is reported as
    /// `AxisSource::Continuous`.
    fn send_pointer_axis_continuous(&mut self, axis: ScrollAxis, distance: f64) {
        let axis = match axis {
            ScrollAxis::Vertical => Axis::Vertical,
            ScrollAxis::Horizontal => Axis::Horizontal,
        };
        let frame = AxisFrame::new(self.millis)
            .source(AxisSource::Continuous)
            .value(axis, distance);

        self.seat_pointer.axis(self.state, frame);
        self.seat_pointer.frame(self.state);
    }
}

/// What `wl_pointer.axis_value120` counts per wheel detent.
const V120_PER_DETENT: i32 = 120;

/// The XKB keycode for an evdev keycode, which upstream's `send_key` takes.
fn xkb_keycode(key: Keycode) -> u32 {
    key.evdev().saturating_add(XKB_KEYCODE_OFFSET)
}

/// Describes a keymap upload failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum KeymapUploadError {
    /// Keeps smithay's diagnostic as text because its error type is not comparable.
    Refused { message: String },
    #[cfg(any(test, feature = "test-fakes"))]
    Injected,
}

impl fmt::Display for KeymapUploadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused { message } => write!(f, "keymap: smithay refused a layout: {message}"),
            #[cfg(any(test, feature = "test-fakes"))]
            Self::Injected => f.write_str("keymap: a test asked this upload to fail"),
        }
    }
}

impl Error for KeymapUploadError {}

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
