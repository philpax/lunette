//! Linux-only: provides the native `lunette` module to Lua.
//!
//! The module exposes compositor, input, texture, and host-integration mechanisms. Configuration
//! policy remains in Lua plugins. Native handles retain the session, not Lua values; plugin
//! attachments are scoped to one Lua state and retire on reload or shutdown.
//!
//! Each frame reads one immutable snapshot. Mutations queue until [`Session::flush`] at frame end,
//! so callbacks do not observe their own changes during the same frame. Invalid arguments raise
//! errors; dead handles return `false` and retain their last-known values. The error boundaries are
//! described in [the Lua API](../../../docs/dev/lua-api.md#errors).

mod claim;
pub mod declarations;
pub mod keys;
mod monitor;
mod output;
mod process;
mod seat;
mod sink;
mod subscribers;
#[cfg(test)]
mod tests;
mod text;
pub mod values;
mod window;

use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ffi::{OsString, c_void},
    mem,
    os::unix::ffi::OsStringExt,
    path::PathBuf,
    rc::Rc,
    sync::Arc,
};

use lunette_compositor::{
    protocol::{
        Argv, Command, OutputId, PixelSize, ProcessId, SeatId, Snapshot, SpawnRequest, WindowId,
        WindowSnapshot,
    },
    state::{DEFAULT_OUTPUT, DEFAULT_SEAT},
};
use lunette_lovr::raw::{_luax_pushtype, ObjectType_T_Texture};
use mlua::{ErrorContext, Function, Lua, Table, Value};

pub use crate::lua::{
    claim::{Claim, ClaimRegistry, LuaLayer, PoolRegistry},
    monitor::Monitor,
    output::Output,
    process::Process,
    seat::Seat,
    sink::Sink,
    text::text_boundaries,
    window::Window,
};
use crate::{
    callback_error::{self, TracedError},
    events::{
        ERROR, EventName, EventQueue, EventSink, LuaEvent, install_dispatchers,
        subscription_functions,
    },
    host::HostSinks,
    keymaps::KeymapCache,
    lua::{
        claim::{ClaimLayer, claim_layer},
        declarations::{FunctionSpec, NullTexture, Options, Record, Type, module, record},
        keys::{KeyCodes, locking_modifier_names, modifier_names},
        monitor::{MonitorSelection, monitor_selection, monitors, select_monitors},
        output::{NewOutput, new_output, outputs},
        seat::{NewSeat, default_seat, new_seat, seats},
        subscribers::{Subscribers, SubscriptionId},
        values::{Cancel, ErrorListener},
    },
    mirrors::MirrorRegistry,
    plugin::{
        attachment::{self, PluginFailure, set_reporter},
        declarations::install as install_plugin,
    },
    properties::WindowProperties,
    reload::reload_from_lua,
    restart::restart_from_lua,
    scale::{STEPS, ScaleStep},
    scene::{Gate, SceneRendering, install_gate},
    texture::{CopyableTexture, FrameGeneration, LovrTexture, MonitorTextures, TextureLedger},
};

/// The name `require` resolves through, and the root of the native surface.
pub const MODULE_NAME: &str = "@lunette";

/// Registers [`MODULE_NAME`] in `package.preload`.
///
/// Each `require` creates a module table for the current session. A reload creates fresh Lua values
/// without retaining references to the prior state.
///
/// # Errors
///
/// Returns an error if `package.preload` is unavailable or the loader cannot be created.
pub fn install<T: LuaTexture>(lua: &Lua, session: &Rc<Session<T>>) -> mlua::Result<()> {
    attachment::install(lua)?;
    // A plugin's load or cleanup failure takes the path a configuration
    // callback's error takes, so `lunette.onError` listeners see it.
    let reporter_session = Rc::clone(session);
    set_reporter(
        lua,
        Rc::new(move |lua: &Lua, failure: &PluginFailure| {
            callback_error::report(
                lua,
                &reporter_session.listeners(ERROR),
                &failure.context(),
                &failure.lua_error(),
            );
        }),
    )?;

    // Before the module, and unconditionally: the gate belongs to the state
    // and not to the module. A configuration that never requires `lunette`
    // still runs inside LÖVR's frame loop.
    let gate_session = Rc::clone(session);
    install_gate(lua, move || gate_session.scene_gate())?;

    let preload: Table = lua.globals().get::<Table>("package")?.get("preload")?;
    let session = Rc::clone(session);
    let loader = lua.create_function(move |lua, ()| module(lua, &session))?;
    preload.set(MODULE_NAME, loader)
}

/// Holds session state shared by Lua handles and the frame loop.
///
/// The session outlives Lua states and runs on the main thread. The Lua API is available only in
/// the main Lua state, not in `lovr.thread` states. The texture type is generic so tests can
/// exercise the session without a graphics device.
#[derive(Debug)]
pub struct Session<T> {
    frame: RefCell<Frame>,
    textures: RefCell<TextureLedger<T>>,
    /// A mirrored monitor's texture, keyed by monitor and not by surface, and
    /// needing none of the surface ledger's death and damage bookkeeping.
    /// [`crate::texture::MonitorTextures`] states why the two are separate
    /// types.
    monitors: RefCell<MonitorTextures<T>>,
    events: RefCell<EventQueue>,
    /// Who is listening for each event, and in what order they subscribed.
    ///
    /// Held here and not on the module table, so a handler registered by a
    /// library and one registered by a configuration are peers: the callback
    /// slot they would otherwise contend for is gone. A soft reload clears the
    /// subscribers, which discards the configuration that registered them while
    /// keeping this state.
    subscribers: RefCell<Subscribers>,
    /// Where a pushed event is announced. Boxed and not a second type
    /// parameter: it is called a few times a frame, and a second type
    /// parameter on every handle costs more to read than the indirection
    /// costs to run.
    sink: Box<dyn EventSink>,
    /// The shared layer pool used by Lua handles and frame rendering.
    claims: Rc<dyn ClaimRegistry>,
    /// The host mirrors shared by Lua handles and frame lifecycle updates.
    mirrors: Rc<dyn MirrorRegistry>,
    /// The host input provider used by sink handles.
    host: Rc<dyn HostSinks>,
    /// Each seat's published layout, compiled on this thread. See
    /// [`crate::keymaps`] for why the compositor cannot provide one.
    keymaps: RefCell<KeymapCache>,
    seat_names: RefCell<seat::SeatNames>,
    /// Per-window properties that survive Lua state reloads.
    properties: RefCell<WindowProperties>,
    /// Requested scene-rendering state. The frame latches it so layer submission and the headset
    /// gate use the same value. The value survives Lua reloads.
    scene: Cell<SceneRendering>,
    /// Whether this frame recorded layer copies that nothing has submitted yet.
    /// [`crate::scene`] describes what happens if they are left unsubmitted.
    unflushed_copies: Cell<bool>,
}

impl<T> Session<T> {
    #[must_use]
    pub fn new(
        sink: Box<dyn EventSink>,
        claims: Rc<dyn ClaimRegistry>,
        mirrors: Rc<dyn MirrorRegistry>,
        host: Rc<dyn HostSinks>,
    ) -> Rc<Self> {
        let empty = Arc::new(Snapshot::default());
        Rc::new(Self {
            frame: RefCell::new(Frame {
                snapshot: Arc::clone(&empty),
                previous: empty,
                generation: FrameGeneration::INITIAL,
                commands: Vec::new(),
                processes: 0,
                seats: 0,
                outputs: 0,
                scene: SceneRendering::default(),
            }),
            textures: RefCell::new(TextureLedger::new()),
            monitors: RefCell::new(MonitorTextures::new()),
            events: RefCell::new(EventQueue::default()),
            subscribers: RefCell::new(Subscribers::default()),
            sink,
            claims,
            mirrors,
            host,
            keymaps: RefCell::new(KeymapCache::default()),
            seat_names: RefCell::new(seat::SeatNames::default()),
            properties: RefCell::new(WindowProperties::new()),
            scene: Cell::new(SceneRendering::default()),
            unflushed_copies: Cell::new(false),
        })
    }

    /// Runs `body` against the per-window properties the session is keeping.
    ///
    /// A closure and not a borrow guard, for the same reason
    /// [`Session::with_textures`] takes one.
    pub fn with_properties<R>(&self, body: impl FnOnce(&mut WindowProperties) -> R) -> R {
        body(&mut self.properties.borrow_mut())
    }

    /// Runs `body` against the compiled keymaps this frame can answer from.
    ///
    /// A closure and not a borrow guard, for the same reason
    /// [`Session::with_textures`] takes one: it is read from inside Lua
    /// callbacks, and a guard held across one would panic on the re-entry.
    pub(crate) fn with_keymaps<R>(&self, body: impl FnOnce(&mut KeymapCache) -> R) -> R {
        body(&mut self.keymaps.borrow_mut())
    }

    #[must_use]
    pub fn claims(&self) -> &dyn ClaimRegistry {
        self.claims.as_ref()
    }

    #[must_use]
    pub fn mirrors(&self) -> &dyn MirrorRegistry {
        self.mirrors.as_ref()
    }

    #[must_use]
    pub fn host(&self) -> &dyn HostSinks {
        self.host.as_ref()
    }

    /// Resolves layer claims and queues grant or revocation events.
    ///
    /// Call after [`Session::begin`] and before event polling. Claims created during callbacks take
    /// effect no earlier than the next frame. Revocations are queued before grants because a grant
    /// may use a layer freed at the same boundary. Handler failures do not undo either transition.
    pub fn resolve_layers(&self) {
        let outcome = self.claims.resolve(self.generation());

        for claim in outcome.revoked {
            self.push_event(LuaEvent::LayerRevoked { claim });
        }
        for claim in outcome.granted {
            self.push_event(LuaEvent::LayerGranted { claim });
        }
    }

    /// Installs a frame snapshot and advances the texture generation.
    ///
    /// Call once per frame, even when the snapshot is unchanged, to invalidate prior-frame texture
    /// references. Events are queued after this call so handlers read the snapshot associated with
    /// each event.
    pub fn begin(&self, snapshot: Arc<Snapshot>) {
        self.events.borrow_mut().clear();

        let live: Vec<SeatId> = snapshot.seats.iter().map(|seat| seat.seat).collect();
        self.keymaps.borrow_mut().retain(&live);
        self.seat_names.borrow_mut().reconcile(&snapshot.seats);

        let mut frame = self.frame.borrow_mut();
        frame.previous = mem::replace(&mut frame.snapshot, snapshot);
        frame.generation = frame.generation.next();
        // Latched once here, so this frame's `setLayers` and this frame's
        // gate answer the same question. A configuration that changes it
        // mid-frame is answered at the next boundary.
        frame.scene = self.scene.get();
        self.unflushed_copies.set(false);

        // A window's properties last as long as a handle can still
        // describe it: one frame past the snapshot losing it.
        // `lunwindowclosed` is dispatched against the frame the window is
        // already gone from, and a handler tidying up after a panel reads them
        // there. [`Session::window`] states the same rule for the same reason.
        let live: Vec<WindowId> = frame
            .snapshot
            .windows
            .iter()
            .chain(frame.previous.windows.iter())
            .map(|window| window.window)
            .collect();
        self.properties.borrow_mut().retain(&live);
    }

    /// Queues an event for `boot.lua`'s poll loop to dispatch this frame.
    ///
    /// Called once per compositor report, after [`Session::begin`] has
    /// installed the snapshot the report belongs with.
    pub fn push_event(&self, event: LuaEvent) {
        self.sink.push(event.name());
        self.events.borrow_mut().push(event);
    }

    /// Adds a listener, answering the ticket that removes it.
    pub(crate) fn subscribe(&self, name: EventName, handler: Function) -> SubscriptionId {
        self.subscribers.borrow_mut().add(name, handler)
    }

    /// Removes a listener. A ticket that names nothing, because it was already
    /// cancelled or because a reload discarded it, removes nothing.
    pub(crate) fn unsubscribe(&self, id: SubscriptionId) {
        self.subscribers.borrow_mut().remove(id);
    }

    /// Everyone listening for an event, in the order they subscribed.
    ///
    /// Returns a snapshot of listeners. Changes made by handlers affect later dispatches, not the
    /// current listener list.
    pub(crate) fn listeners(&self, name: EventName) -> Vec<Function> {
        self.subscribers.borrow().listeners(name)
    }

    /// Discards every listener. A soft reload does this before it re-runs the
    /// configuration.
    pub fn clear_subscribers(&self) {
        self.subscribers.borrow_mut().clear();
    }

    /// Takes the event a dispatch is for, if it is still pending.
    pub(crate) fn take_event(&self, name: EventName) -> Option<LuaEvent> {
        self.events.borrow_mut().take(name)
    }

    /// Returns current or previous-frame data for a window.
    ///
    /// The previous snapshot supplies last-known values to `lunwindowclosed` handles.
    pub(crate) fn window(&self, id: WindowId) -> Option<WindowSnapshot> {
        let frame = self.frame.borrow();
        [&frame.snapshot, &frame.previous]
            .into_iter()
            .find_map(|snapshot| {
                snapshot
                    .windows
                    .iter()
                    .find(|window| window.window == id)
                    .cloned()
            })
    }

    /// Returns queued mutations in submission order and clears the frame queue.
    ///
    /// The caller sends them outside Lua callbacks because sending can block.
    #[must_use]
    pub fn flush(&self) -> Vec<Command> {
        mem::take(&mut self.frame.borrow_mut().commands)
    }

    /// The snapshot the frame is answering from.
    #[must_use]
    pub fn snapshot(&self) -> Arc<Snapshot> {
        Arc::clone(&self.frame.borrow().snapshot)
    }

    /// Which frame is being drawn.
    #[must_use]
    pub fn generation(&self) -> FrameGeneration {
        self.frame.borrow().generation
    }

    /// Whether lunette renders a scene of its own this frame.
    ///
    /// The frame's `setLayers` carries it as `main`, and the gate on
    /// `lovr.headset.getPass` answers from it.
    #[must_use]
    pub fn scene(&self) -> SceneRendering {
        self.frame.borrow().scene
    }

    /// What the configuration last requested. The next frame latches it.
    #[must_use]
    pub fn requested_scene(&self) -> SceneRendering {
        self.scene.get()
    }

    /// Records the value `lunette.setSceneEnabled` received, for the next
    /// boundary.
    pub fn set_scene(&self, scene: SceneRendering) {
        self.scene.set(scene);
    }

    /// Records that this frame copied into at least one layer.
    ///
    /// Called by the frame loop after the blit path has run. The purpose is
    /// the flush [`crate::scene`] describes: on a frame that draws no scene,
    /// nothing else submits LÖVR's stream before the layers' swapchain images
    /// are released.
    pub fn note_copies_recorded(&self) {
        self.unflushed_copies.set(true);
    }

    /// Returns the action for a gated headset call.
    ///
    /// The pending flush is consumed so one frame submits its stream at most once.
    #[must_use]
    pub fn scene_gate(&self) -> Gate {
        if self.scene().drawn() {
            return Gate::Through;
        }
        if self.unflushed_copies.replace(false) {
            Gate::SkipAfterFlush
        } else {
            Gate::Skip
        }
    }

    /// Runs `body` with mutable access to the texture ledger.
    ///
    /// The closure bounds the borrow so it cannot remain held across Lua callback re-entry.
    pub fn with_textures<R>(&self, body: impl FnOnce(&mut TextureLedger<T>) -> R) -> R {
        body(&mut self.textures.borrow_mut())
    }

    /// Runs `body` with mutable access to mirrored-monitor textures.
    pub fn with_monitor_textures<R>(&self, body: impl FnOnce(&mut MonitorTextures<T>) -> R) -> R {
        body(&mut self.monitors.borrow_mut())
    }

    /// Queues a mutation for the frame's flush.
    pub(crate) fn queue(&self, command: Command) {
        self.seat_names.borrow_mut().apply(&command);
        self.frame.borrow_mut().commands.push(command);
    }

    /// Allocates an identifier before the spawn request reaches the compositor.
    ///
    /// The main thread returns the process handle immediately. Compositor-assigned identifiers for
    /// adopted processes use the opposite end of the identifier range.
    fn mint_process(&self) -> Option<ProcessId> {
        let mut frame = self.frame.borrow_mut();
        frame.processes = frame.processes.checked_add(1)?;
        ProcessId::new(frame.processes)
    }

    /// Allocates an identifier before the seat creation request reaches the compositor.
    ///
    /// The range begins after the default seat's identifier.
    fn mint_seat(&self) -> Option<SeatId> {
        let mut frame = self.frame.borrow_mut();
        frame.seats = frame.seats.checked_add(1)?;
        SeatId::new(DEFAULT_SEAT.get().checked_add(frame.seats)?)
    }

    /// Allocates an identifier after the default output's identifier.
    fn mint_output(&self) -> Option<OutputId> {
        let mut frame = self.frame.borrow_mut();
        frame.outputs = frame.outputs.checked_add(1)?;
        OutputId::new(DEFAULT_OUTPUT.get().checked_add(frame.outputs)?)
    }
}

/// A frame's snapshot, mutations, and minted identifiers.
#[derive(Debug)]
struct Frame {
    snapshot: Arc<Snapshot>,
    /// The previous frame's snapshot, kept only so a handle minted for
    /// something absent from the current snapshot can still answer with its
    /// data.
    previous: Arc<Snapshot>,
    generation: FrameGeneration,
    /// The mutations made so far this frame, in the order they were made.
    commands: Vec<Command>,
    /// The highest process identifier minted so far.
    processes: u64,
    seats: u64,
    outputs: u64,
    /// Whether lunette renders a scene of its own this frame, latched from
    /// [`Session::scene`] at the boundary.
    scene: SceneRendering,
}

/// Converts a texture into the value Lua receives.
///
/// This boundary needs a graphics device. Snapshot-backed handle behavior does not, so tests can
/// use an integer texture. [`CopyableTexture`] also supports `window:stabilize()`.
pub trait LuaTexture: CopyableTexture + 'static {
    /// Produces the value Lua holds for this texture.
    ///
    /// # Errors
    ///
    /// If the value could not be pushed onto the stack.
    fn push(&self, lua: &Lua) -> mlua::Result<Value>;
}

impl LuaTexture for LovrTexture {
    /// Pushes LÖVR's own `Texture` userdata, not a wrapper around it.
    ///
    /// Lua receives the object `lovr.graphics` would have supplied, with the
    /// full `Texture` metatable, because a wrapper would have to re-export
    /// every method LÖVR already binds and would not be accepted by the LÖVR
    /// functions that take a texture.
    fn push(&self, lua: &Lua) -> mlua::Result<Value> {
        let pointer = self.as_raw().cast::<c_void>();

        // SAFETY: `exec_raw` locks the state and hands the closure the raw
        // pointer under a stack guard, and it runs the closure inside a
        // protected call, so the allocation `_luax_pushtype` performs cannot
        // longjmp past mlua. `_luax_pushtype` retains the object itself, so
        // the reference this type holds is untouched.
        unsafe {
            lua.exec_raw((), |state| {
                _luax_pushtype(state.cast(), ObjectType_T_Texture as i32, pointer);
            })
        }
    }
}

/// Builds the module table.
fn module<T: LuaTexture>(lua: &Lua, session: &Rc<Session<T>>) -> mlua::Result<Table> {
    let module = lua.create_table()?;

    for function in module_functions::<T>()
        .into_iter()
        .chain(subscription_functions::<T>())
    {
        module.set(function.spec.name, (function.build)(lua, session)?)?;
    }

    // Here and not in `install`, because `boot.lua` creates
    // `lovr.handlers` after `package.preload` has been populated and before
    // `main.luau` runs. The first `require` is the earliest moment the table
    // exists, and the only moment the module is known to be needed.
    install_dispatchers(lua, session)?;
    install_plugin(lua, &module)?;

    Ok(module)
}

/// One entry on the module table: what it is called, what its type is, and how
/// it is built. The declaration and the closure are one item, so the generated
/// Luau cannot describe a function that is not there.
pub(crate) struct ModuleFunction<T> {
    pub spec: FunctionSpec,
    /// The Luau type, derived from what the closure takes and returns.
    pub ty: fn() -> Type,
    pub build: fn(&Lua, &Rc<Session<T>>) -> mlua::Result<mlua::Function>,
}

module! {
    /// Every mapped toplevel, as of this frame's snapshot.
    fn windows(lua, session) -> Vec<Window<T>> { window_handles(lua, session) }

    /// Runs a program as a client of this compositor. The handle comes back
    /// before the request reaches the compositor, so it describes a process
    /// that does not exist yet: `alive` is false until the snapshot lists
    /// it.
    fn spawn(_lua, session, options: Options<Spawn>) -> Process<T> { spawn(session, &options) }

    /// The user's own screens, whether or not they are being mirrored.
    fn monitors(lua, session) -> Vec<Monitor<T>> { monitors(lua, session) }

    /// Requests fresh host-monitor selection without a restore token. Existing captures continue until success. False returns a refusal message.
    fn selectMonitors(_lua, session) -> (bool, Option<String>) { Ok(select_monitors(session)) }

    /// The latest explicit selection's status. A failed or pending request can coexist with running captures.
    fn monitorSelection(_lua, session) -> MonitorSelection { Ok(monitor_selection(session)) }

    /// Requests a composition layer for a window's pixels. Claims are ranked at the frame boundary, so a fresh claim is granted no earlier than the next frame.
    fn claimLayer(_lua, session, options: Options<ClaimLayer>) -> Claim<T> {
        claim_layer(session, &options)
    }

    /// A seat with its own pointer, keyboard, and keymap. Dead until the compositor has created it; the same rule applies to `spawn`.
    fn newSeat(_lua, session, name: String, options: Option<Options<NewSeat>>) -> Seat<T> {
        new_seat(session, &name, options.as_ref())
    }

    /// Every seat, including the one each session starts with.
    fn seats(lua, session) -> Vec<Seat<T>> { seats(lua, session) }

    /// The seat used when an input call omits its seat argument. Returns nil when this frame's snapshot has no default seat. Each call returns a fresh handle; compare seat ids for identity.
    fn defaultSeat(_lua, session) -> Option<Seat<T>> { Ok(default_seat(session)) }

    /// An output for clients to lay out against.
    fn newOutput(_lua, session, options: Options<NewOutput>) -> Output<T> {
        new_output(session, &options)
    }

    /// Every output, including the default one.
    fn outputs(lua, session) -> Vec<Output<T>> { outputs(lua, session) }

    /// Whether lunette draws a scene of its own. Latched at the next frame boundary, and kept across a soft reload.
    fn setSceneEnabled(_lua, session, enabled: bool) -> () {
        session.set_scene(SceneRendering::from_enabled(enabled));
        Ok(())
    }

    /// The value `setSceneEnabled` received last. The next frame latches it.
    fn sceneEnabled(_lua, session) -> bool { Ok(session.requested_scene().drawn()) }

    /// Calls `handler` whenever a callback raises, and answers the function that stops it. The standard library's error module subscribes to draw a panel; without a subscription, the error reaches the log and nothing else.
    fn onError(lua, session, handler: ErrorListener) -> Cancel {
        let id = session.subscribe(ERROR, handler.0);
        let cancelling = Rc::clone(session);
        lua.create_function(move |_, ()| {
            cancelling.unsubscribe(id);
            Ok(())
        })
        .map(Cancel)
    }

    /// Reports an error as a raising callback is reported: it is logged and every `lunette.onError` listener is notified. `context` leads the message. A dispatcher that protects each of several handlers reports one handler's error with it and continues with the next.
    fn reportError(lua, session, options: Options<ReportError>) -> () {
        let report = report_error_fields(options.table())?;
        callback_error::report_traced(lua, &session.listeners(ERROR), &report);
        Ok(())
    }

    /// Every modifier name a seat accepts, in the order a keymap numbers them. `seat:setModifiers` takes these names, and `seat.modifiers` returns them.
    fn modifierNames(_lua, _session) -> Vec<String> { Ok(modifier_names()) }

    /// Locked modifier names form a subset of `modifierNames()`. Each locked modifier toggles on a
    /// press.
    fn lockingModifierNames(_lua, _session) -> Vec<String> { Ok(locking_modifier_names()) }

    /// Every key lunette names, by name, as the evdev keycode `sink:key` takes. The table is fresh on each call.
    fn keyCodes(_lua, _session) -> KeyCodes { Ok(KeyCodes) }

    /// Returns a fresh array of one-based byte offsets for extended grapheme clusters, including the terminal offset `#text + 1`. Empty text returns `{ 1 }`. The text must be valid UTF-8; invalid byte strings raise an error.
    fn textBoundaries(_lua, _session, text: mlua::LuaString) -> Vec<usize> {
        text_boundaries(text)
    }

    /// The ladder a layer's requested size is quantised up, ascending. A panel whose scale Lua raises requests a size the free list already holds.
    fn scaleSteps(_lua, _session) -> Vec<f64> { Ok(scale_steps()) }

    /// Shuts down plugin runtimes, retires their contract epoch, and re-runs the configuration in the same Lua state, keeping the compositor, the clients, and their textures. Answers whether it loaded, and the error if it did not.
    fn reload(lua, session) -> (bool, Option<String>) {
        reload_from_lua(lua, session.mirrors(), &|| session.clear_subscribers())
    }

    /// Tears the session down and starts it again, graphics device included.
    fn restart(lua, _session) -> () { restart_from_lua(lua) }
}

/// `lunette.windows()`: every mapped toplevel, as of this frame's snapshot.
fn window_handles<T: LuaTexture>(
    _lua: &Lua,
    session: &Rc<Session<T>>,
) -> mlua::Result<Vec<Window<T>>> {
    let snapshot = session.snapshot();
    Ok(snapshot
        .windows
        .iter()
        .map(|window| Window::new(Rc::clone(session), window))
        .collect())
}

/// `lunette.scaleSteps()`: the scale ladder, ascending, as plain numbers.
///
/// The same ladder [`crate::scale`] quantises a layer's requested size against.
/// One ladder and not two, so a panel whose scale Lua raises requests a size
/// the free list already holds and does not force an allocation. An
/// allocation blocks on `XR_INFINITE_DURATION`.
fn scale_steps() -> Vec<f64> {
    STEPS
        .iter()
        .map(|step| f64::from(step.in_120ths()) / f64::from(ScaleStep::DENOMINATOR))
        .collect()
}

/// `lunette.spawn{ argv = …, env = …, cwd = …, xwayland = … }`.
///
/// The handle comes back before the request reaches the compositor, so it
/// describes a process that does not exist yet: `alive` is false until the
/// snapshot lists it, and a spawn that fails outright is reported through
/// `lovr.lunprocessexited` and not by this call raising.
fn spawn<T: LuaTexture>(
    session: &Rc<Session<T>>,
    options: &Options<Spawn>,
) -> mlua::Result<Process<T>> {
    let options = options.table();

    let argv = Argv::from_list(strings(options, "argv")?).ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: spawn needs an argv naming a program to run, and the list given was empty",
        )
    })?;

    let env = match options.get::<Option<Table>>("env")? {
        Some(table) => {
            let mut env = Vec::new();
            for pair in table.pairs::<mlua::LuaString, mlua::LuaString>() {
                let (name, value) = pair?;
                env.push((os_string(&name), os_string(&value)));
            }
            // Two variables set in one table have no order of their own, and a
            // child's environment is not order-sensitive, but a stable order
            // makes what was sent reproducible.
            env.sort_unstable();
            env
        }
        None => Vec::new(),
    };

    let process = session.mint_process().ok_or_else(|| {
        mlua::Error::runtime("lunette: the process identifier space is exhausted")
    })?;

    session.queue(Command::Spawn(SpawnRequest {
        process,
        argv,
        env,
        cwd: options
            .get::<Option<mlua::LuaString>>("cwd")?
            .map(|cwd| PathBuf::from(os_string(&cwd))),
        output: spawn_output::<T>(options)?,
        xwayland: options.get::<Option<bool>>("xwayland")?.unwrap_or(false),
    }));

    Ok(Process::new(Rc::clone(session), process))
}

/// The only output the spawned client is shown, if the caller named one.
///
/// Absent means the output every session starts with; a client lunette did not
/// spawn is shown that output too. The value is an output handle and not an
/// identifier, so a caller cannot pass a number that happens to be in range
/// and mean something else by it.
fn spawn_output<T: LuaTexture>(options: &Table) -> mlua::Result<Option<OutputId>> {
    let Some(value) = options.get::<Option<Value>>("output")? else {
        return Ok(None);
    };

    match &value {
        Value::UserData(handle) => Ok(Some(handle.borrow::<Output<T>>()?.id())),
        other => Err(mlua::Error::runtime(format!(
            "lunette: spawn's output takes an output handle from lunette.newOutput, not a {}",
            other.type_name()
        ))),
    }
}

record! {
    /// What a listener for an error raised inside a callback is given.
    struct ErrorEvent {
        /// The error, with the boundary it came through leading it.
        message: String,
        /// Where it was raised, as Lua reports it.
        traceback: String,
    }
}

record! {
    /// What `lunette.reportError` takes.
    options ReportError as ReportErrorOptions {
        /// The dispatcher or operation the error came through. It leads the message.
        context: String,
        /// The error itself.
        message: String,
        /// Where it was raised, as Lua reports it.
        traceback: Option<String>,
    }
}

/// Reads `lunette.reportError` fields and names a missing or mistyped one in the error.
fn report_error_fields(options: &Table) -> mlua::Result<TracedError> {
    let context: String = options
        .get("context")
        .context("lunette: reportError's context")?;
    let message: String = options
        .get("message")
        .context("lunette: reportError's message")?;
    let traceback: Option<String> = options
        .get("traceback")
        .context("lunette: reportError's traceback")?;
    Ok(TracedError {
        message: format!("{context}: {message}"),
        traceback: traceback.unwrap_or_default(),
    })
}

record! {
    /// What `lunette.spawn` takes.
    options Spawn as SpawnOptions {
        /// The program and its arguments. The list may not be empty.
        argv: Vec<String>,
        cwd: Option<String>,
        /// Added to the environment the session was started with.
        env: Option<HashMap<String, String>>,
        /// The only output the client is shown. Absent means the default one;
        /// a client lunette did not spawn is shown that output too.
        output: Option<Output<NullTexture>>,
        xwayland: Option<bool>,
    }
}

/// Refuses a table carrying an option this build does not act on.
///
/// A silently ignored option is a configuration that does not do what it
/// states; the failure shows as behaviour and not as an error. The
/// accepted names come from the declaration the generated Luau is rendered
/// from, so the two cannot disagree.
pub(crate) fn reject_unknown_options(options: &Table, known: &Record) -> mlua::Result<()> {
    for pair in options.pairs::<Value, Value>() {
        let (key, _) = pair?;
        let name = match &key {
            Value::String(name) => name.to_string_lossy(),
            other => other.type_name().to_owned(),
        };
        if !known.names().any(|accepted| accepted == name) {
            return Err(mlua::Error::runtime(format!(
                "lunette: '{name}' is not an option here; this call takes {}",
                known.names().collect::<Vec<_>>().join(", ")
            )));
        }
    }

    Ok(())
}

/// Reads an array of strings out of an option table.
fn strings(options: &Table, name: &str) -> mlua::Result<Vec<OsString>> {
    let Some(list) = options.get::<Option<Table>>(name)? else {
        return Ok(Vec::new());
    };

    list.sequence_values::<mlua::LuaString>()
        .map(|value| value.map(|value| os_string(&value)))
        .collect()
}

/// A Lua string as an operating-system string.
///
/// Lua strings are byte strings, and a program's arguments and environment are
/// byte strings, so the conversion preserves the bytes and does not require
/// UTF-8. A path or a variable that is not valid UTF-8 is unusual and legal,
/// and WayVR's equivalent read fails on that case.
fn os_string(value: &mlua::LuaString) -> OsString {
    OsString::from_vec(value.as_bytes().to_vec())
}

/// Checks a pair of numbers before they are taken for a size in pixels.
///
/// `noun` names what is being sized, so the error message names the argument
/// the caller got wrong when a configuration is sizing several things a frame.
fn pixel_size(width: f64, height: f64, noun: &str) -> mlua::Result<PixelSize> {
    let pixels = |value: f64| {
        // The bound makes the cast below exact: a finite whole number
        // in `1 ..= u32::MAX` is representable in both.
        (value.is_finite() && value >= 1.0 && value <= f64::from(u32::MAX) && value.fract() == 0.0)
            .then_some(value as u32)
    };

    match (pixels(width), pixels(height)) {
        (Some(width), Some(height)) => Ok(PixelSize::new(width, height)),
        _ => Err(mlua::Error::runtime(format!(
            "lunette: ({width}, {height}) is not a {noun}; both are whole pixel counts and have to \
             be at least one"
        ))),
    }
}
