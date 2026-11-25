//! Windows session startup.

use std::{
    env, io,
    path::{self, PathBuf},
    process::ExitCode,
    rc::Rc,
};

use clap::Parser;
use lunette::{
    audio::NativeAudioRegistry,
    control::{ControlSwitch, pipe},
    events::LovrEventSink,
    frame::Startup,
    host::NoHostSinks,
    layers::{LayerPool, LovrLayers},
    lua::{PoolRegistry, Session},
    mirrors::WindowsMirrors,
};
use lunette_capture::{
    audio::{AudioService, SourceLimits, WasapiAudioBackend, WindowsAudioTargets},
    windows,
};
use tracing::{error, info, warn};
use tracing_subscriber::{EnvFilter, filter::LevelFilter};

use crate::{
    boot::{self, SessionPaths},
    check,
    cli::{self, Cli},
};

pub(super) fn run() -> ExitCode {
    let default = LevelFilter::INFO;
    let (filter, filter_error) = match EnvFilter::builder()
        .with_default_directive(default.into())
        .from_env()
    {
        Ok(filter) => (filter, None),
        Err(error) => (
            EnvFilter::default().add_directive(default.into()),
            Some(error),
        ),
    };
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter(filter)
        .init();
    if let Some(error) = filter_error {
        warn!(
            "logging: {} could not be parsed, falling back to {default}: {error}",
            EnvFilter::DEFAULT_ENV
        );
    }
    match run_session(Cli::parse()) {
        Ok(status) => status,
        Err(error) => {
            error!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run_session(arguments: Cli) -> Result<ExitCode, Box<dyn std::error::Error>> {
    if arguments.list_windows {
        for window in windows::windows()? {
            println!("{}", window.title);
        }
        return Ok(ExitCode::SUCCESS);
    }

    let exe = env::current_exe()?;
    let install = exe
        .parent()
        .ok_or("lunette executable has no parent directory")?;
    let installed_config = install.join("config");
    let user_config = path_from_env("LOCALAPPDATA")
        .map(|root| root.join("Lunette").join("config"))
        .unwrap_or_else(|| installed_config.clone());
    let config = arguments
        .config_path
        .or_else(|| path_from_env("LUNETTE_CONFIG_PATH"))
        .unwrap_or_else(|| {
            if user_config.is_dir() {
                user_config.clone()
            } else {
                installed_config
            }
        });
    if let Some(cli::Command::Check { roots, definitions }) = &arguments.command {
        return Ok(check::run(roots, &config, definitions.as_deref()));
    }

    let data = path_from_env("LUNETTE_STDLIB_PATH").unwrap_or_else(|| install.join("lua"));
    if let Some(destination) = arguments.dump_config {
        let destination = if destination.as_os_str().is_empty() {
            user_config
        } else {
            destination
        };
        for written in cli::dump(&destination, &path::absolute(&data)?)? {
            info!(path = %written.display(), "wrote");
        }
        return Ok(ExitCode::SUCCESS);
    }
    let config = path::absolute(config)?;
    if !config.join("main.luau").is_file() {
        return Err(format!(
            "config: no main.luau at {}; use --config-path to select a configuration",
            config.display()
        )
        .into());
    }
    let data = path::absolute(data)?;
    if !data.is_dir() {
        return Err(format!(
            "module data: {} is unavailable; set LUNETTE_STDLIB_PATH to the Lua directory",
            data.display()
        )
        .into());
    }
    if config.canonicalize()? == data.canonicalize()? {
        return Err("config and Lua module data must be separate directories".into());
    }

    let window = if let Some(title) = &arguments.window_title {
        let mut matching = windows::windows()?
            .into_iter()
            .filter(|window| window.title == *title);
        let window = matching.next().ok_or_else(|| {
            format!("no visible Windows window has the title {title:?}; use --list-windows to see titles")
        })?;
        if matching.next().is_some() {
            return Err(format!("several Windows windows have the title {title:?}").into());
        }
        Some(window)
    } else {
        None
    };

    info!(path = %config.display(), "loading the configuration");
    info!(path = %data.display(), "mounting the module data");
    // SAFETY: the entry point owns LÖVR's headset module and stays on the frame thread.
    let layers = Rc::new(PoolRegistry::new(LayerPool::new(unsafe {
        LovrLayers::new()
    })));
    let mirrors = Rc::new(WindowsMirrors::new());
    let audio_targets = WindowsAudioTargets::default();
    let audio = NativeAudioRegistry::native_processes(AudioService::new(
        Box::new(WasapiAudioBackend::new(audio_targets.clone())),
        SourceLimits::default(),
    ));
    let session = Session::new_with_audio(
        Box::new(LovrEventSink),
        Rc::clone(&layers) as _,
        Rc::clone(&mirrors) as _,
        Rc::new(NoHostSinks),
        Rc::new(audio),
    );
    let control_setting = env::var_os("LUNETTE_CONTROL");
    let switch = ControlSwitch::from_setting(
        control_setting
            .as_deref()
            .map(|value| value.to_string_lossy())
            .as_deref(),
    );
    let control = match pipe::start(switch) {
        Ok(control) => control,
        Err(error) => {
            warn!(%error, "the Windows control pipe is unavailable");
            None
        }
    };
    let (_control_thread, chunks) = match control {
        Some((worker, chunks)) => (Some(worker), Some(chunks)),
        None => (None, None),
    };
    Ok(boot::run(
        SessionPaths {
            config: &config,
            standard_library: &data,
            forwarded: &arguments.forwarded,
        },
        &session,
        &layers,
        chunks.as_ref(),
        Startup {
            window,
            mirrors,
            audio_targets,
        },
        boot::RuntimeOptions {
            execution: arguments.luau_execution,
            gc_budget: arguments.luau_gc_budget_us,
        },
    ))
}

fn path_from_env(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}
