//! Linux-only: delivers compositor lifecycle events to Lua callbacks.
//!
//! Each `lun*` event carries one table built at dispatch time, because LÖVR variants cannot hold mlua userdata.

mod macros;

#[cfg(test)]
use std::cell::RefCell;
use std::{collections::VecDeque, ffi::c_char, fmt, mem, ptr, rc::Rc};

use lunette_capture::monitor::MonitorKey;
use lunette_compositor::protocol::{
    Event as CompositorEvent, ProcessId, ProcessOutcome, SignalNumber, Stream, WindowId,
};
use lunette_lovr::raw::{CustomEvent, Event as LovrEvent, EventType_EVENT_CUSTOM, lovrEventPush};
use mlua::{Lua, Table};
use tracing::info;

use crate::{
    callback_error::report,
    events::macros::events,
    lua::{
        LuaTexture, Monitor, Process, Session, Window,
        declarations::NullTexture,
        values::{OutcomeName, StreamName},
    },
};

/// A compositor event delivered to a Lua callback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LuaEvent {
    /// `lovr.lunwindowopened{ window = … }`.
    WindowOpened { window: WindowId },
    /// `lovr.lunwindowclosed{ window = … }`. The handle is dead because the snapshot no longer lists the window.
    WindowClosed { window: WindowId },
    /// `lovr.lunmonitoradded{ monitor = … }`.
    ///
    /// Startup screens are also reported when the mirror lifecycle first observes them. A screen
    /// unplugged before dispatch is not reported.
    MonitorAdded { monitor: MonitorKey },
    /// `lovr.lunprocessexited{ process = …, outcome = …, … }`.
    ProcessExited {
        process: ProcessId,
        outcome: ProcessOutcome,
    },
    /// `lovr.lunprocessoutput{ process = …, stream = …, text = … }`.
    ProcessOutput {
        process: ProcessId,
        stream: Stream,
        bytes: Vec<u8>,
    },
}

impl LuaEvent {
    /// The callback this event is delivered to.
    #[must_use]
    pub fn name(&self) -> EventName {
        match self {
            Self::WindowOpened { .. } => WINDOW_OPENED,
            Self::WindowClosed { .. } => WINDOW_CLOSED,
            Self::MonitorAdded { .. } => MONITOR_ADDED,
            Self::ProcessExited { .. } => PROCESS_EXITED,
            Self::ProcessOutput { .. } => PROCESS_OUTPUT,
        }
    }

    /// Which compositor reports become Lua callbacks.
    ///
    /// Exhaustive, so a new protocol variant needs an answer here. A client's output is also
    /// logged here, so it has a record whether or not a handler listens.
    #[must_use]
    pub fn from_compositor(event: &CompositorEvent) -> Option<Self> {
        match event {
            CompositorEvent::WindowOpened { window } => {
                Some(Self::WindowOpened { window: *window })
            }
            CompositorEvent::WindowClosed { window } => {
                Some(Self::WindowClosed { window: *window })
            }
            CompositorEvent::ProcessExited { process, outcome } => Some(Self::ProcessExited {
                process: *process,
                outcome: outcome.clone(),
            }),
            CompositorEvent::ProcessOutput {
                process,
                stream,
                bytes,
            } => {
                log_output(*process, *stream, bytes);
                Some(Self::ProcessOutput {
                    process: *process,
                    stream: *stream,
                    bytes: bytes.clone(),
                })
            }
            // The snapshot carries the title, and a handler reads it from the window.
            CompositorEvent::TitleChanged { .. } => None,
            // These belong to the frame loop, and the configuration cannot act on them.
            CompositorEvent::SurfaceDamaged { .. }
            | CompositorEvent::BufferImported { .. }
            | CompositorEvent::SurfaceGone { .. }
            | CompositorEvent::ProcessObservationChanged { .. }
            | CompositorEvent::AudioProcessResolved(_) => None,
            // Neither half of the restart handshake reaches Lua. The replacement state sees the outcome as windows with textures again.
            CompositorEvent::GraphicsReleased | CompositorEvent::GraphicsAdopted { .. } => None,
        }
    }
}

/// Logs one chunk a client wrote. The bytes are rendered lossily for the log only; the event
/// carries them intact.
fn log_output(process: ProcessId, stream: Stream, bytes: &[u8]) {
    let text = String::from_utf8_lossy(bytes);
    info!(%process, stream = stream.as_str(), "{}", text.trim_end());
}

/// A validated event name that fits LÖVR's `CustomEvent` name field.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct EventName(&'static str);

impl EventName {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        self.0
    }

    /// Returns a zero-padded C name array with a terminating NUL.
    #[must_use]
    fn to_c_name(self) -> [c_char; CUSTOM_EVENT_NAME_CAPACITY] {
        let mut name = [0; CUSTOM_EVENT_NAME_CAPACITY];
        for (slot, byte) in name.iter_mut().zip(self.0.as_bytes()) {
            *slot = *byte as c_char;
        }
        name
    }
}

impl fmt::Debug for EventName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}", self.0)
    }
}

impl fmt::Display for EventName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

/// Receives the LÖVR queue name for an event pending dispatch.
///
/// Tests use [`RecordingEventSink`] because LÖVR initializes its event module during boot.
pub trait EventSink: fmt::Debug {
    /// Announces that an event of this name is pending dispatch.
    fn push(&self, name: EventName);
}

/// Pushes `lun*` event names onto LÖVR's queue so they retain ordering with other callbacks.
#[derive(Clone, Copy, Debug, Default)]
pub struct LovrEventSink;

impl EventSink for LovrEventSink {
    /// Pushes a custom event name without a payload.
    ///
    /// LÖVR frees custom-event variants but not their backing array, so the C event carries no variant allocation.
    fn push(&self, name: EventName) {
        // SAFETY: zero is a valid event discriminant, and construction overwrites the custom-event fields.
        let mut event: LovrEvent = unsafe { mem::zeroed() };
        event.type_ = EventType_EVENT_CUSTOM;
        event.data.custom = CustomEvent {
            name: name.to_c_name(),
            data: ptr::null_mut(),
            count: 0,
        };

        // SAFETY: the event contains no Rust pointers, and the event module is initialised.
        unsafe { lovrEventPush(event) };
    }
}

/// Events pending dispatch for the current frame.
///
/// Unconsumed events are cleared at the next frame boundary so `lovr.event.clear()` cannot deliver them against a later snapshot.
#[derive(Debug, Default)]
pub(crate) struct EventQueue {
    pending: VecDeque<LuaEvent>,
}

impl EventQueue {
    pub(crate) fn push(&mut self, event: LuaEvent) {
        self.pending.push_back(event);
    }

    pub(crate) fn take(&mut self, name: EventName) -> Option<LuaEvent> {
        let index = self.pending.iter().position(|event| event.name() == name)?;
        self.pending.remove(index)
    }

    pub(crate) fn clear(&mut self) {
        self.pending.clear();
    }
}

/// Installs dispatchers in `lovr.handlers` for every supported `lun*` event.
///
/// # Errors
///
/// Returns an error if `lovr.handlers` is unavailable or a dispatcher cannot be created.
pub(crate) fn install_dispatchers<T: LuaTexture>(
    lua: &Lua,
    session: &Rc<Session<T>>,
) -> mlua::Result<()> {
    let handlers = handlers_table(lua)?;

    for &name in EVENT_NAMES {
        let session = Rc::clone(session);
        let dispatcher = lua.create_function(move |lua, ()| dispatch(lua, &session, name))?;
        handlers.set(name.as_str(), dispatcher)?;
    }

    Ok(())
}

/// The event name used to notify listeners about callback errors, which bypass LÖVR's event queue.
pub const ERROR: EventName = event_name("lunerror");

events! {
    /// A toplevel maps, and this frame's snapshot includes it.
    WINDOW_OPENED = lunwindowopened(_lua, session) as WindowOpenedEvent via onWindowOpened
        from LuaEvent::WindowOpened { window } =>
    {
        /// The window that opened.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
    }

    /// A toplevel closes. The handle is already dead but still reports the window's last title, size, and identifier.
    WINDOW_CLOSED = lunwindowclosed(_lua, session) as WindowClosedEvent via onWindowClosed
        from LuaEvent::WindowClosed { window } =>
    {
        /// The window that closed.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
    }

    /// A host screen appears, including every screen attached at startup.
    MONITOR_ADDED = lunmonitoradded(_lua, session) as MonitorAddedEvent via onMonitorAdded
        from LuaEvent::MonitorAdded { monitor } =>
    {
        /// The screen that appeared.
        // `deliverable` has already checked the screen is attached, so this is never nil.
        monitor: Monitor<NullTexture> = session
            .mirrors()
            .state(monitor)
            .map(|state| Monitor::new(Rc::clone(session), state)),
    }

    /// A spawned process ends, or never starts.
    PROCESS_EXITED = lunprocessexited(_lua, session) as ProcessExitedEvent via onProcessExited
        from LuaEvent::ProcessExited { process, outcome } =>
    {
        /// The process that ends.
        process: Process<NullTexture> = Process::new(Rc::clone(session), *process),
        /// Which of the three fields below the event carries. A string, so a failed spawn is not mistaken for an exit with no code.
        outcome: OutcomeName = OutcomeName(outcome.clone()),
        /// The status it exited with.
        code: Option<i32> = outcome.code(),
        /// The signal that terminates the process.
        signal: Option<u32> = outcome.signal().map(SignalNumber::get),
        /// What failed, for a program that never started.
        message: Option<String> = outcome.message(),
    }

    /// A spawned process writes to one of its captured streams.
    PROCESS_OUTPUT = lunprocessoutput(lua, session) as ProcessOutputEvent via onProcessOutput
        from LuaEvent::ProcessOutput { process, stream, bytes } =>
    {
        /// The process that wrote.
        process: Process<NullTexture> = Process::new(Rc::clone(session), *process),
        /// Which stream the process writes to.
        stream: StreamName = StreamName(*stream),
        /// The bytes written. A Lua string is a byte string, so non-UTF-8 output arrives intact.
        text: String = lua.create_string(bytes)?,
    }
}

/// Names an event, refusing one that does not fit `CustomEvent.name`.
///
/// Every name is a constant, so the assertions run at compile time and an
/// overlong or NUL-bearing name fails the build.
const fn event_name(name: &'static str) -> EventName {
    assert!(
        name.len() < CUSTOM_EVENT_NAME_CAPACITY,
        "a lun* event name has to fit CustomEvent.name, which is char[32] at event.h:102-106"
    );

    // An embedded NUL would truncate the name, so `lovr.handlers` would be indexed by a prefix.
    let bytes = name.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        assert!(bytes[index] != 0, "a lun* event name cannot contain a NUL");
        index += 1;
    }

    EventName(name)
}

/// Capacity of the NUL-terminated `CustomEvent.name` field.
const CUSTOM_EVENT_NAME_CAPACITY: usize = 32;

/// Dispatches a pending event with a Lua table payload that can contain userdata handles.
fn dispatch<T: LuaTexture>(
    lua: &Lua,
    session: &Rc<Session<T>>,
    name: EventName,
) -> mlua::Result<()> {
    // Ignore names without a pending Rust payload, including names pushed directly by Lua.
    let Some(event) = session.take_event(name) else {
        return Ok(());
    };

    let listeners = session.listeners(name);
    if listeners.is_empty() || !deliverable(session, &event) {
        return Ok(());
    }

    let payload = payload(lua, session, &event)?;

    // Each handler runs under a protected call, so a failure does not stop later handlers or queued events.
    for handler in listeners {
        if let Err(error) = handler.call::<()>(payload.clone()) {
            report(
                lua,
                &session.listeners(ERROR),
                &format!("lunette.{}", registrar(name)),
                &error,
            );
        }
    }

    Ok(())
}

/// Whether the thing an event names still exists, so its payload can carry a live handle.
///
/// A screen unplugged between the frame boundary and dispatch is skipped, because the next plug
/// event and `lunette.monitors()` report the screens that are attached.
fn deliverable<T>(session: &Session<T>, event: &LuaEvent) -> bool {
    match event {
        LuaEvent::MonitorAdded { monitor } => session.mirrors().state(monitor).is_some(),
        LuaEvent::WindowOpened { .. }
        | LuaEvent::WindowClosed { .. }
        | LuaEvent::ProcessExited { .. }
        | LuaEvent::ProcessOutput { .. } => true,
    }
}

/// The `lovr.handlers` table `boot.lua` installs.
fn handlers_table(lua: &Lua) -> mlua::Result<Table> {
    let lovr = lua.globals().get::<Option<Table>>("lovr")?.ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: the lovr global is missing, so lun* callbacks have nowhere to be delivered; \
             the module is meant to be required from a LÖVR project's main.luau",
        )
    })?;

    lovr.get::<Option<Table>>("handlers")?.ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: lovr.handlers is missing, and boot.lua:354 is what creates it; the module \
             cannot have been required from a running LÖVR session",
        )
    })
}

/// Records event names for tests that replay dispatch through `lovr.handlers`.
#[cfg(test)]
#[derive(Clone, Debug, Default)]
pub(crate) struct RecordingEventSink {
    pushed: Rc<RefCell<Vec<EventName>>>,
}

#[cfg(test)]
impl RecordingEventSink {
    pub(crate) fn take(&self) -> Vec<EventName> {
        mem::take(&mut self.pushed.borrow_mut())
    }
}

#[cfg(test)]
impl EventSink for RecordingEventSink {
    fn push(&self, name: EventName) {
        self.pushed.borrow_mut().push(name);
    }
}

#[cfg(test)]
mod tests;
