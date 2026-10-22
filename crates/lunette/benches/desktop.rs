//! Linux-only: measures desktop callbacks with deterministic inputs and recorded or offscreen graphics.

mod compiler_metrics;
#[path = "../tests/graphics/owner.rs"]
mod owner;
mod profiling;
#[path = "../tests/lua/state.rs"]
mod state;

use std::{
    env,
    error::Error,
    ffi::c_int,
    fs,
    mem::MaybeUninit,
    num::NonZeroU32,
    path::{Path, PathBuf},
    process::{Command, ExitCode, Stdio},
    time::Instant,
};

use clap::{Parser, ValueEnum};
use lunette::execution::{self, ExecutionMode, InstructionBudget, TierUp};
use mlua::{Function, Lua, ObjectLike, Table, ffi};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Parser)]
#[command(
    about = "Compare Luau O1, O2, and supported O2 native and tiered execution without a display or headset"
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
    /// Source reloads within each sample's existing Lua state and graphics device.
    #[arg(long, default_value = "3", value_parser = clap::value_parser!(u32).range(1..))]
    reloads: u32,
    /// Timed validation frames after each reload; excluded from reload latency.
    #[arg(long, default_value = "30", value_parser = clap::value_parser!(u32).range(1..))]
    reload_frames: u32,
    /// Warmup frames after each reload; excluded from reload latency.
    #[arg(long, default_value = "10", value_parser = clap::value_parser!(u32).range(1..))]
    reload_warmup: u32,
    /// Restrict measurement to one execution mode for profiling.
    #[arg(long, value_enum, conflicts_with = "modes")]
    mode: Option<Mode>,
    /// Compare these execution modes instead of the default set.
    #[arg(long, value_enum, value_delimiter = ',')]
    modes: Vec<Mode>,
    /// Interpreted entries plus loop iterations before a tiered function waits for promotion.
    #[arg(long, default_value = "1000", value_parser = clap::value_parser!(u32).range(1..=i64::from(i32::MAX)))]
    tier_threshold: u32,
    /// Hot functions that can wait for promotion at once.
    #[arg(long, default_value = "256", value_parser = clap::value_parser!(u32).range(1..=i64::from(i32::MAX)))]
    tier_queue: u32,
    /// Bytecode instructions promoted between frames; at least one queued function promotes.
    #[arg(long, default_value = "1000")]
    tier_budget: usize,
    /// Collect Luau callback stacks instead of performance measurements or reloads.
    #[arg(long, requires = "mode")]
    profile_output: Option<PathBuf>,
    /// CPU-time sampling request rate for the Luau safepoint profiler.
    #[arg(long, default_value = "499", value_parser = clap::value_parser!(u32).range(1..=2000))]
    profile_hz: u32,
    /// Disable Luau sampling while collecting native perf stacks.
    #[arg(long, requires_all = ["profile_output", "profile_perf_control", "profile_perf_ack"])]
    profile_native_only: bool,
    /// Optional perf record control FIFO; used only during update and draw callbacks.
    #[arg(long, requires_all = ["profile_output", "profile_perf_ack", "profile_native_only"])]
    profile_perf_control: Option<PathBuf>,
    /// Optional perf record acknowledgement FIFO.
    #[arg(long, requires_all = ["profile_output", "profile_perf_control"])]
    profile_perf_ack: Option<PathBuf>,
    /// Render with real offscreen LÖVR graphics instead of the Lua graphics recorder.
    #[arg(long, value_enum, default_value = "recorded")]
    renderer: Renderer,
    /// Validate the scene and compiler modes without collecting performance results.
    #[arg(long)]
    smoke: bool,
    // Cargo passes this flag to custom benchmark harnesses.
    #[arg(long, hide = true)]
    bench: bool,
    // Each offscreen sample exits to reclaim externally closed mlua allocations and worker pools.
    #[arg(long, hide = true, requires = "mode")]
    sample_child: bool,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq, Serialize, ValueEnum)]
enum Mode {
    #[value(name = "o1-interpreter")]
    O1,
    #[value(name = "o2-interpreter")]
    O2,
    #[value(name = "o2-native")]
    Native,
    #[value(name = "o2-native-marked")]
    Marked,
    #[value(name = "o2-tiered")]
    Tiered,
    /// Tiered counting without promotion, which bounds the counters' interpreter overhead.
    #[value(name = "o2-counting")]
    Counting,
}

impl Mode {
    fn execution(self) -> ExecutionMode {
        match self {
            Self::O1 => ExecutionMode::Interpreter,
            Self::O2 => ExecutionMode::Optimized,
            Self::Native => ExecutionMode::Native,
            Self::Marked => ExecutionMode::NativeMarked,
            Self::Tiered | Self::Counting => ExecutionMode::Tiered,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::O1 => "o1-interpreter",
            Self::O2 => "o2-interpreter",
            Self::Native => "o2-native",
            Self::Marked => "o2-native-marked",
            Self::Tiered => "o2-tiered",
            Self::Counting => "o2-counting",
        }
    }

    /// Whether load-time compilation binds native code for the scene's modules.
    fn binds_at_load(self) -> bool {
        matches!(self, Self::Native | Self::Marked)
    }

    fn counts(self) -> bool {
        matches!(self, Self::Tiered | Self::Counting)
    }
}

/// The native compilation a span of compiler work must contain.
#[derive(Clone, Copy)]
enum NativeWork {
    /// No native compilation request.
    None,
    /// Marked-only requests that bind nothing, because no scene module carries a directive.
    Attempted,
    /// Bound native functions and emitted code.
    Bound,
}

impl NativeWork {
    fn of_scene(mode: Mode) -> Self {
        match mode {
            Mode::O1 | Mode::O2 => Self::None,
            Mode::Native | Mode::Marked | Mode::Tiered => Self::Bound,
            Mode::Counting => Self::Attempted,
        }
    }

    // A reload loads sources without running frames, so tiered modes have promoted nothing yet.
    fn of_reload(mode: Mode) -> Self {
        match mode {
            Mode::O1 | Mode::O2 => Self::None,
            Mode::Native | Mode::Marked => Self::Bound,
            Mode::Tiered | Mode::Counting => Self::Attempted,
        }
    }
}

#[derive(Clone, Copy, Eq, PartialEq, ValueEnum)]
enum Renderer {
    Recorded,
    Offscreen,
}

impl Renderer {
    fn name(self) -> &'static str {
        match self {
            Self::Recorded => "all-panels-recorded-graphics",
            Self::Offscreen => "all-panels-offscreen-graphics",
        }
    }
}

// The marker-only candidate covers frame dispatch, window panels, UI packing, and production picking.
const MARKED_MODULES: &[&str] = &[
    "@lunette-plugins/session/frame/init.luau",
    "@lunette-plugins/panels/service/private/panel.luau",
    "@lunette-plugins/panels/service/private/draw.luau",
    "@lunette-plugins/panels/service/private/shape.luau",
    "@lunette-plugins/interaction/picking.luau",
    "@lunette-plugins/ui/host/private/rendering/pack.luau",
];

type FrameResult = (
    f64,
    f64,
    Option<bool>,
    Option<bool>,
    Option<bool>,
    f64,
    f64,
    f64,
    f64,
    f64,
);

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Measurement {
    round: u32,
    mode: Mode,
    setup_ms: f64,
    frame_mean_us: f64,
    frame_p95_us: f64,
    update_mean_us: f64,
    draw_mean_us: f64,
    update_cpu_mean_us: f64,
    draw_cpu_mean_us: f64,
    submit_mean_us: f64,
    submit_cpu_mean_us: f64,
    wait_mean_us: f64,
    micro_us: f64,
    micro_cpu_us: f64,
    checksum: f64,
    lua_bytes: usize,
    panels: u32,
    windows: u32,
    rendering: Value,
    frame_native: (bool, bool, bool),
    micro_native: (bool, bool, bool),
    compiler_metrics: Value,
    compiler_before_scene: Value,
    compiler_scene_work: Value,
    compiler_after_initial_gc: Value,
    lua_bytes_after_initial_gc: usize,
    source_loads: Value,
    reloads: Vec<Value>,
    promotion_cpu_mean_us: f64,
    tier_up: Value,
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
    // LÖVR initialization can change the working directory; profile paths belong to the caller.
    let working_directory = std::env::current_dir()?;
    for path in [
        &mut arguments.profile_output,
        &mut arguments.profile_perf_control,
        &mut arguments.profile_perf_ack,
    ]
    .into_iter()
    .flatten()
    {
        if path.is_relative() {
            *path = working_directory.join(path.as_path());
        }
    }
    if arguments.smoke {
        arguments.rounds = 1;
        arguments.frames = 3;
        arguments.warmup = 2;
        arguments.micro_iterations = 20;
        arguments.reload_frames = 3;
        arguments.reload_warmup = 2;
    }
    if cfg!(debug_assertions) && !arguments.smoke {
        return Err("desktop benchmark: performance measurements require cargo bench; use --smoke for validation".into());
    }
    if arguments.profile_output.is_some() {
        if arguments.sample_child || arguments.rounds != 1 {
            return Err("desktop profile: use --rounds 1 without --sample-child".into());
        }
        if arguments.renderer == Renderer::Offscreen {
            validate_software_driver()?;
        }
        if arguments.warmup.checked_add(arguments.frames).is_none() {
            return Err("desktop profile: warmup plus frames exceeds the frame index range".into());
        }
        let mode = arguments.mode.ok_or("desktop profile: specify --mode")?;
        let sample = measure(mode, 1, &arguments)?;
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "profile_output": arguments.profile_output,
                "mode": mode.name(),
                "instrumented": true,
                "performance_comparison": false,
                "measurement": sample,
            }))?
        );
        return Ok(());
    }
    if arguments.warmup.checked_add(arguments.frames).is_none()
        || arguments
            .reload_warmup
            .checked_add(arguments.reload_frames)
            .is_none()
    {
        return Err("desktop benchmark: warmup plus frames exceeds the frame index range".into());
    }
    if arguments.renderer == Renderer::Offscreen {
        validate_software_driver()?;
    }
    if arguments.sample_child {
        let mode = arguments
            .mode
            .ok_or("desktop benchmark: child sample needs a mode")?;
        println!("{}", serde_json::to_string(&measure(mode, 1, &arguments)?)?);
        return Ok(());
    }
    let (mut modes, native_codegen) = available_modes()?;
    if !arguments.modes.is_empty() {
        if let Some(missing) = arguments.modes.iter().find(|mode| !modes.contains(mode)) {
            return Err(format!(
                "desktop benchmark: {} is not supported by this build or CPU",
                missing.name()
            )
            .into());
        }
        modes = arguments.modes.clone();
    } else {
        // Counting is an overhead diagnostic rather than a candidate, so it runs only on request.
        modes.retain(|mode| *mode != Mode::Counting);
    }
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
            let measured = if arguments.renderer == Renderer::Offscreen {
                measure_in_child(mode, round + 1, &arguments)?
            } else {
                measure(mode, round + 1, &arguments)?
            };
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
                "update_thread_cpu_mean_us": sample.update_cpu_mean_us,
                "draw_thread_cpu_mean_us": sample.draw_cpu_mean_us,
                "callback_thread_cpu_mean_us": sample.update_cpu_mean_us + sample.draw_cpu_mean_us,
                "promotion_thread_cpu_mean_us": sample.promotion_cpu_mean_us,
                "tier_up": sample.tier_up,
                "submit_mean_us": sample.submit_mean_us,
                "submit_thread_cpu_mean_us": sample.submit_cpu_mean_us,
                "wait_mean_us": sample.wait_mean_us,
                "micro_us_per_iteration": sample.micro_us,
                "micro_thread_cpu_us_per_iteration": sample.micro_cpu_us,
                "micro_checksum": sample.checksum,
                "lua_bytes": sample.lua_bytes,
                "panels": sample.panels,
                "windows": sample.windows,
                "rendering": sample.rendering,
                "compiler_metrics": sample.compiler_metrics,
                "compiler_before_scene": sample.compiler_before_scene,
                "compiler_scene_work": sample.compiler_scene_work,
                "compiler_after_initial_gc": sample.compiler_after_initial_gc,
                "lua_bytes_after_initial_gc": sample.lua_bytes_after_initial_gc,
                "source_loads": sample.source_loads,
                "reloads": sample.reloads,
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
                "callback_thread_cpu_mean_us_median": median(samples.iter().map(|s| s.update_cpu_mean_us + s.draw_cpu_mean_us).collect()),
                "callback_plus_promotion_thread_cpu_mean_us_median": median(samples.iter().map(|s| s.update_cpu_mean_us + s.draw_cpu_mean_us + s.promotion_cpu_mean_us).collect()),
                "promotion_thread_cpu_mean_us_median": median(samples.iter().map(|s| s.promotion_cpu_mean_us).collect()),
                "scene_native_compile_cpu_ms_median": median(samples.iter().map(|s| counter(&s.compiler_scene_work, "native_compile_cpu_ns") / 1e6).collect()),
                "scene_native_functions_bound_median": median(samples.iter().map(|s| counter(&s.compiler_scene_work, "native_functions_bound")).collect()),
                "scene_native_code_bytes_median": median(samples.iter().map(|s| counter(&s.compiler_scene_work, "native_code_bytes")).collect()),
                "codegen_reserved_bytes_after_initial_gc_median": median(samples.iter().map(|s| counter(&s.compiler_after_initial_gc, "codegen_reserved_bytes")).collect()),
                "codegen_reserved_bytes_after_reloads_median": median(samples.iter().map(|s| s.reloads.last().map_or(0., |reload| counter(&reload["compiler_after_gc"], "codegen_reserved_bytes"))).collect()),
                "update_thread_cpu_mean_us_median": median(samples.iter().map(|s| s.update_cpu_mean_us).collect()),
                "draw_thread_cpu_mean_us_median": median(samples.iter().map(|s| s.draw_cpu_mean_us).collect()),
                "submit_mean_us_median": median(samples.iter().map(|s| s.submit_mean_us).collect()),
                "submit_thread_cpu_mean_us_median": median(samples.iter().map(|s| s.submit_cpu_mean_us).collect()),
                "wait_mean_us_median": median(samples.iter().map(|s| s.wait_mean_us).collect()),
                "micro_us_per_iteration_median": median(samples.iter().map(|s| s.micro_us).collect()),
                "micro_thread_cpu_us_per_iteration_median": median(samples.iter().map(|s| s.micro_cpu_us).collect()),
                "setup_ms_median": median(samples.iter().map(|s| s.setup_ms).collect()),
            })
        })
        .collect();
    let comparisons: Vec<Value> = comparison_pairs(&modes)
        .into_iter()
        .map(|(baseline, candidate)| {
            Ok(json!({
                "baseline": baseline.name(),
                "candidate": candidate.name(),
                "paired_reduction_percent": paired_reductions(&measurements, baseline, candidate)?,
            }))
        })
        .collect::<Result<_, Box<dyn Error>>>()?;
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "schema": 13,
            "smoke": arguments.smoke,
            "workload": arguments.renderer.name(),
            "timing": "elapsed clocks include scheduling delays; thread CPU measures update/draw and submission separately, excluding driver worker threads, GPU execution, compositor imports, XR waits, and presentation",
            "native_codegen": native_codegen,
            "native_execution_verification": "untimed lua_incustomexecution caller-frame checks at entry, after the initial assert, after draw, and after geometry; all-native post-assert wrappers must be native, marker-only wrappers must stay interpreted, and tiered wrappers are recorded without an expectation; a raw callback verifies production picking is native in both load-time native modes before every initial/reload timing loop, and records tiered picking after warmup; later instructions and callees may fall back to the interpreter",
            "tier_up": {
                "threshold": arguments.tier_threshold,
                "queue_capacity": arguments.tier_queue,
                "instruction_budget_per_frame": arguments.tier_budget,
                "promotion": "between frames, after each warmup and timed frame; promotion thread CPU is measured outside the callbacks and reported separately",
            },
            "sample_order": "rotating modes with each following round reversed",
            "sample_isolation": if arguments.renderer == Renderer::Offscreen { "fresh child process per sample; inherited environment and CPU affinity; process startup excluded from setup timing" } else { "fresh Lua state per sample in one process" },
            "architecture": std::env::consts::ARCH,
            "os": std::env::consts::OS,
            "debug_assertions": cfg!(debug_assertions),
            "rounds": arguments.rounds,
            "frames": arguments.frames,
            "warmup": arguments.warmup,
            "micro_iterations": arguments.micro_iterations,
            "reloads_per_sample": arguments.reloads,
            "reload_validation_frames": arguments.reload_frames,
            "reload_validation_warmup": arguments.reload_warmup,
            "marked_modules": MARKED_MODULES,
            "reload_description": "same VM, graphics resources, client windows, and glyph atlas; production runtime shutdown and source-cache clearing; latency includes panel reopening, glyph readiness, and pixel readbacks; post-reload warmup/timing validation and full GC excluded",
            "compiler_metrics_description": "opt-in cumulative production compile/load bridge counters and clocks; emitted native bytes are cumulative, arena reservations are live/peak capacity rather than live executable bytes; source reads and scene startup are outside compiler clocks",
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
            vec![
                Mode::O1,
                Mode::O2,
                Mode::Native,
                Mode::Marked,
                Mode::Tiered,
                Mode::Counting,
            ],
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
    // Each pair reverses the same rotation, balancing the position of every mode across rounds.
    order.rotate_left((round as usize / 2) % modes.len());
    if round % 2 == 1 {
        order.reverse();
    }
    order
}

fn measure_in_child(
    mode: Mode,
    round: u32,
    arguments: &Arguments,
) -> Result<Measurement, Box<dyn Error>> {
    let mut command = Command::new(env::current_exe()?);
    command.args([
        "--sample-child",
        "--mode",
        mode.name(),
        "--renderer",
        "offscreen",
        "--rounds",
        "1",
        "--frames",
        &arguments.frames.to_string(),
        "--warmup",
        &arguments.warmup.to_string(),
        "--micro-iterations",
        &arguments.micro_iterations.to_string(),
        "--reloads",
        &arguments.reloads.to_string(),
        "--reload-frames",
        &arguments.reload_frames.to_string(),
        "--reload-warmup",
        &arguments.reload_warmup.to_string(),
        "--tier-threshold",
        &arguments.tier_threshold.to_string(),
        "--tier-queue",
        &arguments.tier_queue.to_string(),
        "--tier-budget",
        &arguments.tier_budget.to_string(),
    ]);
    if arguments.smoke {
        command.arg("--smoke");
    }
    let output = command.stderr(Stdio::inherit()).output()?;
    if !output.status.success() {
        return Err(format!(
            "desktop benchmark: round {round} {} child exited with {}",
            mode.name(),
            output.status
        )
        .into());
    }
    let mut sample: Measurement = serde_json::from_slice(&output.stdout)?;
    if sample.mode != mode || sample.round != 1 {
        return Err("desktop benchmark: child returned the wrong sample".into());
    }
    sample.round = round;
    Ok(sample)
}

fn measure(mode: Mode, round: u32, arguments: &Arguments) -> Result<Measurement, Box<dyn Error>> {
    let roots = state::Roots::of_repository(Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."));
    let started = Instant::now();
    let graphics = if arguments.renderer == Renderer::Offscreen {
        Some(owner::Owner::new()?)
    } else {
        None
    };
    let lua = match &graphics {
        Some(owner) => {
            owner
                .configure(&roots)
                .and_then(|()| owner.initialize())
                .map_err(|error| error.to_string())?;
            owner.lua().clone()
        }
        None => state::new(&roots)?,
    };
    let mut jit_symbols = None;
    let mut workload: Option<Table> = None;
    let result = (|| {
        if arguments.profile_output.is_some()
            && matches!(mode, Mode::Native | Mode::Marked | Mode::Tiered)
        {
            jit_symbols = Some(profiling::jit_symbols::JitSymbols::install()?);
        }
        // Only the loader wrapper is installed before this point; every scene module uses this mode.
        execution::enable_metrics(&lua)?;
        execution::configure(&lua, mode.execution())?;
        if mode.counts() {
            execution::set_tier_up(&lua, tier_up(arguments)?)?;
        }
        let loader = state::BenchmarkLoader {
            marked: if mode == Mode::Marked {
                MARKED_MODULES
            } else {
                &[]
            }
            .iter()
            .map(|path| (*path).to_owned())
            .collect(),
            ..state::BenchmarkLoader::default()
        };
        lua.set_app_data(loader);
        state::use_configuration(&lua, Path::new(env!("CARGO_MANIFEST_DIR")).join("benches"))?;
        let probe = native_probe(&lua, mode)?;
        compiler_regression(&lua)?;
        let compiler_before_scene = compiler_metrics::snapshot(&lua)?;
        let require: Function = lua.globals().get("require")?;
        let module: Table = require.call("scene")?;
        let cpu_clock =
            lua.create_function(|_, ()| thread_cpu_seconds().map_err(mlua::Error::external))?;
        let controller: Table = module.call_function(
            "setup",
            (arguments.renderer == Renderer::Offscreen, cpu_clock),
        )?;
        workload = Some(controller.clone());
        drop(module);
        drop(require);
        let setup_ms = started.elapsed().as_secs_f64() * 1e3;
        tracing::debug!(mode = mode.name(), setup_ms, "scene ready");
        let scene: Table = controller.get("current")?;
        let mut measured = measure_workload(&lua, &scene, &probe, mode, setup_ms, arguments)?;
        measured.compiler_scene_work =
            compiler_metrics::difference(&compiler_before_scene, &measured.compiler_metrics)?;
        validate_compiler_work(&measured.compiler_scene_work, NativeWork::of_scene(mode))?;
        measured.compiler_before_scene = compiler_before_scene;
        drop(scene);
        lua.gc_collect()?;
        lua.gc_collect()?;
        measured.compiler_after_initial_gc = compiler_metrics::snapshot(&lua)?;
        measured.lua_bytes_after_initial_gc = lua.used_memory();
        if arguments.profile_output.is_none() {
            measured.reloads = measure_reloads(&lua, &controller, &probe, &measured, arguments)?;
        }
        Ok(measured)
    })()
    .map_err(|error: Box<dyn Error>| error.to_string());
    let mut failures = Vec::new();
    if let Some(jit_symbols) = jit_symbols {
        match jit_symbols.finish() {
            Ok(path) => tracing::info!(path = %path.display(), "native Luau perf map retained"),
            Err(error) => failures.push(error.to_string()),
        }
    }
    if let Some(workload) = workload
        && let Err(error) = workload.call_function::<()>("close", ())
    {
        failures.push(format!("scene cleanup: {error}"));
    }
    failures.extend(state::shutdown(&lua));
    drop(lua);
    if let Some(owner) = graphics
        && let Err(error) = owner.finish(Ok(()))
    {
        failures.push(error);
    }
    match result {
        Ok(mut sample) if failures.is_empty() => {
            sample.round = round;
            Ok(sample)
        }
        Ok(_) => Err(format!("desktop benchmark: {}", failures.join("\n")).into()),
        Err(error) if failures.is_empty() => Err(error.into()),
        Err(error) => Err(format!(
            "{error}\ndesktop benchmark cleanup: {}",
            failures.join("\n")
        )
        .into()),
    }
}

fn thread_cpu_seconds() -> std::io::Result<f64> {
    let mut time = MaybeUninit::<libc::timespec>::uninit();
    // SAFETY: clock_gettime initializes the timespec on success; the pointer is writable and aligned.
    if unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, time.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: the successful clock_gettime call initialized both fields.
    let time = unsafe { time.assume_init() };
    Ok(time.tv_sec as f64 + time.tv_nsec as f64 * 1e-9)
}

fn validate_software_driver() -> Result<(), Box<dyn Error>> {
    let paths = env::var_os("VK_DRIVER_FILES")
        .or_else(|| env::var_os("VK_ICD_FILENAMES"))
        .ok_or("desktop benchmark: offscreen rendering requires an explicitly selected Mesa lavapipe ICD")?;
    if paths.is_empty() {
        return Err("desktop benchmark: the software ICD selection is empty".into());
    }
    for path in env::split_paths(&paths) {
        let source = fs::read_to_string(&path)?;
        if !source.contains("libvulkan_lvp") {
            return Err(format!(
                "desktop benchmark: ICD {} is not Mesa lavapipe",
                path.display()
            )
            .into());
        }
    }
    Ok(())
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
    verify_execution(mode, "unmarked compiled probe", actual)?;
    if mode == Mode::Marked {
        let marked = lua.load("--!native\nreturn function(probe) local n = 0 for i = 1, 100 do n += i end return probe(), n end")
            .set_name("@benchmark-marked-probe.luau").into_function()?;
        execution::compile(lua, &marked)?;
        let marked_function: Function = marked.call(())?;
        let (native, sum): (bool, u32) = marked_function.call(&probe)?;
        if !native || sum != 5050 {
            return Err(mlua::Error::runtime(
                "desktop benchmark: explicitly marked probe is not native or its arithmetic differs",
            ));
        }
    }
    Ok(probe)
}

unsafe extern "C-unwind" fn caller_is_native(state: *mut ffi::lua_State) -> c_int {
    // SAFETY: Luau invokes this callback with a live state; level 1 is the calling Lua function.
    unsafe {
        ffi::lua_pushboolean(state, ffi::lua_incustomexecution(state, 1));
    }
    1
}

fn selected_execution(lua: &Lua, workload: &Table, mode: Mode) -> mlua::Result<()> {
    if selected_is_native(lua, workload)? != mode.binds_at_load() {
        return Err(mlua::Error::runtime(
            "desktop benchmark: selected production picking execution does not match its native scope",
        ));
    }
    Ok(())
}

fn selected_is_native(lua: &Lua, workload: &Table) -> mlua::Result<bool> {
    lua.set_named_registry_value("benchmark.selected.native", mlua::Value::Nil)?;
    // SAFETY: the callback only inspects its live caller and returns a valid raycast result.
    let probe = unsafe { lua.create_c_function(selected_caller_is_native)? };
    workload.call_function::<()>("selectedProbe", probe)?;
    lua.named_registry_value("benchmark.selected.native")
}

unsafe extern "C-unwind" fn selected_caller_is_native(state: *mut ffi::lua_State) -> c_int {
    // SAFETY: Luau invokes this callback in the production picking call; its registry and stack are live.
    unsafe {
        let native = ffi::lua_incustomexecution(state, 1);
        ffi::lua_pushboolean(state, native);
        ffi::lua_setfield(
            state,
            ffi::LUA_REGISTRYINDEX,
            c"benchmark.selected.native".as_ptr(),
        );
        for _ in 0..3 {
            ffi::lua_pushnumber(state, 1.);
        }
    }
    3
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
    selected_execution(lua, workload, mode)?;
    let (_, _, frame_entry, frame_after_draw, frame_after_assert): (f64, f64, bool, bool, bool) =
        frame.call((1, probe))?;
    let (_, micro_entry, micro_after_geometry, micro_after_assert): (f64, bool, bool, bool) =
        micro.call((arguments.micro_iterations, probe))?;
    if mode.counts() {
        // Wrappers promote once they become hot, so their entry state depends on the warmup history rather than on the mode.
    } else if mode != Mode::Native {
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
    let mut warmup_log = PromotionLog::default();
    let mut warmup_callback_cpu_us = Vec::with_capacity(arguments.warmup as usize);
    for index in 1..=arguments.warmup {
        let result: FrameResult = frame.call(index)?;
        warmup_callback_cpu_us.push(result.5 + result.6);
        warmup_log.after_frame(lua, mode, arguments, index)?;
    }
    let picking_native_after_warmup = selected_is_native(lua, workload)?;
    workload.call_function::<()>("validate", ())?;
    micro.call::<f64>(arguments.micro_iterations)?;
    let profiler = arguments
        .profile_output
        .as_ref()
        .map(|_| {
            profiling::Session::start(
                lua,
                arguments.profile_hz,
                arguments.profile_perf_control.clone(),
                arguments.profile_perf_ack.clone(),
                !arguments.profile_native_only,
            )
        })
        .transpose()?;
    let boundary = profiler
        .as_ref()
        .map(|session| session.boundary(lua))
        .transpose()?;
    let mut times = Vec::with_capacity(arguments.frames as usize);
    let (mut update_us, mut draw_us) = (0., 0.);
    let (mut update_cpu_us, mut draw_cpu_us) = (0., 0.);
    let (mut submit_us, mut submit_cpu_us, mut wait_us) = (0., 0., 0.);
    let mut timed_log = PromotionLog::default();
    for index in 1..=arguments.frames {
        let started = Instant::now();
        let (update, draw, _, _, _, update_cpu, draw_cpu, submit, submit_cpu, wait): FrameResult =
            if let Some(boundary) = &boundary {
                frame.call((arguments.warmup + index, mlua::Value::Nil, boundary))?
            } else {
                frame.call(arguments.warmup + index)?
            };
        times.push(started.elapsed().as_secs_f64() * 1e6);
        for value in [update, draw, update_cpu, draw_cpu, submit, submit_cpu, wait] {
            if !value.is_finite() || value < 0. {
                return Err(
                    "desktop benchmark: a callback timing is negative or non-finite".into(),
                );
            }
        }
        update_us += update;
        draw_us += draw;
        update_cpu_us += update_cpu;
        draw_cpu_us += draw_cpu;
        submit_us += submit;
        submit_cpu_us += submit_cpu;
        wait_us += wait;
        timed_log.after_frame(lua, mode, arguments, arguments.warmup + index)?;
    }
    drop(boundary);
    if let Some(profiler) = profiler {
        let mut report = profiler.finish()?;
        report["mode"] = json!(mode.name());
        report["process_id"] = json!(std::process::id());
        report["jit_perf_map"] = if matches!(mode, Mode::Native | Mode::Marked | Mode::Tiered) {
            json!(format!("/tmp/perf-{}.map", std::process::id()))
        } else {
            serde_json::Value::Null
        };
        report["renderer"] = json!(arguments.renderer.name());
        report["frames"] = json!(arguments.frames);
        report["warmup"] = json!(arguments.warmup);
        report["performance_comparison"] = json!(false);
        let output = arguments
            .profile_output
            .as_ref()
            .ok_or("desktop profile: output path is missing")?;
        fs::write(output, serde_json::to_vec_pretty(&report)?).map_err(|error| {
            std::io::Error::new(
                error.kind(),
                format!("desktop profile: write {}: {error}", output.display()),
            )
        })?;
    }
    let started = Instant::now();
    let cpu_started = thread_cpu_seconds()?;
    let checksum: f64 = micro.call(arguments.micro_iterations)?;
    let micro_cpu_us =
        (thread_cpu_seconds()? - cpu_started) * 1e6 / f64::from(arguments.micro_iterations);
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
        frame_p95_us: times
            .get((times.len() * 95).div_ceil(100).saturating_sub(1))
            .copied()
            .unwrap_or_default(),
        update_mean_us: update_us / f64::from(arguments.frames),
        draw_mean_us: draw_us / f64::from(arguments.frames),
        update_cpu_mean_us: update_cpu_us / f64::from(arguments.frames),
        draw_cpu_mean_us: draw_cpu_us / f64::from(arguments.frames),
        submit_mean_us: submit_us / f64::from(arguments.frames),
        submit_cpu_mean_us: submit_cpu_us / f64::from(arguments.frames),
        wait_mean_us: wait_us / f64::from(arguments.frames),
        micro_us,
        micro_cpu_us,
        checksum,
        lua_bytes: lua.used_memory(),
        panels: workload.get("panels")?,
        windows: workload.get("windows")?,
        rendering: match workload.get::<Option<Table>>("rendering")? {
            Some(details) => json!({
                "device": details.get::<String>("device")?,
                "width": details.get::<u32>("width")?,
                "height": details.get::<u32>("height")?,
                "draws": details.get::<u32>("draws")?,
                "draws_culled": details.get::<u32>("drawsCulled")?,
                "non_background_pixels": details.get::<u32>("nonBackgroundPixels")?,
                "changed_texture_pixels": details.get::<u32>("changedTexturePixels")?,
                "glyph_warm_frames": details.get::<u32>("glyphWarmFrames")?,
                "validated": details.get::<bool>("validated")?,
            }),
            None => Value::Null,
        },
        frame_native: (frame_entry, frame_after_draw, frame_after_assert),
        micro_native: (micro_entry, micro_after_geometry, micro_after_assert),
        compiler_metrics: compiler_metrics::snapshot(lua)?,
        compiler_before_scene: Value::Null,
        compiler_scene_work: Value::Null,
        compiler_after_initial_gc: Value::Null,
        lua_bytes_after_initial_gc: 0,
        source_loads: source_loads(lua)?,
        reloads: Vec::new(),
        promotion_cpu_mean_us: timed_log.cpu_us / f64::from(arguments.frames),
        tier_up: json!({
            "warmup": warmup_log.report(),
            "timed": timed_log.report(),
            "hot_queue_len_after": execution::hot_queue_len(lua)?,
            "picking_native_after_warmup": picking_native_after_warmup,
            "warmup_callback_thread_cpu_us": warmup_callback_cpu_us,
            "warmup_promotion_thread_cpu_us": warmup_log.series,
        }),
    })
}

/// Promotion work between frames in one phase of a workload measurement.
#[derive(Default)]
struct PromotionLog {
    calls: u32,
    functions: usize,
    cpu_us: f64,
    max_cpu_us: f64,
    last_frame: Option<u32>,
    series: Vec<f64>,
}

impl PromotionLog {
    fn after_frame(
        &mut self,
        lua: &Lua,
        mode: Mode,
        arguments: &Arguments,
        frame: u32,
    ) -> Result<(), Box<dyn Error>> {
        if mode != Mode::Tiered || execution::hot_queue_len(lua)? == 0 {
            self.series.push(0.);
            return Ok(());
        }
        let started = thread_cpu_seconds()?;
        let functions = execution::promote(lua, InstructionBudget(arguments.tier_budget))?;
        let cpu_us = (thread_cpu_seconds()? - started) * 1e6;
        self.calls += 1;
        self.functions += functions;
        self.cpu_us += cpu_us;
        self.max_cpu_us = self.max_cpu_us.max(cpu_us);
        self.last_frame = Some(frame);
        self.series.push(cpu_us);
        Ok(())
    }

    fn report(&self) -> Value {
        json!({
            "promotion_calls": self.calls,
            "functions_promoted": self.functions,
            "promotion_thread_cpu_us": self.cpu_us,
            "max_promotion_thread_cpu_us": self.max_cpu_us,
            "last_promotion_frame": self.last_frame,
        })
    }
}

fn tier_up(arguments: &Arguments) -> Result<TierUp, Box<dyn Error>> {
    Ok(TierUp {
        threshold: NonZeroU32::new(arguments.tier_threshold)
            .ok_or("desktop benchmark: the tier-up threshold is zero")?,
        queue_capacity: NonZeroU32::new(arguments.tier_queue)
            .ok_or("desktop benchmark: the tier-up queue capacity is zero")?,
    })
}

fn measure_reloads(
    lua: &Lua,
    controller: &Table,
    probe: &Function,
    original: &Measurement,
    arguments: &Arguments,
) -> Result<Vec<Value>, Box<dyn Error>> {
    let mut results = Vec::new();
    let mut validation_arguments = arguments.clone();
    validation_arguments.frames = arguments.reload_frames;
    validation_arguments.warmup = arguments.reload_warmup;
    for index in 1..=arguments.reloads {
        let retired = retired_workload(lua, controller)?;
        let before = compiler_metrics::snapshot(lua)?;
        let loads_before = source_loads(lua)?;
        let cpu_started = thread_cpu_seconds()?;
        let started = Instant::now();
        let current: Table = controller.call_function("reload", ())?;
        let elapsed_ms = started.elapsed().as_secs_f64() * 1e3;
        let cpu_ms = (thread_cpu_seconds()? - cpu_started) * 1e3;
        let after = compiler_metrics::snapshot(lua)?;
        let loads_after = source_loads(lua)?;
        for path in MARKED_MODULES {
            let previous = loads_before[*path]
                .as_u64()
                .ok_or("desktop benchmark: source load count missing")?;
            if loads_after[*path].as_u64() != Some(previous + 1) {
                return Err(format!(
                    "desktop benchmark: reload did not recompile {path} exactly once"
                )
                .into());
            }
        }
        let delta = compiler_metrics::difference(&before, &after)?;
        validate_compiler_work(&delta, NativeWork::of_reload(original.mode))?;
        let validated = measure_workload(
            lua,
            &current,
            probe,
            original.mode,
            elapsed_ms,
            &validation_arguments,
        )?;
        equivalent(original, &validated)?;
        drop(current);
        let memory_before_gc = lua.used_memory();
        lua.gc_collect()?;
        lua.gc_collect()?;
        let after_gc = compiler_metrics::snapshot(lua)?;
        if !retired.get::<mlua::Value>(1)?.is_nil() || !retired.get::<mlua::Value>(2)?.is_nil() {
            return Err(
                "desktop benchmark: retired workload functions remain reachable after full GC"
                    .into(),
            );
        }
        results.push(json!({
            "index": index,
            "elapsed_ms": elapsed_ms,
            "thread_cpu_ms": cpu_ms,
            "compiler_work": delta,
            "compiler_after": after,
            "compiler_after_gc": after_gc,
            "lua_bytes_before_gc": memory_before_gc,
            "lua_bytes_after_gc": lua.used_memory(),
            "retired_workload_collected": true,
            "callback_thread_cpu_mean_us": validated.update_cpu_mean_us + validated.draw_cpu_mean_us,
            "micro_thread_cpu_us_per_iteration": validated.micro_cpu_us,
            "checksum": validated.checksum,
            "rendering": validated.rendering,
            "source_loads": loads_after,
            "frame_native": validated.frame_native,
            "micro_native": validated.micro_native,
            "promotion_thread_cpu_mean_us": validated.promotion_cpu_mean_us,
            "tier_up": validated.tier_up,
        }));
    }
    Ok(results)
}

fn retired_workload(lua: &Lua, controller: &Table) -> mlua::Result<Table> {
    let current: Table = controller.get("current")?;
    let weak = lua.create_table()?;
    let metatable = lua.create_table()?;
    metatable.set("__mode", "v")?;
    weak.set_metatable(Some(metatable))?;
    weak.set(1, current.get::<Function>("frame")?)?;
    weak.set(2, current.get::<Function>("micro")?)?;
    Ok(weak)
}

fn validate_compiler_work(work: &Value, native: NativeWork) -> Result<(), Box<dyn Error>> {
    let count = |key: &str| {
        work[key]
            .as_u64()
            .ok_or_else(|| format!("desktop benchmark: missing compiler counter {key}"))
    };
    if count("bytecode_compile_calls")? < MARKED_MODULES.len() as u64
        || count("bytecode_load_calls")? != count("bytecode_compile_calls")?
        || count("native_compile_result_errors")? != 0
        || count("native_compile_failures")? != 0
    {
        return Err("desktop benchmark: compiler work is missing or has native failures".into());
    }
    let bound = count("native_functions_bound")? > 0;
    let emitted = count("native_code_bytes")? > 0;
    let requested = count("native_compile_calls")? > 0;
    let matches = match native {
        NativeWork::None => !requested && !bound && !emitted,
        NativeWork::Attempted => requested && !bound && !emitted,
        NativeWork::Bound => bound && emitted,
    };
    if !matches {
        return Err(
            "desktop benchmark: compiler emission does not match the requested scope".into(),
        );
    }
    Ok(())
}

fn source_loads(lua: &Lua) -> mlua::Result<Value> {
    let loader = lua
        .app_data_ref::<state::BenchmarkLoader>()
        .ok_or_else(|| mlua::Error::runtime("desktop benchmark: source loader is missing"))?;
    for path in MARKED_MODULES {
        if !loader.loads.contains_key(*path) {
            return Err(mlua::Error::runtime(format!(
                "desktop benchmark: candidate module {path} was not loaded"
            )));
        }
    }
    serde_json::to_value(&loader.loads).map_err(mlua::Error::external)
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
                "callback_thread_cpu": reduction(base.update_cpu_mean_us + base.draw_cpu_mean_us, next.update_cpu_mean_us + next.draw_cpu_mean_us),
                "callback_plus_promotion_thread_cpu": reduction(base.update_cpu_mean_us + base.draw_cpu_mean_us + base.promotion_cpu_mean_us, next.update_cpu_mean_us + next.draw_cpu_mean_us + next.promotion_cpu_mean_us),
                "micro": reduction(base.micro_us, next.micro_us),
                "micro_thread_cpu": reduction(base.micro_cpu_us, next.micro_cpu_us),
            }))
        })
        .collect()
}

// Adjacent modes, plus tiered against each mode it replaces and counting against the interpreter it slows.
fn comparison_pairs(modes: &[Mode]) -> Vec<(Mode, Mode)> {
    let mut pairs: Vec<(Mode, Mode)> = modes.windows(2).map(|pair| (pair[0], pair[1])).collect();
    for extra in [
        (Mode::O1, Mode::Tiered),
        (Mode::O2, Mode::Tiered),
        (Mode::Native, Mode::Tiered),
        (Mode::O2, Mode::Counting),
    ] {
        if modes.contains(&extra.0) && modes.contains(&extra.1) && !pairs.contains(&extra) {
            pairs.push(extra);
        }
    }
    pairs
}

fn counter(work: &Value, key: &str) -> f64 {
    work[key].as_u64().unwrap_or_default() as f64
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
