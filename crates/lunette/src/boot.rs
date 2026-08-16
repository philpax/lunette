//! Linux-only: the LÖVR boot sequence.
//!
//! Paths reach the Lua `arg` table as raw bytes through
//! `std::os::unix::ffi::OsStrExt`, and the symbols this module calls come from
//! the `liblovr.so` that `lunette-lovr` builds.
//!
//! This module replicates `vendor/lovr/src/main.c` in Rust, against the symbols
//! that `LOVR_BUILD_SHARED=ON` and `LOVR_BUILD_WITH_SYMBOLS=ON` export. LÖVR's
//! own `main` is excluded from the shared build, so there is no collision to
//! resolve; what has to be reproduced is the ordering, which LÖVR depends on.
//!
//! Three things depart from a literal replication, all deliberately.
//!
//! The `arg` table places the configuration directory at `arg[1]`, where
//! `src/main.c:43-46` places only `argv[0]` at `arg[0]`. See [`arg_entries`].
//!
//! `src/main.c:24` calls `exit()` from inside the step function. This module
//! returns the status up to `main` instead. Observable behaviour is identical
//! today; the seam is what lets the compositor and control threads be torn
//! down in order once they exist.
//!
//! The exit status is read from stack index 1, where `src/main.c:21` reads
//! index -1. `vendor/lovr/etc/boot.lua:374` returns `result, cookie`, so a
//! finished coroutine leaves two values behind and index -1 is the nil cookie.
//! Upstream's `lua_tointeger` on that nil yields 0, which makes every exit
//! report success. See [`step`]; do not "correct" this back to match `main.c`.
//!
//! One thing has no counterpart in `main.c` at all: the standard library is
//! mounted into LÖVR's virtual filesystem, so that `require '@mullion'` resolves.
//! See [`install_standard_library_mount`].

use std::{
    env,
    ffi::{CStr, OsString, c_int},
    mem,
    os::unix::ffi::OsStrExt,
    path::Path,
    process::ExitCode,
    ptr,
    rc::Rc,
};

use lunette::{
    aliases::{Alias, MULLION, SPEC},
    control::{Budget, CHUNKS_PER_FRAME, ChunkQueue, answer},
    frame::{FrameDriver, Startup},
    layers::{LovrBlits, LovrLayers},
    lua::{PoolRegistry, Session, install_on_state},
    safe_mode,
    texture::LovrTexture,
};
use lunette_lovr::{BOOT_LUA, Platform, clear_log_callback, raw, set_log_callback};
use mlua::Lua;
use mlua_sys as lua;
use tracing::{debug, error, info, warn};

/// The directories a session is loaded from.
///
/// Both are resolved by the entry point, which is the only part of the program
/// permitted to read the environment. They travel together because they are two
/// paths of the same shape, and a positional pair of them is a swap waiting to
/// happen.
#[derive(Debug, Clone, Copy)]
pub struct SessionPaths<'a> {
    /// Where LÖVR loads `main.lua` and `conf.lua` from.
    pub config: &'a Path,
    /// Where the `mullion` standard library is mounted from.
    pub standard_library: &'a Path,
    /// What was left on the command line after lunette took its own arguments,
    /// which reaches the configuration as Lua's `arg`.
    pub forwarded: &'a [OsString],
}

/// Boots LÖVR and runs the Lua session until it exits.
///
/// `paths` names the configuration directory and the standard library, both
/// already resolved.
///
/// `session` outlives every Lua state this creates, and is what `main.lua`
/// reaches the compositor through. A restart closes the state and builds
/// another; the session, the clients, and their textures are untouched by that,
/// which is the whole reason it is owned out here.
///
/// `control` is where `lunctl` chunks arrive, or `None` when the session was
/// started without a control socket. It outlives every Lua state for the reason
/// the session does: the socket and its thread are not disturbed by a restart.
///
/// `startup` is what the entry point resolved while the process was still
/// single-threaded. The compositor is built from it on the first frame at which
/// LÖVR has a graphics device to lend, which is why it travels this far rather
/// than being used in `main`.
///
/// # A restart keeps the compositor and its clients
///
/// `lovr.event.restart` closes the Lua state, and closing it destroys LÖVR's
/// graphics module and the `VkDevice` the compositor borrowed. The compositor
/// thread survives that, because the device is taken back from it before the
/// state closes and a new one is lent to it afterwards. [`crate::restart`] is
/// that protocol and states the ordering; the Wayland socket, the connections,
/// and the clients' buffers are untouched throughout, which is what
/// `lunette-v1.AC5.5` asks for.
///
/// `lunette::reload` is the cheaper path for a reconfiguration, and it works by
/// not discarding anything native at all.
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
    // the calling thread, which is therefore the thread that owns LÖVR's
    // graphics and headset modules for the life of the process.
    let blits = unsafe { LovrBlits::new() };
    let mut driver = FrameDriver::new(Rc::clone(session), Rc::clone(layers), blits, startup);

    // The restart cookie outlives every Lua state: one session writes it and
    // the next reads it back. `src/main.c:40` gets that lifetime from a
    // function-static; here the enclosing scope provides it.
    //
    // SAFETY: `Variant`'s discriminant is `TYPE_NIL`, which is zero, and every
    // payload it selects is valid when zeroed. This is the initial state
    // `src/main.c:40`'s static gets from C's zero-initialisation.
    let mut cookie: raw::Variant = unsafe { mem::zeroed() };

    let status = loop {
        match run_session(paths, session, &mut driver, control, &mut cookie) {
            Outcome::Restart => (),
            Outcome::Exit { status } => break status,
            Outcome::LoadFailed => break FAILURE_STATUS,
        }
    };

    // Nothing after the last session should reach the compositor, but a load
    // failure leaves it running: `run_session` returns before `run_steps` is
    // reached, so nothing has stopped it.
    driver.shutdown();
    platform.destroy();
    ExitCode::from(status)
}

/// The exit status of a session whose `boot.lua` never started.
///
/// `src/main.c:54` returns 1 from `main` in this case.
const FAILURE_STATUS: u8 = 1;

/// How one pass through the restart loop ended.
#[derive(Debug)]
enum Outcome {
    /// `boot.lua` asked for a restart. The cookie carries state to the next
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

/// Creates a Lua state, runs `boot.lua` in it, and drives it to completion.
fn run_session(
    paths: SessionPaths<'_>,
    session: &Rc<Session<LovrTexture>>,
    driver: &mut FrameDriver,
    control: Option<&ChunkQueue>,
    cookie: &mut raw::Variant,
) -> Outcome {
    // SAFETY: this is the sequence at `vendor/lovr/src/main.c:34-74`, in the
    // same order, on a state this function exclusively owns for its lifetime.
    // Each `cast` converts between bindgen's opaque `lua_State` and mlua-sys',
    // which are two declarations of the same C type.
    //
    // The state is created through mlua so that its allocator (`MemoryState`)
    // and per-state `ExtraData` are present: mlua's luau `get_or_init_from_ptr`
    // needs the allocator userdata to be mlua's, and LÖVR cannot provide it on
    // a state it created itself. mlua and LÖVR then share the exact same state.
    // Ownership stays with mlua, so on exit `luax_close` runs LÖVR's finalizers
    // and the mlua handle is forgotten rather than dropped (which would close
    // the already-closed state again).
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
        // this installs lives in the state rather than in Rust.
        install_standard_library_mount(state, paths.standard_library);

        // Before `boot.lua`, because `main.lua` runs inside it and requires the
        // module at its top. After `luaL_openlibs`, because the module is
        // registered through `package.preload`.
        //
        // SAFETY: the state was created above, is closed only after
        // `run_steps` returns, and no reference into it is kept.
        if let Err(error) = install_on_state(&lua_handle, session) {
            error!("lua: the lunette module could not be registered: {error}");
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

        // After the chunk, which is what creates the `lovr` table, and before
        // the first resume, which is when `boot.lua` reads `lovr.boot` back.
        // There is no other moment: the coroutine boots the modules and runs
        // `main.lua` on the same resume.
        //
        // SAFETY: `state` is live until the `luax_close` below, and the
        // reference mlua constructs over it is consumed inside this call.
        if let Err(error) = safe_mode::install_trigger(&lua_handle) {
            // Not fatal. The session still boots; what it loses is the fallback
            // if it turns out the configuration does not load.
            error!("lua: safe mode could not be armed: {error}");
        }

        // SAFETY: `thread` stays alive until the `luax_close` below, and the
        // callback is cleared before that happens on every path out of
        // `run_steps`.
        set_log_callback(raw::luax_vlog, thread.cast());

        let outcome = run_steps(state, thread, driver, control, cookie, &lua_handle);

        // `run_steps` closed the state via `luax_close` (LÖVR's finalizers ran).
        // Mark the mlua state closed so that ValueRefs dropped during this
        // function's unwind (e.g. the `Function` captured by the safe-mode
        // trigger) skip poking the freed ref thread.
        lua_handle.exec_raw_lua(|raw| raw.mark_closed());

        // The mlua handle would close it again on drop, so it is forgotten —
        // the state is already gone, and the handle is the only thing that
        // would touch it.
        std::mem::forget(lua_handle);

        outcome
    }
}

/// Drives `thread` one frame at a time until it restarts or exits, then tears
/// the Lua state down.
///
/// # Safety
///
/// `state` must be a live Lua state, `thread` the coroutine `boot.lua` returned
/// from it, and the log callback must be installed against `thread`.
unsafe fn run_steps(
    state: *mut lua::lua_State,
    thread: *mut lua::lua_State,
    driver: &mut FrameDriver,
    control: Option<&ChunkQueue>,
    cookie: &mut raw::Variant,
    lua_handle: &Lua,
) -> Outcome {
    loop {
        // The frame's snapshot and the frame's events are installed together,
        // before `boot.lua` polls, so a `lun*` handler reads a snapshot that
        // already accounts for the event it was handed.
        driver.begin_frame();

        // SAFETY: the caller guarantees `thread` is live, and nothing in this
        // loop closes it before returning.
        let step = unsafe { step(thread) };

        // Before the branch, so that a session ending still delivers the
        // mutations its last frame made — a `win:close()` from a quit handler,
        // for instance.
        driver.end_frame();

        match step {
            Step::Continue => {
                // Between two frames, which is the whole of what makes a chunk
                // safe: `lovr.update` and `lovr.draw` have both finished and the
                // next frame has not begun, so a chunk touching the same state a
                // callback touches has nobody to race.
                //
                // The single session `lua_handle` is used here directly; it is
                // not closed until after `run_steps` returns, so the `&Lua`
                // captured by the closure is valid for the whole loop.
                if let Some(control) = control {
                    control.drain(CHUNKS_PER_FRAME, |chunk| {
                        answer(lua_handle, chunk, Budget::DEFAULT)
                    });
                }

                // SAFETY: yielding to the platform is what `src/main.c:66` does
                // between frames; `os_sleep` touches no Lua state.
                unsafe { raw::os_sleep(0.0) };
            }
            Step::Restart => {
                // Before the cookie is read and long before `luax_close`, and
                // that ordering is the whole of this path's correctness.
                // `luax_close` runs LÖVR's finalizer chain, which reaches
                // `gpu_destroy` — `vkDeviceWaitIdle`, `vkDestroyDevice`,
                // `vkDestroyInstance` — and `lovrHeadsetDestroy`'s
                // `xrDestroySession`. Every imported image, every allocation
                // behind one, and every composition layer was created against
                // those. `crate::restart` sets out the sequence this drives; it
                // is deliberately not a `luax_atexit` finalizer, and that module
                // records why.
                driver.quiesce();
                // SAFETY: `boot.lua` leaves the cookie at index 2 of the thread
                // when it yields "restart"; `src/main.c:68` reads it there.
                unsafe {
                    raw::luax_checkvariant(thread.cast(), 2, cookie);
                    // An object cookie holds a reference counted by the state
                    // that is about to close, so it cannot cross the restart.
                    // `src/main.c:69` drops it the same way.
                    if cookie.__bindgen_anon_1.type_ == raw::VariantType_TYPE_OBJECT {
                        *cookie = mem::zeroed();
                    }
                }
                clear_log_callback();
                // The state is about to close; mark it so mlua ValueRefs
                // dropped during `luax_close`'s finalizer GC skip the freed
                // ref thread.
                lua_handle.exec_raw_lua(|raw| raw.mark_closed());
                // SAFETY: no Lua value obtained above outlives this call.
                unsafe { raw::luax_close(state.cast()) };
                return Outcome::Restart;
            }
            Step::Exit { status } => {
                // Before the state closes, because closing it destroys the
                // graphics module and the device the compositor borrowed.
                driver.shutdown();
                clear_log_callback();
                // The state is about to close; mark it so mlua ValueRefs
                // dropped during `luax_close`'s finalizer GC skip the freed
                // ref thread.
                lua_handle.exec_raw_lua(|raw| raw.mark_closed());
                // `src/main.c:23` closes the thread rather than the state on
                // this path, which LÖVR resolves back to the main state.
                //
                // SAFETY: no Lua value obtained above outlives this call.
                unsafe { raw::luax_close(thread.cast()) };
                return Outcome::Exit { status };
            }
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

        // The type is checked before reading, because `lua_tolstring` converts
        // a number to a string in place and that would corrupt the status the
        // exit path reads back at the same index. `src/main.c:18` checks first
        // too.
        if lua::lua_type(thread, 1) == lua::LUA_TSTRING
            && string_bytes(thread, 1) == Some(b"restart".as_slice())
        {
            return Step::Restart;
        }

        // Index 1, not the -1 that `src/main.c:21` uses.
        // `vendor/lovr/etc/boot.lua:374` finishes with `return result, cookie`,
        // so the resumed coroutine leaves two values on its stack: the status
        // at index 1 and the restart cookie at index 2. Index -1 is therefore
        // the cookie, which is nil on the exit path, and `lua_tointeger` on nil
        // is 0 — upstream reports success for every exit. The restart check
        // above already reads index 1, and `run_steps` already reads the cookie
        // at index 2, so index 1 is the only reading consistent with both.
        //
        // `src/main.c:25` passes this to `exit()`, which narrows it to the low
        // byte before the kernel sees it. Narrowing here is the same value.
        Step::Exit {
            status: lua::lua_tointeger(thread, 1) as u8,
        }
    }
}

/// Arranges for the `mullion` standard library and development specs to be
/// mounted into LÖVR's virtual filesystem the moment that filesystem exists.
///
/// # Why this is a hook rather than a call
///
/// Mounting needs `lovr.filesystem`, and that module is created by
/// `vendor/lovr/etc/boot.lua:76` — inside the coroutine, on the same resume that
/// goes on to run `main.lua` at `:183`. So there is no moment between the two
/// that the host can reach: before the resume the module does not exist, and
/// after it the configuration has already run. Wrapping the `package.preload`
/// entry the module is created by is what puts the mount between them.
///
/// The wrapper is a C closure holding the original loader and the path as Lua
/// upvalues, not a Rust closure holding Lua values. Rust keeps no reference into
/// the state, which is what lets a soft reload discard the state without
/// anything here dangling.
///
/// # Precedence
///
/// The configuration is mounted at the filesystem root by `boot.lua:125`, while
/// the standard library is mounted at `@mullion` and the optional specs at
/// `@spec`. A configuration therefore cannot shadow a mullion module by name,
/// and the standard library cannot shadow the `main.lua` it is loaded alongside.
///
/// # Read-only
///
/// A physfs mount is read-only, so `lovr.filesystem.write` cannot modify a file
/// in the standard library. What a session writes goes to the save directory
/// `lovr.filesystem.setIdentity` establishes. That directory is mounted ahead of
/// everything else when `conf.saveprecedence` is left at LÖVR's default of true,
/// which lets a write there shadow a standard-library module by name; the
/// shipped `conf.lua` turns it off, and `docs/stdlib.md` records why.
///
/// A directory that does not exist fails to mount and is reported. That is not
/// fatal: a configuration that never mentions `@mullion` is supported, and one
/// that does gets a `require` error naming the module. The spec tree is mounted
/// only when `directory/spec` exists, which keeps it out of installed trees.
///
/// # Safety
///
/// `state` must be a live Lua state with `luaL_openlibs` and `luax_preload`
/// already run on it, and with room for six stack slots. The optional spec
/// directory is captured as nil when it is not present.
unsafe fn install_standard_library_mount(state: *mut lua::lua_State, directory: &Path) {
    // SAFETY: every push below is balanced before this returns, and the caller
    // guarantees the state and the stack room.
    unsafe {
        lua::lua_getglobal(state, c"package".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TTABLE {
            // Unreachable after `luaL_openlibs`, and checked anyway: indexing a
            // non-table raises, and this runs under no `pcall`, so the error
            // would `longjmp` out through Rust frames rather than being handled.
            error!("lua: package is not a table, so the standard library cannot be mounted");
            lua::lua_pop(state, 1);
            return;
        }

        lua::lua_getfield(state, -1, c"preload".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TTABLE {
            error!(
                "lua: package.preload is not a table, so the standard library cannot be mounted"
            );
            lua::lua_pop(state, 2);
            return;
        }

        lua::lua_getfield(state, -1, FILESYSTEM_MODULE.as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TFUNCTION {
            // `luax_preload` did not register it, which means this build of LÖVR
            // is not the one this module was written against.
            error!(
                "lua: {} is not preloaded, so the standard library cannot be mounted",
                FILESYSTEM_MODULE.to_string_lossy()
            );
            lua::lua_pop(state, 3);
            return;
        }

        let mullion_directory = directory.join(MULLION.directory);
        let bytes = mullion_directory.as_os_str().as_bytes();
        lua::lua_pushlstring(state, bytes.as_ptr().cast(), bytes.len());
        let spec_directory = directory.join(SPEC.directory);
        if spec_directory.is_dir() {
            let spec_bytes = spec_directory.as_os_str().as_bytes();
            lua::lua_pushlstring(state, spec_bytes.as_ptr().cast(), spec_bytes.len());
        } else {
            lua::lua_pushnil(state);
        }
        lua::lua_pushcclosure(state, open_filesystem_and_mount, 3);
        lua::lua_setfield(state, -2, FILESYSTEM_MODULE.as_ptr());

        lua::lua_pop(state, 2);
    }
}

/// The `package.preload` key LÖVR's filesystem module is registered under.
const FILESYSTEM_MODULE: &CStr = c"lovr.filesystem";

/// Opens `lovr.filesystem`, mounts the standard library onto it, and installs
/// the host's `lovr.log`.
///
/// Installed by [`install_standard_library_mount`], which is where the reasoning
/// for the timing is. Upvalue 1 is the loader `luax_preload` registered;
/// upvalue 2 is the standard-library directory, and upvalue 3 is the optional
/// spec directory.
///
/// The log handler rides along for the same reason: `boot.lua` assigns its own
/// `lovr.log` in its chunk body, and requires `lovr.filesystem` from inside
/// `lovr.boot`, which is after that and before the first message it logs.
/// Pushes the mount point a root is given, built from the alias rather than
/// written out, so that the name a session mounts and the name the checker
/// resolves cannot part.
///
/// # Safety
///
/// The caller guarantees `state` is a live Lua state with a free stack slot.
unsafe fn push_mount_point(state: *mut lua::lua_State, alias: &Alias) {
    let point = alias.mount_point();
    let bytes = point.as_bytes();
    // SAFETY: the caller's guarantee, and `point` outlives the call, which is
    // all Lua needs: it copies the bytes.
    unsafe {
        lua::lua_pushlstring(state, bytes.as_ptr().cast(), bytes.len());
    }
}

unsafe extern "C-unwind" fn open_filesystem_and_mount(state: *mut lua::lua_State) -> c_int {
    // SAFETY: Lua calls this as the `lovr.filesystem` loader, with the three
    // upvalues the closure was built with and the module name at index 1.
    unsafe {
        lua::lua_pushvalue(state, lua::lua_upvalueindex(1));
        lua::lua_pushvalue(state, 1);
        lua::lua_call(state, 1, 1);

        // Before the mount, so that a build whose `lovr.filesystem` carries no
        // `mount` still gets its diagnostics routed.
        install_log_handler(state);

        lua::lua_getfield(state, -1, c"mount".as_ptr());
        if lua::lua_type(state, -1) != lua::LUA_TFUNCTION {
            error!("lua: lovr.filesystem has no mount function");
            lua::lua_pop(state, 1);
            return 1;
        }

        lua::lua_pushvalue(state, lua::lua_upvalueindex(2));
        // The mount point is explicit so a configuration cannot shadow a
        // mullion module by placing a file with the same dotted name at root.
        push_mount_point(state, &MULLION);
        // Appended, although the explicit mount point already prevents a
        // configuration file from shadowing the standard-library module.
        lua::lua_pushboolean(state, 1);
        lua::lua_call(state, 3, 2);

        // `luax_pushsuccess` (`vendor/lovr/src/api/api.c:403`) returns `true`, or
        // `false` and the message.
        if lua::lua_toboolean(state, -2) == 0 {
            let message = match string_bytes(state, -1) {
                Some(bytes) => String::from_utf8_lossy(bytes).into_owned(),
                None => "no reason was given".to_owned(),
            };
            warn!(
                "lua: the mullion standard library could not be mounted: {message}; a \
                 configuration that requires it will fail to load"
            );
        }

        let filesystem = -1;
        lua::lua_pop(state, 2);

        if lua::lua_type(state, lua::lua_upvalueindex(3)) == lua::LUA_TSTRING {
            lua::lua_pushvalue(state, filesystem);
            lua::lua_getfield(state, -1, c"mount".as_ptr());
            if lua::lua_type(state, -1) == lua::LUA_TFUNCTION {
                lua::lua_pushvalue(state, lua::lua_upvalueindex(3));
                push_mount_point(state, &SPEC);
                lua::lua_pushboolean(state, 1);
                lua::lua_call(state, 3, 2);
                if lua::lua_toboolean(state, -2) == 0 {
                    let message = match string_bytes(state, -1) {
                        Some(bytes) => String::from_utf8_lossy(bytes).into_owned(),
                        None => "no reason was given".to_owned(),
                    };
                    warn!("lua: the spec tree could not be mounted: {message}");
                }
                lua::lua_pop(state, 2);
            } else {
                lua::lua_pop(state, 1);
            }
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

    // SAFETY: every push below is balanced by the store that follows it, and
    // the sequence matches `src/main.c:39-47`.
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
/// `arg[0]` is the executable, `arg[1]` is the configuration directory, and
/// `arg[2..]` are the user's own arguments.
///
/// The middle entry is the whole point. `src/main.c:43-46` copies `argv`
/// verbatim, which leaves `arg[1]` holding whatever the user typed.
/// `vendor/lovr/etc/boot.lua:90-102` requires `arg[1]` to name a source: if it
/// is absent or starts with `-`, boot.lua prints `usage: lovr <source>` and
/// quits. Otherwise it shifts every index down by one so the source lands at
/// `arg[0]`, and calls `lovr.filesystem.setSource` on it at
/// `vendor/lovr/etc/boot.lua:131`. Putting the configuration directory at
/// `arg[1]` is therefore how LÖVR comes to be pointed at it; lunette never
/// calls `setSource` itself.
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
/// slice borrows Lua's own copy, which lives only until that value leaves the
/// stack, so the caller must not let the lifetime outlive it. Note also that
/// `lua_tolstring` converts a number at `index` to a string in place.
/// Fixed, because `tracing` metadata is `'static` and a LÖVR log tag is not.
const LUA_LOG_TARGET: &str = "lunette::lua";

/// Replaces `lovr.log` with [`log_to_tracing`], leaving the stack as it found it.
///
/// A missing `lovr` global is reported rather than raised: the session still
/// boots, and what it loses is the routing.
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
/// Both sources arrive here: a Lua caller calls it directly, and the engine's C
/// log reaches it through `luax_vlog`, which looks `lovr.log` up on each call. A
/// configuration replacing `lovr.log` therefore takes the engine's messages with
/// it, which the LÖVR documentation advertises rather than warns against.
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
            // `boot.lua` logs with no level at all, so anything unrecognised is
            // carried at info rather than dropped.
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
}
