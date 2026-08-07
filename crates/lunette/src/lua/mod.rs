//! Linux-only: the `lunette` module, which is the native mechanism Lua is
//! written against.
//!
//! `require('lunette')` resolves to the table [`install`] registers. Everything
//! reachable from it is mechanism: what a window is, where its pixels are, and
//! where a pointer event goes. Policy — panels, layouts, placement rules — is
//! `mullion`, is written in Lua against this same surface, and is not here.
//!
//! # Rust holds no reference into Lua
//!
//! Nothing here keeps a `Lua`, a `RegistryKey`, or any handle to a Lua value
//! beyond the call that produced it. The closures registered below capture an
//! [`Rc<Session>`] and nothing else, and every handle answers by reading
//! through that `Rc`.
//!
//! That is a prohibition rather than a preference. The soft reload discards the
//! Lua state and re-runs `main.lua` while the compositor, the clients, and the
//! textures keep running, and it can only do that if the Rust side is holding
//! nothing the discarded state owned. A cached `Table` here would be a dangling
//! registry reference the moment a reload happened.
//!
//! # The frame
//!
//! [`Session::begin`] installs the frame's snapshot and advances the frame
//! generation. Every read a callback performs during that frame answers from
//! that one snapshot, so two reads cannot straddle a publication and describe
//! two different instants.
//!
//! Mutations do not reach the compositor as they are made. They queue on the
//! session, and [`Session::flush`] hands the frame's queue over once, at frame
//! end. A callback therefore never observes the effect of its own mutation
//! within the frame it made it, which is the same rule the protocol underneath
//! imposes anyway.
//!
//! # Errors
//!
//! A defect in the caller's code raises: a malformed argument, an unknown
//! option, a coordinate that is not a number. A race with a client that has
//! exited does not — a dead handle answers `false` and reads its last-known
//! values, because taking the session down over a window closing half a frame
//! early is worse than doing nothing. `docs/decisions.md` records that choice.
//!
//! Raising is safe: `boot.lua` runs every callback under `xpcall`, and the
//! handler reports. Nothing here swallows an error to keep a frame alive.

mod claim;
mod monitor;
mod output;
mod process;
mod seat;
mod sink;
#[cfg(test)]
mod tests;
mod window;

use std::{
    cell::{Cell, RefCell},
    ffi::{OsString, c_void},
    mem,
    os::unix::ffi::OsStringExt,
    path::PathBuf,
    rc::Rc,
    sync::Arc,
};

use lunette_compositor::{
    protocol::{
        Argv, Command, OutputId, PixelSize, PointerButton, ProcessId, SeatId, Snapshot,
        SpawnRequest, WindowId, WindowSnapshot,
    },
    state::{DEFAULT_OUTPUT, DEFAULT_SEAT},
};
use lunette_lovr::raw::{_luax_pushtype, ObjectType_T_Texture};
use mlua::{Lua, Table, Value};

pub use crate::lua::{
    claim::{Claim, ClaimRegistry, LuaLayer, PoolRegistry},
    monitor::Monitor,
    output::Output,
    process::Process,
    seat::Seat,
    sink::Sink,
    window::Window,
};
use crate::{
    events::{EventName, EventQueue, EventSink, LuaEvent, install_dispatchers},
    host::HostSinks,
    keymaps::KeymapCache,
    lua::{
        claim::claim_layer,
        monitor::monitors,
        output::{new_output, outputs},
        seat::{new_seat, seats},
    },
    mirrors::MirrorRegistry,
    properties::WindowProperties,
    reload::reload_from_lua,
    restart::restart_from_lua,
    scale::{STEPS, ScaleStep},
    scene::{Gate, SceneRendering, install_gate},
    texture::{CopyableTexture, FrameGeneration, LovrTexture, MonitorTextures, TextureLedger},
};

/// The name `require` resolves through, and the root of the native surface.
pub const MODULE_NAME: &str = "lunette";

/// Registers the module so that `require('lunette')` resolves.
///
/// Called on LÖVR's own state before `boot.lua` runs. The module is built by
/// the loader rather than being built once and captured, so that a soft reload
/// — which clears `package.loaded` and re-runs `main.lua` — gets a fresh table
/// built against the same session, and so that no Lua value is held in Rust
/// between calls.
///
/// # Errors
///
/// If `package.preload` cannot be reached, or the loader cannot be created.
pub fn install<T: LuaTexture>(lua: &Lua, session: &Rc<Session<T>>) -> mlua::Result<()> {
    // Before the module, and unconditionally: the gate belongs to the state
    // rather than to the module, and a configuration that never requires
    // `lunette` still runs inside LÖVR's frame loop.
    let gate_session = Rc::clone(session);
    install_gate(lua, move || gate_session.scene_gate())?;

    let preload: Table = lua.globals().get::<Table>("package")?.get("preload")?;
    let session = Rc::clone(session);
    let loader = lua.create_function(move |lua, ()| module(lua, &session))?;
    preload.set(MODULE_NAME, loader)
}

/// Registers the module on a Lua state lunette does not own.
///
/// `Lua::get_or_init_from_ptr` constructs mlua's view of an existing state with
/// its `owned` flag clear, so mlua never closes LÖVR's state; the boot sequence
/// keeps that responsibility. Calling it twice on the same state returns the
/// same instance rather than building a second one.
///
/// # Safety
///
/// `state` must be a live Lua state that outlives every call made through the
/// module — in practice LÖVR's main state, between `luax_preload` and loading
/// `boot.lua`. The standard library must already be open, because the module is
/// registered through `package.preload`.
///
/// # Errors
///
/// As [`install`].
pub unsafe fn install_on_state<T: LuaTexture>(
    state: *mut mlua::ffi::lua_State,
    session: &Rc<Session<T>>,
) -> mlua::Result<()> {
    // SAFETY: the caller guarantees the state, and the reference is consumed
    // before this function returns rather than being stored anywhere.
    let lua = unsafe { Lua::get_or_init_from_ptr(state) };
    install(lua, session)
}

/// What the Lua module reads, and where its mutations queue.
///
/// One exists per process, from before the Lua state does. The frame loop holds
/// an [`Rc`] to it and so does every closure the module registers; both run on
/// the main thread, which is why the interior mutability is a [`RefCell`] and
/// not a lock. The Lua API is available only in the main state, and
/// `lovr.thread` states do not receive it.
///
/// Generic over the texture for the reason [`TextureLedger`] is: the conversion
/// this module performs needs a Lua state and no graphics device, and the
/// generic is what lets the tests supply a texture that is a plain integer.
#[derive(Debug)]
pub struct Session<T> {
    frame: RefCell<Frame>,
    textures: RefCell<TextureLedger<T>>,
    /// A mirrored monitor's texture, which is keyed by monitor rather than by
    /// surface and needs none of the surface ledger's death and damage
    /// bookkeeping. [`crate::texture::MonitorTextures`] says why the two are
    /// separate types.
    monitors: RefCell<MonitorTextures<T>>,
    events: RefCell<EventQueue>,
    /// Where a pushed event is announced. Boxed rather than a second type
    /// parameter: it is called a handful of times a frame, and threading
    /// another generic through every handle would cost more to read than the
    /// indirection costs to run.
    sink: Box<dyn EventSink>,
    /// Which claims hold composition layers. Behind a trait for the same reason
    /// the sink is, and shared rather than owned because the frame loop drives
    /// the blit and the submit through the same pool.
    claims: Rc<dyn ClaimRegistry>,
    /// Which of the host's monitors are mirrored. Behind a trait and shared for
    /// the same reasons the pool is: the frame loop advances the portal exchange
    /// through the same lifecycle Lua mirrors and dismisses through.
    mirrors: Rc<dyn MirrorRegistry>,
    /// Where a host sink's input goes. Behind a trait for the same reason: the
    /// provider chain belongs to `lunette-capture`, and threading it through
    /// every handle as a type parameter would cost more to read than the
    /// indirection costs to run.
    host: Rc<dyn HostSinks>,
    /// Each seat's published layout, compiled on this thread. See
    /// [`crate::keymaps`] for why the compositor cannot hand one over.
    keymaps: RefCell<KeymapCache>,
    /// Per-window state the configuration asked to be kept for it. Here rather
    /// than in Lua because the session outlives the Lua state and a soft reload
    /// discards it; [`crate::properties`] states the whole reasoning.
    properties: RefCell<WindowProperties>,
    /// Whether the configuration wants lunette's own scene rendered. Read at
    /// the frame boundary into [`Frame::scene`] rather than live, so that the
    /// frame's `setLayers` and the frame's gate cannot disagree.
    ///
    /// Sticky across frames, and across a soft reload: a reload discards the
    /// Lua state and this is not part of it, so a configuration that had turned
    /// the scene off keeps it off until it says otherwise. Every reloaded
    /// configuration sets it from `lovr.update` anyway, which runs before
    /// anything is drawn.
    scene: Cell<SceneRendering>,
    /// Whether this frame recorded layer copies that nothing has submitted yet.
    /// [`crate::scene`] says what happens if they are left unsubmitted.
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
            sink,
            claims,
            mirrors,
            host,
            keymaps: RefCell::new(KeymapCache::default()),
            properties: RefCell::new(WindowProperties::new()),
            scene: Cell::new(SceneRendering::default()),
            unflushed_copies: Cell::new(false),
        })
    }

    /// Runs `body` against the per-window properties the session is keeping.
    ///
    /// A closure rather than a borrow guard, for the reason
    /// [`Session::with_textures`] takes one.
    pub fn with_properties<R>(&self, body: impl FnOnce(&mut WindowProperties) -> R) -> R {
        body(&mut self.properties.borrow_mut())
    }

    /// Runs `body` against the compiled keymaps this frame can answer from.
    ///
    /// A closure rather than a borrow guard, for the reason
    /// [`Session::with_textures`] takes one: it is read from inside Lua
    /// callbacks, and a guard held across one would panic on the re-entry.
    pub(crate) fn with_keymaps<R>(&self, body: impl FnOnce(&mut KeymapCache) -> R) -> R {
        body(&mut self.keymaps.borrow_mut())
    }

    /// The pool, for the handles that read it and the frame loop that drives it.
    #[must_use]
    pub fn claims(&self) -> &dyn ClaimRegistry {
        self.claims.as_ref()
    }

    /// The host's monitors, for the handles that read them.
    #[must_use]
    pub fn mirrors(&self) -> &dyn MirrorRegistry {
        self.mirrors.as_ref()
    }

    /// The host desktop, for the sinks that deliver to it.
    #[must_use]
    pub fn host(&self) -> &dyn HostSinks {
        self.host.as_ref()
    }

    /// Assigns the pool's layers for this frame, announcing what changed.
    ///
    /// Called once at frame start, after [`Session::begin`] and before
    /// `boot.lua` polls, so that a claim made during a callback is granted no
    /// earlier than the next frame and a panel's realisation cannot change
    /// between its `lovr.update` and its `lovr.draw`. Both events therefore
    /// reach their handlers ahead of `lovr.update`, and a handler reading
    /// `claim.granted` in the same frame agrees with the event it was handed.
    ///
    /// The grant and the revocation have already happened in Rust by the time
    /// either is announced, so a handler that raises changes neither. It is
    /// reported and the frame continues.
    ///
    /// Revocations are announced before grants, which is the order they happen
    /// in: revoking is what frees the layer a grant in the same boundary takes.
    pub fn resolve_layers(&self) {
        let outcome = self.claims.resolve(self.generation());

        for claim in outcome.revoked {
            self.push_event(LuaEvent::LayerRevoked { claim });
        }
        for claim in outcome.granted {
            self.push_event(LuaEvent::LayerGranted { claim });
        }
    }

    /// Starts a frame against the compositor's latest snapshot.
    ///
    /// Advancing the generation is what invalidates the previous frame's
    /// texture handles, so this runs once per frame even when the snapshot has
    /// not changed.
    ///
    /// The frame's events are drained onto the session after this, never
    /// before: a handler reads through the snapshot installed here, and an
    /// event that arrived ahead of it would describe a window the snapshot has
    /// not heard of.
    pub fn begin(&self, snapshot: Arc<Snapshot>) {
        self.events.borrow_mut().clear();

        let live: Vec<SeatId> = snapshot.seats.iter().map(|seat| seat.seat).collect();
        self.keymaps.borrow_mut().retain(&live);

        let mut frame = self.frame.borrow_mut();
        frame.previous = mem::replace(&mut frame.snapshot, snapshot);
        frame.generation = frame.generation.next();
        // Latched once here, so that this frame's `setLayers` and this frame's
        // gate answer the same question. A configuration that changes it
        // mid-frame is answered at the next boundary.
        frame.scene = self.scene.get();
        self.unflushed_copies.set(false);

        // A window's properties last exactly as long as a handle can still
        // describe it, which is one frame past the snapshot losing it:
        // `lunwindowclosed` is dispatched against the frame the window is
        // already gone from, and a handler tidying up after a panel reads them
        // there. [`Session::window`] draws the same line for the same reason.
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

    /// Takes the event a dispatch is for, if it is still pending.
    pub(crate) fn take_event(&self, name: EventName) -> Option<LuaEvent> {
        self.events.borrow_mut().take(name)
    }

    /// What the snapshot last said about a window, this frame or the one
    /// before.
    ///
    /// The fallback is what makes a `lunwindowclosed` payload useful. The
    /// window is gone from the frame's own snapshot by the time the handler
    /// runs — that is what the event reports — so a handle built from it alone
    /// would know nothing but the identifier.
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

    /// Takes the frame's queued mutations, for the caller to send onward.
    ///
    /// Called once at frame end. The commands are returned rather than sent
    /// from here so that this type does not need to know about the compositor
    /// thread, and so that the send — which can block — happens somewhere a
    /// Lua callback is not running.
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
    /// What the frame's `setLayers` carries as `main`, and what the gate on
    /// `lovr.headset.getPass` answers from.
    #[must_use]
    pub fn scene(&self) -> SceneRendering {
        self.frame.borrow().scene
    }

    /// What the configuration last asked for, which the next frame will latch.
    #[must_use]
    pub fn requested_scene(&self) -> SceneRendering {
        self.scene.get()
    }

    /// Records what `lunette.setSceneEnabled` was told, for the next boundary.
    pub fn set_scene(&self, scene: SceneRendering) {
        self.scene.set(scene);
    }

    /// Records that this frame copied into at least one layer.
    ///
    /// Called by the frame loop after the blit path has run. What it is for is
    /// the flush [`crate::scene`] describes: on a frame that draws no scene,
    /// nothing else submits LÖVR's stream before the layers' swapchain images
    /// are released.
    pub fn note_copies_recorded(&self) {
        self.unflushed_copies.set(true);
    }

    /// What the gate on `lovr.headset.getPass` should do about this call.
    ///
    /// Taking the flush rather than reading it is what makes it happen once a
    /// frame however many gated calls the frame makes.
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

    /// Runs `body` against the ledger of textures the frame may hand out.
    ///
    /// A closure rather than a borrow guard, so that the borrow cannot outlive
    /// the statement that took it — the ledger is read from inside Lua
    /// callbacks, and a guard held across one would panic on the re-entry.
    pub fn with_textures<R>(&self, body: impl FnOnce(&mut TextureLedger<T>) -> R) -> R {
        body(&mut self.textures.borrow_mut())
    }

    /// Runs `body` against the textures the frame's mirrored monitors hold.
    ///
    /// A closure rather than a borrow guard, for the reason
    /// [`Session::with_textures`] takes one.
    pub fn with_monitor_textures<R>(&self, body: impl FnOnce(&mut MonitorTextures<T>) -> R) -> R {
        body(&mut self.monitors.borrow_mut())
    }

    /// Queues a mutation for the frame's flush.
    pub(crate) fn queue(&self, command: Command) {
        self.frame.borrow_mut().commands.push(command);
    }

    /// Allocates the identifier a spawn is reported under.
    ///
    /// The main thread mints it, because `lunette.spawn` returns a handle in
    /// the same call and so the identifier has to exist before the compositor
    /// has seen the request. The compositor allocates identifiers for adopted
    /// processes from the top of the range downwards, so the two cannot meet.
    fn mint_process(&self) -> Option<ProcessId> {
        let mut frame = self.frame.borrow_mut();
        frame.processes = frame.processes.checked_add(1)?;
        ProcessId::new(frame.processes)
    }

    /// Allocates the identifier a seat is created under.
    ///
    /// Minted here for the reason a process identifier is: `lunette.newSeat`
    /// returns a handle in the same call, so the identifier exists before the
    /// compositor has seen the request. Counting from the default seat rather
    /// than from one, because the default seat already holds the first.
    fn mint_seat(&self) -> Option<SeatId> {
        let mut frame = self.frame.borrow_mut();
        frame.seats = frame.seats.checked_add(1)?;
        SeatId::new(DEFAULT_SEAT.get().checked_add(frame.seats)?)
    }

    /// Allocates the identifier an output is created under.
    ///
    /// Minted here for the reason a seat identifier is, and counted from the
    /// default output for the reason a seat is counted from the default seat:
    /// that one already holds the first.
    fn mint_output(&self) -> Option<OutputId> {
        let mut frame = self.frame.borrow_mut();
        frame.outputs = frame.outputs.checked_add(1)?;
        OutputId::new(DEFAULT_OUTPUT.get().checked_add(frame.outputs)?)
    }
}

/// What one frame answers from.
#[derive(Debug)]
struct Frame {
    snapshot: Arc<Snapshot>,
    /// The frame before's, kept only so that a handle minted for something that
    /// has just gone can still say what it was.
    previous: Arc<Snapshot>,
    generation: FrameGeneration,
    /// The mutations made so far this frame, in the order they were made.
    commands: Vec<Command>,
    /// The highest process identifier minted so far.
    processes: u64,
    /// How many seats have been minted beyond the default one.
    seats: u64,
    /// How many outputs have been minted beyond the default one.
    outputs: u64,
    /// Whether lunette renders a scene of its own this frame, latched from
    /// [`Session::scene`] at the boundary.
    scene: SceneRendering,
}

/// How a texture is handed to Lua.
///
/// The seam is here rather than at the ledger because this is the only part of
/// the conversion that needs a graphics device: everything else about a window
/// handle is a projection of a snapshot, and the tests exercise that projection
/// with a texture that is an integer.
///
/// [`CopyableTexture`] is a supertrait rather than a second bound at each use,
/// because `window:stabilize()` is part of the same surface: a texture the
/// module can hand to Lua is one Lua can ask for a stable copy of.
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
    /// Lua receives the object `lovr.graphics` would have handed it, with the
    /// full `Texture` metatable, because a wrapper would have to re-export
    /// every method LÖVR already binds and would not be accepted by the LÖVR
    /// functions that take a texture.
    fn push(&self, lua: &Lua) -> mlua::Result<Value> {
        let pointer = self.as_raw().cast::<c_void>();

        // SAFETY: `exec_raw` locks the state and hands the closure the raw
        // pointer under a stack guard, and it runs the closure inside a
        // protected call, so the allocation `_luax_pushtype` performs cannot
        // longjmp past mlua. `_luax_pushtype` retains the object itself
        // (`api/api.c:262`), so the reference this type holds is untouched.
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

    let windows_session = Rc::clone(session);
    module.set(
        "windows",
        lua.create_function(move |lua, ()| windows(lua, &windows_session))?,
    )?;

    let spawn_session = Rc::clone(session);
    module.set(
        "spawn",
        lua.create_function(move |_, options: Table| spawn(&spawn_session, &options))?,
    )?;

    let monitors_session = Rc::clone(session);
    module.set(
        "monitors",
        lua.create_function(move |lua, ()| monitors(lua, &monitors_session))?,
    )?;

    let claim_session = Rc::clone(session);
    module.set(
        "claimLayer",
        lua.create_function(move |_, options: Table| claim_layer(&claim_session, &options))?,
    )?;

    let new_seat_session = Rc::clone(session);
    module.set(
        "newSeat",
        lua.create_function(
            move |_, (name, options): (mlua::LuaString, Option<Table>)| {
                new_seat(&new_seat_session, &name.to_string_lossy(), options.as_ref())
            },
        )?,
    )?;

    let seats_session = Rc::clone(session);
    module.set(
        "seats",
        lua.create_function(move |lua, ()| seats(lua, &seats_session))?,
    )?;

    let new_output_session = Rc::clone(session);
    module.set(
        "newOutput",
        lua.create_function(move |_, options: Table| new_output(&new_output_session, &options))?,
    )?;

    let outputs_session = Rc::clone(session);
    module.set(
        "outputs",
        lua.create_function(move |lua, ()| outputs(lua, &outputs_session))?,
    )?;

    let set_scene_session = Rc::clone(session);
    module.set(
        "setSceneEnabled",
        lua.create_function(move |_, enabled: bool| {
            set_scene_session.set_scene(SceneRendering::from_enabled(enabled));
            Ok(())
        })?,
    )?;

    let scene_session = Rc::clone(session);
    module.set(
        "sceneEnabled",
        lua.create_function(move |_, ()| Ok(scene_session.requested_scene().drawn()))?,
    )?;

    // Captures nothing: the ladder is a constant of the build, not a property of
    // a session.
    module.set(
        "scaleSteps",
        lua.create_function(|lua, ()| scale_steps(lua))?,
    )?;

    // Captures nothing. A reload is entirely a matter of the Lua state — the
    // compositor, the clients, and their textures are not touched by one — so
    // this reaches for no session and holds no Lua value between calls.
    module.set(
        "reload",
        lua.create_function(|lua, ()| reload_from_lua(lua))?,
    )?;

    // Captures nothing, for the same reason `reload` does not: the restart is
    // asked for by pushing LÖVR's own event, and the teardown that follows it
    // belongs to the frame loop rather than to anything reachable from here.
    module.set(
        "restart",
        lua.create_function(|lua, ()| restart_from_lua(lua))?,
    )?;

    // Here rather than in `install`, because `boot.lua:345` creates
    // `lovr.handlers` after `package.preload` has been populated and before
    // `main.lua` runs — so the first `require` is the earliest moment the table
    // exists, and the only one at which the module is known to be wanted.
    install_dispatchers(lua, session)?;

    Ok(module)
}

/// `lunette.windows()`: every mapped toplevel, as of this frame's snapshot.
fn windows<T: LuaTexture>(lua: &Lua, session: &Rc<Session<T>>) -> mlua::Result<Table> {
    let snapshot = session.snapshot();
    let windows = lua.create_table_with_capacity(snapshot.windows.len(), 0)?;

    for (index, window) in (1..).zip(&snapshot.windows) {
        windows.set(index, Window::new(Rc::clone(session), window))?;
    }

    Ok(windows)
}

/// `lunette.scaleSteps()`: the scale ladder, ascending, as plain numbers.
///
/// The same ladder [`crate::scale`] quantises a layer's requested size against.
/// One ladder rather than two, so that a panel whose scale Lua raises asks the
/// pool for a size the free list already holds instead of forcing an allocation
/// — and an allocation blocks on `XR_INFINITE_DURATION`.
///
/// A fresh table each call rather than one shared table, so a configuration that
/// writes into what it was handed cannot change what the next caller reads.
fn scale_steps(lua: &Lua) -> mlua::Result<Table> {
    let steps = lua.create_table_with_capacity(STEPS.len(), 0)?;

    for (index, step) in (1..).zip(STEPS) {
        steps.set(
            index,
            f64::from(step.in_120ths()) / f64::from(ScaleStep::DENOMINATOR),
        )?;
    }

    Ok(steps)
}

/// `lunette.spawn{ argv = …, env = …, cwd = …, xwayland = … }`.
///
/// The handle comes back before the compositor has seen the request, so it
/// describes a process that does not exist yet: `alive` is false until the
/// snapshot lists it, and a spawn that fails outright is reported through
/// `lovr.lunprocessexited` rather than by this call raising.
fn spawn<T: LuaTexture>(session: &Rc<Session<T>>, options: &Table) -> mlua::Result<Process<T>> {
    reject_unknown_options(options, SPAWN_OPTIONS)?;

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
/// Absent means the output every session starts with, which is what a client
/// lunette did not spawn is shown too. The value is an output handle rather than
/// an identifier, so a caller cannot pass a number that happens to be in range
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

/// The options `lunette.spawn` accepts.
const SPAWN_OPTIONS: &[&str] = &["argv", "cwd", "env", "output", "xwayland"];

/// Refuses a table carrying an option this build does not act on.
///
/// A silently ignored option is a configuration that does not do what it says,
/// and the failure surfaces as behaviour rather than as an error.
pub(crate) fn reject_unknown_options(options: &Table, known: &[&str]) -> mlua::Result<()> {
    for pair in options.pairs::<Value, Value>() {
        let (key, _) = pair?;
        let name = match &key {
            Value::String(name) => name.to_string_lossy(),
            other => other.type_name().to_owned(),
        };
        if !known.contains(&name.as_str()) {
            return Err(mlua::Error::runtime(format!(
                "lunette: '{name}' is not an option here; this call takes {}",
                known.join(", ")
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
/// Lua strings are byte strings and a program's arguments and environment are
/// byte strings, so this passes bytes through rather than requiring UTF-8. A
/// path or a variable that is not valid UTF-8 is unusual and legal, and WayVR's
/// equivalent read fails on exactly that case.
fn os_string(value: &mlua::LuaString) -> OsString {
    OsString::from_vec(value.as_bytes().to_vec())
}

/// Checks a pair of numbers before they are taken for a size in pixels.
///
/// `noun` names what is being sized, so the message says which argument the
/// caller got wrong when a configuration is sizing several things a frame.
fn pixel_size(width: f64, height: f64, noun: &str) -> mlua::Result<PixelSize> {
    let pixels = |value: f64| {
        // The bound is what makes the cast below exact: a finite whole number
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

/// The name Lua spells a pointer button with.
///
/// Rejecting an unrecognised name rather than defaulting: `sink:button('lft',
/// true)` is a typo, and a silent left click is harder to find than an error.
fn pointer_button(name: &str) -> Option<PointerButton> {
    match name {
        "left" => Some(PointerButton::Left),
        "right" => Some(PointerButton::Right),
        "middle" => Some(PointerButton::Middle),
        "back" => Some(PointerButton::Back),
        "forward" => Some(PointerButton::Forward),
        _ => None,
    }
}

/// The buttons [`pointer_button`] accepts, for the error message that lists
/// them.
const POINTER_BUTTONS: &str = "left, right, middle, back, forward";
