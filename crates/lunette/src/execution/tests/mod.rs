use std::{ffi::CStr, mem::MaybeUninit};

use mlua::{Function, Lua, ffi};

use super::*;

mod promoter;
mod tier_up;

// The local probe avoids a global lookup that can leave native execution before the callback.
const PROBE_SOURCE: &str = r#"
local functions = {
    function(probe: () -> boolean, limit: number): (boolean, number)
        local total = 0
        for index = 1, limit do
            total += index
        end
        return probe(), total
    end,
}
return functions[1](...)
"#;

const MODES: [ExecutionMode; 5] = [
    ExecutionMode::Interpreter,
    ExecutionMode::Optimized,
    ExecutionMode::Native,
    ExecutionMode::NativeMarked,
    ExecutionMode::Tiered,
];

#[test]
fn configuring_one_vm_does_not_change_another_vm() {
    let first = Lua::new();
    let second = Lua::new();
    configure(&first, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure(&second, ExecutionMode::Optimized).expect("optimized execution is supported");

    configure_mode(&first, ExecutionMode::Native);
    assert_eq!(
        c_settings(&first),
        if supported() { (2, true) } else { (1, false) }
    );
    assert_eq!(c_settings(&second), (2, false));
    for loader in [Loader::C, Loader::Mlua] {
        let first_function = loader
            .load(&first, PROBE_SOURCE, c"@first.luau")
            .expect("the first VM loads");
        let second_function = loader
            .load(&second, PROBE_SOURCE, c"@second.luau")
            .expect("the second VM loads");
        compile(&first, &first_function).expect("the first VM compiles");
        compile(&second, &second_function).expect("the second VM compiles");
        assert_eq!(
            probe_execution(&first, &first_function),
            (supported(), 5050)
        );
        assert_eq!(probe_execution(&second, &second_function), (false, 5050));
    }

    configure(&second, ExecutionMode::Interpreter).expect("the second VM changes mode");
    assert_eq!(
        c_settings(&first),
        if supported() { (2, true) } else { (1, false) }
    );
    assert_eq!(c_settings(&second), (1, false));
    let third = Lua::new();
    for loader in [Loader::C, Loader::Mlua] {
        let function = loader
            .load(&third, PROBE_SOURCE, c"@fresh.luau")
            .expect("a fresh VM loads");
        compile(&third, &function).expect("compilation in a fresh VM is harmless");
        assert_eq!(probe_execution(&third, &function), (false, 5050));
    }
}

#[test]
fn coroutines_share_scope_changes_without_changing_another_vm() {
    let lua = Lua::new();
    let other = Lua::new();
    configure(&lua, ExecutionMode::Optimized).expect("optimized execution is supported");
    configure(&other, ExecutionMode::Optimized).expect("optimized execution is supported");
    let configure_on_coroutine = lua
        .create_function(|lua, ()| {
            configure_mode(lua, ExecutionMode::NativeMarked);
            for loader in [Loader::C, Loader::Mlua] {
                assert_probe(lua, loader, false, false);
                assert_probe(lua, loader, true, true);
            }
            Ok(())
        })
        .expect("the coroutine callback is created");
    let thread = lua
        .create_thread(configure_on_coroutine)
        .expect("the coroutine is created");
    thread
        .resume::<()>(())
        .expect("the coroutine configures its VM");
    for loader in [Loader::C, Loader::Mlua] {
        assert_probe(&lua, loader, false, false);
        assert_probe(&lua, loader, true, true);
        assert_probe(&other, loader, true, false);
    }

    configure_mode(&lua, ExecutionMode::Native);
    let inspect_on_coroutine = lua
        .create_function(|lua, ()| {
            for loader in [Loader::C, Loader::Mlua] {
                assert_probe(lua, loader, false, true);
                assert_probe(lua, loader, true, true);
            }
            Ok(())
        })
        .expect("the coroutine callback is created");
    let thread = lua
        .create_thread(inspect_on_coroutine)
        .expect("the coroutine is created");
    thread
        .resume::<()>(())
        .expect("the coroutine sees the main thread's scope");
    for loader in [Loader::C, Loader::Mlua] {
        assert_probe(&other, loader, false, false);
    }
}

#[test]
fn marked_scope_requires_a_native_directive_in_both_loaders() {
    let lua = Lua::new();
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure_mode(&lua, ExecutionMode::NativeMarked);
    for loader in [Loader::C, Loader::Mlua] {
        assert_probe(&lua, loader, false, false);
        assert_probe(&lua, loader, true, true);
    }
}

#[test]
fn marked_scope_accepts_native_functions_without_a_module_directive() {
    let lua = Lua::new();
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure_mode(&lua, ExecutionMode::NativeMarked);
    let source = PROBE_SOURCE.replacen("function(", "@native function(", 1);
    for loader in [Loader::C, Loader::Mlua] {
        let chunk = loader
            .load(&lua, &source, c"@native-function.luau")
            .expect("the annotated function loads without a module directive");
        compile(&lua, &chunk).expect("the annotated function's chunk compiles");
        assert_eq!(probe_execution(&lua, &chunk), (supported(), 5050));
    }
}

#[test]
fn compiling_a_returned_plain_closure_does_not_inherit_its_chunks_native_directive() {
    let lua = Lua::new();
    for loader in [Loader::C, Loader::Mlua] {
        configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
        let source = format!(
            "--!native\n{}",
            PROBE_SOURCE.replace("return functions[1](...)", "return functions[1]")
        );
        let chunk = loader
            .load(&lua, &source, c"@returned-closure.luau")
            .expect("the marked chunk loads without native compilation");
        let function: Function = chunk.call(()).expect("the plain closure is returned");
        configure_mode(&lua, ExecutionMode::NativeMarked);
        compile(&lua, &function).expect("a returned plain closure is harmless to compile");
        assert_eq!(probe_execution(&lua, &function), (false, 5050));
        compile(&lua, &chunk).expect("the original marked chunk compiles its nested functions");
        assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
        compile(&lua, &function).expect("a direct request preserves the already-bound native code");
        assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
    }
}

#[test]
fn legacy_boolean_c_configuration_selects_all_or_no_native_compilation() {
    let lua = Lua::new();
    configure(&lua, ExecutionMode::Optimized).expect("optimized execution is supported");
    configure_mode(&lua, ExecutionMode::NativeMarked);
    for (optimization, native) in [(2, true), (1, false)] {
        let before = c_settings(&lua);
        // SAFETY: exec_raw locks the live VM and protects the legacy configuration call.
        let configured: bool = unsafe {
            lua.exec_raw((), |state| {
                let configured = raw::luax_setluauoptions(state.cast(), optimization, native);
                ffi::lua_pushboolean(state, i32::from(configured));
            })
        }
        .expect("the legacy C configuration call is protected");
        assert_eq!(configured, !native || supported());
        assert_eq!(
            c_settings(&lua),
            if configured {
                (optimization, native)
            } else {
                before
            }
        );
        assert_probe(&lua, Loader::C, false, native);
        assert_probe(&lua, Loader::C, true, native);
        assert_eq!(
            inlining_upvalues(&lua, Loader::C),
            u8::from(optimization == 1)
        );
    }
}

#[test]
fn an_unconfigured_c_loader_uses_o1_without_native_compilation() {
    let lua = Lua::new();
    let unconfigured = inlining_upvalues(&lua, Loader::C);
    assert_probe(&lua, Loader::C, false, false);
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    assert_eq!(unconfigured, inlining_upvalues(&lua, Loader::C));
    assert_eq!(unconfigured, 1);
    configure(&lua, ExecutionMode::Optimized).expect("optimized execution is supported");
    assert_eq!(inlining_upvalues(&lua, Loader::C), 0);
}

#[test]
fn scope_changes_apply_at_compilation_and_preserve_existing_native_functions() {
    let lua = Lua::new();
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    let mut pending = Vec::new();
    for loader in [Loader::C, Loader::Mlua] {
        let function = loader
            .load(&lua, PROBE_SOURCE, c"@pending.luau")
            .expect("the interpreter chunk loads");
        pending.push(function);
    }
    configure_mode(&lua, ExecutionMode::Native);
    for function in &pending {
        assert_eq!(probe_execution(&lua, function), (false, 5050));
        compile(&lua, function).expect("the current scope applies to an existing function");
        assert_eq!(probe_execution(&lua, function), (supported(), 5050));
    }
    configure_mode(&lua, ExecutionMode::NativeMarked);
    for function in &pending {
        compile(&lua, function).expect("recompilation preserves native functions");
        assert_eq!(probe_execution(&lua, function), (supported(), 5050));
    }
    let mut unmarked = Vec::new();
    for loader in [Loader::C, Loader::Mlua] {
        let function = loader
            .load(&lua, PROBE_SOURCE, c"@unmarked.luau")
            .expect("the unmarked chunk loads");
        compile(&lua, &function).expect("unmarked compilation is harmless");
        assert_eq!(probe_execution(&lua, &function), (false, 5050));
        unmarked.push(function);
    }
    configure_mode(&lua, ExecutionMode::Native);
    for function in &unmarked {
        assert_eq!(probe_execution(&lua, function), (false, 5050));
        compile(&lua, function).expect("the broader scope compiles unmarked functions");
        assert_eq!(probe_execution(&lua, function), (supported(), 5050));
    }
    configure_mode(&lua, ExecutionMode::Native);
    configure(&lua, ExecutionMode::Interpreter).expect("the VM returns to the interpreter");
    for loader in [Loader::C, Loader::Mlua] {
        assert_probe(&lua, loader, true, false);
    }
    for function in pending.iter().chain(&unmarked) {
        compile(&lua, function).expect("interpreter recompilation is harmless");
        assert_eq!(probe_execution(&lua, function), (supported(), 5050));
    }
}

#[test]
fn c_and_mlua_loaders_agree_and_mlua_requires_explicit_native_compilation() {
    for mode in MODES {
        let lua = Lua::new();
        configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
        configure_mode(&lua, mode);
        let native = is_native(mode) && supported();
        let upvalues = if mode == ExecutionMode::Optimized || native {
            0
        } else {
            1
        };
        for loader in [Loader::C, Loader::Mlua] {
            assert_eq!(inlining_upvalues(&lua, loader), upvalues);
        }
        let source = format!("--!native\n{PROBE_SOURCE}");
        let c_function = Loader::C
            .load(&lua, &source, c"@parity.luau")
            .expect("the C loader accepts typed source");
        let mlua_function = Loader::Mlua
            .load(&lua, &source, c"@parity.luau")
            .expect("mlua accepts typed source");
        assert_eq!(probe_execution(&lua, &c_function), (native, 5050));
        assert_eq!(probe_execution(&lua, &mlua_function), (false, 5050));
        compile(&lua, &mlua_function).expect("explicit compilation succeeds");
        assert_eq!(
            probe_execution(&lua, &mlua_function),
            probe_execution(&lua, &c_function)
        );
        compile(&lua, &probe(&lua)).expect("compiling a C function is harmless");
    }
}

#[test]
fn native_configuration_succeeds_or_preserves_both_compilers_when_unsupported() {
    let lua = Lua::new();
    for mode in [ExecutionMode::Interpreter, ExecutionMode::Optimized] {
        for native_mode in [
            ExecutionMode::Native,
            ExecutionMode::NativeMarked,
            ExecutionMode::Tiered,
        ] {
            configure(&lua, mode).expect("bytecode compilation is supported");
            let before_c = c_settings(&lua);
            let before_mlua = inlining_upvalues(&lua, Loader::Mlua);
            assert_eq!(
                before_mlua,
                if mode == ExecutionMode::Interpreter {
                    1
                } else {
                    0
                }
            );
            let configured = configure(&lua, native_mode);
            if supported() {
                configured.expect("native execution is supported");
                assert_eq!(c_settings(&lua), (2, true));
                assert_eq!(inlining_upvalues(&lua, Loader::Mlua), 0);
            } else {
                let error = configured.expect_err("unsupported native execution is rejected");
                assert!(
                    error
                        .to_string()
                        .contains("native compilation is not supported"),
                    "{error}"
                );
                assert_eq!(c_settings(&lua), before_c);
                assert_eq!(inlining_upvalues(&lua, Loader::Mlua), before_mlua);
            }
        }
    }
}

#[test]
fn both_loaders_preserve_source_errors_and_debug_information_in_each_mode() {
    for mode in MODES {
        let lua = Lua::new();
        configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
        configure_mode(&lua, mode);
        for loader in [Loader::C, Loader::Mlua] {
            let syntax = loader
                .load(&lua, "--!native\nlocal =", c"@syntax-error.luau")
                .expect_err("invalid source is rejected");
            assert!(
                syntax.to_string().contains("syntax-error.luau:2:"),
                "{mode:?} {syntax}"
            );
            let chunk = loader
                .load(
                    &lua,
                    "--!native\nlocal function fail()\n    error('execution sentinel')\nend\nreturn fail",
                    c"@runtime-error.luau",
                )
                .expect("the error fixture loads");
            compile(&lua, &chunk).expect("the error fixture compiles");
            let function: Function = chunk.call(()).expect("the nested function is returned");
            let info = function.info();
            assert_eq!(info.name.as_deref(), Some("fail"));
            assert_eq!(info.source.as_deref(), Some("@runtime-error.luau"));
            assert_eq!(info.line_defined, Some(2));
            let error = function
                .call::<()>(())
                .expect_err("the nested function raises");
            let message = error.to_string();
            assert!(
                message.contains("runtime-error.luau:3:"),
                "{mode:?} {message}"
            );
            assert!(message.contains("execution sentinel"), "{mode:?} {message}");
            assert!(message.contains("fail"), "{mode:?} {message}");
            let recovered = loader
                .load(&lua, "return 42", c"@recovered.luau")
                .expect("loading still works after errors");
            assert_eq!(recovered.call::<i64>(()).expect("execution recovers"), 42);
        }
    }
}

#[test]
fn metrics_are_disabled_until_enabled_and_late_enable_preserves_both_compilers() {
    let lua = Lua::new();
    assert!(
        metrics(&lua)
            .expect("a disabled snapshot is harmless")
            .is_none()
    );
    // SAFETY: LuauMetrics contains only integer fields, for which zero is valid.
    let mut untouched: LuauMetrics = unsafe { MaybeUninit::zeroed().assume_init() };
    untouched.bytecodeCompileCalls = 41;
    untouched.lastNativeCompileResult = -7;
    // SAFETY: exec_raw locks the VM and the output outlives the protected call.
    let available: bool = unsafe {
        lua.exec_raw((), |state| {
            let available = raw::luax_getluaumetrics(state.cast(), &mut untouched);
            ffi::lua_pushboolean(state, i32::from(available));
        })
    }
    .expect("a disabled raw snapshot is harmless");
    assert!(!available);
    assert_eq!(untouched.bytecodeCompileCalls, 41);
    assert_eq!(untouched.lastNativeCompileResult, -7);

    configure(&lua, ExecutionMode::Optimized).expect("optimized execution is supported");
    configure_mode(&lua, ExecutionMode::NativeMarked);
    let before_c = c_settings(&lua);
    let before_mlua = inlining_upvalues(&lua, Loader::Mlua);
    let error = enable_metrics(&lua).expect_err("late metrics activation is rejected");
    assert!(
        error
            .to_string()
            .contains("before the first execution configuration"),
        "{error}"
    );
    assert_eq!(c_settings(&lua), before_c);
    assert_eq!(inlining_upvalues(&lua, Loader::Mlua), before_mlua);
    assert!(metrics(&lua).expect("metrics stay disabled").is_none());
    for loader in [Loader::C, Loader::Mlua] {
        assert_probe(&lua, loader, false, false);
        assert_probe(&lua, loader, true, true);
    }
}

#[test]
fn metrics_start_at_zero_and_enable_is_idempotent_even_after_configuration() {
    let lua = Lua::new();
    // SAFETY: the protected call owns a live VM and the invalid scope is rejected.
    let configured: bool = unsafe {
        lua.exec_raw((), |state| {
            let configured = raw::luax_setluauoptions_scoped(state.cast(), 1, -1);
            ffi::lua_pushboolean(state, i32::from(configured));
        })
    }
    .expect("an invalid configuration is harmless");
    assert!(!configured);
    enable_metrics(&lua).expect("a failed configuration does not prevent metrics activation");
    let initial = snapshot(&lua);
    assert!(counters(&initial).into_iter().all(|value| value == 0));
    assert_eq!(initial.codegenReservedBytes, 0);
    assert_eq!(initial.codegenPeakReservedBytes, 0);
    assert_eq!(initial.codegenLiveReservationCount, 0);
    assert_eq!(initial.codegenPeakReservationCount, 0);
    assert_eq!(initial.lastNativeCompileResult, -1);
    assert_eq!(initial.nativeCodegenAvailable, u32::from(supported()));
    #[cfg(target_os = "linux")]
    {
        assert_eq!(initial.elapsedClockAvailable, 1);
        assert_eq!(initial.threadCpuClockAvailable, 1);
    }
    enable_metrics(&lua).expect("activation is idempotent");
    assert_snapshot_equal(&initial, &snapshot(&lua));

    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    Loader::C
        .load(&lua, "return 42", c"@metrics.luau")
        .expect("the measured chunk loads");
    let configured = snapshot(&lua);
    enable_metrics(&lua).expect("already-enabled metrics remain enabled after configuration");
    assert_snapshot_equal(&configured, &snapshot(&lua));
}

#[test]
fn metrics_count_bridge_work_and_syntax_errors_but_not_mlua_bytecode_work() {
    let lua = Lua::new();
    enable_metrics(&lua).expect("metrics activate before configuration");
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    let initial = snapshot(&lua);
    let source = "local total = 0; for index = 1, 100 do total += index end; return total";
    let function = Loader::C
        .load(&lua, source, c"@measured.luau")
        .expect("the chunk loads");
    assert_eq!(function.call::<i64>(()).expect("the chunk executes"), 5050);
    let loaded = snapshot(&lua);
    assert_eq!(loaded.bytecodeCompileCalls, 1);
    assert_eq!(loaded.bytecodeCompileInputBytes, source.len() as u64);
    assert!(loaded.bytecodeCompileOutputBytes > 0);
    assert_eq!(loaded.bytecodeLoadCalls, 1);
    assert_eq!(
        loaded.bytecodeLoadInputBytes,
        loaded.bytecodeCompileOutputBytes
    );
    assert_eq!(loaded.nativeCompileCalls, 0);
    assert_eq!(loaded.lastNativeCompileResult, -1);
    assert_monotonic(&initial, &loaded);
    assert_times_advance(&loaded);

    let rust_loaded = Loader::Mlua
        .load(&lua, source, c"@rust-loaded.luau")
        .expect("mlua loads");
    compile(&lua, &rust_loaded).expect("interpreter compilation is harmless");
    assert_eq!(rust_loaded.call::<i64>(()).expect("mlua executes"), 5050);
    assert_snapshot_equal(&loaded, &snapshot(&lua));

    let invalid = "local =";
    Loader::C
        .load(&lua, invalid, c"@invalid.luau")
        .expect_err("syntax errors are reported");
    let failed = snapshot(&lua);
    assert_eq!(failed.bytecodeCompileCalls, 2);
    assert_eq!(
        failed.bytecodeCompileInputBytes,
        (source.len() + invalid.len()) as u64
    );
    assert_eq!(failed.bytecodeLoadCalls, 2);
    assert_eq!(failed.nativeCompileCalls, 0);
    assert_eq!(failed.lastNativeCompileResult, -1);
    assert_monotonic(&loaded, &failed);
    let recovered = Loader::C
        .load(&lua, "return 7", c"@recovered.luau")
        .expect("loading recovers");
    assert_eq!(recovered.call::<i64>(()).expect("execution recovers"), 7);
    assert_eq!(snapshot(&lua).bytecodeCompileCalls, 3);
}

#[test]
fn native_metrics_distinguish_skipped_work_emission_and_live_reservations() {
    let lua = Lua::new();
    enable_metrics(&lua).expect("metrics activate before configuration");
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure_mode(&lua, ExecutionMode::NativeMarked);
    let initial = snapshot(&lua);
    for loader in [Loader::C, Loader::Mlua] {
        let function = loader
            .load(&lua, PROBE_SOURCE, c"@unmarked.luau")
            .expect("the chunk loads");
        compile(&lua, &function).expect("an unmarked native request is not an error");
        assert_eq!(probe_execution(&lua, &function), (false, 5050));
    }
    let skipped = snapshot(&lua);
    assert_eq!(skipped.nativeCompileCalls, if supported() { 3 } else { 0 });
    assert_eq!(skipped.nativeFunctionsCompiled, 0);
    assert_eq!(skipped.nativeFunctionsBound, 0);
    assert_eq!(skipped.nativeCodeBytes, 0);
    assert_eq!(skipped.nativeCompileResultErrors, 0);
    assert_eq!(skipped.nativeCompileFailures, 0);
    assert_eq!(
        skipped.lastNativeCompileResult,
        if supported() { 2 } else { -1 }
    );
    assert_monotonic(&initial, &skipped);

    let source = format!("--!native\n{PROBE_SOURCE}");
    let function = Loader::C
        .load(&lua, &source, c"@native.luau")
        .expect("the native chunk loads");
    assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
    let emitted = snapshot(&lua);
    assert_eq!(
        emitted.nativeCompileCalls,
        skipped.nativeCompileCalls + u64::from(supported())
    );
    assert_eq!(emitted.nativeCompileResultErrors, 0);
    assert_eq!(emitted.nativeCompileFailures, 0);
    if supported() {
        assert!(emitted.nativeFunctionsTotal > 0);
        assert!(emitted.nativeFunctionsCompiled > 0);
        assert!(emitted.nativeFunctionsBound > 0);
        assert!(emitted.nativeFunctionsCompiled <= emitted.nativeFunctionsTotal);
        assert!(emitted.nativeBytecodeBytes > 0);
        assert!(emitted.nativeCodeBytes > 0);
        assert!(emitted.nativeMetadataBytes > 0);
        assert!(emitted.codegenReservedBytes > 0);
        assert!(emitted.codegenReservationBytes >= emitted.codegenReservedBytes);
        assert!(emitted.codegenLiveReservationCount > 0);
        assert!(emitted.codegenReservationCount >= emitted.codegenLiveReservationCount);
        assert_eq!(emitted.lastNativeCompileResult, 0);
    }
    assert_monotonic(&skipped, &emitted);
    assert_snapshot_equal(&emitted, &snapshot(&lua));
    enable_metrics(&lua).expect("re-enabling does not reset gauges or cumulative counters");
    assert_snapshot_equal(&emitted, &snapshot(&lua));

    compile(&lua, &function).expect("recompilation is harmless");
    let repeated = snapshot(&lua);
    assert_eq!(
        repeated.nativeCompileCalls,
        emitted.nativeCompileCalls + u64::from(supported())
    );
    assert_eq!(repeated.nativeCodeBytes, emitted.nativeCodeBytes);
    assert_eq!(
        repeated.nativeFunctionsCompiled,
        emitted.nativeFunctionsCompiled
    );
    assert_eq!(repeated.codegenReservedBytes, emitted.codegenReservedBytes);
    assert_eq!(repeated.nativeCompileResultErrors, 0);
    assert_eq!(
        repeated.lastNativeCompileResult,
        if supported() { 1 } else { -1 }
    );

    let rust_loaded = Loader::Mlua
        .load(&lua, &source, c"@rust-native.luau")
        .expect("mlua loads");
    let before_mlua_compile = snapshot(&lua);
    assert_snapshot_equal(&repeated, &before_mlua_compile);
    compile(&lua, &rust_loaded).expect("explicit mlua native compilation is measured");
    assert_eq!(probe_execution(&lua, &rust_loaded), (supported(), 5050));
    let rust_compiled = snapshot(&lua);
    assert_eq!(
        rust_compiled.bytecodeCompileCalls,
        repeated.bytecodeCompileCalls
    );
    assert_eq!(rust_compiled.bytecodeLoadCalls, repeated.bytecodeLoadCalls);
    assert_eq!(
        rust_compiled.nativeCompileCalls,
        repeated.nativeCompileCalls + u64::from(supported())
    );
    if supported() {
        assert!(rust_compiled.nativeCodeBytes > repeated.nativeCodeBytes);
    }
    compile(&lua, &probe(&lua)).expect("C functions do not enter CodeGen");
    assert_snapshot_equal(&rust_compiled, &snapshot(&lua));

    let failing = Loader::C
        .load(
            &lua,
            "--!native\nreturn function() error('metrics sentinel') end",
            c"@runtime-error.luau",
        )
        .expect("the runtime error fixture compiles");
    let failing_function: Function = failing.call(()).expect("the error function is returned");
    let before_error = snapshot(&lua);
    failing_function
        .call::<()>(())
        .expect_err("the function raises a runtime error");
    assert_snapshot_equal(&before_error, &snapshot(&lua));
    assert_eq!(before_error.nativeCompileResultErrors, 0);
    assert_eq!(before_error.nativeCompileFailures, 0);
}

#[test]
fn metrics_survive_reload_and_gc_and_are_shared_only_by_coroutines() {
    let lua = Lua::new();
    let other = Lua::new();
    enable_metrics(&lua).expect("metrics activate before configuration");
    configure(&lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure_mode(&lua, ExecutionMode::Native);
    let callback = lua
        .create_function(|lua, ()| {
            let function = Loader::C.load(lua, PROBE_SOURCE, c"@coroutine.luau")?;
            assert_eq!(probe_execution(lua, &function), (supported(), 5050));
            Ok(())
        })
        .expect("the coroutine callback is created");
    let thread = lua
        .create_thread(callback)
        .expect("the coroutine is created");
    thread.resume::<()>(()).expect("the coroutine executes");
    let first = snapshot(&lua);
    assert_eq!(first.bytecodeCompileCalls, 1);
    assert!(
        metrics(&other)
            .expect("the other VM has no metrics")
            .is_none()
    );
    enable_metrics(&other).expect("another VM activates independently");
    assert_eq!(snapshot(&other).bytecodeCompileCalls, 0);

    lua.gc_collect().expect("garbage collection succeeds");
    let collected = snapshot(&lua);
    assert_monotonic(&first, &collected);
    assert_eq!(collected.nativeCodeBytes, first.nativeCodeBytes);
    assert_eq!(
        collected.nativeFunctionsCompiled,
        first.nativeFunctionsCompiled
    );
    assert!(collected.codegenReservedBytes <= first.codegenReservedBytes);
    assert!(collected.codegenLiveReservationCount <= first.codegenLiveReservationCount);
    assert!(collected.codegenPeakReservedBytes >= first.codegenPeakReservedBytes);
    assert!(collected.codegenPeakReservationCount >= first.codegenPeakReservationCount);
    for _ in 0..2 {
        lua.gc_collect()
            .expect("previous reload functions are collected");
        let before_reload = snapshot(&lua);
        let function = Loader::C
            .load(&lua, PROBE_SOURCE, c"@reload.luau")
            .expect("the source reloads");
        let reloaded = snapshot(&lua);
        assert_eq!(
            reloaded.bytecodeCompileCalls,
            before_reload.bytecodeCompileCalls + 1
        );
        assert_eq!(
            reloaded.bytecodeLoadCalls,
            before_reload.bytecodeLoadCalls + 1
        );
        if supported() {
            assert!(reloaded.nativeCodeBytes > before_reload.nativeCodeBytes);
            assert!(reloaded.nativeFunctionsCompiled > before_reload.nativeFunctionsCompiled);
            assert!(reloaded.codegenReservedBytes > 0);
        }
        lua.gc_collect()
            .expect("collection with live native functions succeeds");
        assert_eq!(probe_execution(&lua, &function), (supported(), 5050));
        let live = snapshot(&lua);
        assert_eq!(live.codegenReservedBytes, reloaded.codegenReservedBytes);
        assert_eq!(
            live.codegenLiveReservationCount,
            reloaded.codegenLiveReservationCount
        );
        assert_monotonic(&before_reload, &live);
    }
    assert_eq!(snapshot(&other).bytecodeCompileCalls, 0);
}

#[derive(Clone, Copy)]
enum Loader {
    C,
    Mlua,
}

impl Loader {
    fn load(self, lua: &Lua, source: &str, name: &CStr) -> mlua::Result<Function> {
        match self {
            Self::C => {
                // SAFETY: source and name outlive the protected call. It catches lua_error before Rust unwinds and restores the stack.
                unsafe {
                    lua.exec_raw((), |state| {
                        let status = raw::luax_loadbufferx(
                            state.cast(),
                            source.as_ptr().cast(),
                            source.len(),
                            name.as_ptr(),
                            std::ptr::null(),
                        );
                        if status != ffi::LUA_OK {
                            ffi::lua_error(state);
                        }
                    })
                }
            }
            Self::Mlua => lua
                .load(source)
                .set_name(name.to_str().expect("fixture names are UTF-8"))
                .into_function(),
        }
    }
}

fn configure_mode(lua: &Lua, mode: ExecutionMode) {
    let before = c_settings(lua);
    let configured = configure(lua, mode);
    if !is_native(mode) || supported() {
        configured.expect("the execution mode is supported");
    } else {
        let error = configured.expect_err("unsupported native execution is rejected");
        assert!(
            error
                .to_string()
                .contains("native compilation is not supported"),
            "{error}"
        );
        assert_eq!(c_settings(lua), before);
    }
}

fn is_native(mode: ExecutionMode) -> bool {
    matches!(
        mode,
        ExecutionMode::Native | ExecutionMode::NativeMarked | ExecutionMode::Tiered
    )
}

fn c_settings(lua: &Lua) -> (i32, bool) {
    (
        lua.named_registry_value("lovr.luau.optimization")
            .expect("the optimization setting exists"),
        lua.named_registry_value("lovr.luau.native")
            .expect("the native setting exists"),
    )
}

fn inlining_upvalues(lua: &Lua, loader: Loader) -> u8 {
    let chunk = loader.load(
        lua,
        "local function square(value: number): number return value * value end; return function(value: number): number return square(value) end",
        c"@inlining.luau",
    ).expect("the inlining fixture loads");
    let function: Function = chunk
        .call(())
        .expect("the inlining fixture returns a function");
    function.info().num_upvalues
}

fn assert_probe(lua: &Lua, loader: Loader, marked: bool, native: bool) {
    let source = if marked {
        format!("--!native\n{PROBE_SOURCE}")
    } else {
        PROBE_SOURCE.to_owned()
    };
    let function = loader
        .load(lua, &source, c"@probe.luau")
        .expect("the probe loads");
    compile(lua, &function).expect("the probe compiles");
    assert_eq!(
        probe_execution(lua, &function),
        (native && supported(), 5050)
    );
}

fn probe_execution(lua: &Lua, function: &Function) -> (bool, i64) {
    function
        .call((probe(lua), 100))
        .expect("the execution probe returns")
}

fn probe(lua: &Lua) -> Function {
    // SAFETY: the callback follows the Lua C ABI and only inspects its live Lua caller.
    unsafe { lua.create_c_function(native_probe) }.expect("the native probe is created")
}

unsafe extern "C-unwind" fn native_probe(state: *mut ffi::lua_State) -> i32 {
    // SAFETY: Lua invokes the callback with a live state and its caller at level 1.
    unsafe {
        ffi::lua_pushboolean(state, ffi::lua_incustomexecution(state, 1));
    }
    1
}

fn snapshot(lua: &Lua) -> LuauMetrics {
    metrics(lua)
        .expect("the metrics query succeeds")
        .expect("metrics are enabled")
}

fn counters(metrics: &LuauMetrics) -> [u64; 31] {
    [
        metrics.bytecodeCompileCalls,
        metrics.bytecodeCompileInputBytes,
        metrics.bytecodeCompileOutputBytes,
        metrics.bytecodeCompileElapsedNs,
        metrics.bytecodeCompileCpuNs,
        metrics.bytecodeLoadCalls,
        metrics.bytecodeLoadInputBytes,
        metrics.bytecodeLoadElapsedNs,
        metrics.bytecodeLoadCpuNs,
        metrics.nativeCompileCalls,
        metrics.nativeFunctionsTotal,
        metrics.nativeFunctionsCompiled,
        metrics.nativeFunctionsBound,
        metrics.nativeBytecodeBytes,
        metrics.nativeCodeBytes,
        metrics.nativeDataBytes,
        metrics.nativeMetadataBytes,
        metrics.nativeCompileResultErrors,
        metrics.nativeCompileFailures,
        metrics.nativeCompileElapsedNs,
        metrics.nativeCompileCpuNs,
        metrics.hotPromotionCalls,
        metrics.hotFunctionsPromoted,
        metrics.hotPromotionElapsedNs,
        metrics.hotPromotionCpuNs,
        metrics.hotBindElapsedNs,
        metrics.hotBindCpuNs,
        metrics.codegenReservationBytes,
        metrics.codegenReservationCount,
        metrics.codegenPeakReservedBytes,
        metrics.codegenPeakReservationCount,
    ]
}

fn assert_monotonic(before: &LuauMetrics, after: &LuauMetrics) {
    for (before, after) in counters(before).into_iter().zip(counters(after)) {
        assert!(
            after >= before,
            "the cumulative counter decreases: {before} -> {after}"
        );
    }
    assert!(after.codegenReservedBytes <= after.codegenPeakReservedBytes);
    assert!(after.codegenLiveReservationCount <= after.codegenPeakReservationCount);
}

fn assert_snapshot_equal(before: &LuauMetrics, after: &LuauMetrics) {
    assert_eq!(counters(before), counters(after));
    assert_eq!(before.codegenReservedBytes, after.codegenReservedBytes);
    assert_eq!(
        before.codegenLiveReservationCount,
        after.codegenLiveReservationCount
    );
    assert_eq!(
        before.lastNativeCompileResult,
        after.lastNativeCompileResult
    );
    assert_eq!(before.elapsedClockAvailable, after.elapsedClockAvailable);
    assert_eq!(
        before.threadCpuClockAvailable,
        after.threadCpuClockAvailable
    );
    assert_eq!(before.nativeCodegenAvailable, after.nativeCodegenAvailable);
}

fn assert_times_advance(metrics: &LuauMetrics) {
    if metrics.elapsedClockAvailable != 0 {
        assert!(metrics.bytecodeCompileElapsedNs > 0);
        assert!(metrics.bytecodeLoadElapsedNs > 0);
    }
    if metrics.threadCpuClockAvailable != 0 {
        assert!(metrics.bytecodeCompileCpuNs > 0);
        assert!(metrics.bytecodeLoadCpuNs > 0);
    }
}

/// Returns a VM in tiered execution with the given threshold, or `None` when native compilation is unsupported.
fn tiered(threshold: u32) -> Option<Lua> {
    let lua = Lua::new();
    configure_tiered(&lua, threshold).then_some(lua)
}

fn configure_tiered(lua: &Lua, threshold: u32) -> bool {
    configure(lua, ExecutionMode::Interpreter).expect("interpreter execution is supported");
    configure_mode(lua, ExecutionMode::Tiered);
    if !supported() {
        return false;
    }
    set_tier_up(
        lua,
        TierUp {
            threshold: NonZeroU32::new(threshold).expect("the threshold is nonzero"),
            queue_capacity: NonZeroU32::new(8).expect("the capacity is nonzero"),
        },
    )
    .expect("tier-up parameters are accepted");
    true
}

// The chunk is loaded after the parameters apply, so its own entry counts too. Draining a chunk that queued itself keeps the queue to the
// functions under test, which is unambiguous only while nothing else waits.
fn returned(lua: &Lua, loader: Loader, source: &str) -> Function {
    let chunk = loader
        .load(lua, source, c"@tier-up.luau")
        .expect("the fixture loads");
    let before = hot_queue_len(lua).expect("the queue is readable");
    let function = chunk.call(()).expect("the fixture returns a function");
    if hot_queue_len(lua).expect("the queue is readable") > before {
        assert_eq!(
            before, 0,
            "a queued chunk is drained only from an empty queue"
        );
        promote(lua, InstructionBudget(usize::MAX)).expect("the chunk promotes");
    }
    function
}

fn call_probe(lua: &Lua, function: &Function) -> bool {
    function.call(probe(lua)).expect("the probe returns")
}
