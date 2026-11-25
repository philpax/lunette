//! Commands from Windows monitor sinks, ordered with window commands.

use lunette_capture::{
    hid::{PanelPoint, WheelDelta},
    monitor::MonitorKey,
};
use lunette_compositor::protocol::{Command, Keycode, ModifierState, PointerButton, SeatId};

#[derive(Debug)]
pub(crate) enum WindowsCommand {
    Native(Command),
    Monitor {
        seat: SeatId,
        monitor: MonitorKey,
        input: MonitorInput,
    },
}

#[derive(Debug)]
pub(crate) enum MonitorInput {
    Point(PanelPoint),
    Button(PointerButton, bool),
    Leave,
    Wheel(WheelDelta),
    Key(Keycode, bool),
    Modifiers(ModifierState),
    Text(String),
}
