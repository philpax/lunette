//! Linux-only: the lunette binary, which boots LÖVR, runs the Lua session, and
//! orchestrates the compositor and capture subsystems.
//!
//! The configuration directory follows the XDG base directory specification,
//! whose `$HOME/.config` and `/etc/xdg` defaults are Unix paths, and the boot
//! sequence below it is Linux-only in turn.
//!
//! This is the application entry point. No other part of the program reads the
//! environment or installs a `tracing` subscriber. Everything it learns from
//! the environment is passed onward as a parameter.
//!
//! # Writing the environment
//!
//! Exporting `WAYLAND_DISPLAY` happens here and nowhere else, and it must
//! happen before any other thread exists. Everything lunette starts then finds
//! its socket without being told.
//!
//! In Rust 2024 `std::env::set_var` is `unsafe`, and it is unsound once the
//! process is multithreaded: a concurrent `getenv` anywhere, including inside a
//! C library, reads a pointer the write may free. LÖVR and GLFW spawn threads
//! as they boot, and the compositor thread cannot start before them because it
//! needs the graphics device they create. The top of `main`, before anything
//! else runs, is the safe moment for the write.
//!
//! That ordering is available because binding the socket needs nothing from the
//! graphics device; the compositor thread needs the device. [`listen`] runs
//! here, at the top of `main`, and returns the name. The socket then passes to
//! the frame loop, which starts the thread once LÖVR has created the device it
//! needs.
//!
//! `lunette_compositor::client::listen` does not export the name itself, and
//! its documentation carries the other half of the explanation. Setting the
//! variable next to the code that creates the socket is natural; it is wrong
//! for a reason that is not visible there.
//!
//! The export also follows the read of the host's `WAYLAND_DISPLAY`. The two
//! are one function; see [`read_host_then_export_display`].
//!
//! # LÖVR's GLFW and the `DISPLAY` export
//!
//! Setting `WAYLAND_DISPLAY` in a process that is about to open a window of its
//! own is a way to deadlock: the window's toolkit would connect to a socket
//! whose compositor thread has not started, and wait for a registry that cannot
//! arrive until the thread has. LÖVR's GLFW is built with
//! `GLFW_BUILD_WAYLAND OFF` (vendor/lovr/CMakeLists.txt), so it is X11-only and
//! never reads the variable. A LÖVR build with Wayland support would have to
//! save the host's value and hand it back, or defer the export until after the
//! window exists; the soundness rule above forbids the deferral.
//!
//! `DISPLAY` is not exported. It would name lunette's own X server whether or
//! not xwayland-satellite started, and every X11 client lunette launched would
//! then hang against a socket with nothing behind it. A spawned child receives
//! both values explicitly from the compositor's spawner, which holds the bridge
//! state.

mod boot;
mod check;
mod cli;

use std::{
    env,
    ffi::{OsStr, OsString},
    io,
    path::{Path, PathBuf},
    process::ExitCode,
    rc::Rc,
};

use boot::SessionPaths;
use clap::Parser;
use cli::Cli;
use lunette::{
    control::{self, ControlSwitch},
    events::LovrEventSink,
    frame::{HostDesktop, Startup},
    host::{HostPointer, HostSinks, NoHostSinks},
    layers::{LayerPool, LovrLayers},
    lua::{PoolRegistry, Session},
    mirrors::{HostMirrors, MirrorFrames, MirrorRegistry, NoMonitors},
    texture::BarrierPolicy,
};
use lunette_capture::{
    hid::{self, HidConfig},
    mirror::MirrorSet,
    monitor::OutputWatcher,
    portal::{CursorPolicy, WlxPortal},
    tokens::{self, Loaded, TokenFile},
};
use lunette_compositor::{
    client::{DisplayName, XwaylandSatellite, listen},
    protocol::{KeymapConfig, KeymapDefaults},
    selection::DataControlSource,
};
use tracing::{error, info, warn};
use tracing_subscriber::{EnvFilter, filter::LevelFilter};

/// Selects the check command before any boot work. The configuration
/// directory is resolved first, because a check given no paths checks it.
///
/// The command owns its input paths, so this pure selector only borrows them
/// for the checker and leaves the imperative startup path untouched.
fn check_dispatch(command: Option<&cli::Command>) -> Option<(&[PathBuf], Option<&Path>, bool)> {
    match command {
        Some(cli::Command::Check {
            roots,
            definitions,
            old_solver,
        }) => Some((roots, definitions.as_deref(), *old_solver)),
        None => None,
    }
}

fn main() -> ExitCode {
    // The parse failure is held because reporting it needs the subscriber the
    // filter is being built for. Without the hold, a typo in the variable looks
    // exactly like the variable being unset.
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

    let arguments = Cli::parse();

    let candidates = config_directory_candidates(&ConfigDirectorySources::from_environment());
    let Some(searched) = select_config_directory(&candidates) else {
        error!("config: no configuration directory could be determined");
        return ExitCode::FAILURE;
    };

    if let Some((roots, definitions, old_solver)) = check_dispatch(arguments.command.as_ref()) {
        let configuration = config_directory(arguments.config_path.as_deref(), searched);
        return check::run(roots, configuration, definitions, old_solver);
    }

    if let Some(destination) = &arguments.dump_config {
        // An empty value means the flag was given without one, and the first
        // candidate is where a user's own configuration belongs.
        let destination = if destination.as_os_str().is_empty() {
            candidates.first().map_or(searched, PathBuf::as_path)
        } else {
            destination.as_path()
        };

        // Absolute, because the file it is written into is one the user may
        // open from anywhere, and a relative alias would resolve against
        // whichever directory the editor happened to start in.
        let module_data = absolute(&module_data_directory(
            &ModuleDataSources::from_environment(),
        ));
        return match cli::dump(destination, &module_data) {
            Ok(written) => {
                for path in written {
                    info!(path = %path.display(), "wrote");
                }
                ExitCode::SUCCESS
            }
            Err(error) => {
                error!("{error}");
                ExitCode::FAILURE
            }
        };
    }

    let config_directory = config_directory(arguments.config_path.as_deref(), searched);

    info!(path = %config_directory.display(), "loading the configuration");

    let module_data = module_data_directory(&ModuleDataSources::from_environment());
    if module_data_conflicts_with_configuration(config_directory, &module_data) {
        error!(
            "config: the module-data path {} is also the configuration directory; the two directories cannot be mounted separately",
            module_data.display()
        );
        return ExitCode::FAILURE;
    }
    info!(path = %module_data.display(), "mounting the module data");

    let state_directory = state_directory(&StateDirectorySources::from_environment());

    // Runs before anything spawns a thread, so the failure to bind is reported
    // among the other startup failures, not after a headset has come up.
    // A session without a control socket is still a session; the failure to
    // bind is a warning, and the user loses `lunctl`, not their windows.
    let control = match absolute_path(env::var_os(XDG_RUNTIME_DIR)) {
        Some(runtime_directory) => {
            // Lossy conversion, not discard: a value that is not text is not
            // `on`, and `env::var` would report it as unset, the one reading
            // that leaves the endpoint open.
            let setting =
                env::var_os(LUNETTE_CONTROL).map(|value| value.to_string_lossy().into_owned());
            let switch = ControlSwitch::from_setting(setting.as_deref());
            match control::start(switch, &runtime_directory) {
                Ok(started) => started,
                Err(error) => {
                    warn!("{error}; this session cannot be reached with lunctl");
                    None
                }
            }
        }
        None => {
            warn!(
                "lunctl: {XDG_RUNTIME_DIR} does not name an absolute path, so there is nowhere \
                 private to put the control socket; this session cannot be reached with lunctl"
            );
            None
        }
    };
    // The thread is held for the life of the process and stopped when it goes.
    // The queue passes to the frame loop; the frame loop is the sole holder of
    // the Lua state.
    let (_control_thread, chunks) = match control {
        Some((thread, queue)) => (Some(thread), Some(queue)),
        None => (None, None),
    };

    // `name`, not `display`: `tracing`'s macros bring a function of that name
    // into scope, and a local would shadow it.
    let (socket, name) = match listen() {
        Ok(bound) => bound,
        Err(error) => {
            error!("{error}");
            return ExitCode::FAILURE;
        }
    };

    // SAFETY: this is the only write to the environment in the program, and it
    // runs before anything has spawned a thread. The subscriber is installed,
    // the configuration directory is resolved, and the socket is bound; none
    // of those starts one. Every later reader is in a thread this write
    // precedes.
    let host_socket = unsafe { read_host_then_export_display(&name) };

    info!(
        "connect a client from outside with WAYLAND_DISPLAY={}",
        name.wayland().to_string_lossy()
    );

    // Three references to at most two objects. Lua reaches the mirrors through
    // `MirrorRegistry` and the pointer through `HostSinks`, both dyn-safe; the
    // frame loop reaches the same mirrors through `MirrorFrames` and the same
    // pointer concretely. Neither of those types is one Lua should hold.
    let (mirrors, sinks, desktop): (
        Rc<dyn MirrorRegistry>,
        Rc<dyn HostSinks>,
        Option<HostDesktop>,
    ) = match host_socket
        .path()
        .and_then(|socket| open_host(socket, state_directory.as_deref()))
    {
        Some(host) => (
            Rc::clone(&host.mirrors) as _,
            Rc::clone(&host.pointer) as _,
            Some(HostDesktop {
                outputs: host.outputs,
                mirrors: host.mirrors as Rc<dyn MirrorFrames>,
                pointer: host.pointer,
                tokens: host.tokens,
            }),
        ),
        None => (Rc::new(NoMonitors) as _, Rc::new(NoHostSinks) as _, None),
    };

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
        host: desktop,
        // Independent of `desktop`: a host whose screens cannot be captured, for
        // lack of a portal or because the user refused one, still has a
        // clipboard, and bridging it needs nothing but the socket.
        clipboard: host_socket.path().map(DataControlSource::new),
        keymap_defaults: keymap_defaults_from_environment(),
    };

    // SAFETY: this is the thread that runs the LÖVR boot sequence below and
    // every frame after it, so it is the thread that owns the headset module,
    // and it stays that way for the life of the process.
    let backend = unsafe { LovrLayers::new() };

    // Built before the Lua state and outliving it. A restart throws the state
    // away, and the session the next one attaches to needs the same pool; the
    // outliving keeps a restart from costing every panel its layer.
    //
    // Two references to the one pool. Lua reaches it through `ClaimRegistry`,
    // which is dyn-safe and hides the backend; the blit and the submit need the
    // backend's own `Layer` type, so they hold it concretely.
    let layers = Rc::new(PoolRegistry::new(LayerPool::new(backend)));

    let session = Session::new(
        Box::new(LovrEventSink),
        Rc::clone(&layers) as _,
        mirrors,
        sinks,
    );
    boot::run(
        SessionPaths {
            config: config_directory,
            standard_library: &module_data,
            forwarded: &arguments.forwarded,
        },
        &session,
        &layers,
        chunks.as_ref(),
        startup,
    )
}

/// Everything the host desktop is reached through, before it is split between
/// the Lua session and the frame loop.
struct Host {
    mirrors: Rc<HostMirrors<WlxPortal>>,
    pointer: Rc<HostPointer>,
    outputs: OutputWatcher,
    tokens: Option<TokenFile>,
}

/// Opens the user's own desktop: its monitors, its screencast portal, and its
/// input.
///
/// `None` when the host's outputs cannot be read, and the session then runs with
/// no monitors and no host input. That is not a fault to stop for; lunette is
/// usable as a compositor for the clients it spawns. The failure is reported,
/// because a user who expected their screens is otherwise left guessing.
///
/// The outputs decide it because everything else depends on them. A screencast
/// stream is correlated to a monitor by logical geometry, and a host sink maps a
/// hit through its monitor's rectangle; with no monitors there is nothing for
/// either to reach. It also means an X11 host has no monitors here, since there
/// are no `wl_output`s on one.
fn open_host(socket: &Path, state_directory: Option<&Path>) -> Option<Host> {
    let outputs = match OutputWatcher::connect(socket) {
        Ok(outputs) => outputs,
        Err(error) => {
            warn!(
                "{error}; lunette will show none of the host's screens and will not drive its \
                 pointer"
            );
            return None;
        }
    };

    let portal = match WlxPortal::connect() {
        Ok(portal) => portal,
        Err(error) => {
            warn!("{error}; no monitor can be mirrored this session");
            return None;
        }
    };

    let (stored, tokens) = read_tokens(state_directory);

    // `wl_virtual` is not configured. It requires a keymap to upload before its
    // first keystroke, and no keymap builder exists yet. Naming the socket
    // without one would produce a provider the first key disconnects, so the
    // chain reports "not configured" and falls to uinput.
    let input = hid::open(&HidConfig::default());
    if let Some(error) = input.unreachable() {
        warn!("{error}");
    }

    // The roster is not attached here, even though the enumeration has already
    // read it. The watcher reports it as a change on its first poll, and
    // attaching it on that one path is how `lovr.lunmonitoradded` fires for the
    // monitors present at startup as well as for one plugged in later. Attaching
    // here would consume the change and announce nothing.
    info!(
        monitors = outputs.outputs().len(),
        provider = %input.kind(),
        "the host desktop is reachable",
    );

    Some(Host {
        mirrors: Rc::new(HostMirrors::new(MirrorSet::new(
            portal,
            CursorPolicy::Hidden,
            stored,
        ))),
        pointer: Rc::new(HostPointer::new(input)),
        outputs,
        tokens,
    })
}

/// Reads the restore tokens, and says whether they may be written back.
///
/// A file written by a later lunette is read for nothing and must not be
/// rewritten: rendering this version's fields over it would drop the ones this
/// version does not know about. [`Loaded::for_session`] decides that, and a
/// [`TokenFile`] is the sole type `tokens::write` accepts, so the answer here
/// cannot be a convention this function is trusted to keep.
fn read_tokens(state_directory: Option<&Path>) -> (tokens::TokenStore, Option<TokenFile>) {
    let Some(directory) = state_directory else {
        warn!(
            "state: neither {XDG_STATE_HOME} nor HOME names an absolute path, so screencast \
             permissions will be asked for again on every run"
        );
        return (tokens::TokenStore::new(), None);
    };

    let path = directory.join(TOKEN_FILE);
    let loaded = match tokens::read(&path) {
        Ok(loaded) => loaded,
        Err(error) => {
            warn!("{error}; the screencast portal will prompt again");
            return (tokens::TokenStore::new(), None);
        }
    };

    match &loaded {
        Loaded::Store(store) => {
            info!(path = %path.display(), monitors = store.len(), "read the screencast tokens");
        }
        Loaded::Absent => {}
        Loaded::FromTheFuture { found, supported } => warn!(
            path = %path.display(),
            %found,
            %supported,
            "the screencast tokens were written by a later lunette, so they are left untouched",
        ),
    }

    loaded.for_session(path)
}

/// The host compositor's socket, as it stood before lunette's own display name
/// replaced it in the environment.
///
/// Only [`read_host_then_export_display`] creates one; holding one proves the
/// read happened first.
#[derive(Debug)]
struct HostWaylandSocket(Option<PathBuf>);

impl HostWaylandSocket {
    fn path(&self) -> Option<&Path> {
        self.0.as_deref()
    }
}

/// Reads the host compositor's socket, then points `WAYLAND_DISPLAY` at
/// lunette's own.
///
/// One function because the order between the two is load-bearing, and the
/// constraint is invisible from either side. Everything that reaches the host
/// compositor, the output enumeration and the `wl_virtual` input provider when
/// a keymap builder exists, needs the socket the user's own session is on;
/// after the export the variable names lunette's. A read below the export
/// would enumerate lunette's own compositor and report zero monitors, which in
/// the log is indistinguishable from a machine with no readable screens.
///
/// Reading inside the function that performs the export is how the inversion
/// stays unwritable: there is no `WAYLAND_DISPLAY` export anywhere else, and no
/// other way to obtain a [`HostWaylandSocket`].
///
/// # Safety
///
/// The process must still be single-threaded. `std::env::set_var` is unsound
/// once it is not: a concurrent `getenv` anywhere, including inside a C library,
/// reads a pointer this write may free.
unsafe fn read_host_then_export_display(display: &DisplayName) -> HostWaylandSocket {
    let socket = host_wayland_socket(
        env::var_os(XDG_RUNTIME_DIR).as_deref(),
        env::var_os(WAYLAND_DISPLAY).as_deref(),
    );

    // SAFETY: the caller's guarantee, and the read above has already happened.
    unsafe { env::set_var(WAYLAND_DISPLAY, display.wayland()) };

    HostWaylandSocket(socket)
}

/// The host compositor's socket, from the two variables that name it.
///
/// `WAYLAND_DISPLAY` may be an absolute path, which the protocol permits and
/// which is taken as-is, or a name relative to `XDG_RUNTIME_DIR`. `None` when
/// there is no host Wayland session to reach; a machine at a bare TTY and an
/// X11-only session both leave it unset.
fn host_wayland_socket(runtime_dir: Option<&OsStr>, display: Option<&OsStr>) -> Option<PathBuf> {
    let display = PathBuf::from(display.filter(|display| !display.is_empty())?);
    if display.is_absolute() {
        return Some(display);
    }
    Some(absolute_path(runtime_dir.map(OsStr::to_owned))?.join(display))
}

/// The desktop's own keyboard layout, from the variables libxkbcommon reads.
///
/// The variables are read here, not left to libxkbcommon, for two reasons. A
/// library does not read the environment. A default naming several layouts has
/// to be narrowed to its first entry, and that needs the name it was written
/// under; libxkbcommon offers no way to ask a compiled keymap which RMLVO
/// layout produced it, so a keymap compiled from an empty name cannot be cut
/// down afterwards.
///
/// An unset or empty variable stays absent. That name then comes from
/// libxkbcommon's own compiled-in default, whose value the installation
/// controls.
fn keymap_defaults_from_environment() -> KeymapDefaults {
    fn name(variable: &str) -> Option<String> {
        env::var(variable).ok().filter(|value| !value.is_empty())
    }

    KeymapDefaults::new(KeymapConfig {
        rules: name(XKB_DEFAULT_RULES),
        model: name(XKB_DEFAULT_MODEL),
        layout: name(XKB_DEFAULT_LAYOUT),
        variant: name(XKB_DEFAULT_VARIANT),
        options: name(XKB_DEFAULT_OPTIONS),
    })
}

/// The environment values the state directory is resolved from.
#[derive(Debug)]
struct StateDirectorySources {
    /// `$XDG_STATE_HOME`, when it is set to an absolute path.
    xdg_state_home: Option<PathBuf>,
    /// `$HOME`, when it is set to an absolute path.
    home: Option<PathBuf>,
}

impl StateDirectorySources {
    fn from_environment() -> Self {
        Self {
            xdg_state_home: absolute_path(env::var_os(XDG_STATE_HOME)),
            home: absolute_path(env::var_os("HOME")),
        }
    }
}

/// Where lunette keeps what it records, not what it receives.
///
/// State is not configuration, so the state directory is not the configuration
/// directory: the portal's restore tokens are written by lunette, and the
/// configuration directory may be the read-only system one. There is no system
/// fallback for the same reason: a token belongs to one user's session.
///
/// The directory is not created here. `lunette_capture::tokens::write` writes
/// through a sibling temporary file and reports a directory it cannot write to,
/// which is the same failure as any other and is already handled as one.
fn state_directory(sources: &StateDirectorySources) -> Option<PathBuf> {
    sources
        .xdg_state_home
        .as_ref()
        .map(|state| state.join("lunette"))
        .or_else(|| {
            sources
                .home
                .as_ref()
                .map(|home| home.join(".local").join("state").join("lunette"))
        })
}

/// Where a client is told to find lunette's socket.
const WAYLAND_DISPLAY: &str = "WAYLAND_DISPLAY";

/// The AppImage runtime's own root, when lunette is running from one.
const APPDIR: &str = "APPDIR";

/// Where a relative `WAYLAND_DISPLAY` is resolved against, and where the control
/// socket's private directory is created.
const XDG_RUNTIME_DIR: &str = "XDG_RUNTIME_DIR";

/// The switch that turns the control socket off.
///
/// `lunctl` is equivalent to root access on the user's session, so an
/// evaluation endpoint must be possible to leave out. `off` is the only value
/// that disables it; `docs/dev/lua-api.md` states the rest.
const LUNETTE_CONTROL: &str = "LUNETTE_CONTROL";

/// The XDG base directory for what a program records, not what it receives.
const XDG_STATE_HOME: &str = "XDG_STATE_HOME";

/// The five names libxkbcommon resolves an unnamed layout from. A desktop
/// exports them for its session; NixOS writes `XKB_DEFAULT_LAYOUT` from
/// `services.xserver.xkb.layout`, and sway and Hyprland export it too.
const XKB_DEFAULT_RULES: &str = "XKB_DEFAULT_RULES";
const XKB_DEFAULT_MODEL: &str = "XKB_DEFAULT_MODEL";
const XKB_DEFAULT_LAYOUT: &str = "XKB_DEFAULT_LAYOUT";
const XKB_DEFAULT_VARIANT: &str = "XKB_DEFAULT_VARIANT";
const XKB_DEFAULT_OPTIONS: &str = "XKB_DEFAULT_OPTIONS";

/// The file the screencast portal's restore tokens are kept in.
const TOKEN_FILE: &str = "screencast-tokens.toml";

/// The two diagnostic settings for image import.
///
/// Neither the queue family an imported image is acquired from nor the layout it
/// is taken to be in is settled, and the point of measuring is to try the other
/// value without a rebuild. `crates/lunette/src/texture/mod.rs` documents what
/// each accepts; an unrecognised value falls back with a warning, and the
/// session keeps running.
const IMPORT_QUEUE_FAMILY: &str = "LUNETTE_IMPORT_QUEUE_FAMILY";
const IMPORT_LAYOUT: &str = "LUNETTE_IMPORT_LAYOUT";

/// The verbosity applied when `RUST_LOG` names none, or names something that
/// does not parse.
const DEFAULT_LOG_LEVEL: LevelFilter = LevelFilter::INFO;

/// The install-time prefix the module data is installed under.
///
/// A packager sets `LUNETTE_PREFIX` when building. The `Makefile` passes its
/// own `PREFIX` down, so a build and the install that follows it agree without
/// either being told twice. The default is the one the `Makefile` uses.
pub(crate) const PREFIX: &str = match option_env!("LUNETTE_PREFIX") {
    Some(path) => path,
    None => "/usr/local",
};

/// The development override for where the module data is read from.
///
/// Pointing it at a working tree is the whole development loop for `mullion`;
/// the override wins outright, because a first consultation could be shadowed
/// by an installed copy.
const STDLIB_PATH: &str = "LUNETTE_STDLIB_PATH";

/// The development override for which configuration directory is loaded.
///
/// It exists for the same reason [`STDLIB_PATH`] does: a working copy is not
/// on the search path. Pointing `$XDG_CONFIG_HOME` at one instead would reach
/// every client the session spawns, and each would then look for its own
/// configuration under it. Only lunette reads this one.
///
/// `--config-path` outranks it. A session started with the flag loads what the
/// flag says, whatever the environment holds.
const CONFIG_PATH: &str = "LUNETTE_CONFIG_PATH";

/// The install-time system configuration directory.
///
/// A packager sets `LUNETTE_SYSCONFDIR` when building. The default matches the
/// `/etc/xdg` fallback the XDG base directory specification names, so
/// `$SYSCONFDIR/xdg` resolves to that fallback for the usual prefix.
const SYSCONFDIR: &str = match option_env!("LUNETTE_SYSCONFDIR") {
    Some(path) => path,
    None => "/etc",
};

/// The values module-data resolution depends on.
///
/// Gathered here, keeping [`module_data_directory`] a pure function of its
/// inputs and the environment read in exactly one place. The same arrangement
/// [`ConfigDirectorySources`] uses, for the same reasons.
#[derive(Debug)]
struct ModuleDataSources {
    /// `$LUNETTE_STDLIB_PATH`, when it is set to something.
    override_path: Option<PathBuf>,
    /// The install-time prefix.
    prefix: PathBuf,
}

impl ModuleDataSources {
    fn from_environment() -> Self {
        Self {
            override_path: non_empty_path(env::var_os(STDLIB_PATH)),
            prefix: PathBuf::from(PREFIX),
        }
    }
}

/// Where the `mullion` module data is read from.
///
/// The precedence is stated, not left to the order things are mounted in:
/// `$LUNETTE_STDLIB_PATH` when it is set, and `$PREFIX/share/lunette/lua`
/// otherwise. A developer pointing the variable at a working tree is the whole
/// development loop for `mullion`, so a working tree has to win over an
/// installed copy, not be shadowed by one.
///
/// A relative override is taken as it stands and resolved by the process's
/// working directory. The XDG variables differ, because the specification
/// requires them to be absolute. `LUNETTE_STDLIB_PATH=lua cargo run` from the
/// source tree is exactly the case the relative form exists for.
///
/// There is no third candidate. `./lua` was considered, to let a build tree
/// work without the variable, and was not taken: it makes what a session
/// requires depend on the directory it was started from, a property no user can
/// see and no configuration can state.
fn module_data_directory(sources: &ModuleDataSources) -> PathBuf {
    sources
        .override_path
        .clone()
        .unwrap_or_else(|| sources.prefix.join("share").join("lunette").join("lua"))
}

/// Whether mounting the module data would ask PhysFS to mount the
/// configuration directory twice.
///
/// The paths are compared as supplied. The module-data override is allowed to
/// be relative, and canonicalising either path here would change
/// the documented resolution semantics; the duplicate-mount error would become
/// clearer, nothing else would change.
fn module_data_conflicts_with_configuration(config: &Path, module_data: &Path) -> bool {
    config == module_data
}

/// The environment values configuration-directory resolution depends on.
///
/// Gathered here, keeping [`config_directory_candidates`] a pure function of its
/// inputs and the environment read in exactly one place.
#[derive(Debug)]
struct ConfigDirectorySources {
    /// `$LUNETTE_CONFIG_PATH`, when it is set to something.
    ///
    /// Taken as it stands, not required to be absolute like the XDG variables:
    /// `LUNETTE_CONFIG_PATH=etc/xdg/lunette cargo run` from a working copy is
    /// the case it exists for. [`STDLIB_PATH`] gets the same latitude.
    override_path: Option<PathBuf>,
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
            override_path: non_empty_path(env::var_os(CONFIG_PATH)),
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
    let mut candidates = Vec::with_capacity(4);
    if let Some(override_path) = &sources.override_path {
        candidates.push(override_path.clone());
    }
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
/// candidate is used anyway, so boot.lua's own "no main.lua" message names the
/// directory the user is expected to create, not a system path they cannot
/// write to.
fn select_config_directory(candidates: &[PathBuf]) -> Option<&Path> {
    candidates
        .iter()
        .find(|candidate| candidate.is_dir())
        .or_else(|| candidates.first())
        .map(PathBuf::as_path)
}

/// The configuration directory a session loads, and `lunette check` checks
/// when it is given no paths.
///
/// An explicit directory is used as given, existing or not. Falling back to
/// the search path would load a configuration the user did not name, and
/// report the one they did as though it had been read.
fn config_directory<'a>(named: Option<&'a Path>, searched: &'a Path) -> &'a Path {
    named.unwrap_or(searched)
}

/// Accepts an environment value only when it names something.
fn non_empty_path(value: Option<OsString>) -> Option<PathBuf> {
    value.filter(|value| !value.is_empty()).map(PathBuf::from)
}

/// Resolves a path against the working directory when it is relative.
///
/// The standard-library override is allowed to be relative, so
/// `LUNETTE_STDLIB_PATH=lua` works from the source tree. A `.luaurc` carrying
/// that path verbatim would resolve against the reader's directory, not the
/// writer's, so the path is made absolute where it is written and nowhere else.
fn absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        return path.to_owned();
    }
    env::current_dir().map_or_else(|_| path.to_owned(), |current| current.join(path))
}

/// Accepts an environment value when it names an absolute path.
///
/// The XDG base directory specification requires a relative value to be treated
/// as unset, and an empty value is how a shell usually spells "not set".
fn absolute_path(value: Option<OsString>) -> Option<PathBuf> {
    let value = PathBuf::from(value?);
    value.is_absolute().then_some(value)
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::fs;

    use pretty_assertions::assert_eq;
    use tempfile::TempDir;

    use super::*;

    #[test]
    fn check_dispatch_selects_check_without_a_boot_path() {
        let command = cli::Command::Check {
            roots: vec![PathBuf::from("config.luau")],
            definitions: Some(PathBuf::from("definitions.luau")),
            old_solver: true,
        };

        let (roots, definitions, old_solver) =
            check_dispatch(Some(&command)).expect("the check command must be selected");
        assert_eq!(roots, [PathBuf::from("config.luau")]);
        assert_eq!(definitions, Some(Path::new("definitions.luau")));
        assert!(old_solver);
        assert!(check_dispatch(None).is_none());
    }

    /// A state directory holding a token file with `text` in it.
    fn state_with_tokens(text: &str) -> TempDir {
        let directory = TempDir::new().expect("a temporary directory can be created");
        std::fs::write(directory.path().join(TOKEN_FILE), text).expect("the file can be written");
        directory
    }

    #[test]
    fn a_token_file_this_version_wrote_is_read_and_may_be_written_back() {
        let directory = state_with_tokens(
            "version = 1\n\
             [[monitors]]\n\
             key = { descriptor = \"Acme X24\" }\n\
             token = \"kept\"\n",
        );

        let (store, file) = read_tokens(Some(directory.path()));

        assert_eq!(store.len(), 1);
        assert_eq!(
            file.map(|file| file.path().to_owned()),
            Some(directory.path().join(TOKEN_FILE)),
        );
    }

    #[test]
    fn no_token_file_yet_still_names_somewhere_to_write_one() {
        // The ordinary first run: nothing to read, and reason to be able to
        // record what the first grant returns.
        let directory = TempDir::new().expect("a temporary directory can be created");

        let (store, file) = read_tokens(Some(directory.path()));

        assert!(store.is_empty());
        assert!(file.is_some());
    }

    #[test]
    fn a_token_file_from_a_later_version_is_neither_read_nor_writable() {
        // The case corrupts; it does not fail cleanly: rendering this version's
        // fields over it would drop the ones this version does not know about.
        let directory = state_with_tokens(
            "version = 2\n\
             [[monitors]]\n\
             key = { descriptor = \"Acme X24\" }\n\
             token = \"kept\"\n\
             something-later-versions-have = true\n",
        );

        let (store, file) = read_tokens(Some(directory.path()));

        assert!(store.is_empty());
        assert_eq!(file, None);
    }

    #[test]
    fn a_token_file_this_version_cannot_parse_is_left_alone() {
        // Including a file at this version carrying a field this version does
        // not know, which `deny_unknown_fields` refuses: it is either a typo or
        // a field a later version added without bumping, and writing over
        // either discards whatever it held.
        for text in [
            "this is not toml {{{",
            "version = 1\n\
             [[monitors]]\n\
             key = { descriptor = \"Acme X24\" }\n\
             token = \"kept\"\n\
             typoed = 3\n",
        ] {
            let directory = state_with_tokens(text);

            let (store, file) = read_tokens(Some(directory.path()));

            assert!(store.is_empty(), "{text}");
            assert_eq!(file, None, "{text}");
        }
    }

    #[test]
    fn with_no_state_directory_there_is_nothing_to_read_and_nowhere_to_write() {
        let (store, file) = read_tokens(None);

        assert!(store.is_empty());
        assert_eq!(file, None);
    }

    fn state_sources(xdg_state_home: Option<&str>, home: Option<&str>) -> StateDirectorySources {
        StateDirectorySources {
            xdg_state_home: xdg_state_home.map(PathBuf::from),
            home: home.map(PathBuf::from),
        }
    }

    fn socket(runtime_dir: Option<&str>, display: Option<&str>) -> Option<PathBuf> {
        host_wayland_socket(runtime_dir.map(OsStr::new), display.map(OsStr::new))
    }

    #[test]
    fn a_relative_wayland_display_resolves_against_the_runtime_directory() {
        assert_eq!(
            socket(Some("/run/user/1000"), Some("wayland-1")),
            Some(PathBuf::from("/run/user/1000/wayland-1")),
        );
    }

    #[test]
    fn an_absolute_wayland_display_is_taken_as_it_stands() {
        // The protocol permits it, and a session that uses it has no reason to
        // set XDG_RUNTIME_DIR to anything in particular.
        assert_eq!(
            socket(None, Some("/tmp/custom/wayland-9")),
            Some(PathBuf::from("/tmp/custom/wayland-9")),
        );
    }

    #[test]
    fn no_wayland_display_names_no_host_socket() {
        // A bare TTY, and an X11-only session. Both are ordinary, and both mean
        // lunette can see none of the host's screens.
        assert_eq!(socket(Some("/run/user/1000"), None), None);
        assert_eq!(socket(Some("/run/user/1000"), Some("")), None);
    }

    #[test]
    fn a_relative_wayland_display_with_no_runtime_directory_names_nothing() {
        // There is nothing to resolve it against, and guessing /run/user/$UID
        // would connect to a socket the session did not name.
        assert_eq!(socket(None, Some("wayland-1")), None);
        assert_eq!(socket(Some("relative"), Some("wayland-1")), None);
    }

    #[test]
    fn the_state_directory_prefers_xdg_state_home() {
        assert_eq!(
            state_directory(&state_sources(Some("/state"), Some("/home/user"))),
            Some(PathBuf::from("/state/lunette")),
        );
    }

    #[test]
    fn the_state_directory_falls_back_to_the_xdg_default_under_home() {
        assert_eq!(
            state_directory(&state_sources(None, Some("/home/user"))),
            Some(PathBuf::from("/home/user/.local/state/lunette")),
        );
    }

    #[test]
    fn no_state_directory_is_representable() {
        // There is no system fallback, unlike the configuration directory: a
        // restore token belongs to one user's session.
        assert_eq!(state_directory(&state_sources(None, None)), None);
    }

    fn module_data(override_path: Option<&str>, prefix: &str) -> PathBuf {
        module_data_directory(&ModuleDataSources {
            override_path: override_path.map(PathBuf::from),
            prefix: PathBuf::from(prefix),
        })
    }

    #[test]
    fn module_data_defaults_to_the_compiled_in_prefix() {
        assert_eq!(
            module_data(None, "/usr/local"),
            PathBuf::from("/usr/local/share/lunette/lua"),
        );
    }

    #[test]
    fn the_module_data_override_wins_over_the_prefix() {
        // The whole development loop for mullion: a working tree beats an
        // installed copy without being shadowed by one.
        assert_eq!(
            module_data(Some("/src/lunette/lua"), "/usr"),
            PathBuf::from("/src/lunette/lua"),
        );
    }

    #[test]
    fn a_relative_module_data_override_is_taken_as_it_stands() {
        // A relative override is taken as it stands, unlike the XDG variables,
        // which the specification requires to be absolute. `LUNETTE_STDLIB_PATH=lua
        // cargo run` is the case it exists for.
        assert_eq!(module_data(Some("lua"), "/usr"), PathBuf::from("lua"));
    }

    #[test]
    fn the_configuration_directory_cannot_also_be_the_module_data() {
        let directory = Path::new("/tmp/lunette");

        assert!(module_data_conflicts_with_configuration(
            directory, directory
        ));
        assert!(!module_data_conflicts_with_configuration(
            directory,
            Path::new("/tmp/lunette/lua"),
        ));
        assert!(!module_data_conflicts_with_configuration(
            directory,
            Path::new("/tmp/other/lunette"),
        ));
    }

    #[test]
    fn an_empty_override_counts_as_unset() {
        // How a shell usually spells "not set". Taken literally it would mount
        // the current working directory, silently.
        assert_eq!(non_empty_path(Some(OsString::new())), None);
        assert_eq!(non_empty_path(None), None);
        assert_eq!(
            non_empty_path(Some(OsString::from("lua"))),
            Some(PathBuf::from("lua"))
        );
    }

    fn sources(xdg_config_home: Option<&str>, home: Option<&str>) -> ConfigDirectorySources {
        ConfigDirectorySources {
            override_path: None,
            xdg_config_home: xdg_config_home.map(PathBuf::from),
            home: home.map(PathBuf::from),
            sysconfdir: PathBuf::from("/etc"),
        }
    }

    /// The override wins, and the rest stay behind it: a session pointed at a
    /// working copy still falls back to the installed configuration if the
    /// working copy has none.
    #[test]
    fn the_override_outranks_every_other_candidate() {
        let sources = ConfigDirectorySources {
            override_path: Some(PathBuf::from("etc/xdg/lunette")),
            ..sources(Some("/xdg"), Some("/home/user"))
        };

        assert_eq!(
            config_directory_candidates(&sources),
            vec![
                PathBuf::from("etc/xdg/lunette"),
                PathBuf::from("/xdg/lunette"),
                PathBuf::from("/home/user/.config/lunette"),
                PathBuf::from("/etc/xdg/lunette"),
            ]
        );
    }

    /// A relative override is taken as it stands, unlike the XDG variables,
    /// which are ignored unless absolute. `LUNETTE_CONFIG_PATH=etc/xdg/lunette`
    /// from a working copy is the case it exists for.
    #[test]
    fn a_relative_configuration_override_is_taken_as_it_stands() {
        let sources = ConfigDirectorySources {
            override_path: Some(PathBuf::from("etc/xdg/lunette")),
            ..sources(None, None)
        };

        assert_eq!(
            config_directory_candidates(&sources).first(),
            Some(&PathBuf::from("etc/xdg/lunette"))
        );
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

    /// `lunette check` with no paths reads the directory a session would
    /// load: the first existing candidate, unless `--config-path` names one.
    #[test]
    fn check_without_paths_reads_the_configuration_a_session_would_load() {
        let xdg = TempDir::new().expect("a temporary directory");
        let home = TempDir::new().expect("a temporary directory");
        let configuration = home.path().join(".config").join("lunette");
        fs::create_dir_all(&configuration).expect("the configuration directory");
        fs::write(configuration.join("main.lua"), "").expect("main.lua");

        // `$XDG_CONFIG_HOME/lunette` is not there, so the search passes it.
        let candidates =
            config_directory_candidates(&sources(xdg.path().to_str(), home.path().to_str()));
        let searched = select_config_directory(&candidates).expect("a candidate");
        let checked = check::targets(&[], config_directory(None, searched)).expect("the files");
        assert_eq!(checked, vec![configuration.join("main.lua")]);

        let named = xdg.path().join("named");
        fs::create_dir_all(&named).expect("the named directory");
        fs::write(named.join("main.lua"), "").expect("main.lua");
        let checked =
            check::targets(&[], config_directory(Some(&named), searched)).expect("the files");
        assert_eq!(checked, vec![named.join("main.lua")]);
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
