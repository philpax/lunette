//! The LÖVR boot sequence.
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

use std::{
    env,
    ffi::{CStr, OsString, c_int},
    mem,
    os::unix::ffi::OsStrExt,
    path::Path,
    process::ExitCode,
    ptr,
};

use lunette_lovr::{BOOT_LUA, Platform, clear_log_callback, raw, set_log_callback};
use mlua_sys as lua;
use tracing::error;

/// Boots LÖVR and runs the Lua session until it exits.
///
/// `config_directory` is the directory LÖVR loads `main.lua` and `conf.lua`
/// from. It is resolved by the caller, which is the only part of the program
/// permitted to read the environment.
pub fn run(config_directory: &Path) -> ExitCode {
    let platform = match Platform::init() {
        Ok(platform) => platform,
        Err(error) => {
            error!("{error}");
            return ExitCode::FAILURE;
        }
    };

    // The restart cookie outlives every Lua state: one session writes it and
    // the next reads it back. `src/main.c:40` gets that lifetime from a
    // function-static; here the enclosing scope provides it.
    //
    // SAFETY: `Variant`'s discriminant is `TYPE_NIL`, which is zero, and every
    // payload it selects is valid when zeroed. This is the initial state
    // `src/main.c:40`'s static gets from C's zero-initialisation.
    let mut cookie: raw::Variant = unsafe { mem::zeroed() };

    let status = loop {
        match run_session(config_directory, &mut cookie) {
            Session::Restart => (),
            Session::Exit { status } => break status,
            Session::LoadFailed => break FAILURE_STATUS,
        }
    };

    platform.destroy();
    ExitCode::from(status)
}

/// The exit status of a session whose `boot.lua` never started.
///
/// `src/main.c:54` returns 1 from `main` in this case.
const FAILURE_STATUS: u8 = 1;

/// How one pass through the restart loop ended.
#[derive(Debug)]
enum Session {
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
fn run_session(config_directory: &Path, cookie: &mut raw::Variant) -> Session {
    // SAFETY: this is the sequence at `vendor/lovr/src/main.c:34-74`, in the
    // same order, on a state this function exclusively owns for its lifetime.
    // Each `cast` converts between bindgen's opaque `lua_State` and mlua-sys',
    // which are two declarations of the same C type.
    unsafe {
        let state = lua::luaL_newstate();
        if state.is_null() {
            error!("lua: the interpreter state could not be allocated");
            return Session::LoadFailed;
        }

        raw::luax_setmainthread(state.cast());
        lua::luaL_openlibs(state);
        raw::luax_preload(state.cast());
        push_arg_table(state, config_directory, cookie);

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
            return Session::LoadFailed;
        }

        let thread = lua::lua_tothread(state, -1);
        if thread.is_null() {
            error!("lua: boot.lua did not return a coroutine");
            return Session::LoadFailed;
        }

        // SAFETY: `thread` stays alive until the `luax_close` below, and the
        // callback is cleared before that happens on every path out of
        // `run_steps`.
        set_log_callback(raw::luax_vlog, thread.cast());

        run_steps(state, thread, cookie)
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
    cookie: &mut raw::Variant,
) -> Session {
    loop {
        // SAFETY: the caller guarantees `thread` is live, and nothing in this
        // loop closes it before returning.
        match unsafe { step(thread) } {
            // SAFETY: yielding to the platform is what `src/main.c:66` does
            // between frames; `os_sleep` touches no Lua state.
            Step::Continue => unsafe { raw::os_sleep(0.0) },
            Step::Restart => {
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
                // SAFETY: no Lua value obtained above outlives this call.
                unsafe { raw::luax_close(state.cast()) };
                return Session::Restart;
            }
            Step::Exit { status } => {
                clear_log_callback();
                // `src/main.c:23` closes the thread rather than the state on
                // this path, which LÖVR resolves back to the main state.
                //
                // SAFETY: no Lua value obtained above outlives this call.
                unsafe { raw::luax_close(thread.cast()) };
                return Session::Exit { status };
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

/// Builds the global `arg` table `boot.lua` reads.
///
/// # Safety
///
/// `state` must be a live Lua state with room for two stack slots, and `cookie`
/// must be a valid `Variant`.
unsafe fn push_arg_table(
    state: *mut lua::lua_State,
    config_directory: &Path,
    cookie: &mut raw::Variant,
) {
    let mut arguments = env::args_os();
    let executable = arguments
        .next()
        .unwrap_or_else(|| OsString::from("lunette"));
    let entries = arg_entries(executable, config_directory, arguments);

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
