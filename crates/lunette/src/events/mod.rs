//! Linux-only: turns what the compositor reports into `lovr.lun*` callbacks.
//!
//! Eight of the nine events `docs/dev/lua-api.md` specifies are delivered from
//! here. `lunerror` is the ninth and is not one of them: it is not pushed onto
//! LÖVR's queue, because an error is reported where it happens. Queued
//! delivery would arrive a frame later. [`crate::callback_error`] emits it.
//!
//! Six of the eight are the compositor's, and are drained from its channel at
//! frame start. The two layer events are lunette's own: nothing outside the
//! process generates them, and [`crate::lua::Session::resolve_layers`] pushes
//! them at the boundary where the grant or revocation takes effect.
//!
//! # Delivery from the frame thread
//!
//! `lovrEventPush` takes the event module's own lock, so any thread may call
//! it. Nothing but the frame thread does. Events are drained from the channel
//! at frame start, immediately after [`Session::begin`] has installed the
//! snapshot they belong with, so a handler reading `lunette.windows()` sees a
//! snapshot that already includes the window the event names. The compositor
//! thread would push when it reaches the event in its own loop, which need not
//! align with a frame; a handler could then be given a window the frame's
//! snapshot does not contain.
//!
//! # Limits `CustomEvent` imposes
//!
//! The name is `char name[32]` (`event.h`), so it caps at 31 bytes and a NUL.
//! `l_event.c` copies the name in with no bound of its own, so a longer one
//! overruns the buffer, with no truncation; [`EventName`] refuses it at
//! compile time for the names below.
//!
//! `boot.lua` unpacks four payload arguments and dispatches them, so at most
//! four values reach a handler. Every `lun*` event carries exactly one table,
//! even the events with a single field: the shape is the same across
//! callbacks, and a field added later is not a change to the callback's
//! signature.
//!
//! # Dispatcher between the queue and the handler
//!
//! `boot.lua` sets `lovr.handlers = setmetatable({}, { __index = lovr })`, so
//! pushing `lunwindowopened` would call `lovr.lunwindowopened` with nothing
//! installed here. Two things make direct delivery insufficient.
//!
//! A `CustomEvent` carries `Variant`s, and a `Variant` holds numbers, strings,
//! tables, and LÖVR objects. A window handle is an mlua userdata, and a
//! `Variant` cannot hold it. The payload table is built at dispatch time, on
//! the native side, where the handles can be made.
//!
//! An error raised by a handler dispatched straight from `boot.lua`'s poll
//! loop unwinds the loop, so the rest of the frame's events are never
//! delivered. The dispatcher calls the handler through mlua, which is a
//! protected call, and passes what comes back to [`crate::callback_error`].
//! The error panel, the rate limiting, and the wording of a report belong to
//! `mullion.error`, and that module defines them.

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

/// A report the Lua configuration is given a callback for.
///
/// A projection of [`CompositorEvent`]: the compositor reports things Lua has
/// no callback for, such as a damaged surface or an imported buffer, and the
/// frame loop handles those alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LuaEvent {
    /// `lovr.lunwindowopened{ window = … }`.
    WindowOpened { window: WindowId },
    /// `lovr.lunwindowclosed{ window = … }`. The handle is already dead by the
    /// time the handler runs, because the snapshot the handler reads no longer
    /// lists the window.
    WindowClosed { window: WindowId },
    /// `lovr.luntitlechanged{ window = …, title = … }`.
    TitleChanged { window: WindowId, title: String },
    /// `lovr.lunmonitoradded{ id = …, monitor = … }`.
    ///
    /// One of the host's screens, distinct from a compositor output: the
    /// identity is the key `lunette-capture` resolved, and the handle is the
    /// object `lunette.monitors()` returns. Pushed by the frame loop whenever
    /// the mirror lifecycle reports a monitor for the first time, including
    /// every monitor present when lunette started.
    MonitorAdded { monitor: MonitorKey },
    /// `lovr.lunprocessexited{ process = …, outcome = …, … }`.
    ///
    /// The one report a caller of `lunette.spawn` gets for a program that
    /// never started. The outcome travels with the event, because the report
    /// must state why the program did not start and an exit code cannot hold
    /// that reason.
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
    /// The layer travels alongside the claim even though `claim.layer` exposes
    /// the same value. The event reports that the panel gained a layer, and
    /// the payload carries the layer so a handler does not have to read it
    /// from the claim.
    LayerGranted { claim: ClaimId },
    /// `lovr.lunlayerrevoked{ claim = … }`.
    ///
    /// No layer, because there is none: the claim holds nothing by the time the
    /// handler runs, and the event reports that fact. The claim stays alive and
    /// receives a layer again when a layer becomes free and nothing outranks
    /// the claim.
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

/// The name a `lun*` event is pushed under, short enough to fit `CustomEvent`.
///
/// Stored as a borrowed `&'static str`. `CustomEvent` carries a C array, built
/// by [`EventName::to_c_name`] at the boundary. Every name in the program is a
/// literal, and carrying it as one keeps the Rust side comparable, printable,
/// and usable as a Lua key without a conversion.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct EventName(&'static str);

impl EventName {
    /// Accepts a name that fits `CustomEvent.name`.
    ///
    /// `const`, so [`event_name`] can refuse an overlong name during
    /// compilation, the point where refusal costs nothing.
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

    /// The NUL-terminated array `CustomEvent.name` is.
    ///
    /// The remaining bytes stay zero, so two events with the same name produce
    /// byte-identical structures, and a reader of a core dump is not shown the
    /// tail of an earlier name.
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

/// Where a pushed event is delivered.
///
/// The seam exists because `lovrEventPush` requires LÖVR's event module to be
/// initialised, which happens inside `boot.lua`. The queue, the payload, the
/// dispatch, and the handler are all exercised against [`RecordingEventSink`]
/// without LÖVR.
pub trait EventSink: fmt::Debug {
    /// Announces that an event of this name is pending dispatch.
    fn push(&self, name: EventName);
}

/// Pushes onto LÖVR's own event queue, so `lun*` callbacks interleave with
/// `lovr.keypressed` and the rest in the order they are produced.
#[derive(Clone, Copy, Debug, Default)]
pub struct LovrEventSink;

impl EventSink for LovrEventSink {
    /// Builds the `CustomEvent` `l_event.c` builds, with no payload.
    ///
    /// No payload, because `l_lovrEventPoll` destroys each `Variant` of a
    /// custom event but never frees the array holding them (`l_event.c`). An
    /// event that carries a payload leaks the allocation for the life of the
    /// process; a count of zero and a null pointer avoid the leak. Nothing is
    /// lost: the payload is built from Rust at dispatch time, and a `Variant`
    /// could carry the identity of the event across, which [`EventQueue`]
    /// already holds, because LÖVR's queue and its own are both
    /// first-in-first-out.
    fn push(&self, name: EventName) {
        // SAFETY: zero is a valid `Event`: `EventType` is a C enum whose first
        // variant is zero, and every member of `EventData` is a plain
        // aggregate. Both fields are overwritten at construction, and the
        // value is used afterwards.
        let mut event: LovrEvent = unsafe { mem::zeroed() };
        event.type_ = EventType_EVENT_CUSTOM;
        event.data.custom = CustomEvent {
            name: name.to_c_name(),
            data: ptr::null_mut(),
            count: 0,
        };

        // SAFETY: the event is a self-contained value with no pointer into
        // Rust's memory, and `lovrEventPush` takes it by value under the event
        // module's own lock. The module is initialised by `boot.lua` during
        // startup, and this code runs at frame start, after that.
        unsafe { lovrEventPush(event) };
    }
}

/// The events pushed this frame that have not been dispatched yet.
///
/// One entry is added for every push, and taken back when `boot.lua` reaches
/// the matching event in its poll loop. Both queues are first-in-first-out and
/// nothing else pushes a `lun*` name, so the first pending event of a name is
/// the one dispatched.
///
/// An entry that is never taken is dropped at the start of the next frame. A
/// handler can call `lovr.event.clear()`, which discards the rest of the
/// frame's queue; those entries are then never taken. The drop prevents a
/// discarded event from being delivered against a snapshot from a later
/// frame.
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

/// Installs the dispatcher for every `lun*` event this build delivers.
///
/// Called when the module is built, which is the first `require('lunette')`.
/// `lovr.handlers` exists by then: `boot.lua` creates it, then runs
/// `main.lua`. The first `require` is also the earliest point at which the
/// module is known to be in use; nothing earlier indicates that the
/// configuration needs it.
///
/// # Errors
///
/// If `lovr.handlers` cannot be reached, or a dispatcher cannot be created.
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

/// Where an error raised inside a listener is offered.
///
/// `lunerror` is not pushed through the queue: it is raised on the way out of a
/// dispatch, not reported by the compositor. It shares the registry, so
/// subscribing to it uses the same mechanism as subscribing to any other
/// event.
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

/// How many bytes `CustomEvent.name` holds, the last of which is the NUL.
const CUSTOM_EVENT_NAME_CAPACITY: usize = 32;

/// Hands one event to the configuration's handler.
///
/// Takes no arguments, because the event carries none: the pending queue names
/// the window that opened, and the payload table is built here because it can
/// hold handles a `Variant` could not.
fn dispatch<T: LuaTexture>(
    lua: &Lua,
    session: &Rc<Session<T>>,
    name: EventName,
) -> mlua::Result<()> {
    // Absent when something else pushed this name, such as `lovr.event.push`
    // from Lua, or when a handler cleared the queue and the entry outlived the
    // event. Neither case is an error, and neither has anything to report.
    let Some(event) = session.take_event(name) else {
        return Ok(());
    };

    let listeners = session.listeners(name);
    if listeners.is_empty() {
        return Ok(());
    }

    let payload = payload(lua, session, &event)?;

    // Every listener is called, including the ones after a listener that
    // raised. The listeners subscribed independently, and one failing does not
    // stop the next from hearing the event.
    //
    // mlua calls through `lua_pcall` with `luaL_traceback` as the message
    // handler, so an error arrives with its traceback, and `boot.lua`'s poll
    // loop is not unwound; the frame's remaining events are still delivered.
    // [`crate::callback_error`] handles the error from here: the rate
    // limiting, the wording, and the panel belong to `mullion.error`, and this
    // is the boundary that hands the error over.
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
             the module is meant to be required from a LÖVR project's main.lua",
        )
    })?;

    lovr.get::<Option<Table>>("handlers")?.ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: lovr.handlers is missing, and boot.lua:345 is what creates it; the module \
             cannot have been required from a running LÖVR session",
        )
    })
}

/// Records the names pushed to it, in place of LÖVR's event queue.
///
/// The recorded names are what a test replays through `lovr.handlers` to
/// reproduce `boot.lua`'s poll loop, so the dispatch under test is the
/// production one. Shared, so the copy handed to the session and the copy the
/// test reads are the same recorder.
#[cfg(test)]
#[derive(Clone, Debug, Default)]
pub(crate) struct RecordingEventSink {
    pushed: Rc<RefCell<Vec<EventName>>>,
}

#[cfg(test)]
impl RecordingEventSink {
    /// The names pushed since the last call, in push order.
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
