//! Reports the bridge's cumulative compiler counters and CodeGen reservation gauges.

use lunette::execution;
use mlua::Lua;
use serde_json::{Value, json};

pub fn snapshot(lua: &Lua) -> mlua::Result<Value> {
    let stats = execution::metrics(lua)?
        .ok_or_else(|| mlua::Error::runtime("desktop benchmark: compiler metrics are disabled"))?;
    if stats.elapsedClockAvailable == 0 || stats.threadCpuClockAvailable == 0 {
        return Err(mlua::Error::runtime(
            "desktop benchmark: compiler clocks are unavailable",
        ));
    }
    Ok(json!({
        "bytecode_compile_calls": stats.bytecodeCompileCalls,
        "bytecode_compile_input_bytes": stats.bytecodeCompileInputBytes,
        "bytecode_compile_output_bytes": stats.bytecodeCompileOutputBytes,
        "bytecode_compile_elapsed_ns": stats.bytecodeCompileElapsedNs,
        "bytecode_compile_cpu_ns": stats.bytecodeCompileCpuNs,
        "bytecode_load_calls": stats.bytecodeLoadCalls,
        "bytecode_load_input_bytes": stats.bytecodeLoadInputBytes,
        "bytecode_load_elapsed_ns": stats.bytecodeLoadElapsedNs,
        "bytecode_load_cpu_ns": stats.bytecodeLoadCpuNs,
        "native_compile_calls": stats.nativeCompileCalls,
        "native_functions_total": stats.nativeFunctionsTotal,
        "native_functions_compiled": stats.nativeFunctionsCompiled,
        "native_functions_bound": stats.nativeFunctionsBound,
        "native_bytecode_bytes": stats.nativeBytecodeBytes,
        "native_code_bytes": stats.nativeCodeBytes,
        "native_data_bytes": stats.nativeDataBytes,
        "native_metadata_bytes": stats.nativeMetadataBytes,
        "native_compile_result_errors": stats.nativeCompileResultErrors,
        "native_compile_failures": stats.nativeCompileFailures,
        "native_compile_elapsed_ns": stats.nativeCompileElapsedNs,
        "native_compile_cpu_ns": stats.nativeCompileCpuNs,
        "hot_promotion_calls": stats.hotPromotionCalls,
        "hot_functions_promoted": stats.hotFunctionsPromoted,
        "hot_promotion_elapsed_ns": stats.hotPromotionElapsedNs,
        "hot_promotion_cpu_ns": stats.hotPromotionCpuNs,
        "codegen_reserved_bytes": stats.codegenReservedBytes,
        "codegen_peak_reserved_bytes": stats.codegenPeakReservedBytes,
        "codegen_reservation_bytes": stats.codegenReservationBytes,
        "codegen_reservation_count": stats.codegenReservationCount,
        "codegen_live_reservation_count": stats.codegenLiveReservationCount,
        "codegen_peak_reservation_count": stats.codegenPeakReservationCount,
        "last_native_compile_result": stats.lastNativeCompileResult,
        "elapsed_clock_available": stats.elapsedClockAvailable,
        "thread_cpu_clock_available": stats.threadCpuClockAvailable,
        "native_codegen_available": stats.nativeCodegenAvailable,
    }))
}

/// Computes cumulative work only; current and peak reservation gauges remain in snapshots.
pub fn difference(before: &Value, after: &Value) -> mlua::Result<Value> {
    let mut delta = serde_json::Map::new();
    for key in [
        "bytecode_compile_calls",
        "bytecode_compile_input_bytes",
        "bytecode_compile_output_bytes",
        "bytecode_compile_elapsed_ns",
        "bytecode_compile_cpu_ns",
        "bytecode_load_calls",
        "bytecode_load_input_bytes",
        "bytecode_load_elapsed_ns",
        "bytecode_load_cpu_ns",
        "native_compile_calls",
        "native_functions_total",
        "native_functions_compiled",
        "native_functions_bound",
        "native_bytecode_bytes",
        "native_code_bytes",
        "native_data_bytes",
        "native_metadata_bytes",
        "native_compile_result_errors",
        "native_compile_failures",
        "native_compile_elapsed_ns",
        "native_compile_cpu_ns",
        "hot_promotion_calls",
        "hot_functions_promoted",
        "hot_promotion_elapsed_ns",
        "hot_promotion_cpu_ns",
        "codegen_reservation_bytes",
        "codegen_reservation_count",
    ] {
        let read = |value: &Value| {
            value.get(key).and_then(Value::as_u64).ok_or_else(|| {
                mlua::Error::runtime(format!("desktop benchmark: missing compiler counter {key}"))
            })
        };
        let value = read(after)?.checked_sub(read(before)?).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "desktop benchmark: compiler counter {key} regressed"
            ))
        })?;
        delta.insert(key.to_owned(), json!(value));
    }
    Ok(Value::Object(delta))
}
