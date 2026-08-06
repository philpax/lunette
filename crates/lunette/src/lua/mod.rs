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

mod process;
mod sink;
#[cfg(test)]
mod tests;
mod window;

use std::{
    cell::RefCell,
    ffi::{OsString, c_void},
    os::unix::ffi::OsStringExt,
    path::PathBuf,
    rc::Rc,
    sync::Arc,
};

use lunette_compositor::protocol::{
    Argv, Command, PointerButton, ProcessId, Snapshot, SpawnRequest,
};
use lunette_lovr::raw::{_luax_pushtype, ObjectType_T_Texture};
use mlua::{Lua, Table, Value};

pub use crate::lua::{process::Process, sink::Sink, window::Window};
use crate::texture::{FrameGeneration, LovrTexture, TextureLedger};

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
}

impl<T> Session<T> {
    #[must_use]
    pub fn new() -> Rc<Self> {
        Rc::new(Self {
            frame: RefCell::new(Frame {
                snapshot: Arc::new(Snapshot::default()),
                generation: FrameGeneration::INITIAL,
                commands: Vec::new(),
                processes: 0,
            }),
            textures: RefCell::new(TextureLedger::new()),
        })
    }

    /// Starts a frame against the compositor's latest snapshot.
    ///
    /// Advancing the generation is what invalidates the previous frame's
    /// texture handles, so this runs once per frame even when the snapshot has
    /// not changed.
    pub fn begin(&self, snapshot: Arc<Snapshot>) {
        let mut frame = self.frame.borrow_mut();
        frame.snapshot = snapshot;
        frame.generation = frame.generation.next();
    }

    /// Takes the frame's queued mutations, for the caller to send onward.
    ///
    /// Called once at frame end. The commands are returned rather than sent
    /// from here so that this type does not need to know about the compositor
    /// thread, and so that the send — which can block — happens somewhere a
    /// Lua callback is not running.
    #[must_use]
    pub fn flush(&self) -> Vec<Command> {
        std::mem::take(&mut self.frame.borrow_mut().commands)
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

    /// Runs `body` against the ledger of textures the frame may hand out.
    ///
    /// A closure rather than a borrow guard, so that the borrow cannot outlive
    /// the statement that took it — the ledger is read from inside Lua
    /// callbacks, and a guard held across one would panic on the re-entry.
    pub fn with_textures<R>(&self, body: impl FnOnce(&mut TextureLedger<T>) -> R) -> R {
        body(&mut self.textures.borrow_mut())
    }

    /// Queues a mutation for the frame's flush.
    fn queue(&self, command: Command) {
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
}

/// What one frame answers from.
#[derive(Debug)]
struct Frame {
    snapshot: Arc<Snapshot>,
    generation: FrameGeneration,
    /// The mutations made so far this frame, in the order they were made.
    commands: Vec<Command>,
    /// The highest process identifier minted so far.
    processes: u64,
}

/// How a texture is handed to Lua.
///
/// The seam is here rather than at the ledger because this is the only part of
/// the conversion that needs a graphics device: everything else about a window
/// handle is a projection of a snapshot, and the tests exercise that projection
/// with a texture that is an integer.
pub trait LuaTexture: 'static {
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
        // Outputs are not addressable from Lua yet, so there is nothing a
        // caller could name here. `reject_unknown_options` refuses the key.
        output: None,
        xwayland: options.get::<Option<bool>>("xwayland")?.unwrap_or(false),
    }));

    Ok(Process::new(Rc::clone(session), process))
}

/// The options `lunette.spawn` accepts.
///
/// `output` is documented in `docs/compositor.md` and is deliberately absent:
/// nothing hands Lua an output handle yet, so accepting the key would mean
/// accepting a value that cannot be honoured.
const SPAWN_OPTIONS: &[&str] = &["argv", "cwd", "env", "xwayland"];

/// Refuses a table carrying an option this build does not act on.
///
/// A silently ignored option is a configuration that does not do what it says,
/// and the failure surfaces as behaviour rather than as an error.
fn reject_unknown_options(options: &Table, known: &[&str]) -> mlua::Result<()> {
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
