//! Measures production desktop callbacks with deterministic windows and recorded graphics.

#[path = "../tests/lua/state.rs"]
mod state;

use std::{error::Error, ffi::c_int, path::Path, process::ExitCode, time::Instant};

use clap::{Parser, ValueEnum};
use lunette::execution::{self, ExecutionMode};
use mlua::{Function, Lua, ObjectLike, Table, ffi};
use serde_json::{Value, json};

#[derive(Parser)]
#[command(
    about = "Compare Luau O1, O2, and supported O2 native execution without a display or headset"
)]
struct Arguments {
    #[arg(long, default_value = "7", value_parser = clap::value_parser!(u32).range(1..))]
    rounds: u32,
    #[arg(long, default_value = "600", value_parser = clap::value_parser!(u32).range(1..))]
    frames: u32,
    #[arg(long, default_value = "120", value_parser = clap::value_parser!(u32).range(1..))]
    warmup: u32,
    #[arg(long, default_value = "20000", value_parser = clap::value_parser!(u32).range(2..))]
    micro_iterations: u32,
    /// Restrict measurement to one execution mode for profiling.
    #[arg(long, value_enum)]
    mode: Option<Mode>,
    /// Validate the scene and compiler modes without collecting performance results.
    #[arg(long)]
    smoke: bool,
    // Cargo passes this flag to custom benchmark harnesses.
    #[arg(long, hide = true)]
    bench: bool,
}

#[derive(Clone, Copy, Eq, PartialEq, ValueEnum)]
enum Mode {
    #[value(name = "o1-interpreter")]
    O1,
    #[value(name = "o2-interpreter")]
    O2,
    #[value(name = "o2-native")]
    Native,
}

impl Mode {
    fn execution(self) -> ExecutionMode {
        match self {
            Self::O1 => ExecutionMode::Interpreter,
            Self::O2 => ExecutionMode::Optimized,
            Self::Native => ExecutionMode::Native,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::O1 => "o1-interpreter",
            Self::O2 => "o2-interpreter",
            Self::Native => "o2-native",
        }
    }
}

struct Measurement {
    round: u32,
    mode: Mode,
    setup_ms: f64,
    frame_mean_us: f64,
    frame_p95_us: f64,
    update_mean_us: f64,
    draw_mean_us: f64,
    micro_us: f64,
    checksum: f64,
    lua_bytes: usize,
    panels: u32,
    windows: u32,
    frame_native: (bool, bool, bool),
    micro_native: (bool, bool, bool),
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();
    match run(Arguments::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            tracing::error!(%error, "desktop benchmark failed");
            ExitCode::FAILURE
        }
    }
}

fn run(mut arguments: Arguments) -> Result<(), Box<dyn Error>> {
    if arguments.smoke {
        arguments.rounds = 1;
        arguments.frames = 3;
        arguments.warmup = 2;
        arguments.micro_iterations = 20;
    }
    if cfg!(debug_assertions) && !arguments.smoke {
        return Err("desktop benchmark: performance measurements require cargo bench; use --smoke for validation".into());
    }
    if arguments.warmup.checked_add(arguments.frames).is_none() {
        return Err("desktop benchmark: warmup plus frames exceeds the frame index range".into());
    }
    let (mut modes, native_codegen) = available_modes()?;
    if let Some(mode) = arguments.mode {
        if !modes.contains(&mode) {
            return Err(format!(
                "desktop benchmark: {} is not supported by this build or CPU",
                mode.name()
            )
            .into());
        }
        modes.retain(|candidate| *candidate == mode);
    }
    let mut measurements = Vec::new();
    for round in 0..arguments.rounds {
        for mode in round_modes(&modes, round) {
            let measured = measure(mode, round + 1, &arguments)?;
            if let Some(first) = measurements.first() {
                equivalent(first, &measured)?;
            }
            tracing::info!(
                round = round + 1,
                mode = mode.name(),
                frame_native = ?measured.frame_native,
                micro_native = ?measured.micro_native,
                frame_us = measured.frame_mean_us,
                "sample complete"
            );
            measurements.push(measured);
        }
    }
    let samples: Vec<Value> = measurements
        .iter()
        .map(|sample| {
            json!({
                "round": sample.round,
                "mode": sample.mode.name(),
                "setup_ms": sample.setup_ms,
                "frame_mean_us": sample.frame_mean_us,
                "frame_p95_us": sample.frame_p95_us,
                "update_mean_us": sample.update_mean_us,
                "draw_mean_us": sample.draw_mean_us,
                "micro_us_per_iteration": sample.micro_us,
                "micro_checksum": sample.checksum,
                "lua_bytes": sample.lua_bytes,
                "panels": sample.panels,
                "windows": sample.windows,
                "native_execution": {
                    "frame_entry": sample.frame_native.0,
                    "frame_after_draw": sample.frame_native.1,
                    "frame_after_assert": sample.frame_native.2,
                    "micro_entry": sample.micro_native.0,
                    "micro_after_geometry": sample.micro_native.1,
                    "micro_after_assert": sample.micro_native.2,
                },
            })
        })
        .collect();
    let summaries: Vec<Value> = modes
        .iter()
        .map(|mode| {
            let samples: Vec<_> = measurements.iter().filter(|s| s.mode == *mode).collect();
            json!({
                "mode": mode.name(),
                "frame_mean_us_median": median(samples.iter().map(|s| s.frame_mean_us).collect()),
                "frame_p95_us_median": median(samples.iter().map(|s| s.frame_p95_us).collect()),
                "update_mean_us_median": median(samples.iter().map(|s| s.update_mean_us).collect()),
                "draw_mean_us_median": median(samples.iter().map(|s| s.draw_mean_us).collect()),
                "micro_us_per_iteration_median": median(samples.iter().map(|s| s.micro_us).collect()),
                "setup_ms_median": median(samples.iter().map(|s| s.setup_ms).collect()),
            })
        })
        .collect();
    let comparisons: Vec<Value> = modes
        .windows(2)
        .map(|pair| {
            Ok(json!({
                "baseline": pair[0].name(),
                "candidate": pair[1].name(),
                "paired_reduction_percent": paired_reductions(&measurements, pair[0], pair[1])?,
            }))
        })
        .collect::<Result<_, Box<dyn Error>>>()?;
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "schema": 2,
            "smoke": arguments.smoke,
            "workload": "all-panels-recorded-graphics",
            "native_codegen": native_codegen,
            "native_execution_verification": "untimed lua_incustomexecution caller-frame checks at entry, after the initial assert, after draw, and after geometry; the compiled probe and post-assert workload probes must match the requested mode; later workload instructions and callees may fall back to the interpreter",
            "sample_order": "rotating modes with each following round reversed",
            "architecture": std::env::consts::ARCH,
            "os": std::env::consts::OS,
            "debug_assertions": cfg!(debug_assertions),
            "rounds": arguments.rounds,
            "frames": arguments.frames,
            "warmup": arguments.warmup,
            "micro_iterations": arguments.micro_iterations,
            "summaries": summaries,
            "comparisons": comparisons,
            "samples": samples,
        }))?
    );
    Ok(())
}

fn available_modes() -> Result<(Vec<Mode>, Value), Box<dyn Error>> {
    if execution::supported() {
        return Ok((
            vec![Mode::O1, Mode::O2, Mode::Native],
            json!({ "available": true, "reason": null }),
        ));
    }
    let lua = Lua::new();
    let reason = match execution::configure(&lua, ExecutionMode::Native) {
        Err(error) => error.to_string(),
        Ok(()) => {
            return Err(
                "desktop benchmark: native configuration succeeds despite a negative support query"
                    .into(),
            );
        }
    };
    tracing::info!(%reason, "native comparison unavailable");
    Ok((
        vec![Mode::O1, Mode::O2],
        json!({ "available": false, "reason": reason }),
    ))
}

fn round_modes(modes: &[Mode], round: u32) -> Vec<Mode> {
    let mut order = modes.to_vec();
    // Each pair reverses the same rotation; three modes visit all six permutations in six rounds.
    order.rotate_left((round as usize / 2) % modes.len());
    if round % 2 == 1 {
        order.reverse();
    }
    order
}

fn measure(mode: Mode, round: u32, arguments: &Arguments) -> Result<Measurement, Box<dyn Error>> {
    let roots = state::Roots::of_repository(Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."));
    let started = Instant::now();
    let lua = state::new(&roots)?;
    let mut workload: Option<Table> = None;
    let result = (|| {
        // Only the loader wrapper is installed before this point; every scene module uses this mode.
        execution::configure(&lua, mode.execution())?;
        state::use_configuration(&lua, Path::new(env!("CARGO_MANIFEST_DIR")).join("benches"))?;
        let probe = native_probe(&lua, mode)?;
        compiler_regression(&lua)?;
        let require: Function = lua.globals().get("require")?;
        let module: Table = require.call("scene")?;
        let scene: Table = module.call_function("setup", ())?;
        workload = Some(scene.clone());
        let setup_ms = started.elapsed().as_secs_f64() * 1e3;
        tracing::debug!(mode = mode.name(), setup_ms, "scene ready");
        measure_workload(&lua, &scene, &probe, mode, setup_ms, arguments)
    })();
    let mut failures = Vec::new();
    if let Some(workload) = workload
        && let Err(error) = workload.call_function::<()>("close", ())
    {
        failures.push(format!("scene cleanup: {error}"));
    }
    failures.extend(state::shutdown(&lua));
    match result {
        Ok(mut sample) if failures.is_empty() => {
            sample.round = round;
            Ok(sample)
        }
        Ok(_) => Err(format!("desktop benchmark: {}", failures.join("\n")).into()),
        Err(error) if failures.is_empty() => Err(error),
        Err(error) => Err(format!(
            "{error}\ndesktop benchmark cleanup: {}",
            failures.join("\n")
        )
        .into()),
    }
}

fn native_probe(lua: &Lua, mode: Mode) -> mlua::Result<Function> {
    // SAFETY: The callback only inspects its live caller and returns one boolean on the same VM's stack.
    let probe = unsafe { lua.create_c_function(caller_is_native)? };
    let chunk = lua
        .load("return function(probe: () -> boolean): (boolean, number)\n  local total = 0\n  for index = 1, 100 do total += index end\n  return probe(), total\nend")
        .set_name("@benchmark-native-probe.luau")
        .into_function()?;
    execution::compile(lua, &chunk)?;
    let function: Function = chunk.call(())?;
    let (actual, total): (bool, u32) = function.call(&probe)?;
    if total != 5050 {
        return Err(mlua::Error::runtime(
            "desktop benchmark: compiled probe arithmetic differs",
        ));
    }
    verify_execution(mode, "compiled probe", actual)?;
    Ok(probe)
}

unsafe extern "C-unwind" fn caller_is_native(state: *mut ffi::lua_State) -> c_int {
    // SAFETY: Luau invokes this callback with a live state; level 1 is the calling Lua function.
    unsafe {
        ffi::lua_pushboolean(state, ffi::lua_incustomexecution(state, 1));
    }
    1
}

fn verify_execution(mode: Mode, function: &str, actual: bool) -> mlua::Result<()> {
    let expected = mode == Mode::Native;
    if actual != expected {
        return Err(mlua::Error::runtime(format!(
            "desktop benchmark: {} {function}: native execution is {actual}, expected {expected}",
            mode.name()
        )));
    }
    Ok(())
}

fn measure_workload(
    lua: &Lua,
    workload: &Table,
    probe: &Function,
    mode: Mode,
    setup_ms: f64,
    arguments: &Arguments,
) -> Result<Measurement, Box<dyn Error>> {
    let frame: Function = workload.get("frame")?;
    let micro: Function = workload.get("micro")?;
    let (_, _, frame_entry, frame_after_draw, frame_after_assert): (f64, f64, bool, bool, bool) =
        frame.call((1, probe))?;
    let (_, micro_entry, micro_after_geometry, micro_after_assert): (f64, bool, bool, bool) =
        micro.call((arguments.micro_iterations, probe))?;
    if mode != Mode::Native {
        for (function, actual) in [
            ("frame entry", frame_entry),
            ("frame after draw", frame_after_draw),
            ("frame after assert", frame_after_assert),
            ("micro entry", micro_entry),
            ("micro after geometry", micro_after_geometry),
            ("micro after assert", micro_after_assert),
        ] {
            verify_execution(mode, function, actual)?;
        }
    } else {
        for (function, actual) in [
            ("frame after assert", frame_after_assert),
            ("micro after assert", micro_after_assert),
        ] {
            verify_execution(mode, function, actual)?;
        }
    }
    for index in 1..=arguments.warmup {
        frame.call::<()>(index)?;
    }
    workload.call_function::<()>("validate", ())?;
    micro.call::<f64>(arguments.micro_iterations)?;
    let mut times = Vec::with_capacity(arguments.frames as usize);
    let (mut update_us, mut draw_us) = (0., 0.);
    for index in 1..=arguments.frames {
        let started = Instant::now();
        let (update, draw): (f64, f64) = frame.call(arguments.warmup + index)?;
        times.push(started.elapsed().as_secs_f64() * 1e6);
        update_us += update;
        draw_us += draw;
    }
    let started = Instant::now();
    let checksum: f64 = micro.call(arguments.micro_iterations)?;
    let micro_us = started.elapsed().as_secs_f64() * 1e6 / f64::from(arguments.micro_iterations);
    if !checksum.is_finite() {
        return Err("desktop benchmark: geometry checksum is not finite".into());
    }
    workload.call_function::<()>("validate", ())?;
    times.sort_by(f64::total_cmp);
    Ok(Measurement {
        round: 0,
        mode,
        setup_ms,
        frame_mean_us: times.iter().sum::<f64>() / f64::from(arguments.frames),
        frame_p95_us: times[(times.len() * 95).div_ceil(100).saturating_sub(1)],
        update_mean_us: update_us / f64::from(arguments.frames),
        draw_mean_us: draw_us / f64::from(arguments.frames),
        micro_us,
        checksum,
        lua_bytes: lua.used_memory(),
        panels: workload.get("panels")?,
        windows: workload.get("windows")?,
        frame_native: (frame_entry, frame_after_draw, frame_after_assert),
        micro_native: (micro_entry, micro_after_geometry, micro_after_assert),
    })
}

fn compiler_regression(lua: &Lua) -> mlua::Result<()> {
    let source = "local function fail()\n  error('benchmark location sentinel')\nend\nfail()";
    let function = lua
        .load(source)
        .set_name("@benchmark-location.luau")
        .into_function()?;
    execution::compile(lua, &function)?;
    match function.call::<()>(()) {
        Err(error) if error.to_string().contains("benchmark-location.luau:2") => Ok(()),
        result => Err(mlua::Error::runtime(format!(
            "benchmark: source location lost: {result:?}"
        ))),
    }
}

fn equivalent(first: &Measurement, next: &Measurement) -> Result<(), Box<dyn Error>> {
    if first.windows != next.windows || first.panels != next.panels {
        return Err("desktop benchmark: scene population differs between samples".into());
    }
    if !next.checksum.is_finite()
        || (first.checksum - next.checksum).abs() > 1e-8 * first.checksum.abs().max(1.)
    {
        return Err("desktop benchmark: geometry checksum differs between samples".into());
    }
    Ok(())
}

fn paired_reductions(
    measurements: &[Measurement],
    baseline: Mode,
    candidate: Mode,
) -> Result<Vec<Value>, Box<dyn Error>> {
    measurements
        .iter()
        .filter(|sample| sample.mode == baseline)
        .map(|base| {
            let next = measurements
                .iter()
                .find(|sample| sample.round == base.round && sample.mode == candidate)
                .ok_or("desktop benchmark: comparison is missing a sample from the same round")?;
            Ok(json!({
                "round": base.round,
                "frame": reduction(base.frame_mean_us, next.frame_mean_us),
                "update": reduction(base.update_mean_us, next.update_mean_us),
                "draw": reduction(base.draw_mean_us, next.draw_mean_us),
                "micro": reduction(base.micro_us, next.micro_us),
            }))
        })
        .collect()
}

fn reduction(baseline: f64, optimized: f64) -> f64 {
    (1. - optimized / baseline) * 100.
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    let middle = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) / 2.
    } else {
        values[middle]
    }
}
