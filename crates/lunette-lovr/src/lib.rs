//! Linux, x86_64-only: the FFI surface for the lunette fork of LÖVR.
//!
//! The architecture half of that is [`LogCallback`], which names bindgen's
//! System V x86_64 `va_list`; the platform half is the `liblovr.so` the build
//! script produces.
//!
//! This crate owns the boundary between Rust and LÖVR. Its build script drives
//! LÖVR's cmake build, generates bindings with bindgen, and emits the link
//! directives for `liblovr.so` and the LuaJIT it ships. Everything the rest of
//! the workspace needs from LÖVR — the `luax_*` entry points, the platform
//! hooks, and the embedded `boot.lua` — is reached through here.
//!
//! Orchestration is not this crate's job. The boot sequence, the frame loop,
//! and the Lua state's lifetime belong to the `lunette` binary; this crate
//! exposes the mechanism those are written against.

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
    //! name is the one LÖVR gives it. The lint suppressions below cover the C
    //! naming conventions that survive generation; nothing in this module is
    //! hand-written.

    #![allow(non_camel_case_types, non_snake_case, non_upper_case_globals)]

    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
}

/// LÖVR's `boot.lua`, the script that runs before any user code.
///
/// The build script copies it out of `vendor/lovr/etc/boot.lua`. It lives here
/// rather than in the binary crate because `OUT_DIR` resolves to the `OUT_DIR`
/// of the crate being compiled, and only this crate's build script puts the
/// file there.
pub const BOOT_LUA: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/boot.lua"));

/// The signature LÖVR hands log lines to; `vendor/lovr/src/util.h:67`.
///
/// `luax_vlog` has exactly this shape, which is what the boot sequence installs.
///
/// x86_64-only: `raw::__va_list_tag` is the name bindgen gives the System V
/// x86_64 `va_list`. Other architectures spell it differently — on aarch64
/// clang's is `struct __va_list` — so this alias has to change with them, which
/// is why `flake.nix` declares `x86_64-linux` alone.
pub type LogCallback = unsafe extern "C" fn(
    context: *mut c_void,
    level: c_int,
    tag: *const c_char,
    format: *const c_char,
    args: *mut raw::__va_list_tag,
);

/// A live LÖVR platform layer: windowing, timing, and event delivery.
///
/// The token exists so that teardown cannot run before startup or twice.
/// [`Platform::destroy`] consumes it, and there is deliberately no `Drop`
/// implementation: `vendor/lovr/src/main.c:25` tears the platform down only
/// after the Lua state has closed, and a destructor would take that ordering
/// away from the caller.
#[must_use = "the platform stays initialised until `destroy` consumes this"]
#[derive(Debug)]
pub struct Platform(());

impl Platform {
    /// Initialises the platform layer.
    pub fn init() -> Result<Self, Error> {
        // SAFETY: `os_init` takes no arguments and touches no Rust state.
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
/// `context` is handed back to `callback` on every log line, so it must stay
/// valid — and must not be aliased in a way `callback` violates — until
/// [`clear_log_callback`] runs or another callback replaces this one.
pub unsafe fn set_log_callback(callback: LogCallback, context: *mut c_void) {
    // SAFETY: the caller guarantees `context` outlives the callback.
    unsafe { raw::lovrSetLogCallback(Some(callback), context) };
}

/// Stops routing LÖVR's log output, releasing the context the callback held.
pub fn clear_log_callback() {
    // SAFETY: a null callback and a null context are what LÖVR checks for; see
    // `vendor/lovr/src/util.c`'s `lovrLog`.
    unsafe { raw::lovrSetLogCallback(None, ptr::null_mut()) };
}

/// A failure in the LÖVR layer.
#[derive(Debug)]
pub enum Error {
    /// `os_init` reported failure. LÖVR gives no further detail.
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
