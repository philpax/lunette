//! Linux-only: runs LÖVR's boot sequence against symbols from the shared `liblovr.so` build.
//!
//! The sequence preserves LÖVR's step order and passes Unix paths to Lua as raw bytes. It also
//! mounts the Lua module roots into LÖVR's virtual filesystem before configuration code runs.

use std::{
    env,
    ffi::{CStr, OsString, c_int},
    mem,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::ExitCode,
    ptr,
    rc::Rc,
};

use lunette::{
    aliases::ModuleRoots,
    control::{Budget, CHUNKS_PER_FRAME, ChunkQueue, answer},
    frame::{FrameDriver, Startup},
    layers::{LovrBlits, LovrLayers},
    lua::{PoolRegistry, Session, install},
    plugin::host,
    require, safe_mode,
    texture::LovrTexture,
};
use lunette_lovr::{BOOT_LUA, Platform, clear_log_callback, raw, set_log_callback};
use mlua::Lua;
use mlua_sys as lua;
use tracing::{debug, error, info, warn};

/// The directories a session is loaded from.
///
/// The entry point resolves both directories; it is the sole part of the
/// program that reads the environment. They are passed together because two
/// positional paths of the same shape are easy to swap.
#[derive(Debug, Clone, Copy)]
pub struct SessionPaths<'a> {
    /// Where LÖVR loads `main.luau` and `conf.luau` from.
    pub config: &'a Path,
    /// The root of the Lua module data from which mounted roots are resolved.
    pub standard_library: &'a Path,
    /// The command-line arguments remaining after lunette takes its own. The
    /// configuration receives them as Lua's `arg`.
    pub forwarded: &'a [OsString],
}

/// Boots LÖVR and runs the Lua session until it exits.
///
/// The resolved paths, control queue, session, layer registry, and startup settings outlive each
/// Lua state. A restart replaces the state while preserving the compositor, clients, and textures.
/// [`crate::restart`] defines the device handoff order. `lunette::reload` reconfigures without
/// replacing native state.
pub fn run(
    paths: SessionPaths<'_>,
    session: &Rc<Session<LovrTexture>>,
    layers: &Rc<PoolRegistry<LovrLayers>>,
    control: Option<&ChunkQueue>,
    startup: Startup,
) -> ExitCode {
    let platform = match Platform::init() {
        Ok(platform) => platform,
        Err(error) => {
            error!("{error}");
            return ExitCode::FAILURE;
        }
    };

    // SAFETY: this function runs the boot sequence and every frame after it on
    // the calling thread; that thread owns LÖVR's graphics and headset modules
    // for the life of the process.
    let blits = unsafe { LovrBlits::new() };
    let mut driver = FrameDriver::new(Rc::clone(session), Rc::clone(layers), blits, startup);

    // The restart cookie crosses Lua states. A nil-initialised Variant is valid before first use.
    //
    // SAFETY: `Variant` uses zero for `TYPE_NIL`, and zero is valid for its payload.
    let mut cookie: raw::Variant = unsafe { mem::zeroed() };

    let status = loop {
        match run_session(paths, session, &mut driver, control, &mut cookie) {
            Outcome::Restart => (),
            Outcome::Exit { status } => break status,
            Outcome::LoadFailed => break FAILURE_STATUS,
        }
    };

    // A load failure returns before `run_steps` shuts down the compositor.
    driver.shutdown();
    platform.destroy();
    ExitCode::from(status)
}

/// The exit status of a session whose `boot.lua` never started.
const FAILURE_STATUS: u8 = 1;

/// How one pass through the restart loop ended.
#[derive(Debug)]
enum Outcome {
    /// `boot.lua` requested a restart. The cookie carries state to the next
    /// session, and the Lua state has already been closed.
    Restart,
    /// The session ended and the process exits with this status. The Lua state
    /// has already been closed.
    Exit {
        /// The status `boot.lua` returned, narrowed the way `exit()` narrows it.
        status: u8,
    },
    /// `boot.lua` could not be loaded or run. No Lua state survives to close.
    LoadFailed,
}

/// Creates a Lua state, runs `boot.lua` in it, and executes it to completion.
fn run_session(
    paths: SessionPaths<'_>,
    session: &Rc<Session<LovrTexture>>,
    driver: &mut FrameDriver,
    control: Option<&ChunkQueue>,
    cookie: &mut raw::Variant,
) -> Outcome {
    // SAFETY: LÖVR's boot sequence runs in order on a state this function exclusively owns. Each
    // cast converts between bindgen's and mlua-sys' declarations of the same C type.
    //
    // mlua creates the state with its allocator and per-state `ExtraData`, which its Luau
    // integration requires. LÖVR then uses that same state. `luax_close` runs LÖVR's finalizers,
    // after which the mlua handle is forgotten to prevent a second close.
    let lua_handle = Lua::new();
    let state = lua_handle.exec_raw_lua(|raw| raw.state());
    if state.is_null() {
        error!("lua: the interpreter state could not be allocated");
        return Outcome::LoadFailed;
    }

    unsafe {
        raw::luax_setmainthread(state.cast());
        lua::luaL_openlibs(state);
        raw::luax_preload(state.cast());

        // After `luax_preload`, because the entry it registers is the one this
        // wraps.
        //
        // SAFETY: the three calls above are exactly the preconditions, and what
        // this installs is kept in the state, not in Rust.
        let roots = ModuleRoots::development(paths.standard_library);
        install_standard_library_mount(state, &roots);

        // Before `boot.lua`, because `main.luau` runs inside it and requires the
        // module at its top. After `luaL_openlibs`, because the module is
        // registered through `package.preload`.
        //
        // SAFETY: the state was created above, is closed only after
        // `run_steps` returns, and no reference into it is kept.
        if let Err(error) = install(&lua_handle, session) {
            error!("lua: the lunette module could not be registered: {error}");
            return Outcome::LoadFailed;
        }

        // Before `boot.lua`, which requires `main.luau` through it.
        if let Err(error) = require::install(&lua_handle) {
            error!("lua: relative require could not be installed: {error}");
            return Outcome::LoadFailed;
        }

        push_arg_table(state, paths.config, paths.forwarded, cookie);

        lua::lua_pushcfunction(state, message_handler);

        let loaded = raw::luax_loadbufferx(
            state.cast(),
            BOOT_LUA.as_ptr().cast(),
            BOOT_LUA.len(),
            c"@boot.lua".as_ptr(),
            ptr::null(),
        );
        if loaded != 0 || lua::lua_pcall(state, 0, 1, -2) != 0 {
            error!("lua: {}", describe_error(state));
            return Outcome::LoadFailed;
        }

        let thread = lua::lua_tothread(state, -1);
        if thread.is_null() {
            error!("lua: boot.lua did not return a coroutine");
            return Outcome::LoadFailed;
        }

        // Install the trigger after `boot.lua` creates `lovr` and before its
        // coroutine resumes to load modules and run `main.luau`. That resume
        // does not return to the host between these steps.
        //
        // SAFETY: `state` is live until the `luax_close` below, and the
        // reference mlua constructs over it is consumed inside this call.
        if let Err(error) = safe_mode::install_trigger(&lua_handle) {
            // Not fatal. The session still boots; it loses the fallback for a
            // configuration that does not load.
            error!("lua: safe mode could not be armed: {error}");
        }

        // SAFETY: `thread` stays alive until the `luax_close` below, and the
        // callback is cleared before that happens on every path out of
        // `run_steps`.
        set_log_callback(raw::luax_vlog, thread.cast());

        let outcome = run_steps(state, thread, session, driver, control, cookie, &lua_handle);

        // `run_steps` closed the state via `luax_close` (LÖVR's finalizers ran).
        // Mark the mlua state closed, so ValueRefs dropped during this
        // function's unwind (e.g. the `Function` captured by the safe-mode
        // trigger) skip poking the freed ref thread.
        lua_handle.exec_raw_lua(|raw| raw.mark_closed());

        // The mlua handle would close it again on drop, so it is forgotten; the
        // state is already gone, and the handle would touch it again.
        std::mem::forget(lua_handle);

        outcome
    }
}

/// Executes `thread` one frame at a time until it restarts or exits, then
/// tears the Lua state down.
///
/// # Safety
///
/// `state` must be a live Lua state, `thread` the coroutine `boot.lua` returned
/// from it, and the log callback must be installed against `thread`.
unsafe fn run_steps(
    state: *mut lua::lua_State,
    thread: *mut lua::lua_State,
    session: &Rc<Session<LovrTexture>>,
    driver: &mut FrameDriver,
    control: Option<&ChunkQueue>,
    cookie: &mut raw::Variant,
    lua_handle: &Lua,
) -> Outcome {
    let mut first_frame = true;
    loop {
        // The frame's snapshot and the frame's events are installed together,
        // before `boot.lua` polls, so a `lun*` handler reads a snapshot that
        // already accounts for the event it was handed.
        driver.begin_frame();

        // SAFETY: the caller guarantees `thread` is live, and nothing in this
        // loop closes it before returning.
        let step = unsafe { step(thread) };

        match step {
            Step::Continue => {
                if first_frame {
                    first_frame = false;

                    // `lovr.simulate` reaches GLFW's `getViewAngles` when the headset module loads
                    // but is inactive.
                    //
                    // SAFETY: reads two fields from the `lovr` global table
                    // on `state`, which is the main state and is live. The
                    // two values are popped before any further Lua call.
                    let headset_loaded = unsafe {
                        lua::lua_getglobal(state, c"lovr".as_ptr());
                        lua::lua_getfield(state, -1, c"headset".as_ptr());
                        let loaded = lua::lua_type(state, -1) != lua::LUA_TNIL;
                        lua::lua_pop(state, 2);
                        loaded
                    };

                    let has_window = unsafe { raw::os_window_is_open() };
                    let has_session = unsafe { raw::lovrHeadsetGetSessionGeneration() } != 0;
                    debug!(
                        has_window,
                        has_session, headset_loaded, "first frame completed"
                    );
                    if let Some(terminal) = first_frame_terminal(FirstFrameState {
                        has_window,
                        headset_loaded,
                        has_session,
                    }) {
                        error!(
                            "no display and no XR runtime: \
                             the session has nothing to present"
                        );
                        return finish_terminal(
                            state, thread, session, driver, cookie, lua_handle, terminal,
                        );
                    }
                }

                // A normal frame ends after Lua has run. Terminal frames use
                // `finish_terminal`, which performs the same flush only after
                // runtime callbacks and subscribers have been retired.
                driver.end_frame();

                // Between two frames. `lovr.update` and `lovr.draw` have both
                // finished and the next frame has not begun, so a chunk
                // touching the same state a callback touches has nobody to
                // race. This interval is why a chunk is safe.
                //
                // The single session `lua_handle` is used here directly; it is
                // not closed until after `run_steps` returns, so the `&Lua`
                // captured by the closure is valid for the whole loop.
                if let Some(control) = control {
                    control.drain(CHUNKS_PER_FRAME, |chunk| {
                        answer(lua_handle, chunk, Budget::DEFAULT)
                    });
                }

                // SAFETY: `os_sleep` yields to the platform and does not access Lua state.
                unsafe { raw::os_sleep(0.0) };
            }
            Step::Restart => {
                return finish_terminal(
                    state,
                    thread,
                    session,
                    driver,
                    cookie,
                    lua_handle,
                    Terminal::Restart,
                );
            }
            Step::Exit { status } => {
                return finish_terminal(
                    state,
                    thread,
                    session,
                    driver,
                    cookie,
                    lua_handle,
                    Terminal::Exit { status },
                );
            }
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct FirstFrameState {
    has_window: bool,
    headset_loaded: bool,
    has_session: bool,
}

/// Chooses the terminal action when the first frame has no display or XR session.
fn first_frame_terminal(state: FirstFrameState) -> Option<Terminal> {
    if !state.has_window && state.headset_loaded && !state.has_session {
        Some(Terminal::Exit {
            status: FAILURE_STATUS,
        })
    } else {
        None
    }
}

/// The native action taken after the runtime and final frame have retired.
#[derive(Clone, Copy, Debug)]
enum Terminal {
    /// Keep the compositor and client graph while replacing the Lua state.
    Restart,
    /// Stop the compositor and finish the process.
    Exit { status: u8 },
}

/// Retires the live Lua runtime and closes one terminal session.
///
/// The order is fixed: retire plugin runtimes, clear subscribers, flush the
/// final frame, quiesce or stop native state, and close Lua last.
fn finish_terminal(
    state: *mut lua::lua_State,
    thread: *mut lua::lua_State,
    session: &Rc<Session<LovrTexture>>,
    driver: &mut FrameDriver,
    cookie: &mut raw::Variant,
    lua_handle: &Lua,
    terminal: Terminal,
) -> Outcome {
    host::shutdown(lua_handle, "terminal shutdown");
    session.clear_subscribers();
    driver.end_frame();
    match terminal {
        Terminal::Restart => {
            driver.quiesce();
            // SAFETY: `boot.lua` leaves the restart cookie at thread stack index 2.
            unsafe {
                raw::luax_checkvariant(thread.cast(), 2, cookie);
                // An object cookie holds a reference counted by the state
                // that is about to close, so it cannot cross the restart.
                if cookie.__bindgen_anon_1.type_ == raw::VariantType_TYPE_OBJECT {
                    *cookie = mem::zeroed();
                }
            }
        }
        Terminal::Exit { .. } => {
            // SAFETY: the headset remains initialized until the Lua state
            // closes. OpenVR acknowledges a requested exit before teardown.
            unsafe { raw::lovrHeadsetWillExit() };
            driver.shutdown();
        }
    }
    // SAFETY: every prior phase has retired Lua callbacks, flushed the
    // frame, and quiesced or stopped native users of the state.
    unsafe {
        close_lua_state(
            state,
            thread,
            lua_handle,
            matches!(terminal, Terminal::Exit { .. }),
        )
    };

    match terminal {
        Terminal::Restart => Outcome::Restart,
        Terminal::Exit { status } => Outcome::Exit { status },
    }
}

/// Clears callbacks and closes the external LÖVR state after native teardown.
unsafe fn close_lua_state(
    state: *mut lua::lua_State,
    thread: *mut lua::lua_State,
    lua_handle: &Lua,
    close_thread: bool,
) {
    clear_log_callback();
    lua_handle.exec_raw_lua(|raw| raw.mark_closed());
    // SAFETY: no Lua value obtained above outlives this call. Normal exit
    // closes the boot coroutine while the main state stays open; restart closes
    // the main state after the coroutine has already returned.
    unsafe {
        if close_thread {
            raw::luax_close(thread.cast());
        } else {
            raw::luax_close(state.cast());
        }
    }
}

/// What one frame of the session asked for.
#[derive(Debug)]
enum Step {
    /// The coroutine yielded; run another frame.
    Continue,
    /// The coroutine finished and asked for a fresh Lua state.
    Restart,
    /// The coroutine finished and asked the process to end.
    Exit {
        /// The status `boot.lua` returned, narrowed the way `exit()` narrows it.
        status: u8,
    },
}

/// Runs one frame of the session.
///
/// # Safety
///
/// `thread` must be the live coroutine `boot.lua` returned.
unsafe fn step(thread: *mut lua::lua_State) -> Step {
    // SAFETY: the caller guarantees `thread` is live and resumable.
    unsafe {
        if raw::luax_resume(thread.cast(), 0) == lua::LUA_YIELD {
            return Step::Continue;
        }

        // Check the type first because `lua_tolstring` converts numbers to strings in place.
        if lua::lua_type(thread, 1) == lua::LUA_TSTRING
            && string_bytes(thread, 1) == Some(b"restart".as_slice())
        {
            return Step::Restart;
        }

        // `boot.lua` returns the status at stack index 1 and the restart cookie at index 2. Reading
        // the last value would convert the nil cookie to status zero. Narrowing to `u8` matches
        // `exit()`.
        Step::Exit {
            status: lua::lua_tointeger(thread, 1) as u8,
        }
    }
}

/// Describes one mounted module root for the Lua-side filesystem hook.
#[derive(Clone, Debug, PartialEq, Eq)]
struct MountDescription {
    source: PathBuf,
    mount_point: String,
    required: bool,
}

/// Derives the mount table from the same validated roots used by the checker.
fn mount_descriptions(roots: &ModuleRoots) -> Vec<MountDescription> {
    roots
        .mounted()
        .map(|root| MountDescription {
            source: root.source.clone(),
            mount_point: root.mount_point(),
            required: root.required(),
        })
        .collect()
}

/// Mounts every resolved development root when `lovr.filesystem` is created.
///
/// The preload wrapper mounts roots when `lovr.filesystem` loads. `boot.lua` loads this module
/// inside the coroutine, then resumes it to load modules and run `main.luau`. The mount occurs
/// during module creation, before configuration execution.
///
/// The C closure stores the original loader and mount data in upvalues. Rust holds no reference
/// into the Lua state. Soft reloads retain the state and hook.
///
/// # Precedence
///
/// The configuration is mounted at the filesystem root. Module roots use the `@` mount point from
/// [`ModuleRoots`], so root-level configuration files cannot shadow them.
///
/// # Read-only
///
/// PhysFS mounts are read-only. Writes through `lovr.filesystem.write` go to LÖVR's save directory,
/// documented in `docs/dev/build-and-development.md#where-things-live-at-runtime`.
///
/// Absent optional roots are skipped. Missing required roots are passed to LÖVR and logged. A
/// configuration that does not require a missing root can still reach safe mode.
///
/// # Safety
///
/// `state` must be a live Lua state with `luaL_openlibs` and `luax_preload`
/// already run on it, with enough stack room for the package tables and one
/// mount record. The root descriptors are validated before they reach Lua.
unsafe fn install_standard_library_mount(state: *mut lua::lua_State, roots: &ModuleRoots) {
    // SAFETY: every push below is balanced before this returns, and the caller
    // guarantees the state and the stack room.
    unsafe {
        lua::lua_getglobal(state, c"package".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TTABLE {
            // Unreachable after `luaL_openlibs`, and checked anyway: indexing a
            // non-table raises, and this runs under no `pcall`, so the error
            // would `longjmp` out through Rust frames and would not be
            // handled.
            error!("lua: package is not a table, so module roots cannot be mounted");
            lua::lua_pop(state, 1);
            return;
        }

        lua::lua_getfield(state, -1, c"preload".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TTABLE {
            error!("lua: package.preload is not a table, so module roots cannot be mounted");
            lua::lua_pop(state, 2);
            return;
        }

        lua::lua_getfield(state, -1, FILESYSTEM_MODULE.as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TFUNCTION {
            // `luax_preload` did not register it, which means this build of LÖVR
            // is not the one this module was written against.
            error!(
                "lua: {} is not preloaded, so module roots cannot be mounted",
                FILESYSTEM_MODULE.to_string_lossy()
            );
            lua::lua_pop(state, 3);
            return;
        }

        lua::lua_newtable(state);
        let mut index = 1;
        for description in mount_descriptions(roots) {
            if !description.required && !description.source.is_dir() {
                continue;
            }
            lua::lua_newtable(state);
            push_path(state, &description.source);
            lua::lua_rawseti(state, -2, 1);
            push_string(state, &description.mount_point);
            lua::lua_rawseti(state, -2, 2);
            lua::lua_pushboolean(state, c_int::from(description.required));
            lua::lua_rawseti(state, -2, 3);
            lua::lua_rawseti(state, -2, index);
            index += 1;
        }
        lua::lua_pushcclosure(state, open_filesystem_and_mount, 2);
        lua::lua_setfield(state, -2, FILESYSTEM_MODULE.as_ptr());

        lua::lua_pop(state, 2);
    }
}

/// The `package.preload` key LÖVR's filesystem module is registered under.
const FILESYSTEM_MODULE: &CStr = c"lovr.filesystem";

/// Pushes a path as a Lua string.
///
/// # Safety
///
/// The caller guarantees `state` is a live Lua state with a free stack slot.
unsafe fn push_path(state: *mut lua::lua_State, path: &Path) {
    // SAFETY: the caller guarantees the Lua state and stack slot.
    unsafe { push_bytes(state, path.as_os_str().as_bytes()) };
}

/// Pushes a UTF-8 string as a Lua string.
///
/// # Safety
///
/// The caller guarantees `state` is a live Lua state with a free stack slot.
unsafe fn push_string(state: *mut lua::lua_State, value: &str) {
    // SAFETY: the caller guarantees the Lua state and stack slot.
    unsafe { push_bytes(state, value.as_bytes()) };
}

/// Pushes arbitrary bytes as a Lua string.
///
/// # Safety
///
/// The caller guarantees `state` is a live Lua state with a free stack slot.
unsafe fn push_bytes(state: *mut lua::lua_State, bytes: &[u8]) {
    // SAFETY: the caller's guarantee, and Lua copies the bytes before this call
    // returns.
    unsafe {
        lua::lua_pushlstring(state, bytes.as_ptr().cast(), bytes.len());
    }
}

/// Opens `lovr.filesystem`, mounts the validated module roots, and installs the
/// host's `lovr.log`.
///
/// [`install_standard_library_mount`] installs this closure; the reasoning for
/// the timing is there. Upvalue 1 is the loader `luax_preload` registered, and
/// upvalue 2 is an array of `{ source, mount point, required }` records.
///
/// The log handler is installed from here for the same reason: `boot.lua`
/// assigns its own `lovr.log` in its chunk body, and requires
/// `lovr.filesystem` from inside `lovr.boot`, which is after that and before
/// the first message it logs.
unsafe extern "C-unwind" fn open_filesystem_and_mount(state: *mut lua::lua_State) -> c_int {
    // SAFETY: Lua calls this as the `lovr.filesystem` loader, with the two
    // upvalues the closure was built with and the module name at index 1.
    unsafe {
        lua::lua_pushvalue(state, lua::lua_upvalueindex(1));
        lua::lua_pushvalue(state, 1);
        lua::lua_call(state, 1, 1);

        // Before the mounts, so a build whose `lovr.filesystem` carries no
        // `mount` still gets its diagnostics routed.
        install_log_handler(state);

        let filesystem = lua::lua_absindex(state, -1);
        lua::lua_getfield(state, filesystem, c"mount".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TFUNCTION {
            error!("lua: lovr.filesystem has no mount function");
            lua::lua_pop(state, 1);
            return 1;
        }
        lua::lua_pop(state, 1);

        let mounts = lua::lua_upvalueindex(2);
        let count = lua::lua_rawlen(state, mounts);
        for index in 1..=count {
            lua::lua_pushvalue(state, filesystem);
            lua::lua_getfield(state, -1, c"mount".as_ptr());
            lua::lua_rawgeti(state, mounts, index as _);
            if lua::lua_type(state, -1) != lua::LUA_TTABLE {
                error!("lua: module root mount record {index} is not a table");
                lua::lua_pop(state, 3);
                continue;
            }

            lua::lua_rawgeti(state, -1, 1);
            lua::lua_rawgeti(state, -2, 2);
            lua::lua_rawgeti(state, -3, 3);
            let required = lua::lua_toboolean(state, -1) != 0;
            lua::lua_pop(state, 1);
            let mount_point = owned_string(state, -1).unwrap_or_else(|| "<unknown>".to_owned());
            lua::lua_remove(state, -3);
            lua::lua_pushboolean(state, 1);
            lua::lua_call(state, 3, 2);

            if lua::lua_toboolean(state, -2) == 0 {
                let message = match string_bytes(state, -1) {
                    Some(bytes) => String::from_utf8_lossy(bytes).into_owned(),
                    None => "no reason was given".to_owned(),
                };
                if required {
                    error!(
                        "lua: required module root {mount_point} could not be mounted: {message}"
                    );
                } else {
                    warn!(
                        "lua: optional module root {mount_point} could not be mounted: {message}"
                    );
                }
            }
            lua::lua_pop(state, 2);
            lua::lua_pop(state, 1);
        }

        1
    }
}

/// Builds the global `arg` table `boot.lua` reads.
///
/// # Safety
///
/// `state` must be a live Lua state with room for two stack slots, and `cookie`
/// must be a valid `Variant`.
unsafe fn push_arg_table(
    state: *mut lua::lua_State,
    config_directory: &Path,
    forwarded: &[OsString],
    cookie: &mut raw::Variant,
) {
    let executable = env::args_os()
        .next()
        .unwrap_or_else(|| OsString::from("lunette"));
    let entries = arg_entries(executable, config_directory, forwarded.iter().cloned());

    // SAFETY: every push below is balanced by the store that follows it.
    unsafe {
        lua::lua_newtable(state);

        raw::luax_pushvariant(state.cast(), cookie);
        lua::lua_setfield(state, -2, c"restart".as_ptr());

        for (index, entry) in (0..).zip(&entries) {
            let bytes = entry.as_bytes();
            lua::lua_pushlstring(state, bytes.as_ptr().cast(), bytes.len());
            lua::lua_rawseti(state, -2, index);
        }

        lua::lua_setglobal(state, c"arg".as_ptr());
    }
}

/// The array part of the global `arg` table, in index order from zero.
///
/// `arg[0]` is the executable, `arg[1]` is the configuration directory, and `arg[2..]` are
/// forwarded arguments. LÖVR uses `arg[1]` as its source path, so the configuration directory
/// occupies that slot.
fn arg_entries(
    executable: OsString,
    config_directory: &Path,
    user_arguments: impl IntoIterator<Item = OsString>,
) -> Vec<OsString> {
    let mut entries = vec![executable, config_directory.as_os_str().to_owned()];
    entries.extend(user_arguments);
    entries
}

/// The message handler `boot.lua` runs under, forwarding to LÖVR's.
///
/// bindgen and mlua-sys each declare Lua's C entry points independently, and
/// disagree on one detail: mlua-sys types a `lua_CFunction` as `extern
/// "C-unwind"` where bindgen types `luax_getstack` as `extern "C"`. This
/// trampoline bridges the two without a transmute. It holds no values with
/// destructors, so a `longjmp` out of `luax_getstack` skips nothing.
unsafe extern "C-unwind" fn message_handler(state: *mut lua::lua_State) -> c_int {
    // SAFETY: Lua calls this only with the state that raised the error.
    unsafe { raw::luax_getstack(state.cast()) }
}

/// Describes the error value on top of `state`'s stack.
///
/// # Safety
///
/// `state` must be a live Lua state with at least one value on its stack.
unsafe fn describe_error(state: *mut lua::lua_State) -> String {
    // SAFETY: the caller guarantees the stack slot exists, and the borrow is
    // consumed before anything can pop it.
    match unsafe { string_bytes(state, -1) } {
        Some(bytes) => String::from_utf8_lossy(bytes).into_owned(),
        None => "boot.lua failed with a non-string error value".to_owned(),
    }
}

/// Borrows the value at `index` as bytes, or `None` if Lua cannot render it as
/// a string.
///
/// Lua strings are byte strings, not UTF-8, so they are returned unvalidated.
///
/// # Safety
///
/// `state` must be a live Lua state holding a value at `index`. The returned
/// slice borrows Lua's own copy, which remains until that value leaves the
/// stack, so the caller must not let the lifetime outlive it; `lua_tolstring`
/// also converts a number at `index` to a string in place.
/// Fixed, because `tracing` metadata is `'static` and a LÖVR log tag is not.
const LUA_LOG_TARGET: &str = "lunette::lua";

/// Replaces `lovr.log` with [`log_to_tracing`], leaving the stack as it found it.
///
/// A missing `lovr` global is reported and the session still boots; the log
/// routing is then absent.
///
/// # Safety
///
/// `state` must be a live Lua state with room for two stack slots, called after
/// `boot.lua` has assigned its own `lovr.log`.
unsafe fn install_log_handler(state: *mut lua::lua_State) {
    // SAFETY: the push below is balanced by the pop, and the caller guarantees
    // the state and the stack room.
    unsafe {
        lua::lua_getglobal(state, c"lovr".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TTABLE {
            error!("lua: lovr is not a table, so its log was left on stdout");
            lua::lua_pop(state, 1);
            return;
        }

        lua::lua_pushcclosure(state, log_to_tracing, 0);
        lua::lua_setfield(state, -2, c"log".as_ptr());
        lua::lua_pop(state, 1);
    }
}

/// The host's `lovr.log`, replacing an implementation that prints the message
/// and drops the level and the tag.
///
/// Two paths reach it. Lua calls it directly; the engine's C log resolves
/// `lovr.log` and calls it through `luax_vlog` on each message. A configuration
/// replacing `lovr.log` takes the engine's messages with it; the LÖVR
/// documentation advertises this outcome.
unsafe extern "C-unwind" fn log_to_tracing(state: *mut lua::lua_State) -> c_int {
    // SAFETY: Lua calls this as `lovr.log(message, level, tag)`, so indices 1 to
    // 3 hold its arguments, an absent one being nil.
    unsafe {
        let message = owned_string(state, 1).unwrap_or_default();
        let level = owned_string(state, 2).unwrap_or_default();
        let tag = owned_string(state, 3).filter(|tag| !tag.is_empty());

        // LÖVR's messages carry a trailing newline, and its own implementation
        // drops one.
        let message = message.strip_suffix('\n').unwrap_or(&message);
        let rendered = match &tag {
            Some(tag) => format!("{tag}: {message}"),
            None => message.to_owned(),
        };

        match level.as_str() {
            "error" => error!(target: LUA_LOG_TARGET, "{rendered}"),
            "warn" => warn!(target: LUA_LOG_TARGET, "{rendered}"),
            "debug" => debug!(target: LUA_LOG_TARGET, "{rendered}"),
            // `boot.lua` logs with no level, so anything unrecognised is
            // carried at info.
            _ => info!(target: LUA_LOG_TARGET, "{rendered}"),
        }

        0
    }
}

/// # Safety
///
/// `state` must be a live Lua state and `index` a slot that exists.
unsafe fn owned_string(state: *mut lua::lua_State, index: c_int) -> Option<String> {
    // SAFETY: the caller guarantees the stack slot exists, and the borrow ends
    // inside this function.
    unsafe { string_bytes(state, index) }.map(|bytes| String::from_utf8_lossy(bytes).into_owned())
}

unsafe fn string_bytes<'a>(state: *mut lua::lua_State, index: c_int) -> Option<&'a [u8]> {
    // SAFETY: the caller guarantees the stack slot exists.
    let pointer = unsafe { lua::lua_tolstring(state, index, ptr::null_mut()) };
    if pointer.is_null() {
        return None;
    }
    // SAFETY: `lua_tolstring` returns a NUL-terminated buffer Lua owns, and the
    // caller guarantees it stays on the stack for the borrow.
    Some(unsafe { CStr::from_ptr(pointer) }.to_bytes())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn first_frame_without_display_or_xr_selects_failure_exit() {
        for has_window in [false, true] {
            for headset_loaded in [false, true] {
                for has_session in [false, true] {
                    let terminal = first_frame_terminal(FirstFrameState {
                        has_window,
                        headset_loaded,
                        has_session,
                    });

                    let should_exit = !has_window && headset_loaded && !has_session;
                    match terminal {
                        Some(Terminal::Exit { status }) => {
                            assert!(
                                should_exit,
                                "unexpected failure exit for {has_window}, {headset_loaded}, {has_session}"
                            );
                            assert_eq!(status, FAILURE_STATUS);
                        }
                        None => assert!(
                            !should_exit,
                            "missing failure exit for {has_window}, {headset_loaded}, {has_session}"
                        ),
                        Some(Terminal::Restart) => {
                            panic!("first-frame validation cannot request restart")
                        }
                    }
                }
            }
        }
    }

    fn entries(config_directory: &str, user_arguments: &[&str]) -> Vec<OsString> {
        arg_entries(
            OsString::from("/usr/bin/lunette"),
            &PathBuf::from(config_directory),
            user_arguments.iter().map(OsString::from),
        )
    }

    #[test]
    fn config_directory_lands_at_index_one() {
        let entries = entries("/home/user/.config/lunette", &[]);
        assert_eq!(entries[1], OsString::from("/home/user/.config/lunette"));
    }

    #[test]
    fn executable_stays_at_index_zero() {
        let entries = entries("/etc/xdg/lunette", &["--verbose"]);
        assert_eq!(entries[0], OsString::from("/usr/bin/lunette"));
    }

    #[test]
    fn user_arguments_follow_the_config_directory() {
        let entries = entries("/etc/xdg/lunette", &["--verbose", "extra"]);
        assert_eq!(
            entries,
            vec![
                OsString::from("/usr/bin/lunette"),
                OsString::from("/etc/xdg/lunette"),
                OsString::from("--verbose"),
                OsString::from("extra"),
            ]
        );
    }

    /// boot.lua rejects an `arg[1]` that starts with `-`, so a user argument
    /// must never be able to reach that slot.
    #[test]
    fn a_leading_flag_cannot_reach_index_one() {
        let entries = entries("/etc/xdg/lunette", &["-h"]);
        assert!(!entries[1].as_bytes().starts_with(b"-"));
    }

    #[test]
    fn development_mounts_share_the_validated_root_model() {
        let roots = ModuleRoots::development("/resolved/lunette");
        let descriptions = mount_descriptions(&roots);

        assert_eq!(
            descriptions
                .iter()
                .map(|description| description.mount_point.as_str())
                .collect::<Vec<_>>(),
            vec![
                "@lunette-plugin",
                "@lunette-contracts",
                "@lunette-plugins",
                "@lunette-desktop",
                "@testing",
            ]
        );
        assert_eq!(
            descriptions
                .iter()
                .map(|description| description.source.clone())
                .collect::<Vec<_>>(),
            vec![
                PathBuf::from("/resolved/lunette/lunette-plugin"),
                PathBuf::from("/resolved/lunette/lunette-contracts"),
                PathBuf::from("/resolved/lunette/lunette-plugins"),
                PathBuf::from("/resolved/lunette/lunette-desktop"),
                PathBuf::from("/resolved/lunette/testing"),
            ]
        );
        assert_eq!(
            descriptions
                .iter()
                .map(|description| description.required)
                .collect::<Vec<_>>(),
            vec![true, true, true, true, false]
        );
    }
}
