//! Linux-only: the FFI surface for the lunette fork of LÖVR.
//!
//! Everything the workspace needs from LÖVR passes through this crate, while orchestration belongs to the `lunette` binary.

use std::{
    error,
    ffi::{c_char, c_int, c_void},
    fmt, ptr,
};

pub mod analyze;
pub mod msdf;

pub mod raw {
    //! The bindgen output, with four items declared by hand instead.
    //!
    //! Bindgen renders `va_list` differently across libclang versions, so these declarations use an opaque pointer and `build.rs` blocklists the generated versions.

    #![allow(non_camel_case_types, non_snake_case, non_upper_case_globals)]

    include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

    pub type fn_log = Option<crate::LogCallback>;

    unsafe extern "C" {
        pub fn luax_vthrow(
            L: *mut ::std::os::raw::c_void,
            format: *const ::std::os::raw::c_char,
            args: *mut ::std::os::raw::c_void,
        );
        pub fn luax_vlog(
            context: *mut ::std::os::raw::c_void,
            level: ::std::os::raw::c_int,
            tag: *const ::std::os::raw::c_char,
            format: *const ::std::os::raw::c_char,
            args: *mut ::std::os::raw::c_void,
        );
        pub fn lovrSetLogCallback(callback: fn_log, userdata: *mut ::std::os::raw::c_void);
    }
}

/// LÖVR's `boot.lua`, the script that runs before any user code.
///
/// Defined here because `OUT_DIR` resolves to the compiling crate's, and only this crate's build script copies the file.
pub const BOOT_LUA: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/boot.lua"));

/// The signature of the callback LÖVR calls for every log line, declared in `vendor/lovr/src/util.h`.
///
/// The `va_list` argument is passed by address and forwarded opaquely.
pub type LogCallback = unsafe extern "C" fn(
    context: *mut c_void,
    level: c_int,
    tag: *const c_char,
    format: *const c_char,
    args: *mut c_void,
);

/// A live LÖVR platform layer: windowing, timing, and event delivery.
///
/// The token exists so teardown cannot run before startup or twice. There is no `Drop`, because teardown must follow the Lua state's closing at a point the caller controls.
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
/// `context` must remain valid, with sound aliasing for `callback`, until [`clear_log_callback`] runs or another callback replaces this one.
pub unsafe fn set_log_callback(callback: LogCallback, context: *mut c_void) {
    // SAFETY: the caller guarantees `context` outlives the callback.
    unsafe { raw::lovrSetLogCallback(Some(callback), context) };
}

/// Stops routing LÖVR's log output and releases the callback context.
pub fn clear_log_callback() {
    // SAFETY: a null callback makes `lovrLog` skip the callback, so the null context is never dereferenced.
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
