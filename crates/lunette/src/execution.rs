//! Configures per-VM Luau compilation, promotes hot functions to native code, and snapshots opt-in bridge metrics.

mod promoter;

use std::{
    ffi::c_void,
    mem::MaybeUninit,
    num::NonZeroU32,
    ptr::{self, NonNull},
};

use lunette_lovr::raw;
pub use lunette_lovr::raw::LuauMetrics;
use mlua::{Function, Lua, chunk::Compiler, ffi};

pub use self::promoter::Promoter;

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
    /// Optimized bytecode, marked-only compilation at load, and native compilation of other functions once they become hot.
    ///
    /// Functions loaded in this mode count interpreted entries and loop iterations. A function whose count reaches the [`TierUp`] threshold waits in a bounded queue until [`promote`] compiles it. Promotion needs no source markers, so it covers code whose workload is unknown in advance.
    Tiered,
}

/// Promotion parameters for [`ExecutionMode::Tiered`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TierUp {
    /// Interpreted entries plus loop iterations after which a function waits for promotion.
    pub threshold: NonZeroU32,
    /// Functions that can wait at once. A function that finds the queue full counts again from the threshold.
    pub queue_capacity: NonZeroU32,
}

/// The bytecode instructions one [`promote`] call may compile.
///
/// Compilation cost grows with function size, so a budget in instructions bounds the time a promotion takes more closely than a function count.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InstructionBudget(pub usize);

/// Sets compilation options for the VM and its coroutines.
///
/// Unsupported native execution leaves both compilers unchanged. Existing functions retain their bytecode and any native code. Scope changes apply to later compilation requests, including requests for existing functions.
pub fn configure(lua: &Lua, mode: ExecutionMode) -> mlua::Result<()> {
    let optimization = match mode {
        ExecutionMode::Interpreter => 1,
        ExecutionMode::Optimized
        | ExecutionMode::Native
        | ExecutionMode::NativeMarked
        | ExecutionMode::Tiered => 2,
    };
    let native_scope = match mode {
        ExecutionMode::Interpreter | ExecutionMode::Optimized => NativeScope::None,
        ExecutionMode::Native => NativeScope::All,
        ExecutionMode::NativeMarked => NativeScope::Marked,
        ExecutionMode::Tiered => NativeScope::Tiered,
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

/// Sets the threshold and queue capacity that [`ExecutionMode::Tiered`] applies to functions loaded afterwards.
///
/// The parameters persist across mode changes. Other modes stop newly loaded functions from counting, and functions already waiting stay queued.
pub fn set_tier_up(lua: &Lua, tier_up: TierUp) -> mlua::Result<()> {
    let threshold = c_int(tier_up.threshold, "threshold")?;
    let queue_capacity = c_int(tier_up.queue_capacity, "queue capacity")?;
    // SAFETY: `exec_raw` locks the live VM, protects registry and queue allocations, and restores the stack.
    let set: bool = unsafe {
        lua.exec_raw((), |state| {
            let set = raw::luax_setluautierup(state.cast(), threshold, queue_capacity);
            ffi::lua_pushboolean(state, i32::from(set));
        })?
    };
    if !set {
        return Err(mlua::Error::runtime(
            "lua execution: tier-up requires a build with native compilation",
        ));
    }
    Ok(())
}

/// Compiles queued hot functions oldest first and returns how many were bound to native code.
///
/// Compilation stops before the next function would exceed the budget, but always takes the first one, so a function larger than the budget still promotes. Functions already compiled through another path leave the queue without compiling. Nested functions are not compiled with their parent. Frames already running a promoted function finish in the interpreter, and its next call enters native code.
pub fn promote(lua: &Lua, budget: InstructionBudget) -> mlua::Result<usize> {
    // SAFETY: `exec_raw` locks the live VM, protects the call, and restores the stack. Compilation allocates no Lua objects.
    let bound: i32 = unsafe {
        lua.exec_raw((), |state| {
            let bound = raw::luax_promoteluau(state.cast(), budget.0);
            ffi::lua_pushinteger(state, bound.into());
        })?
    };
    usize::try_from(bound)
        .map_err(|_| mlua::Error::runtime("lua execution: promotion requires tiered execution"))
}

/// Hot functions taken from the queue so that their code can be generated away from the Lua thread.
///
/// The job keeps its functions alive. After [`HotJob::compile`] returns, it is passed to [`bind_hot`] or [`discard_hot`] on the VM it came
/// from, before that VM closes. A job that is dropped instead leaks its allocation and keeps its functions pinned; [`Promoter`] never
/// drops one while its VM is open.
#[must_use = "a hot job is bound or discarded on its VM"]
pub struct HotJob(NonNull<c_void>);

// SAFETY: compilation reads only the job's snapshots and the functions it pins, and touches no Lua state, so one other thread may own it.
unsafe impl Send for HotJob {}

impl HotJob {
    /// Generates the job's native code. It touches no Lua state, so it runs on any thread while the VM continues.
    pub fn compile(&mut self) {
        // SAFETY: the job is live and owned by this value, and the bridge reads only the job.
        unsafe { raw::luax_compileluauhot(self.0.as_ptr()) }
    }
}

/// Takes queued hot functions within the budget for compilation away from the Lua thread, or `None` when nothing is queued or the VM is
/// not in [`ExecutionMode::Tiered`].
pub fn take_hot(lua: &Lua, budget: InstructionBudget) -> mlua::Result<Option<HotJob>> {
    let mut job = ptr::null_mut();
    // SAFETY: `exec_raw` locks the live VM, protects the pin reservation, and restores the stack.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            job = raw::luax_takeluauhot(state.cast(), budget.0);
        })?;
    }
    Ok(NonNull::new(job).map(HotJob))
}

/// Installs a compiled job's native code and returns how many functions were bound.
///
/// Functions compiled through another path or given a breakpoint while the job was compiled keep their state. The job must have come from
/// this VM, and [`HotJob::compile`] must have returned.
pub fn bind_hot(lua: &Lua, job: HotJob) -> mlua::Result<usize> {
    let mut bound = 0;
    // SAFETY: `exec_raw` locks the live VM and restores the stack. The job came from this VM and compilation has finished.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            bound = raw::luax_bindluauhot(state.cast(), job.0.as_ptr());
        })?;
    }
    Ok(usize::try_from(bound).unwrap_or_default())
}

/// Releases a job without installing its code. The job must have come from this VM, and no compilation of it may be running.
pub fn discard_hot(lua: &Lua, job: HotJob) -> mlua::Result<()> {
    // SAFETY: `exec_raw` locks the live VM and restores the stack. The job came from this VM and nothing else reads it.
    unsafe {
        lua.exec_raw::<()>((), |state| {
            raw::luax_discardluauhot(state.cast(), job.0.as_ptr());
        })
    }
}

/// Returns the number of hot functions waiting for [`promote`].
pub fn hot_queue_len(lua: &Lua) -> mlua::Result<usize> {
    // SAFETY: `exec_raw` locks the live VM and restores the stack. The query reads one field.
    let len: i32 = unsafe {
        lua.exec_raw((), |state| {
            let len = raw::luax_getluauhotqueuesize(state.cast());
            ffi::lua_pushinteger(state, len.into());
        })?
    };
    Ok(usize::try_from(len).unwrap_or_default())
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
/// Counters remain cumulative across snapshots, configuration changes, source reloads, and garbage collection. `codegenReservedBytes` and `codegenLiveReservationCount` are live arena-reservation gauges; the corresponding peak fields are high-water marks. `codegenReservationBytes` and `codegenReservationCount` are cumulative reservation totals. These reservations do not measure live executable code. Native code, data, and metadata byte counters measure cumulative emission. The native totals include [`promote`] calls, and the `hot` fields report that subset.
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
    Tiered = 3,
}

fn c_int(value: NonZeroU32, name: &str) -> mlua::Result<i32> {
    i32::try_from(value.get()).map_err(|_| {
        mlua::Error::runtime(format!(
            "lua execution: the tier-up {name} exceeds {}",
            i32::MAX
        ))
    })
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "tests fail at the operation that violates the contract"
)]
mod tests;
