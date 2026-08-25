//! Linux-only: turning what the compositor reports into `lovr.lun*` callbacks.
//!
//! Eight of the nine events `docs/lua-api.md` specifies are delivered from
//! here. `lunerror` is the ninth and is not one of them: it is not pushed onto
//! LÖVR's queue at all, because an error is reported where it happened rather
//! than a frame later. [`crate::callback_error`] is where it is emitted from.
//!
//! Six of the eight are the compositor's, and are drained from its channel at
//! frame start. The two layer events are lunette's own: nothing outside the
//! process decides them, and [`crate::lua::Session::resolve_layers`] pushes them
//! at the boundary the grant or revocation actually lands on.
//!
//! # Why the compositor thread does not push these itself
//!
//! `lovrEventPush` takes the event module's own lock, so any thread may call
//! it. Nothing but the frame thread does. Events are drained from the channel
//! at frame start, immediately after [`Session::begin`] has installed the
//! snapshot they belong with, so a handler reading `lunette.windows()` sees a
//! snapshot that already accounts for the event it was handed. A push from the
//! compositor thread would arrive whenever the compositor happened to reach it,
//! and a handler could then be given a window the frame's snapshot has never
//! heard of.
//!
//! # Two limits `CustomEvent` imposes
//!
//! The name is `char name[32]` (`event.h:102-106`), so it caps at 31 bytes and
//! a NUL. `l_event.c:165` copies the name in with no bound of its own, so a
//! longer one would be a buffer overrun rather than a truncation; [`EventName`]
//! is where that is refused, at compile time for the names below.
//!
//! `boot.lua:193` unpacks four payload arguments and dispatches them at `:198`,
//! so at most four values reach a handler. Every `lun*` event therefore carries
//! exactly one table, even the events with a single field: the shape is then
//! the same across every phase, and a field added later is not a change to the
//! callback's signature.
//!
//! # Why a dispatcher sits in front of the handler
//!
//! `boot.lua:345` sets `lovr.handlers = setmetatable({}, { __index = lovr })`,
//! so pushing `lunwindowopened` would call `lovr.lunwindowopened` with nothing
//! installed here at all. Two things make that insufficient.
//!
//! A `CustomEvent` carries `Variant`s, and a `Variant` holds numbers, strings,
//! tables, and LÖVR objects — not a window handle, which is an mlua userdata.
//! The payload table is therefore built at dispatch time, on this side, where
//! the handles can be made.
//!
//! And an error raised by a handler dispatched straight from `boot.lua`'s poll
//! loop unwinds the loop, so the rest of the frame's events are never
//! delivered. The dispatcher calls the handler through mlua, which is a
//! protected call, and hands what comes back to [`crate::callback_error`]. The
//! error panel, the rate limiting, and the wording of a report are
//! `mullion.error`'s, and that module is where they are decided.

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
/// Plain data, and a projection of [`CompositorEvent`] rather than a rename of
/// it: the compositor reports things Lua has no callback for — a surface being
/// damaged, a buffer being imported — and those are the frame loop's business
/// alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LuaEvent {
    /// `lovr.lunwindowopened{ window = … }`.
    WindowOpened { window: WindowId },
    /// `lovr.lunwindowclosed{ window = … }`. The handle is already dead by the
    /// time the handler runs, because the snapshot it reads no longer lists the
    /// window.
    WindowClosed { window: WindowId },
    /// `lovr.luntitlechanged{ window = …, title = … }`.
    TitleChanged { window: WindowId, title: String },
    /// `lovr.lunmonitoradded{ id = …, monitor = … }`.
    ///
    /// One of the *host's* screens, not a compositor output: the identity is the
    /// key `lunette-capture` resolved, and the handle is what
    /// `lunette.monitors()` hands out. Pushed by the frame loop whenever the
    /// mirror lifecycle reports a monitor it had not seen, which includes every
    /// monitor present when lunette started.
    MonitorAdded { monitor: MonitorKey },
    /// `lovr.lunprocessexited{ process = …, outcome = …, … }`.
    ///
    /// The only report a caller of `lunette.spawn` gets for a program that
    /// never started, which is why the outcome travels with it rather than
    /// being reduced to an exit code.
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
    /// The layer travels alongside the claim although `claim.layer` reads it
    /// too, because the event is about the panel gaining one and a handler that
    /// does nothing else should not have to go looking.
    LayerGranted { claim: ClaimId },
    /// `lovr.lunlayerrevoked{ claim = … }`.
    ///
    /// No layer, because there is none: the claim holds nothing by the time the
    /// handler runs, which is what the event reports. The claim itself is alive
    /// and takes a layer again as soon as one frees and nothing outranks it.
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

    /// Which compositor reports Lua is given a callback for.
    ///
    /// The match is exhaustive so that a variant added to the protocol has to
    /// be given an answer here, rather than silently becoming an event the
    /// configuration never hears about.
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
            // All three are the frame loop's: one decides whether a stabilised
            // copy is refreshed, one becomes a texture, and one releases it
            // again. None of them is something the configuration can act on —
            // a surface is not a window, and a window going away has its own
            // event.
            CompositorEvent::SurfaceDamaged { .. }
            | CompositorEvent::BufferImported { .. }
            | CompositorEvent::SurfaceGone { .. } => None,
            // The restart handshake's two halves. Neither reaches Lua: the Lua
            // state that asked for the restart is gone by the time the first
            // arrives, and the state that replaces it observes the outcome as
            // windows with textures again rather than as an event. `lunette`
            // driving its own graphics device is mechanism, and mechanism does
            // not need a policy hook.
            CompositorEvent::GraphicsReleased | CompositorEvent::GraphicsAdopted { .. } => None,
        }
    }
}

/// The name a `lun*` event is pushed under, short enough to fit `CustomEvent`.
///
/// A borrowed `&'static str` rather than the C array: the array is what LÖVR
/// wants, and is built on the way out by [`EventName::to_c_name`], but every
/// name in the program is a literal and carrying it as one keeps the Rust side
/// comparable, printable, and usable as a Lua key without a conversion.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct EventName(&'static str);

impl EventName {
    /// Accepts a name that fits `CustomEvent.name`.
    ///
    /// `const` so that [`event_name`] can refuse an overlong name while the
    /// program is being compiled, which is the only moment at which refusing it
    /// costs nothing.
    #[must_use]
    pub const fn new(name: &'static str) -> Option<Self> {
        if name.len() >= CUSTOM_EVENT_NAME_CAPACITY {
            return None;
        }

        // An embedded NUL would terminate the name early on the way through the
        // C array, so `lovr.handlers` would be indexed by a prefix of what was
        // asked for.
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
    /// The remaining bytes stay zero rather than being left undefined, so two
    /// events with the same name produce byte-identical structures and a reader
    /// of a core dump is not shown the tail of an earlier name.
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
/// The seam is here because `lovrEventPush` needs LÖVR's event module to have
/// been initialised, which happens inside `boot.lua`. Everything above it — the
/// queue, the payload, the dispatch, the handler — is exercised against
/// [`RecordingEventSink`] with no LÖVR at all.
pub trait EventSink: fmt::Debug {
    /// Announces that an event of this name is waiting to be dispatched.
    fn push(&self, name: EventName);
}

/// Pushes onto LÖVR's own event queue, so that `lun*` callbacks interleave with
/// `lovr.keypressed` and the rest in the order they were produced.
#[derive(Clone, Copy, Debug, Default)]
pub struct LovrEventSink;

impl EventSink for LovrEventSink {
    /// Builds the `CustomEvent` `l_event.c:162-179` builds, with no payload.
    ///
    /// No payload for a reason worth stating. `l_lovrEventPoll` destroys each
    /// `Variant` of a custom event but never frees the array holding them
    /// (`l_event.c:139-145`), so every event carrying one leaks the allocation
    /// for the life of the process. A count of zero and a null pointer avoid
    /// that entirely, and nothing is lost: the payload is built from Rust at
    /// dispatch time, so the only thing a `Variant` could have carried across
    /// is the identity of the event — which [`EventQueue`] already knows, since
    /// LÖVR's queue and its own are both first-in-first-out.
    fn push(&self, name: EventName) {
        // SAFETY: zero is a valid `Event`: `EventType` is a C enum whose first
        // variant is zero, and every member of `EventData` is a plain
        // aggregate. Both fields are overwritten before the value is used.
        let mut event: LovrEvent = unsafe { mem::zeroed() };
        event.type_ = EventType_EVENT_CUSTOM;
        event.data.custom = CustomEvent {
            name: name.to_c_name(),
            data: ptr::null_mut(),
            count: 0,
        };

        // SAFETY: the event is a self-contained value with no pointer into
        // Rust's memory, and `lovrEventPush` takes it by value under the event
        // module's own lock. The module is initialised by `boot.lua` before any
        // frame runs, which is before anything reaches this.
        unsafe { lovrEventPush(event) };
    }
}

/// The events pushed this frame that have not been dispatched yet.
///
/// One entry is added for every push, and taken back when `boot.lua` reaches
/// the matching event in its poll loop. Both queues are first-in-first-out and
/// nothing else pushes a `lun*` name, so the first pending event of a name is
/// always the one being dispatched.
///
/// An entry that is never taken — `lovr.event.clear()` from a handler discards
/// the rest of the frame's queue — is dropped at the start of the next frame
/// rather than being carried forward, so a discarded event cannot be delivered
/// against a snapshot from a later frame.
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
/// That is late enough for `lovr.handlers` to exist — `boot.lua:345` creates it
/// before `main.lua` runs — and it is the only moment at which the module is
/// known to be wanted at all.
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
/// Not one of the events below: nothing pushes it through the queue, because it
/// is raised on the way out of a dispatch rather than reported by the
/// compositor. It shares the registry so that subscribing to it is the same
/// mechanism as subscribing to anything else.
pub const ERROR: EventName = event_name("lunerror");

events! {
    /// A toplevel was mapped and is in this frame's snapshot.
    WINDOW_OPENED = lunwindowopened(_lua, session) as WindowOpenedEvent via onWindowOpened
        from LuaEvent::WindowOpened { window } =>
    {
        /// The window that opened.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
    }

    /// A toplevel went away. The handle is already dead, because the snapshot the
    /// handler reads no longer lists the window; it still reports what it last knew.
    WINDOW_CLOSED = lunwindowclosed(_lua, session) as WindowClosedEvent via onWindowClosed
        from LuaEvent::WindowClosed { window } =>
    {
        /// The window that closed.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
    }

    /// A toplevel changed its title.
    TITLE_CHANGED = luntitlechanged(_lua, session) as TitleChangedEvent via onTitleChanged
        from LuaEvent::TitleChanged { window, title } =>
    {
        /// The window whose title changed.
        window: Window<NullTexture> = Window::for_id(Rc::clone(session), *window),
        /// The new title. Also readable as `event.window.title`; carried here because
        /// the callback is about the change, and a handler diffing against what it
        /// stored needs the new value in hand.
        title: String = title.as_str(),
    }

    /// One of the host's screens appeared, which includes every screen attached when
    /// lunette started.
    MONITOR_ADDED = lunmonitoradded(_lua, session) as MonitorAddedEvent via onMonitorAdded
        from LuaEvent::MonitorAdded { monitor } =>
    {
        /// What `lunette-capture` resolved the screen by.
        id: String = monitor.to_string(),
        /// The handle, while the screen is still attached. A screen unplugged between
        /// the report and the dispatch has nothing left to hand over but its name.
        monitor: Option<Monitor<NullTexture>> = session
            .mirrors()
            .state(monitor)
            .map(|state| Monitor::new(Rc::clone(session), state)),
    }

    /// A spawned process ended, or never started.
    PROCESS_EXITED = lunprocessexited(_lua, session) as ProcessExitedEvent via onProcessExited
        from LuaEvent::ProcessExited { process, outcome } =>
    {
        /// The process that ended.
        process: Process<NullTexture> = Process::new(Rc::clone(session), *process),
        /// Which of the three fields below this event carries. A string rather than the
        /// presence of a field, so a handler reads it once instead of testing each in
        /// turn, and a spawn that failed is not mistaken for an exit with no code.
        outcome: OutcomeName = OutcomeName(outcome.clone()),
        /// The status it exited with.
        code: Option<i32> = outcome.code(),
        /// The signal that killed it.
        signal: Option<u32> = outcome.signal().map(SignalNumber::get),
        /// What failed, for a program that never ran.
        message: Option<String> = outcome.message(),
    }

    /// A spawned process wrote to one of its captured streams.
    PROCESS_OUTPUT = lunprocessoutput(lua, session) as ProcessOutputEvent via onProcessOutput
        from LuaEvent::ProcessOutput { process, stream, bytes } =>
    {
        /// The process that wrote.
        process: Process<NullTexture> = Process::new(Rc::clone(session), *process),
        /// Which stream it wrote to.
        stream: StreamName = StreamName(*stream),
        /// What it wrote. A Lua string is a byte string, so a child that wrote
        /// something that is not UTF-8 arrives intact and decoding stays the
        /// configuration's decision.
        text: String = lua.create_string(bytes)?,
    }

    /// A claim was given a composition layer, and the panel holding it should draw
    /// onto the layer rather than as an in-scene quad.
    LAYER_GRANTED = lunlayergranted(lua, session) as LayerGrantedEvent via onLayerGranted
        from LuaEvent::LayerGranted { claim } =>
    {
        /// The claim that was granted.
        claim: Claim<NullTexture> = Claim::new(Rc::clone(session), *claim),
        /// The layer it now holds. Never cached across frames: what it names goes away
        /// on revoke.
        layer: GrantedLayer = session.claims().push_layer(lua, *claim)?,
    }

    /// A claim lost its layer to a higher-priority one, and the panel holding it
    /// should draw as an in-scene quad until it is granted again.
    LAYER_REVOKED = lunlayerrevoked(_lua, session) as LayerRevokedEvent via onLayerRevoked
        from LuaEvent::LayerRevoked { claim } =>
    {
        /// The claim that was revoked.
        claim: Claim<NullTexture> = Claim::new(Rc::clone(session), *claim),
    }
}

/// Names an event, refusing one that does not fit `CustomEvent.name`.
///
/// The panic is evaluated while the program is compiled, so a name too long for
/// the array is a build failure rather than a buffer overrun in `memcpy`.
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
/// Takes no arguments, because the event carries none: the pending queue is
/// what says which window opened, and the payload table is built here so that
/// it can hold handles a `Variant` could not.
fn dispatch<T: LuaTexture>(
    lua: &Lua,
    session: &Rc<Session<T>>,
    name: EventName,
) -> mlua::Result<()> {
    // Absent when something else pushed this name — `lovr.event.push` is
    // reachable from Lua — or when a handler cleared the queue and the entry
    // outlived the event. Neither is an error; there is simply nothing to
    // report.
    let Some(event) = session.take_event(name) else {
        return Ok(());
    };

    let listeners = session.listeners(name);
    if listeners.is_empty() {
        return Ok(());
    }

    let payload = payload(lua, session, &event)?;

    // Every listener is called, including the ones after a listener that
    // raised. They subscribed independently and one of them failing is not a
    // reason the next does not hear about the event.
    //
    // mlua calls through `lua_pcall` with `luaL_traceback` as the message
    // handler, so an error arrives here with its traceback rather than unwinding
    // `boot.lua`'s poll loop and taking the frame's remaining events with it.
    // `crate::callback_error` is what happens to it next: the rate limiting, the
    // wording, and the panel are `mullion.error`'s, and this is the boundary
    // that hands the error over.
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

/// The `lovr.handlers` table `boot.lua:345` installs.
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

/// Records what it was pushed, standing in for LÖVR's event queue.
///
/// The recorded names are what a test replays through `lovr.handlers` to
/// reproduce `boot.lua`'s poll loop, so the dispatch under test is the
/// production one. Shared rather than owned, so that the copy handed to the
/// session and the copy the test reads are the same recorder.
#[cfg(test)]
#[derive(Clone, Debug, Default)]
pub(crate) struct RecordingEventSink {
    pushed: Rc<RefCell<Vec<EventName>>>,
}

#[cfg(test)]
impl RecordingEventSink {
    /// The names pushed since the last call, in the order they were pushed.
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
