//! Configures per-VM Luau compilation and snapshots opt-in bridge metrics.

use std::mem::MaybeUninit;

use lunette_lovr::raw;
pub use lunette_lovr::raw::LuauMetrics;
use mlua::{Function, Lua, chunk::Compiler, ffi};

/// Compilation applied to chunks loaded after configuration.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ExecutionMode {
    /// Baseline bytecode optimization without native compilation.
    #[default]
    Interpreter,
    /// Bytecode optimization including inlining, without native compilation.
    Optimized,
    /// Optimized bytecode and native compilation where CodeGen supports the function.
    Native,
    /// Optimized bytecode and Luau's marked-only native compilation for `--!native` modules and `@native` functions.
    NativeMarked,
}

/// Sets compilation options for the VM and its coroutines.
///
/// Unsupported native execution leaves both compilers unchanged. Existing functions retain their bytecode and any native code. Scope changes apply to later compilation requests, including requests for existing functions.
pub fn configure(lua: &Lua, mode: ExecutionMode) -> mlua::Result<()> {
    let optimization = match mode {
        ExecutionMode::Interpreter => 1,
        ExecutionMode::Optimized | ExecutionMode::Native | ExecutionMode::NativeMarked => 2,
    };
    let native_scope = match mode {
        ExecutionMode::Interpreter | ExecutionMode::Optimized => NativeScope::None,
        ExecutionMode::Native => NativeScope::All,
        ExecutionMode::NativeMarked => NativeScope::Marked,
    };
    // SAFETY: `exec_raw` locks the live VM, protects registry allocations, and restores the stack.
    let configured: bool = unsafe {
        lua.exec_raw((), |state| {
            let configured =
                raw::luax_setluauoptions_scoped(state.cast(), optimization, native_scope as i32);
            ffi::lua_pushboolean(state, i32::from(configured));
        })?
    };
    if !configured {
        return Err(mlua::Error::runtime(
            "lua execution: native compilation is not supported by this build or CPU",
        ));
    }
    lua.set_compiler(
        Compiler::new()
            .set_optimization_level(optimization as u8)
            .set_debug_level(1)
            .set_type_info_level(u8::from(native_scope != NativeScope::None)),
    );
    Ok(())
}

/// Compiles a Lua function and its nested functions under the VM's current native scope.
///
/// Interpreter modes leave the function unchanged. [`ExecutionMode::NativeMarked`] forwards Luau's `CodeGen_OnlyNativeModules` policy. The requested function's prototype must carry `LPF_NATIVE_MODULE` or `LPF_NATIVE_FUNCTION`; source provenance is not tracked. This includes `@native` functions in modules without `--!native`, but a plain closure returned from a `--!native` chunk lacks the module flag. To include plain nested functions, callers pass the original chunk to this function before executing it. LÖVR's C loader compiles the original chunk automatically; mlua callers use this function explicitly.
///
/// CodeGen can retain interpreter execution for unsupported functions. A successful request does not prove that CodeGen emits native code.
///
/// # Panics
///
/// Panics if the function belongs to a different Lua VM.
pub fn compile(lua: &Lua, function: &Function) -> mlua::Result<()> {
    // SAFETY: `exec_raw` checks the function's VM, roots it at index 1, protects the call, and restores the stack.
    unsafe {
        lua.exec_raw(function, |state| {
            raw::luax_compilefunction(state.cast(), 1);
        })
    }
}

/// Enables cumulative metrics for the VM and its coroutines before the first successful execution configuration.
///
/// Repeated calls are idempotent, including after configuration. A late first call returns an error without changing compilation settings. Metrics cover calls through the LÖVR bridge, not mlua's bytecode compiler or loader. Explicit native compilation through [`compile`] is included.
pub fn enable_metrics(lua: &Lua) -> mlua::Result<()> {
    // SAFETY: `exec_raw` locks the live VM, protects registry allocations, and restores the stack.
    let enabled: bool = unsafe {
        lua.exec_raw((), |state| {
            let enabled = raw::luax_enableluaumetrics(state.cast());
            ffi::lua_pushboolean(state, i32::from(enabled));
        })?
    };
    if !enabled {
        return Err(mlua::Error::runtime(
            "lua execution metrics: enable metrics before the first execution configuration",
        ));
    }
    Ok(())
}

/// Returns a scalar metrics snapshot, or `None` when metrics are disabled.
///
/// Counters remain cumulative across snapshots, configuration changes, source reloads, and garbage collection. `codegenReservedBytes` and `codegenLiveReservationCount` are live arena-reservation gauges; the corresponding peak fields are high-water marks. `codegenReservationBytes` and `codegenReservationCount` are cumulative reservation totals. These reservations do not measure live executable code. Native code, data, and metadata byte counters measure cumulative emission.
///
/// Times are nanoseconds spent in bridge calls. The availability fields identify supported elapsed, calling-thread CPU, and native CodeGen measurements. `lastNativeCompileResult` holds the Luau CodeGen result value, or `-1` before any native compilation call. Reading a snapshot does not reset counters or gauges.
pub fn metrics(lua: &Lua) -> mlua::Result<Option<LuauMetrics>> {
    let mut snapshot = MaybeUninit::<LuauMetrics>::uninit();
    // SAFETY: `exec_raw` locks the live VM. The output is initialized in full only when the bridge returns true, and outlives the protected call.
    let available: bool = unsafe {
        lua.exec_raw((), |state| {
            let available = raw::luax_getluaumetrics(state.cast(), snapshot.as_mut_ptr());
            ffi::lua_pushboolean(state, i32::from(available));
        })?
    };
    if available {
        // SAFETY: the bridge returns true only after initializing every LuauMetrics field.
        Ok(Some(unsafe { snapshot.assume_init() }))
    } else {
        Ok(None)
    }
}

/// Whether the linked LÖVR build and CPU support Luau native compilation.
pub fn supported() -> bool {
    // SAFETY: the support query takes no state and does not mutate compiler flags.
    unsafe { raw::luax_luaucodegensupported() }
}

#[derive(Clone, Copy, Eq, PartialEq)]
#[repr(i32)]
enum NativeScope {
    None = 0,
    All = 1,
    Marked = 2,
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests fail at the operation that violates the contract"
)]
mod tests;
