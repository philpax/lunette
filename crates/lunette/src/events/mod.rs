//! Linux-only: delivers compositor and layer lifecycle events to Lua callbacks.
//!
//! Compositor events and layer grants or revocations enter LÖVR's event queue on the frame thread,
//! after [`Session::begin`] installs their snapshot. Callback errors are reported immediately
//! through [`crate::callback_error`], not queued for the next frame.
//!
//! LÖVR custom event names have 31 usable bytes plus a NUL terminator. [`EventName`] rejects longer
//! or embedded-NUL names. Each `lun*` event carries one table, built at dispatch time because LÖVR
//! variants cannot hold mlua userdata. Protected dispatch reports handler errors and continues with
//! later listeners.

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

use crate::{
    callback_error::report,
    events::macros::events,
    layers::ClaimId,
    lua::{
        Claim, LuaTexture, Monitor, Process, Session, Window,
        declarations::NullTexture,
        values::{GrantedLayer, OutcomeName, StreamName},
    },
};

/// A compositor or layer event delivered to a Lua callback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LuaEvent {
    /// `lovr.lunwindowopened{ window = … }`.
    WindowOpened { window: WindowId },
    /// `lovr.lunwindowclosed{ window = … }`. The handle is dead before dispatch because the current
    /// snapshot no longer lists the window.
    WindowClosed { window: WindowId },
    /// `lovr.luntitlechanged{ window = …, title = … }`.
    TitleChanged { window: WindowId, title: String },
    /// `lovr.lunmonitoradded{ id = …, monitor = … }`.
    ///
    /// A host screen, identified by the key resolved by `lunette-capture`. Startup screens are also
    /// reported when the mirror lifecycle first observes them.
    MonitorAdded { monitor: MonitorKey },
    /// `lovr.lunprocessexited{ process = …, outcome = …, … }`.
    ///
    /// Reports process exits and spawn failures. The outcome distinguishes failures from exits.
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
    /// `lovr.lunlayergranted{ claim = …, layer = … }`.
    ///
    /// Carries the granted layer alongside the claim so handlers can use it directly.
    LayerGranted { claim: ClaimId },
    /// `lovr.lunlayerrevoked{ claim = … }`.
    ///
    /// The claim holds no layer when this event is dispatched. It remains active and can receive a
    /// layer again when one becomes available.
    LayerRevoked { claim: ClaimId },
}

impl LuaEvent {
    /// The callback this event is delivered to.
    #[must_use]
    pub fn name(&self) -> EventName {
        match self {
            Self::WindowOpened { .. } => WINDOW_OPENED,
            Self::WindowClosed { .. } => WINDOW_CLOSED,
            Self::TitleChanged { .. } => TITLE_CHANGED,
            Self::MonitorAdded { .. } => MONITOR_ADDED,
            Self::ProcessExited { .. } => PROCESS_EXITED,
            Self::ProcessOutput { .. } => PROCESS_OUTPUT,
            Self::LayerGranted { .. } => LAYER_GRANTED,
            Self::LayerRevoked { .. } => LAYER_REVOKED,
        }
    }

    /// Which compositor reports become Lua callbacks.
    ///
    /// The match is exhaustive. A variant added to the protocol must be given
    /// an answer here; an unanswered variant would never reach the
    /// configuration.
    #[must_use]
    pub fn from_compositor(event: &CompositorEvent) -> Option<Self> {
        match event {
            CompositorEvent::WindowOpened { window } => {
                Some(Self::WindowOpened { window: *window })
            }
            CompositorEvent::WindowClosed { window } => {
                Some(Self::WindowClosed { window: *window })
            }
            CompositorEvent::TitleChanged { window, title } => Some(Self::TitleChanged {
                window: *window,
                title: title.clone(),
            }),
            CompositorEvent::ProcessExited { process, outcome } => Some(Self::ProcessExited {
                process: *process,
                outcome: outcome.clone(),
            }),
            CompositorEvent::ProcessOutput {
                process,
                stream,
                bytes,
            } => Some(Self::ProcessOutput {
                process: *process,
                stream: *stream,
                bytes: bytes.clone(),
            }),
            // All three belong to the frame loop: one refreshes a stabilised
            // copy, one becomes a texture, and one releases it again. The
            // configuration cannot act on any of them. A surface is not a
            // window, and a window closing has its own event.
            CompositorEvent::SurfaceDamaged { .. }
            | CompositorEvent::BufferImported { .. }
            | CompositorEvent::SurfaceGone { .. } => None,
            // The restart handshake has two halves. Neither reaches Lua: the
            // Lua state that requested the restart is gone when the first half
            // arrives, and the state that replaces it receives the outcome as
            // windows with textures again; no event is delivered. lunette
            // owning its own graphics device is mechanism, and mechanism has
            // no policy hook.
            CompositorEvent::GraphicsReleased | CompositorEvent::GraphicsAdopted { .. } => None,
        }
    }
}

/// A validated event name that fits LÖVR's `CustomEvent` name field.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct EventName(&'static str);

impl EventName {
    /// Returns `None` when the name exceeds the custom event field capacity or contains a NUL.
    #[must_use]
    pub const fn new(name: &'static str) -> Option<Self> {
        if name.len() >= CUSTOM_EVENT_NAME_CAPACITY {
            return None;
        }

        // An embedded NUL terminates the name early in the C array, so
        // `lovr.handlers` would be indexed by a prefix of the name.
        let bytes = name.as_bytes();
        let mut index = 0;
        while index < bytes.len() {
            if bytes[index] == 0 {
                return None;
            }
            index += 1;
        }

        Some(Self(name))
    }

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
    /// LÖVR frees custom-event variants but not their backing array. Payload tables are built from
    /// the Rust event at dispatch, so the C event carries no variant allocation.
    fn push(&self, name: EventName) {
        // SAFETY: zero is a valid event discriminant. Construction overwrites the custom-event
        // fields.
        let mut event: LovrEvent = unsafe { mem::zeroed() };
        event.type_ = EventType_EVENT_CUSTOM;
        event.data.custom = CustomEvent {
            name: name.to_c_name(),
            data: ptr::null_mut(),
            count: 0,
        };

        // SAFETY: the event contains no Rust pointers. LÖVR receives it by value after event-module
        // initialization.
        unsafe { lovrEventPush(event) };
    }
}

/// Events pending dispatch for the current frame.
///
/// Queue names pair with payloads in insertion order. Unconsumed events are cleared at the next
/// frame boundary so `lovr.event.clear()` cannot deliver them against a later snapshot.
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

/// The event name used to notify listeners about callback errors.
///
/// Callback errors are reported immediately through the listener registry, not through LÖVR's event
/// queue.
pub const ERROR: EventName = event_name("lunerror");

events! {
    /// A toplevel maps, and this frame's snapshot includes it.
    WINDOW_OPENED = lunwindowopened(_lua, session) as WindowOpenedEvent via onWindowOpened
        from LuaEvent::WindowOpened { window } =>
    {
        /// The window that opened.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
    }

    /// A toplevel closes. The handle is already dead, because the snapshot the
    /// handler reads no longer lists the window; the handle still reports the
    /// window's last title, size, and identifier.
    WINDOW_CLOSED = lunwindowclosed(_lua, session) as WindowClosedEvent via onWindowClosed
        from LuaEvent::WindowClosed { window } =>
    {
        /// The window that closed.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
    }

    /// A toplevel changes its title.
    TITLE_CHANGED = luntitlechanged(_lua, session) as TitleChangedEvent via onTitleChanged
        from LuaEvent::TitleChanged { window, title } =>
    {
        /// The window whose title changed.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
        /// The new title. Also readable as `event.window.title`; duplicated in
        /// the payload because the callback reports a change, and a handler
        /// comparing against a stored value needs the new value without a
        /// further read of the window.
        title: String = title.as_str(),
    }

    /// A host screen appears. The event includes every screen attached at
    /// lunette startup.
    MONITOR_ADDED = lunmonitoradded(_lua, session) as MonitorAddedEvent via onMonitorAdded
        from LuaEvent::MonitorAdded { monitor } =>
    {
        /// The key `lunette-capture` identifies the screen by.
        id: String = monitor.to_string(),
        /// The handle, while the screen is still attached. A screen unplugged between
        /// the report and the dispatch has no handle; the payload carries its name.
        monitor: Option<Monitor<NullTexture>> = session
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
        /// Which of the three fields below the event carries. A string, where
        /// field presence would force a handler to test each field in turn, and a
        /// failed spawn is not mistaken for an exit with no code.
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
        /// The bytes written. A Lua string is a byte string, so non-UTF-8
        /// output arrives intact; decoding remains the configuration's
        /// decision.
        text: String = lua.create_string(bytes)?,
    }

    /// A claim receives a composition layer, and the panel holding it draws
    /// onto the layer.
    LAYER_GRANTED = lunlayergranted(lua, session) as LayerGrantedEvent via onLayerGranted
        from LuaEvent::LayerGranted { claim } =>
    {
        /// The claim that received the layer.
        claim: Claim<NullTexture> = Claim::new(Rc::clone(session), *claim),
        /// The layer it holds. Not kept across frames: the layer it names goes
        /// away on revoke.
        layer: GrantedLayer = session.claims().push_layer(lua, *claim)?,
    }

    /// A claim loses its layer to a higher-priority claim, and the panel
    /// holding it draws as an in-scene quad until a layer is granted again.
    LAYER_REVOKED = lunlayerrevoked(_lua, session) as LayerRevokedEvent via onLayerRevoked
        from LuaEvent::LayerRevoked { claim } =>
    {
        /// The claim that lost the layer.
        claim: Claim<NullTexture> = Claim::new(Rc::clone(session), *claim),
    }
}

/// Names an event, refusing one that does not fit `CustomEvent.name`.
///
/// The panic is evaluated while the program is compiled, so a name too long for
/// the array fails the build; `memcpy` never receives an overlong name.
const fn event_name(name: &'static str) -> EventName {
    match EventName::new(name) {
        Some(name) => name,
        None => panic!(
            "a lun* event name has to fit CustomEvent.name, which is char[32] at event.h:102-106"
        ),
    }
}

/// Capacity of the NUL-terminated `CustomEvent.name` field.
const CUSTOM_EVENT_NAME_CAPACITY: usize = 32;

/// Dispatches a pending event with a Lua table payload that can contain userdata handles.
fn dispatch<T: LuaTexture>(
    lua: &Lua,
    session: &Rc<Session<T>>,
    name: EventName,
) -> mlua::Result<()> {
    // Ignore names without a matching pending Rust payload, including names pushed directly by Lua.
    let Some(event) = session.take_event(name) else {
        return Ok(());
    };

    let listeners = session.listeners(name);
    if listeners.is_empty() {
        return Ok(());
    }

    let payload = payload(lua, session, &event)?;

    // Each handler runs under mlua's protected call. Failures include tracebacks and do not stop
    // later handlers or queued events. [`crate::callback_error`] reports them to
    // `lunette.onError` listeners.
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
