//! Linux-only: runs LÖVR's boot sequence against symbols from the shared `liblovr.so` build.
//!
//! The sequence preserves LÖVR's step order and passes Unix paths to Lua as raw bytes. It also
//! mounts the Lua module roots into LÖVR's virtual filesystem before configuration code runs.

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
    aliases::ModuleRoots,
    control::{Budget, CHUNKS_PER_FRAME, ChunkQueue, answer},
    frame::{FrameDriver, Startup},
    layers::{LovrBlits, LovrLayers},
    lua::{PoolRegistry, Session, install},
    plugin::attachment,
    require, safe_mode,
    texture::LovrTexture,
};
use lunette_lovr::{BOOT_LUA, Platform, clear_log_callback, raw, set_log_callback};
use mlua::Lua;
use mlua_sys as lua;
use tracing::{debug, error, info, warn};

/// The directories a session is loaded from.
///
/// Only the entry point reads the environment. The paths travel together
/// because two positional paths of the same shape are easy to swap.
#[derive(Debug, Clone, Copy)]
pub struct SessionPaths<'a> {
    /// Where LÖVR loads `main.luau` and `conf.luau` from.
    pub config: &'a Path,
    /// The root of the Lua module data from which mounted roots are resolved.
    pub standard_library: &'a Path,
    /// The arguments remaining after lunette takes its own, passed to Lua as `arg`.
    pub forwarded: &'a [OsString],
}

/// Boots LÖVR and runs the Lua session until it exits.
///
/// The session, layer registry, and startup settings outlive each Lua state. A restart replaces
/// the state and keeps the compositor, clients, and textures.
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

    // The restart cookie crosses Lua states.
    //
    // SAFETY: `Variant` uses zero for `TYPE_NIL`, and zero is valid for its payload.
    let mut cookie: raw::Variant = unsafe { mem::zeroed() };

    let status = loop {
        match run_session(paths, session, &mut driver, control, &mut cookie) {
            Outcome::Restart => (),
            Outcome::Exit { status } => break status,
        }
    };

    // A load failure returns before `run_steps` shuts down the compositor.
    driver.shutdown();
    platform.destroy();
    ExitCode::from(status)
}

/// The exit status of a session that failed to load or had nothing to present.
const FAILURE_STATUS: u8 = 1;

/// How one pass through the restart loop ended.
#[derive(Clone, Copy, Debug)]
enum Outcome {
    /// Keep the compositor and client graph, and replace the Lua state. The
    /// cookie carries state to the next session.
    Restart,
    /// Stop the compositor and exit the process with this status.
    Exit {
        /// The status `boot.lua` returned, narrowed the way `exit()` narrows it.
        status: u8,
    },
}

/// The outcome of a session that could not be loaded.
const LOAD_FAILED: Outcome = Outcome::Exit {
    status: FAILURE_STATUS,
};

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
    // mlua creates the state because its Luau integration requires its allocator and `ExtraData`.
    // `luax_close` runs LÖVR's finalizers, so the mlua handle is forgotten to prevent a second close.
    let lua_handle = Lua::new();
    let state = lua_handle.exec_raw_lua(|raw| raw.state());
    if state.is_null() {
        error!("lua: the interpreter state could not be allocated");
        return LOAD_FAILED;
    }

    unsafe {
        raw::luax_setmainthread(state.cast());
        lua::luaL_openlibs(state);
        raw::luax_preload(state.cast());

        // After `luax_preload`, because this wraps the entry it registers.
        //
        // SAFETY: the three calls above are the preconditions, and the result
        // lives in the state, not in Rust.
        let roots = ModuleRoots::development(paths.standard_library);
        install_standard_library_mount(state, &roots);

        // Before `boot.lua`, because `main.luau` requires the module at its top.
        // After `luaL_openlibs`, because registration uses `package.preload`.
        //
        // SAFETY: the state is closed only after `run_steps` returns, and no
        // reference into it is kept.
        if let Err(error) = install(&lua_handle, session) {
            error!("lua: the lunette module could not be registered: {error}");
            return LOAD_FAILED;
        }

        // Before `boot.lua`, which requires `main.luau` through it.
        if let Err(error) = require::install(&lua_handle) {
            error!("lua: relative require could not be installed: {error}");
            return LOAD_FAILED;
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
            return LOAD_FAILED;
        }

        let thread = lua::lua_tothread(state, -1);
        if thread.is_null() {
            error!("lua: boot.lua did not return a coroutine");
            return LOAD_FAILED;
        }

        // After `boot.lua` creates `lovr` and before its coroutine resumes, because
        // that resume runs `main.luau` without returning to the host.
        //
        // SAFETY: `state` is live until the `luax_close` below, and the
        // reference mlua constructs over it is consumed inside this call.
        if let Err(error) = safe_mode::install_trigger(&lua_handle) {
            // Not fatal. The session boots without the fallback for a
            // configuration that does not load.
            error!("lua: safe mode could not be armed: {error}");
        }

        // SAFETY: `thread` stays alive until the `luax_close` below, and the
        // callback is cleared before that happens on every path out of
        // `run_steps`.
        set_log_callback(raw::luax_vlog, thread.cast());

        let outcome = run_steps(state, thread, session, driver, control, cookie, &lua_handle);

        // `run_steps` closed the state, and dropping the handle would close it again.
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
        // The snapshot and events are installed together, so a `lun*` handler
        // reads a snapshot that already accounts for its event.
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
                    // SAFETY: `state` is the live main state, and both pushed
                    // values are popped before any further Lua call.
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
                    if !has_window && headset_loaded && !has_session {
                        error!(
                            "no display and no XR runtime: \
                             the session has nothing to present"
                        );
                        return finish_terminal(
                            state,
                            thread,
                            session,
                            driver,
                            cookie,
                            lua_handle,
                            Outcome::Exit {
                                status: FAILURE_STATUS,
                            },
                        );
                    }
                }

                // Terminal frames flush in `finish_terminal` instead, after
                // callbacks and subscribers are retired.
                driver.end_frame();

                // Chunks run between frames, when no callback can race them.
                // `lua_handle` outlives this loop, so the captured `&Lua` stays valid.
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
                    Outcome::Restart,
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
                    Outcome::Exit { status },
                );
            }
        }
    }
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
    outcome: Outcome,
) -> Outcome {
    attachment::shutdown(lua_handle, "terminal shutdown");
    session.clear_subscribers();
    driver.end_frame();
    match outcome {
        Outcome::Restart => {
            driver.quiesce();
            // SAFETY: `boot.lua` leaves the restart cookie at thread stack index 2.
            unsafe {
                raw::luax_checkvariant(thread.cast(), 2, cookie);
                // An object cookie is reference-counted by the closing state,
                // so it cannot cross the restart.
                if cookie.__bindgen_anon_1.type_ == raw::VariantType_TYPE_OBJECT {
                    *cookie = mem::zeroed();
                }
            }
        }
        Outcome::Exit { .. } => {
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
            matches!(outcome, Outcome::Exit { .. }),
        )
    };

    outcome
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
    // SAFETY: no Lua value obtained above outlives this call. Exit closes the
    // boot coroutine; restart closes the main state after the coroutine returned.
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

        // The status is at index 1 and the cookie at 2, so reading the top would turn a nil
        // cookie into status zero. Narrowing to `u8` matches `exit()`.
        Step::Exit {
            status: lua::lua_tointeger(thread, 1) as u8,
        }
    }
}

/// Mounts every resolved development root when `lovr.filesystem` is created.
///
/// Mounting during module creation places the roots before any configuration code runs. Module
/// roots use the `@` mount point, so root-level configuration files cannot shadow them.
///
/// Absent optional roots are skipped. Missing required roots are passed to LÖVR and logged, so a
/// configuration that does not require one can still reach safe mode.
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
        lua::lua_getfield(state, -1, c"preload".as_ptr());

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
        for root in roots.mounted() {
            if !root.required() && !root.source.is_dir() {
                continue;
            }
            lua::lua_newtable(state);
            push_bytes(state, root.source.as_os_str().as_bytes());
            lua::lua_rawseti(state, -2, 1);
            push_bytes(state, root.mount_point().as_bytes());
            lua::lua_rawseti(state, -2, 2);
            lua::lua_pushboolean(state, c_int::from(root.required()));
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
/// Upvalue 1 is the loader `luax_preload` registered, and upvalue 2 is an array
/// of `{ source, mount point, required }` records. The log handler is installed
/// here because this runs after `boot.lua` assigns its own `lovr.log` and before
/// its first message.
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
        let mounts = lua::lua_upvalueindex(2);
        let count = lua::lua_rawlen(state, mounts);
        for index in 1..=count {
            lua::lua_pushvalue(state, filesystem);
            lua::lua_getfield(state, -1, c"mount".as_ptr());
            lua::lua_rawgeti(state, mounts, index as _);
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
/// LÖVR uses `arg[1]` as its source path, so the configuration directory occupies that slot.
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
/// mlua-sys types a `lua_CFunction` as `extern "C-unwind"` and bindgen types
/// `luax_getstack` as `extern "C"`, so this bridges them without a transmute. It
/// holds no values with destructors, so a `longjmp` out of it skips nothing.
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

/// The host's `lovr.log`, which keeps the level and tag that LÖVR's own drops.
///
/// The engine's C log also reaches it through `luax_vlog`, so a configuration
/// replacing `lovr.log` takes the engine's messages with it, as LÖVR documents.
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
            // `boot.lua` logs with no level, so anything unrecognised is info.
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

    /// boot.lua rejects an `arg[1]` that starts with `-`, so the configuration
    /// directory is fixed at index one and a user argument follows it.
    #[test]
    fn the_executable_then_the_configuration_directory_then_user_arguments() {
        assert_eq!(
            entries("/etc/xdg/lunette", &["-h", "extra"]),
            vec![
                OsString::from("/usr/bin/lunette"),
                OsString::from("/etc/xdg/lunette"),
                OsString::from("-h"),
                OsString::from("extra"),
            ]
        );
    }
}
