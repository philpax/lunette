//! Linux-only: records Luau native code registrations in a Linux perf map.

use std::{
    error::Error,
    ffi::{CStr, CString, c_char, c_uint, c_ulong, c_void},
    fs::{File, OpenOptions},
    io::{self, Write},
    os::unix::fs::OpenOptionsExt,
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        OnceLock,
        atomic::{AtomicBool, Ordering},
    },
};

use parking_lot::Mutex;

const PERF_LOG_SYMBOL: &CStr = c"_ZN4Luau7CodeGen10setPerfLogEPvPFvS1_mjPKcE";
static ACTIVE: AtomicBool = AtomicBool::new(false);
static SET_PERF_LOG: OnceLock<Result<SetPerfLog, String>> = OnceLock::new();

type PerfLogCallback = unsafe extern "C" fn(*mut c_void, c_ulong, c_uint, *const c_char);
type SetPerfLog = unsafe extern "C" fn(*mut c_void, Option<PerfLogCallback>);

/// Keeps the perf-map callback context alive until Luau has stopped using it.
pub struct JitSymbols {
    set_perf_log: SetPerfLog,
    context: Option<Box<CallbackContext>>,
    path: PathBuf,
    installed: bool,
}

impl JitSymbols {
    /// Installs Luau's native-code logger and creates `/tmp/perf-<pid>.map` without overwriting it.
    pub fn install() -> Result<Self, Box<dyn Error>> {
        ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| {
                io::Error::other("desktop benchmark perf map: another logger is active")
            })?;

        let installation = Self::install_active();
        if installation.is_err() {
            ACTIVE.store(false, Ordering::Release);
        }
        installation
    }

    fn install_active() -> Result<Self, Box<dyn Error>> {
        let set_perf_log = match SET_PERF_LOG.get_or_init(resolve_set_perf_log) {
            Ok(set_perf_log) => *set_perf_log,
            Err(error) => {
                return Err(
                    io::Error::other(format!("desktop benchmark perf map: {error}")).into(),
                );
            }
        };

        let path = PathBuf::from(format!("/tmp/perf-{}.map", std::process::id()));
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| {
                io::Error::new(
                    error.kind(),
                    format!(
                        "desktop benchmark perf map: create {}: {error}",
                        path.display()
                    ),
                )
            })?;
        let mut context = Box::new(CallbackContext {
            state: Mutex::new(CallbackState { file, error: None }),
        });
        let context_ptr = (&mut *context as *mut CallbackContext).cast::<c_void>();

        // SAFETY: The context remains boxed until the callback is unregistered. The callback has
        // the exact ABI declared by Luau's exported setPerfLog symbol.
        unsafe { set_perf_log(context_ptr, Some(write_perf_map_entry)) };

        Ok(Self {
            set_perf_log,
            context: Some(context),
            path,
            installed: true,
        })
    }

    /// Unregisters the callback, flushes the map, and returns its path without deleting it.
    pub fn finish(mut self) -> Result<PathBuf, Box<dyn Error>> {
        self.uninstall();
        let context = self.context.as_ref().ok_or_else(|| {
            io::Error::other("desktop benchmark perf map: callback context is already released")
        })?;
        let mut state = context.state.lock();
        if let Some(error) = state.error.take() {
            return Err(io::Error::new(
                error.kind(),
                format!(
                    "desktop benchmark perf map: write {}: {error}",
                    self.path.display()
                ),
            )
            .into());
        }
        state.file.flush().map_err(|error| {
            io::Error::new(
                error.kind(),
                format!(
                    "desktop benchmark perf map: flush {}: {error}",
                    self.path.display()
                ),
            )
        })?;
        Ok(self.path.clone())
    }

    fn uninstall(&mut self) {
        if self.installed {
            // SAFETY: The callback is removed before its boxed context is dropped.
            unsafe { (self.set_perf_log)(std::ptr::null_mut(), None) };
            self.installed = false;
        }
    }
}

impl Drop for JitSymbols {
    fn drop(&mut self) {
        self.uninstall();
        self.context.take();
        ACTIVE.store(false, Ordering::Release);
    }
}

struct CallbackContext {
    state: Mutex<CallbackState>,
}

struct CallbackState {
    file: File,
    error: Option<io::Error>,
}

fn resolve_set_perf_log() -> Result<SetPerfLog, String> {
    let symbol = CString::new(PERF_LOG_SYMBOL.to_bytes())
        .map_err(|error| format!("invalid setPerfLog symbol name: {error}"))?;

    // SAFETY: dlsym accepts RTLD_DEFAULT and a NUL-terminated symbol name. dlerror is cleared
    // before lookup so a null result can be paired with the relevant loader error.
    let address = unsafe {
        libc::dlerror();
        let address = libc::dlsym(libc::RTLD_DEFAULT, symbol.as_ptr());
        if address.is_null() {
            let error = libc::dlerror();
            let detail = if error.is_null() {
                "dynamic loader returned no detail".into()
            } else {
                CStr::from_ptr(error).to_string_lossy().into_owned()
            };
            return Err(format!("resolve Luau::CodeGen::setPerfLog: {detail}"));
        }
        address
    };

    // SAFETY: PERF_LOG_SYMBOL names Luau's exported setter with the matching function-pointer ABI.
    Ok(unsafe { std::mem::transmute::<*mut c_void, SetPerfLog>(address) })
}

unsafe extern "C" fn write_perf_map_entry(
    context: *mut c_void,
    address: c_ulong,
    size: c_uint,
    name: *const c_char,
) {
    if context.is_null() {
        return;
    }

    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: The setter receives this pointer from install_active and it remains valid until
        // uninstall unregisters the callback. The mutex serializes callbacks if compilation ever
        // invokes them concurrently.
        let context = unsafe { &*context.cast::<CallbackContext>() };
        let mut state = context.state.lock();
        if state.error.is_some() {
            return;
        }
        if name.is_null() {
            state.error = Some(io::Error::new(
                io::ErrorKind::InvalidData,
                "Luau perf-map callback supplied a null name",
            ));
            return;
        }

        // SAFETY: Luau supplies a NUL-terminated symbol name for the duration of this callback.
        let name = unsafe { CStr::from_ptr(name) }.to_bytes();
        let result = (|| {
            write!(state.file, "{address:x} {size:x} ")?;
            for byte in name {
                state.file.write_all(if matches!(byte, b'\n' | b'\r') {
                    b" "
                } else {
                    std::slice::from_ref(byte)
                })?;
            }
            state.file.write_all(b"\n")
        })();
        if let Err(error) = result {
            state.error = Some(error);
        }
    }));

    if result.is_err() {
        // Record unexpected Rust panics instead of unwinding across Luau's C++ callback boundary.
        let _ = catch_unwind(AssertUnwindSafe(|| {
            // SAFETY: The pointer is still owned by JitSymbols until the logger has been unregistered.
            let context = unsafe { &*context.cast::<CallbackContext>() };
            let mut state = context.state.lock();
            if state.error.is_none() {
                state.error = Some(io::Error::other("perf-map callback panicked"));
            }
        }));
    }
}
