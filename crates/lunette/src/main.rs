//! Linux-only: the lunette binary, which boots LÖVR, runs the Lua session, and
//! orchestrates the compositor and capture subsystems.
//!
//! The configuration directory follows the XDG base directory specification,
//! whose `$HOME/.config` and `/etc/xdg` defaults are Unix paths, and the boot
//! sequence below it is Linux-only in turn.
//!
//! This is the application entry point, and the only part of the program that
//! reads the environment or installs a `tracing` subscriber. Everything it
//! learns from the environment is passed onward as a parameter.
//!
//! # Writing the environment
//!
//! Exporting `WAYLAND_DISPLAY` — so that everything lunette starts finds its
//! socket without being told — happens here and nowhere else, and it has to
//! happen before any other thread exists.
//!
//! In Rust 2024 `std::env::set_var` is `unsafe`, and it is unsound once the
//! process is multithreaded: a concurrent `getenv` anywhere, including inside a
//! C library, reads a pointer the write may free. LÖVR and GLFW spawn threads
//! as they boot, and the compositor thread cannot start before them because it
//! needs the graphics device they create. So the only safe moment is at the top
//! of `main`, before anything else runs.
//!
//! That ordering is available because binding the socket needs nothing from the
//! graphics device — only the compositor *thread* does. [`listen`] runs here,
//! at the top of `main`, and returns the name; the socket then travels down to
//! the frame loop, which starts the thread once LÖVR has a device to lend it.
//!
//! `lunette_compositor::client::listen` therefore does not export the name
//! itself, and carries the other half of this note. Setting the variable next
//! to the code that creates the socket is the obvious thing to do, and it is
//! wrong for a reason that is invisible from there.
//!
//! # Why this does not point LÖVR at lunette's own socket
//!
//! Setting `WAYLAND_DISPLAY` in a process that is about to open a window of its
//! own is a way to deadlock: the window's toolkit would connect to a socket
//! whose compositor thread has not started, and wait for a registry that cannot
//! arrive until it has. LÖVR's GLFW is built with `GLFW_BUILD_WAYLAND OFF`
//! (`vendor/lovr/CMakeLists.txt:113`), so it is X11-only and never reads the
//! variable. A LÖVR build with Wayland support would have to save the host's
//! value and hand it back, or defer the export until after the window exists —
//! which the soundness rule above forbids.
//!
//! `DISPLAY` is deliberately not exported. It would name lunette's own X server
//! whether or not xwayland-satellite actually started, so every X11 client
//! lunette launched would hang against a socket with nothing behind it. A
//! spawned child is told both values explicitly, by the compositor's spawner,
//! which knows whether the bridge is running.

mod boot;

use std::{
    env,
    ffi::OsString,
    io,
    path::{Path, PathBuf},
    process::ExitCode,
    rc::Rc,
};

use lunette::{
    events::LovrEventSink,
    frame::Startup,
    host::NoHostSinks,
    layers::{LayerPool, LovrLayers},
    lua::{PoolRegistry, Session},
    mirrors::NoMonitors,
    texture::BarrierPolicy,
};
use lunette_compositor::client::{XwaylandSatellite, listen};
use tracing::{error, info, warn};
use tracing_subscriber::{EnvFilter, filter::LevelFilter};

fn main() -> ExitCode {
    // The parse failure is held rather than discarded, because reporting it
    // needs the subscriber the filter is being built for. A typo in the
    // variable otherwise looks exactly like the variable being unset.
    let (filter, filter_error) = match EnvFilter::builder()
        .with_default_directive(DEFAULT_LOG_LEVEL.into())
        .from_env()
    {
        Ok(filter) => (filter, None),
        Err(error) => (
            EnvFilter::default().add_directive(DEFAULT_LOG_LEVEL.into()),
            Some(error),
        ),
    };

    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter(filter)
        .init();

    if let Some(error) = filter_error {
        warn!(
            "logging: {} could not be parsed, falling back to {DEFAULT_LOG_LEVEL}: {error}",
            EnvFilter::DEFAULT_ENV
        );
    }

    let candidates = config_directory_candidates(&ConfigDirectorySources::from_environment());
    let Some(config_directory) = select_config_directory(&candidates) else {
        error!("config: no configuration directory could be determined");
        return ExitCode::FAILURE;
    };

    info!(path = %config_directory.display(), "loading the configuration");

    // `name` rather than `display`, because `tracing`'s macros bring a function
    // of that name into scope and a local would shadow it.
    let (socket, name) = match listen() {
        Ok(bound) => bound,
        Err(error) => {
            error!("{error}");
            return ExitCode::FAILURE;
        }
    };

    // SAFETY: this is the only write to the environment in the program, and it
    // runs before anything has spawned a thread — the subscriber is installed,
    // the configuration directory is resolved, and the socket is bound, none of
    // which starts one. Every later reader is in a thread this write precedes.
    unsafe { env::set_var(WAYLAND_DISPLAY, name.wayland()) };

    info!(
        "connect a client from outside with WAYLAND_DISPLAY={}",
        name.wayland().to_string_lossy()
    );

    let startup = Startup {
        socket,
        display: name,
        // Best-effort: an installation without the bridge logs a warning and
        // serves Wayland clients only.
        satellite: Some(XwaylandSatellite::resolve(
            env::var_os(APPDIR)
                .as_deref()
                .filter(|appdir| !appdir.is_empty()),
        )),
        barriers: BarrierPolicy::from_settings(
            env::var(IMPORT_QUEUE_FAMILY).ok().as_deref(),
            env::var(IMPORT_LAYOUT).ok().as_deref(),
        ),
    };

    // SAFETY: this is the thread that runs the LÖVR boot sequence below and
    // every frame after it, so it is the thread that owns the headset module,
    // and it stays that way for the life of the process.
    let backend = unsafe { LovrLayers::new() };

    // Built before the Lua state and outliving it, because a restart throws the
    // state away and the session is what the next one attaches to. The pool
    // outlives it for the same reason, and so a restart does not cost every
    // panel its layer.
    //
    // Two references to the one pool. Lua reaches it through `ClaimRegistry`,
    // which is dyn-safe and hides the backend; the blit and the submit need the
    // backend's own `Layer` type, so they hold it concretely.
    let layers = Rc::new(PoolRegistry::new(LayerPool::new(backend)));

    // `NoMonitors` rather than `HostMirrors`, because two things the lifecycle
    // needs do not exist yet and neither is this file's to invent.
    //
    // Nothing enumerates the host's `wl_output`s, so a `HostMirrors` would hold
    // an empty roster and refuse every monitor a configuration named. And a
    // capture stream negotiates against the DRM formats the importer accepts,
    // which are not known until LÖVR has made a graphics device — several steps
    // into `boot::run`, and the same reason the compositor thread starts from
    // the frame loop rather than from here.
    //
    // `lunette.monitors()` is therefore empty in this build, which is the honest
    // answer for a lunette that cannot see the host's screens. Swapping this for
    // `HostMirrors::new(MirrorSet::new(WlxPortal::connect()?, …))` is what makes
    // it live, and needs no change above this line.
    //
    // `NoHostSinks` follows from the same gap. A host sink maps a hit through
    // its monitor's logical geometry, so a provider opened against a layout with
    // no monitors in it would have nothing to place a cursor on.
    let mirrors = Rc::new(NoMonitors);
    let session = Session::new(
        Box::new(LovrEventSink),
        Rc::clone(&layers) as _,
        mirrors as _,
        Rc::new(NoHostSinks) as _,
    );
    boot::run(config_directory, &session, &layers, startup)
}

/// Where a client is told to find lunette's socket.
const WAYLAND_DISPLAY: &str = "WAYLAND_DISPLAY";

/// The AppImage runtime's own root, when lunette is running from one.
const APPDIR: &str = "APPDIR";

/// The two diagnostic settings milestone 0 exists to answer.
///
/// Neither the queue family an imported image is acquired from nor the layout it
/// is taken to be in is settled, and the point of measuring is to try the other
/// value without a rebuild. `crates/lunette/src/texture/mod.rs` documents what
/// each accepts; an unrecognised value falls back with a warning rather than
/// stopping a session.
const IMPORT_QUEUE_FAMILY: &str = "LUNETTE_IMPORT_QUEUE_FAMILY";
const IMPORT_LAYOUT: &str = "LUNETTE_IMPORT_LAYOUT";

/// The verbosity applied when `RUST_LOG` names none, or names something that
/// does not parse.
const DEFAULT_LOG_LEVEL: LevelFilter = LevelFilter::INFO;

/// The install-time system configuration directory.
///
/// A packager sets `LUNETTE_SYSCONFDIR` when building. The default matches the
/// `/etc/xdg` fallback the XDG base directory specification names, which is
/// what `$SYSCONFDIR/xdg` resolves to for the usual prefix.
const SYSCONFDIR: &str = match option_env!("LUNETTE_SYSCONFDIR") {
    Some(path) => path,
    None => "/etc",
};

/// The environment values configuration-directory resolution depends on.
///
/// They are gathered here so that [`config_directory_candidates`] stays a pure
/// function of its inputs, and so that the environment is read in exactly one
/// place.
#[derive(Debug)]
struct ConfigDirectorySources {
    /// `$XDG_CONFIG_HOME`, when it is set to an absolute path.
    xdg_config_home: Option<PathBuf>,
    /// `$HOME`, when it is set to an absolute path.
    home: Option<PathBuf>,
    /// The install-time system configuration directory.
    sysconfdir: PathBuf,
}

impl ConfigDirectorySources {
    fn from_environment() -> Self {
        Self {
            xdg_config_home: absolute_path(env::var_os("XDG_CONFIG_HOME")),
            home: absolute_path(env::var_os("HOME")),
            sysconfdir: PathBuf::from(SYSCONFDIR),
        }
    }
}

/// The directories that may hold the user's configuration, highest priority
/// first.
///
/// The result is never empty: the system directory has no precondition, so
/// there is always something to fall back to.
fn config_directory_candidates(sources: &ConfigDirectorySources) -> Vec<PathBuf> {
    let mut candidates = Vec::with_capacity(3);
    if let Some(xdg_config_home) = &sources.xdg_config_home {
        candidates.push(xdg_config_home.join("lunette"));
    }
    if let Some(home) = &sources.home {
        candidates.push(home.join(".config").join("lunette"));
    }
    candidates.push(sources.sysconfdir.join("xdg").join("lunette"));
    candidates
}

/// Picks the configuration directory to load from.
///
/// The first candidate that exists wins. When none exists the highest-priority
/// candidate is used anyway, so that boot.lua's own "no main.lua" message names
/// the directory the user is expected to create rather than a system path they
/// cannot write to.
fn select_config_directory(candidates: &[PathBuf]) -> Option<&Path> {
    candidates
        .iter()
        .find(|candidate| candidate.is_dir())
        .or_else(|| candidates.first())
        .map(PathBuf::as_path)
}

/// Accepts an environment value only when it names an absolute path.
///
/// The XDG base directory specification requires a relative value to be treated
/// as unset, and an empty value is how a shell usually spells "not set".
fn absolute_path(value: Option<OsString>) -> Option<PathBuf> {
    let value = PathBuf::from(value?);
    value.is_absolute().then_some(value)
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    fn sources(xdg_config_home: Option<&str>, home: Option<&str>) -> ConfigDirectorySources {
        ConfigDirectorySources {
            xdg_config_home: xdg_config_home.map(PathBuf::from),
            home: home.map(PathBuf::from),
            sysconfdir: PathBuf::from("/etc"),
        }
    }

    #[test]
    fn all_three_candidates_appear_in_priority_order() {
        assert_eq!(
            config_directory_candidates(&sources(Some("/xdg"), Some("/home/user"))),
            vec![
                PathBuf::from("/xdg/lunette"),
                PathBuf::from("/home/user/.config/lunette"),
                PathBuf::from("/etc/xdg/lunette"),
            ]
        );
    }

    #[test]
    fn an_unset_variable_drops_its_candidate() {
        assert_eq!(
            config_directory_candidates(&sources(None, Some("/home/user"))),
            vec![
                PathBuf::from("/home/user/.config/lunette"),
                PathBuf::from("/etc/xdg/lunette"),
            ]
        );
    }

    #[test]
    fn the_system_candidate_is_always_present() {
        assert_eq!(
            config_directory_candidates(&sources(None, None)),
            vec![PathBuf::from("/etc/xdg/lunette")]
        );
    }

    #[test]
    fn selection_falls_back_to_the_highest_priority_candidate() {
        let candidates = vec![
            PathBuf::from("/definitely/not/a/directory/lunette"),
            PathBuf::from("/also/not/a/directory/lunette"),
        ];
        assert_eq!(
            select_config_directory(&candidates),
            Some(Path::new("/definitely/not/a/directory/lunette"))
        );
    }

    #[test]
    fn selection_of_nothing_is_representable() {
        assert_eq!(select_config_directory(&[]), None);
    }

    #[test]
    fn an_absolute_value_is_accepted() {
        assert_eq!(
            absolute_path(Some(OsString::from("/xdg"))),
            Some(PathBuf::from("/xdg"))
        );
    }

    #[test]
    fn a_relative_or_empty_value_counts_as_unset() {
        assert_eq!(absolute_path(Some(OsString::from("xdg"))), None);
        assert_eq!(absolute_path(Some(OsString::new())), None);
        assert_eq!(absolute_path(None), None);
    }
}
