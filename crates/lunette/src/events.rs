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

#[cfg(test)]
use std::cell::RefCell;
use std::{collections::VecDeque, ffi::c_char, fmt, mem, ptr, rc::Rc};

use lunette_capture::monitor::MonitorKey;
use lunette_compositor::protocol::{
    Event as CompositorEvent, ProcessId, ProcessOutcome, Stream, WindowId,
};
use lunette_lovr::raw::{CustomEvent, Event as LovrEvent, EventType_EVENT_CUSTOM, lovrEventPush};
use mlua::{Function, Lua, Table};

use crate::{
    callback_error::report,
    layers::ClaimId,
    lua::{Claim, LuaTexture, Monitor, Process, Session, Window},
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
#[derive(Clone, Copy, PartialEq, Eq)]
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

    for name in EVENT_NAMES {
        let session = Rc::clone(session);
        let dispatcher = lua.create_function(move |lua, ()| dispatch(lua, &session, name))?;
        handlers.set(name.as_str(), dispatcher)?;
    }

    Ok(())
}

/// The `lun*` events this build delivers, and the order they are installed in.
pub(crate) const EVENT_NAMES: [EventName; 8] = [
    WINDOW_OPENED,
    WINDOW_CLOSED,
    TITLE_CHANGED,
    MONITOR_ADDED,
    PROCESS_EXITED,
    PROCESS_OUTPUT,
    LAYER_GRANTED,
    LAYER_REVOKED,
];

const WINDOW_OPENED: EventName = event_name("lunwindowopened");
const WINDOW_CLOSED: EventName = event_name("lunwindowclosed");
const TITLE_CHANGED: EventName = event_name("luntitlechanged");
const MONITOR_ADDED: EventName = event_name("lunmonitoradded");
const PROCESS_EXITED: EventName = event_name("lunprocessexited");
const PROCESS_OUTPUT: EventName = event_name("lunprocessoutput");
const LAYER_GRANTED: EventName = event_name("lunlayergranted");
const LAYER_REVOKED: EventName = event_name("lunlayerrevoked");

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

    let Some(handler) = lua
        .globals()
        .get::<Table>("lovr")?
        .get::<Option<Function>>(name.as_str())?
    else {
        return Ok(());
    };

    let payload = payload(lua, session, &event)?;

    // mlua calls through `lua_pcall` with `luaL_traceback` as the message
    // handler, so an error arrives here with its traceback rather than unwinding
    // `boot.lua`'s poll loop and taking the frame's remaining events with it.
    // `crate::callback_error` is what happens to it next: the rate limiting, the
    // wording, and the panel are `mullion.error`'s, and this is the boundary
    // that hands the error over.
    if let Err(error) = handler.call::<()>(payload) {
        report(lua, &format!("lovr.{name}"), &error);
    }

    Ok(())
}

/// The single table a `lun*` handler is called with.
fn payload<T: LuaTexture>(
    lua: &Lua,
    session: &Rc<Session<T>>,
    event: &LuaEvent,
) -> mlua::Result<Table> {
    let payload = lua.create_table()?;

    match event {
        LuaEvent::WindowOpened { window } | LuaEvent::WindowClosed { window } => {
            payload.set("window", Window::for_id(Rc::clone(session), *window))?;
        }
        LuaEvent::TitleChanged { window, title } => {
            payload.set("window", Window::for_id(Rc::clone(session), *window))?;
            // Also readable as `event.window.title`. Carried explicitly because
            // the callback is about the change, and a handler that wants to
            // diff against what it stored needs the new value in hand.
            payload.set("title", title.as_str())?;
        }
        LuaEvent::MonitorAdded { monitor } => {
            // The identity always, and the handle only while the monitor is
            // still attached: a screen unplugged between the report and the
            // dispatch has nothing left to hand over but its name.
            payload.set("id", monitor.to_string())?;
            if let Some(state) = session.mirrors().state(monitor) {
                payload.set("monitor", Monitor::new(Rc::clone(session), state))?;
            }
        }
        LuaEvent::ProcessExited { process, outcome } => {
            payload.set("process", Process::new(Rc::clone(session), *process))?;
            set_outcome(&payload, outcome)?;
        }
        LuaEvent::ProcessOutput {
            process,
            stream,
            bytes,
        } => {
            payload.set("process", Process::new(Rc::clone(session), *process))?;
            payload.set("stream", stream_name(*stream))?;
            // A Lua string is a byte string, so a child that wrote something
            // that is not UTF-8 arrives intact and decoding stays the
            // configuration's decision.
            payload.set("text", lua.create_string(bytes)?)?;
        }
        LuaEvent::LayerGranted { claim } => {
            payload.set("claim", Claim::new(Rc::clone(session), *claim))?;
            payload.set("layer", session.claims().push_layer(lua, *claim)?)?;
        }
        LuaEvent::LayerRevoked { claim } => {
            payload.set("claim", Claim::new(Rc::clone(session), *claim))?;
        }
    }

    Ok(payload)
}

/// Describes how a process ended, without collapsing the three ways it can.
///
/// The discriminator is a string rather than the presence of a field, so a
/// handler reads `event.outcome` once instead of testing each field in turn,
/// and a spawn that failed is not mistaken for an exit with no code.
fn set_outcome(payload: &Table, outcome: &ProcessOutcome) -> mlua::Result<()> {
    match outcome {
        ProcessOutcome::Exited { code } => {
            payload.set("outcome", "exited")?;
            payload.set("code", *code)
        }
        ProcessOutcome::Signalled { signal } => {
            payload.set("outcome", "signalled")?;
            payload.set("signal", signal.get())
        }
        ProcessOutcome::SpawnFailed { message } => {
            payload.set("outcome", "spawnFailed")?;
            payload.set("message", message.as_str())
        }
    }
}

/// The name Lua spells a captured stream with.
fn stream_name(stream: Stream) -> &'static str {
    match stream {
        Stream::Stdout => "stdout",
        Stream::Stderr => "stderr",
    }
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
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use lunette_compositor::{
        protocol::{ImportedBuffer, PixelSize, SurfaceId},
        surface::{PixelBuffer, ShmFormat},
    };
    use pretty_assertions::assert_eq;

    use super::*;

    fn window_id(raw: u64) -> WindowId {
        WindowId::new(raw).expect("non-zero")
    }

    fn process_id(raw: u64) -> ProcessId {
        ProcessId::new(raw).expect("non-zero")
    }

    /// The longest name `CustomEvent.name` can carry: 31 bytes and the NUL.
    const LONGEST: &str = "lunabcdefghijklmnopqrstuvwxyz01";

    #[test]
    fn every_event_this_build_delivers_has_a_distinct_name() {
        let mut names: Vec<&str> = EVENT_NAMES.iter().map(|name| name.as_str()).collect();
        names.sort_unstable();

        assert_eq!(
            names,
            vec![
                "lunlayergranted",
                "lunlayerrevoked",
                "lunmonitoradded",
                "lunprocessexited",
                "lunprocessoutput",
                "luntitlechanged",
                "lunwindowclosed",
                "lunwindowopened",
            ],
            "a name here is what a configuration writes `function lovr.<name>(event)` against"
        );
    }

    #[test]
    fn a_name_at_the_limit_survives_the_trip_through_the_c_array() {
        assert_eq!(LONGEST.len(), CUSTOM_EVENT_NAME_CAPACITY - 1);

        let name = EventName::new(LONGEST).expect("31 bytes fit");
        let array = name.to_c_name();

        let bytes: Vec<u8> = array.iter().map(|byte| *byte as u8).collect();
        assert_eq!(&bytes[..LONGEST.len()], LONGEST.as_bytes());
        assert_eq!(
            bytes[LONGEST.len()],
            0,
            "the array is what `lovr.handlers` is indexed by, so it has to terminate"
        );
    }

    #[test]
    fn a_name_too_long_for_the_array_is_refused() {
        let overlong = format!("{LONGEST}x");
        assert_eq!(overlong.len(), CUSTOM_EVENT_NAME_CAPACITY);

        // `EventName::new` takes a `&'static str`, and the check is on the
        // length, so leaking one byte of test string is the cheapest way to
        // state the boundary from both sides.
        assert_eq!(EventName::new(String::leak(overlong)), None);
    }

    #[test]
    fn a_name_with_an_embedded_nul_is_refused() {
        assert_eq!(
            EventName::new("lunwindow\0opened"),
            None,
            "the C array would carry only the part before the NUL"
        );
    }

    #[test]
    fn an_empty_array_is_all_zero_beyond_the_name() {
        let array = event_name("lun").to_c_name();
        assert!(array[3..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn the_window_lifecycle_reaches_lua() {
        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::WindowOpened {
                window: window_id(1)
            }),
            Some(LuaEvent::WindowOpened {
                window: window_id(1)
            })
        );
        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::WindowClosed {
                window: window_id(1)
            }),
            Some(LuaEvent::WindowClosed {
                window: window_id(1)
            })
        );
        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::TitleChanged {
                window: window_id(1),
                title: "htop".to_owned(),
            }),
            Some(LuaEvent::TitleChanged {
                window: window_id(1),
                title: "htop".to_owned(),
            })
        );
    }

    #[test]
    fn a_spawn_that_never_started_reaches_lua_as_an_exit() {
        let outcome = ProcessOutcome::SpawnFailed {
            message: "no such file or directory".to_owned(),
        };

        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::ProcessExited {
                process: process_id(3),
                outcome: outcome.clone(),
            }),
            Some(LuaEvent::ProcessExited {
                process: process_id(3),
                outcome,
            }),
            "a mistyped program name has no other way of reaching the configuration"
        );
    }

    #[test]
    fn the_frame_loops_own_reports_are_not_callbacks() {
        let surface = SurfaceId::new(1).expect("non-zero");
        let pixels = PixelBuffer::new(
            PixelSize::new(1, 1),
            ShmFormat::Argb8888,
            vec![0, 0, 0, 255],
        )
        .expect("one pixel");

        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::SurfaceDamaged { surface }),
            None
        );
        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::BufferImported {
                surface,
                buffer: ImportedBuffer::Pixels(pixels),
            }),
            None
        );
        assert_eq!(
            LuaEvent::from_compositor(&CompositorEvent::SurfaceGone { surface }),
            None,
            "a surface is not a window; a window going away is reported on its own"
        );
    }

    #[test]
    fn a_pending_event_is_taken_by_the_name_it_was_pushed_under() {
        let mut queue = EventQueue::default();
        queue.push(LuaEvent::WindowOpened {
            window: window_id(1),
        });

        assert_eq!(queue.take(WINDOW_CLOSED), None);
        assert_eq!(
            queue.take(WINDOW_OPENED),
            Some(LuaEvent::WindowOpened {
                window: window_id(1)
            })
        );
        assert_eq!(
            queue.take(WINDOW_OPENED),
            None,
            "an event is delivered once, or a handler sees the same window open twice"
        );
    }

    #[test]
    fn events_of_one_name_are_taken_in_the_order_they_were_pushed() {
        let mut queue = EventQueue::default();
        for raw in 1..=3 {
            queue.push(LuaEvent::WindowOpened {
                window: window_id(raw),
            });
        }

        let taken: Vec<u64> = (1..=3)
            .filter_map(|_| match queue.take(WINDOW_OPENED) {
                Some(LuaEvent::WindowOpened { window }) => Some(window.get()),
                _ => None,
            })
            .collect();

        assert_eq!(
            taken,
            vec![1, 2, 3],
            "LÖVR's queue is first-in-first-out and so is this one; that is what pairs them"
        );
    }

    #[test]
    fn an_event_of_another_name_does_not_disturb_the_order() {
        let mut queue = EventQueue::default();
        queue.push(LuaEvent::WindowOpened {
            window: window_id(1),
        });
        queue.push(LuaEvent::TitleChanged {
            window: window_id(1),
            title: "htop".to_owned(),
        });
        queue.push(LuaEvent::WindowOpened {
            window: window_id(2),
        });

        assert_eq!(
            queue.take(TITLE_CHANGED),
            Some(LuaEvent::TitleChanged {
                window: window_id(1),
                title: "htop".to_owned(),
            })
        );
        assert_eq!(
            queue.take(WINDOW_OPENED),
            Some(LuaEvent::WindowOpened {
                window: window_id(1)
            })
        );
    }

    #[test]
    fn clearing_drops_what_was_never_dispatched() {
        let mut queue = EventQueue::default();
        queue.push(LuaEvent::WindowOpened {
            window: window_id(1),
        });
        queue.clear();

        assert_eq!(
            queue.take(WINDOW_OPENED),
            None,
            "an event discarded by lovr.event.clear must not be delivered against a later frame's \
             snapshot"
        );
    }

    #[test]
    fn a_recording_sink_reports_each_push_once() {
        let sink = RecordingEventSink::default();
        sink.push(WINDOW_OPENED);
        sink.push(TITLE_CHANGED);

        assert_eq!(sink.take(), vec![WINDOW_OPENED, TITLE_CHANGED]);
        assert_eq!(sink.take(), Vec::new());
    }
}
