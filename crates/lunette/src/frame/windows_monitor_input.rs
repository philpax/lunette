//! Routes shared monitor gestures through the Windows desktop seat.

use std::collections::HashMap;

use lunette_capture::{
    hid::PanelPoint,
    monitor::MonitorKey,
    windows::{self, MonitorId},
};
use lunette_compositor::protocol::{PointerButton, SeatId};

use super::{
    DesktopInput, PointerInput, ScanCode, ScrollAxis, WindowId, native_button, release, report,
};
use crate::{lua::monitor_input::MonitorInput, mirrors::WindowsMirrors};

#[derive(Debug, Default)]
pub(super) struct MonitorSeat {
    pub(super) pointers: HashMap<SeatId, (MonitorKey, PanelPoint)>,
    pub(super) drag: Option<(SeatId, MonitorKey, WindowId)>,
    pub(super) focus: Option<(SeatId, MonitorKey, WindowId)>,
}

impl MonitorSeat {
    pub(super) fn clear_inactive(&mut self, mirrors: &WindowsMirrors) {
        self.pointers
            .retain(|_, (monitor, _)| mirrors.input_target(monitor).is_some());
        if self
            .focus
            .as_ref()
            .is_some_and(|(_, monitor, _)| mirrors.input_target(monitor).is_none())
        {
            self.focus = None;
        }
    }

    pub(super) fn has_focus(&self, mirrors: &WindowsMirrors) -> bool {
        self.focus.as_ref().is_some_and(|(seat, monitor, _)| {
            self.focused_window(*seat, monitor, mirrors).is_some()
        })
    }

    pub(super) fn lost_drag(&self, mirrors: &WindowsMirrors) -> bool {
        self.drag.as_ref().is_some_and(|(_, monitor, window)| {
            mirrors.input_target(monitor).is_none() || !windows::is_foreground(*window)
        })
    }

    fn focused_window(
        &self,
        seat: SeatId,
        monitor: &MonitorKey,
        mirrors: &WindowsMirrors,
    ) -> Option<WindowId> {
        let (owner, key, window) = self.focus.as_ref()?;
        if *owner != seat || key != monitor {
            return None;
        }
        let display = mirrors.input_target(monitor)?;
        windows::monitor_focused(&display, *window).then_some(*window)
    }

    fn send_pointer(
        &self,
        seat: SeatId,
        monitor: &MonitorKey,
        display: &MonitorId,
        action: PointerInput,
    ) -> Option<WindowId> {
        let (hover, hit) = self.pointers.get(&seat)?;
        if hover != monitor {
            return None;
        }
        let held = match &self.drag {
            Some((owner, drag, _)) if *owner != seat || drag != monitor => return None,
            Some((_, _, window)) => Some(*window),
            None => None,
        };
        windows::monitor_pointer(display, *hit, held, action)
            .inspect_err(|error| tracing::debug!(%error, "Windows monitor input could not be sent"))
            .ok()
            .flatten()
    }
}

impl DesktopInput {
    pub(in crate::frame) fn apply_monitor(
        &mut self,
        seat: SeatId,
        monitor: MonitorKey,
        input: MonitorInput,
        mirrors: &WindowsMirrors,
    ) {
        match input {
            MonitorInput::Leave => {
                if self
                    .monitor
                    .pointers
                    .get(&seat)
                    .is_some_and(|(hover, _)| *hover == monitor)
                {
                    self.monitor.pointers.remove(&seat);
                }
                if self
                    .monitor
                    .drag
                    .as_ref()
                    .is_some_and(|(owner, drag, _)| *owner == seat && *drag == monitor)
                {
                    self.release_buttons();
                }
            }
            MonitorInput::Point(hit) => {
                let Some(display) = mirrors.input_target(&monitor) else {
                    return;
                };
                self.monitor.pointers.insert(seat, (monitor.clone(), hit));
                if self
                    .monitor
                    .drag
                    .as_ref()
                    .is_some_and(|(owner, drag, _)| *owner == seat && *drag == monitor)
                    && self
                        .monitor
                        .send_pointer(seat, &monitor, &display, PointerInput::Move)
                        .is_none()
                {
                    self.release_buttons();
                }
            }
            MonitorInput::Button(button, pressed) => {
                self.monitor_button(seat, monitor, button, pressed, mirrors)
            }
            MonitorInput::Wheel(delta) => {
                if self.drag.is_some() {
                    return;
                }
                if let Some(display) = mirrors.input_target(&monitor) {
                    for (axis, ticks) in [
                        (ScrollAxis::Vertical, (-delta.y * 120.0).round() as i32),
                        (ScrollAxis::Horizontal, (delta.x * 120.0).round() as i32),
                    ] {
                        if ticks != 0 {
                            self.monitor.send_pointer(
                                seat,
                                &monitor,
                                &display,
                                PointerInput::Scroll(axis, ticks),
                            );
                        }
                    }
                }
            }
            MonitorInput::Key(key, pressed) => {
                if let Some(key) = ScanCode::from_evdev(key)
                    && let Some(window) = self.monitor.focused_window(seat, &monitor, mirrors)
                {
                    self.key(Some(window), key, pressed);
                }
            }
            MonitorInput::Modifiers(modifiers) => {
                if let Some(window) = self.monitor.focused_window(seat, &monitor, mirrors) {
                    self.set_modifiers(Some(window), &modifiers);
                }
            }
            MonitorInput::Text(text) => {
                if let Some(window) = self.monitor.focused_window(seat, &monitor, mirrors) {
                    report(windows::type_text(window, &text));
                }
            }
        }
    }

    fn monitor_button(
        &mut self,
        seat: SeatId,
        monitor: MonitorKey,
        button: PointerButton,
        pressed: bool,
        mirrors: &WindowsMirrors,
    ) {
        let button = native_button(button);
        if !pressed {
            if self
                .monitor
                .drag
                .as_ref()
                .is_some_and(|(owner, drag, _)| *owner == seat && *drag == monitor)
                && self.pressed.remove(&button)
            {
                release(windows::release_button(button));
                if self.pressed.is_empty() {
                    self.monitor.drag = None;
                }
            }
            return;
        }
        if self.drag.is_some() || self.pressed.contains(&button) {
            return;
        }
        if let Some(display) = mirrors.input_target(&monitor)
            && let Some(window) =
                self.monitor
                    .send_pointer(seat, &monitor, &display, PointerInput::Press(button))
        {
            if self.focused.take().is_some()
                || !self
                    .monitor
                    .focus
                    .as_ref()
                    .is_some_and(|(owner, key, old)| {
                        *owner == seat && *key == monitor && *old == window
                    })
            {
                self.release_keys();
            }
            self.pressed.insert(button);
            self.monitor.drag = Some((seat, monitor.clone(), window));
            self.monitor.focus = Some((seat, monitor, window));
        }
    }
}
