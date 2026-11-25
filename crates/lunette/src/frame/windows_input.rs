//! Routes Lunette's logical seats to the single Windows pointer and keyboard.

#[path = "windows_monitor_input.rs"]
mod monitor;

use std::{
    collections::{BTreeSet, HashMap},
    mem,
};

use lunette_capture::windows::{self, Button, PointerInput, ScanCode, WindowId};
use lunette_compositor::protocol::{
    Command, KeyModifier, Keycode, ModifierState, PixelPoint, PixelSize, PointerButton,
    SURFACE_UNITS_PER_DETENT, ScrollAxis, ScrollDelta, SeatId, SinkId,
};
use tracing::{debug, warn};

use crate::mirrors::WindowsMirrors;

type Target = (WindowId, PixelSize);

#[derive(Debug, Default)]
pub(super) struct DesktopInput {
    pointers: HashMap<SeatId, (SinkId, PixelPoint)>,
    focused: Option<(SeatId, SinkId)>,
    pressed: BTreeSet<Button>,
    drag: Option<(SeatId, SinkId)>,
    monitor: monitor::MonitorSeat,
    keys: BTreeSet<ScanCode>,
    modifiers: BTreeSet<ScanCode>,
}

impl DesktopInput {
    pub(super) fn check_focus(
        &mut self,
        target: impl Fn(SinkId) -> Option<Target>,
        mirrors: &WindowsMirrors,
    ) {
        let foreground =
            |sink| target(sink).is_some_and(|(window, _)| windows::is_foreground(window));
        self.monitor.clear_inactive(mirrors);
        if !self.focused.is_some_and(|(_, sink)| foreground(sink))
            && !self.monitor.has_focus(mirrors)
        {
            self.release_keys();
        }
        if self.drag.is_some_and(|(_, sink)| !foreground(sink)) || self.monitor.lost_drag(mirrors) {
            self.release_buttons();
        }
    }

    pub(super) fn apply(
        &mut self,
        command: Command,
        target: impl Fn(SinkId) -> Option<Target>,
        known: impl Fn(SeatId) -> bool,
    ) {
        match command {
            Command::Pointer {
                seat,
                sink,
                position,
            } if known(seat) => {
                let Some(window) = target(sink) else { return };
                self.pointers.insert(seat, (sink, position));
                if self.drag == Some((seat, sink)) && !point(window, position, PointerInput::Move) {
                    self.release_buttons();
                }
            }
            Command::PointerLeave { seat } => {
                self.pointers.remove(&seat);
                if self.drag.is_some_and(|(owner, _)| owner == seat) {
                    self.release_buttons();
                }
            }
            Command::Button {
                seat,
                sink,
                button,
                pressed,
            } if known(seat) => {
                self.button(seat, sink, button, pressed, target(sink));
            }
            Command::Scroll {
                seat,
                sink,
                axis,
                delta,
            } if known(seat) => {
                if let (Some(&(hover, hit)), Some(window)) =
                    (self.pointers.get(&seat), target(sink))
                    && hover == sink
                    && self.drag.is_none_or(|drag| drag == (seat, sink))
                    && self.monitor.drag.is_none()
                {
                    let ticks = wheel_ticks(axis, delta);
                    if ticks != 0 {
                        point(window, hit, PointerInput::Scroll(axis, ticks));
                    }
                }
            }
            Command::Focus { seat, sink } if known(seat) => {
                if let Some(sink) = sink {
                    if self.drag.is_some_and(|drag| drag != (seat, sink))
                        || self.monitor.drag.is_some()
                    {
                        return;
                    }
                    let Some((window, _)) = target(sink) else {
                        return;
                    };
                    self.set_window_focus(seat, sink);
                    windows::focus(window);
                } else if self.focused.is_some_and(|(owner, _)| owner == seat) {
                    self.focused = None;
                    self.release_keys();
                }
            }
            Command::Key { seat, key, pressed } => {
                if let Some(key) = ScanCode::from_evdev(key)
                    && let Some(window) = self.window_focus(seat, &target)
                {
                    self.key(Some(window), key, pressed);
                }
            }
            Command::Modifiers { seat, modifiers } => {
                if let Some(window) = self.window_focus(seat, &target) {
                    self.set_modifiers(Some(window), &modifiers);
                }
            }
            Command::TypeText { seat, text } => {
                if let Some(window) = self.window_focus(seat, &target) {
                    report(windows::type_text(window, &text));
                }
            }
            _ => {}
        }
    }

    fn button(
        &mut self,
        seat: SeatId,
        sink: SinkId,
        button: PointerButton,
        pressed: bool,
        target: Option<Target>,
    ) {
        let button = native_button(button);

        if !pressed {
            if self.drag == Some((seat, sink)) && self.pressed.remove(&button) {
                release(windows::release_button(button));
                if self.pressed.is_empty() {
                    self.drag = None;
                }
            }
            return;
        }

        if let (Some(&(hover, hit)), Some(window)) = (self.pointers.get(&seat), target)
            && hover == sink
            && self.drag.is_none_or(|drag| drag == (seat, sink))
            && self.monitor.drag.is_none()
            && !self.pressed.contains(&button)
            && point(window, hit, PointerInput::Press(button))
        {
            self.pressed.insert(button);
            self.drag = Some((seat, sink));
            self.set_window_focus(seat, sink);
        }
    }

    fn window_focus(
        &self,
        seat: SeatId,
        target: impl Fn(SinkId) -> Option<Target>,
    ) -> Option<WindowId> {
        let (owner, sink) = self.focused?;
        if owner != seat {
            return None;
        }
        target(sink).map(|(window, _)| window)
    }

    fn set_window_focus(&mut self, seat: SeatId, sink: SinkId) {
        if self.monitor.focus.take().is_some() || self.focused != Some((seat, sink)) {
            self.release_keys();
        }
        self.focused = Some((seat, sink));
    }

    fn key(&mut self, window: Option<WindowId>, key: ScanCode, pressed: bool) {
        if pressed {
            if let Some(window) = window
                && (self.modifiers.contains(&key) && windows::is_foreground(window)
                    || !self.modifiers.contains(&key) && report(key.press(window)))
            {
                self.keys.insert(key);
            }
        } else if self.keys.remove(&key) && !self.modifiers.contains(&key) {
            release(key.release());
        }
    }

    fn set_modifiers(&mut self, window: Option<WindowId>, modifiers: &ModifierState) {
        let wanted: BTreeSet<_> = modifiers
            .iter()
            .filter_map(|modifier| scan_modifier(*modifier))
            .collect();
        self.modifiers.retain(|key| {
            if wanted.contains(key) {
                true
            } else {
                if !self.keys.contains(key) {
                    release(key.release());
                }
                false
            }
        });
        if let Some(window) = window.filter(|window| windows::is_foreground(*window)) {
            for key in wanted {
                if !self.modifiers.contains(&key)
                    && (self.keys.contains(&key) || report(key.press(window)))
                {
                    self.modifiers.insert(key);
                }
            }
        }
    }

    pub(super) fn window_changed(&mut self, sink: SinkId, closed: bool) {
        self.pointers.retain(|_, (hover, _)| *hover != sink);
        if self.drag.is_some_and(|(_, drag)| drag == sink) {
            self.release_buttons();
        }
        if closed && self.focused.is_some_and(|(_, focus)| focus == sink) {
            self.focused = None;
            self.release_keys();
        }
    }

    pub(super) fn remove_seat(&mut self, seat: SeatId) {
        self.pointers.remove(&seat);
        self.monitor.pointers.remove(&seat);
        if self.drag.is_some_and(|(owner, _)| owner == seat)
            || self
                .monitor
                .drag
                .as_ref()
                .is_some_and(|(owner, _, _)| *owner == seat)
        {
            self.release_buttons();
        }
        if self.focused.is_some_and(|(owner, _)| owner == seat) {
            self.focused = None;
            self.release_keys();
        }
        if self
            .monitor
            .focus
            .as_ref()
            .is_some_and(|(owner, _, _)| *owner == seat)
        {
            self.monitor.focus = None;
            self.release_keys();
        }
    }

    pub(super) fn reset(&mut self) {
        self.release_keys();
        self.release_buttons();
        self.pointers.clear();
        self.focused = None;
        self.monitor = monitor::MonitorSeat::default();
    }

    fn release_buttons(&mut self) {
        for button in mem::take(&mut self.pressed) {
            release(windows::release_button(button));
        }
        self.drag = None;
        self.monitor.drag = None;
    }

    fn release_keys(&mut self) {
        let keys = mem::take(&mut self.keys);
        let modifiers = mem::take(&mut self.modifiers);
        for key in keys.union(&modifiers) {
            release(key.release());
        }
    }
}

fn native_button(button: PointerButton) -> Button {
    match button {
        PointerButton::Left => Button::Left,
        PointerButton::Middle => Button::Middle,
        PointerButton::Right => Button::Right,
        PointerButton::Back => Button::Back,
        PointerButton::Forward => Button::Forward,
    }
}

fn scan_modifier(modifier: KeyModifier) -> Option<ScanCode> {
    let evdev = match modifier {
        KeyModifier::Shift => 42,
        KeyModifier::Control => 29,
        KeyModifier::Alt => 56,
        KeyModifier::Logo => 125,
        KeyModifier::Mod5 => 100,
        // Lock keys belong to the host's keyboard state.
        KeyModifier::CapsLock | KeyModifier::NumLock | KeyModifier::Mod3 => return None,
    };
    ScanCode::from_evdev(Keycode::from_evdev(evdev))
}

fn wheel_ticks(axis: ScrollAxis, delta: ScrollDelta) -> i32 {
    let detents = match delta {
        ScrollDelta::Continuous(pixels) => pixels / SURFACE_UNITS_PER_DETENT,
        ScrollDelta::Discrete(detents) => f64::from(detents),
    };
    let direction = if axis == ScrollAxis::Vertical {
        -1.0
    } else {
        1.0
    };
    (detents * 120.0 * direction).round() as i32
}

fn point((window, size): Target, hit: PixelPoint, event: PointerInput) -> bool {
    report(windows::pointer(
        window,
        hit.x / f64::from(size.width),
        hit.y / f64::from(size.height),
        event,
    ))
}

fn report<E: std::fmt::Display>(result: Result<bool, E>) -> bool {
    result.unwrap_or_else(|error| {
        debug!(%error, "Windows input could not be sent");
        false
    })
}

fn release<E: std::fmt::Display>(result: Result<(), E>) {
    if let Err(error) = result {
        warn!(%error, "Windows input release could not be sent");
    }
}
