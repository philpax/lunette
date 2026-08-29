//! Linux x86_64: the FFI surface for the lunette fork of LÖVR.
//!
//! The architecture half of that restriction is in [`LogCallback`]: the type
//! names bindgen's System V x86_64 `va_list`. The platform half is the
//! `liblovr.so` the build script produces.
//!
//! This crate is the boundary between Rust and LÖVR. Its build script runs
//! LÖVR's cmake build, generates bindings with bindgen, and emits the link
//! directives for `liblovr.so` and the LuaJIT it bundles. Everything the rest
//! of the workspace needs from LÖVR passes through this crate: the `luax_*`
//! entry points, the platform hooks, and the embedded `boot.lua`.
//!
//! This crate does not orchestrate. The boot sequence, the frame loop, and the
//! Lua state's lifetime belong to the `lunette` binary. This crate exposes the
//! mechanism those are written against.

use std::{
    error,
    ffi::{c_char, c_int, c_void},
    fmt, ptr,
};

pub mod analyze;

pub mod raw {
    //! The bindgen output, verbatim.
    //!
    //! Every item here is a C symbol reached through an unsafe call, and every
    //! name is LÖVR's own. The lint suppressions below cover the C naming
    //! conventions in the generated output. Nothing in this module is
    //! hand-written.

    #![allow(non_camel_case_types, non_snake_case, non_upper_case_globals)]

    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

/// LÖVR's `boot.lua`, the script that runs before any user code.
///
/// The build script copies it out of `vendor/lovr/etc/boot.lua`. The constant
/// is defined here because `OUT_DIR` resolves to the `OUT_DIR` of the crate
/// being compiled, and the binary crate's build script does not put the file
/// there.
pub const BOOT_LUA: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/boot.lua"));

/// The signature of the callback LÖVR calls for every log line. The
/// declaration is in `vendor/lovr/src/util.h`.
///
/// `luax_vlog` has this shape. The boot sequence installs it as the log
/// callback.
///
/// On x86_64: `raw::__va_list_tag` is the name bindgen uses for the System V
/// x86_64 `va_list`. Other architectures spell it differently. On aarch64
/// clang spells it `struct __va_list`. The alias changes with the
/// architecture, so `flake.nix` declares `x86_64-linux` alone.
pub type LogCallback = unsafe extern "C" fn(
    context: *mut c_void,
    level: c_int,
    tag: *const c_char,
    format: *const c_char,
    args: *mut raw::__va_list_tag,
);

/// A live LÖVR platform layer: windowing, timing, and event delivery.
///
/// The token exists so teardown cannot run before startup or twice.
/// [`Platform::destroy`] consumes it. There is no `Drop` implementation:
/// `vendor/lovr/src/main.c` tears the platform down after the Lua state has
/// closed, and a destructor would run at a point the caller does not control.
#[must_use = "the platform stays initialised until `destroy` consumes this"]
#[derive(Debug)]
pub struct Platform(());

impl Platform {
    /// Initialises the platform layer.
    pub fn init() -> Result<Self, Error> {
        // SAFETY: `os_init` takes no arguments and accesses no Rust state.
        if unsafe { raw::os_init() } {
            Ok(Self(()))
        } else {
            Err(Error::PlatformInit)
        }
    }

    /// Tears the platform layer down.
    pub fn destroy(self) {
        // SAFETY: holding a `Platform` means `os_init` succeeded, and consuming
        // it here means no second call can follow.
        unsafe { raw::os_destroy() };
    }
}

/// Routes LÖVR's log output through `callback`.
///
/// # Safety
///
/// `context` is passed to `callback` on every log line. It must remain valid,
/// and its aliasing must be sound for `callback`, until
/// [`clear_log_callback`] runs or another callback replaces this one.
pub unsafe fn set_log_callback(callback: LogCallback, context: *mut c_void) {
    // SAFETY: the caller guarantees `context` outlives the callback.
    unsafe { raw::lovrSetLogCallback(Some(callback), context) };
}

/// Stops routing LÖVR's log output and releases the callback context.
pub fn clear_log_callback() {
    // SAFETY: a null callback makes `lovrLog` skip the callback, so the null
    // context is never dereferenced. See `vendor/lovr/src/util.c`'s `lovrLog`.
    unsafe { raw::lovrSetLogCallback(None, ptr::null_mut()) };
}

/// A failure in the LÖVR layer.
#[derive(Debug)]
pub enum Error {
    /// `os_init` failed. LÖVR reports no further detail.
    PlatformInit,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "lovr: ")?;
        match self {
            Self::PlatformInit => write!(f, "the platform layer could not start"),
        }
    }
}

impl error::Error for Error {}
