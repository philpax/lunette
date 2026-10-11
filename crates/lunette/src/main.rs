//! Linux-only: the lunette binary, which boots LÖVR, runs the Lua session, and orchestrates the compositor and capture subsystems.
//! The binary is the sole environment reader and `tracing` subscriber owner.

mod boot;
mod check;
mod cli;

use std::{
    env,
    ffi::{OsStr, OsString},
    io, iter,
    path::{self, Path, PathBuf},
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
    clipboard::DataControlSource,
    hid::{self, HidConfig, XkbKeymap},
    mirror::{MirrorSet, NoNodeWatch, NodeWatch, PipewireNodeWatch, screencopy::WlxClient},
    monitor::OutputWatcher,
    portal::{
        CursorPolicy, PortalError, RequestId, RequestProgress, ScreenCastPortal, SessionRequest,
        WlxPortal,
    },
    tokens::{self, Loaded, TokenFile},
};
use lunette_compositor::{
    keymap::Keymap,
    listener::listen,
    protocol::{KeymapConfig, KeymapDefaults},
    satellite::XwaylandSatellite,
};
use tracing::{error, info, warn};
use tracing_subscriber::{EnvFilter, filter::LevelFilter};

fn main() -> ExitCode {
    // Delay reporting until the subscriber can emit the parse error.
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

    if let Some(cli::Command::CheckAnnotations { roots }) = &arguments.command {
        return check::run_annotations(roots);
    }

    let candidates = ConfigDirectoryCandidates::new(&ConfigDirectorySources::from_environment());
    // A check given no paths checks the directory a session would load.
    let config_directory = arguments
        .config_path
        .as_deref()
        .unwrap_or_else(|| candidates.select());

    if let Some(cli::Command::Check { roots, definitions }) = &arguments.command {
        return check::run(roots, config_directory, definitions.as_deref());
    }

    let module_data = module_data_directory(&ModuleDataSources::from_environment());

    if let Some(destination) = &arguments.dump_config {
        let destination = if destination.as_os_str().is_empty() {
            candidates.highest()
        } else {
            destination.as_path()
        };

        // Absolute, because readers may use another working directory.
        let module_data = path::absolute(&module_data).unwrap_or(module_data);
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

    info!(path = %config_directory.display(), "loading the configuration");

    // Both directories are PhysFS mount points, which cannot coincide.
    if config_directory == module_data {
        error!(
            "config: the module-data path {} is also the configuration directory; the two directories cannot be mounted separately",
            module_data.display()
        );
        return ExitCode::FAILURE;
    }
    info!(path = %module_data.display(), "mounting the module data");

    let state_directory = state_directory(&StateDirectorySources::from_environment());
    let keymap_defaults = keymap_defaults_from_environment();

    // SAFETY: no application worker has started, and nothing above spawns threads.
    let host_socket = unsafe { prepare_host_display() };

    // Bind before LÖVR starts. Failure disables `lunctl` but does not stop the session.
    let control = match absolute_path(env::var_os(XDG_RUNTIME_DIR)) {
        Some(runtime_directory) => {
            // Lossy conversion keeps non-UTF-8 settings distinct from unset.
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
    let (_control_thread, chunks) = match control {
        Some((thread, queue)) => (Some(thread), Some(queue)),
        None => (None, None),
    };

    let (socket, name) = match listen() {
        Ok(bound) => bound,
        Err(error) => {
            error!("{error}");
            return ExitCode::FAILURE;
        }
    };

    info!(
        "connect a client from outside with WAYLAND_DISPLAY={}",
        name.wayland_display_num_string()
    );

    let (mirrors, sinks, desktop): (
        Rc<dyn MirrorRegistry>,
        Rc<dyn HostSinks>,
        Option<HostDesktop>,
    ) = match host_socket
        .as_deref()
        .and_then(|socket| open_host(socket, state_directory.as_deref(), &keymap_defaults))
    {
        Some(host) => (
            Rc::clone(&host.mirrors) as _,
            Rc::clone(&host.pointer) as _,
            Some(HostDesktop {
                outputs: host.outputs,
                capture_client: upstream_capture_client,
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
        // A missing bridge serves Wayland clients only without a warning.
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
        clipboard: host_socket.as_deref().map(DataControlSource::new),
        keymap_defaults,
    };

    // SAFETY: this thread owns the headset module for the process lifetime.
    let backend = unsafe { LovrLayers::new() };

    // The layer pool outlives Lua states so a restart preserves panel assignments.
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

struct AvailablePortal(Result<WlxPortal, PortalError>);

impl ScreenCastPortal for AvailablePortal {
    fn begin(&mut self, request: SessionRequest) -> Result<RequestId, PortalError> {
        match &mut self.0 {
            Ok(portal) => portal.begin(request),
            Err(error) => Err(error.clone()),
        }
    }

    fn poll(&mut self, request: RequestId) -> RequestProgress {
        match &mut self.0 {
            Ok(portal) => portal.poll(request),
            Err(error) => RequestProgress::Failed(error.clone()),
        }
    }
}

/// Host desktop resources shared by the Lua session and frame loop.
struct Host {
    mirrors: Rc<HostMirrors<AvailablePortal>>,
    pointer: Rc<HostPointer>,
    outputs: OutputWatcher,
    tokens: Option<TokenFile>,
}

/// Opens host monitor capture and input. Returns `None` when host outputs or the portal are unavailable.
fn open_host(
    socket: &Path,
    state_directory: Option<&Path>,
    keymap_defaults: &KeymapDefaults,
) -> Option<Host> {
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

    let portal = AvailablePortal(WlxPortal::connect().inspect_err(|error| {
        warn!("{error}; portal fallback is unavailable; direct capture remains available");
    }));
    // Without a portal there is no session whose end needs noticing.
    let nodes = if portal.0.is_ok() {
        watch_portal_nodes()
    } else {
        Box::new(NoNodeWatch)
    };

    let (stored, tokens) = read_tokens(state_directory);

    let input = hid::open(&HidConfig {
        host_socket: Some(socket.to_owned()),
        keymap: default_seat_keymap(keymap_defaults),
    });
    if let Some(error) = input.unreachable() {
        warn!("{error}");
    }

    // Keep startup outputs pending so the first poll emits `lovr.lunmonitoradded` for each.
    info!(
        monitors = outputs.outputs().len(),
        provider = %input.kind(),
        "the host desktop is reachable",
    );

    Some(Host {
        mirrors: Rc::new(HostMirrors::new(
            MirrorSet::new(portal, CursorPolicy::Visible, stored).with_node_watch(nodes),
        )),
        pointer: Rc::new(HostPointer::new(input)),
        outputs,
        tokens,
    })
}

/// Watches PipeWire for the removal of portal nodes, which is how a portal session that ends is
/// noticed.
fn watch_portal_nodes() -> Box<dyn NodeWatch> {
    match PipewireNodeWatch::start() {
        Ok(watch) => Box::new(watch),
        Err(error) => {
            warn!(
                "{error}; a portal session that the user stops leaves its monitors marked as \
                 mirrored with no frames"
            );
            Box::new(NoNodeWatch)
        }
    }
}

/// The layout the default seat compiles, which `wl_virtual` uploads when it opens.
///
/// `zwp_virtual_keyboard_v1` disconnects a client that sends a key before a keymap, so the
/// provider needs one before any seat exists. The default seat's layout is the one a host
/// keystroke most often carries, so its first keystroke uploads nothing further. Returns `None`
/// when the layout does not compile, which leaves `wl_virtual` unconfigured.
fn default_seat_keymap(defaults: &KeymapDefaults) -> Option<XkbKeymap> {
    match Keymap::compile(&KeymapConfig::default(), defaults) {
        Ok(keymap) => XkbKeymap::new(keymap.text().as_str()),
        Err(error) => {
            warn!("{error}; the virtual keyboard has no layout, so wl_virtual cannot open");
            None
        }
    }
}

/// Loads restore tokens and returns a write handle only for compatible data.
///
/// A file from a later version stays untouched, preserving fields older code does not know.
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

/// Resolves the host socket and removes the inherited descriptor override.
///
/// The pinned client's constructor would otherwise remove `WAYLAND_SOCKET` after workers have started.
///
/// # Safety
///
/// The process must be single-threaded, because a concurrent environment read can access memory freed by `std::env::remove_var`.
unsafe fn prepare_host_display() -> Option<PathBuf> {
    let socket = host_wayland_socket(
        env::var_os(XDG_RUNTIME_DIR).as_deref(),
        env::var_os(WAYLAND_DISPLAY).as_deref(),
    );

    // SAFETY: the caller guarantees single-threaded startup.
    unsafe { env::remove_var("WAYLAND_SOCKET") };

    socket
}

/// Constructs the pinned environment-based client at the application boundary.
fn upstream_capture_client() -> Option<WlxClient> {
    // Startup removes WAYLAND_SOCKET, so connect_to_env only reads the environment. Missing upstream globals panic, and setup falls back to the portal.
    std::panic::catch_unwind(WlxClient::new).unwrap_or_else(|_| {
        warn!("direct capture: the upstream host client could not initialize");
        None
    })
}

/// Resolves an absolute `WAYLAND_DISPLAY` path or a name relative to `XDG_RUNTIME_DIR`.
fn host_wayland_socket(runtime_dir: Option<&OsStr>, display: Option<&OsStr>) -> Option<PathBuf> {
    let display = PathBuf::from(display.filter(|display| !display.is_empty())?);
    if display.is_absolute() {
        return Some(display);
    }
    Some(absolute_path(runtime_dir.map(OsStr::to_owned))?.join(display))
}

/// Reads libxkbcommon's layout variables at the application boundary.
///
/// An unset or empty value stays absent so libxkbcommon uses its default. The names are kept because the compiled keymap does not expose its RMLVO source.
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

/// Resolves the per-user directory for screencast restore tokens.
///
/// The configuration directory may be read-only, and restore tokens belong to one user's session.
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

const WAYLAND_DISPLAY: &str = "WAYLAND_DISPLAY";

const APPDIR: &str = "APPDIR";

const XDG_RUNTIME_DIR: &str = "XDG_RUNTIME_DIR";

/// Disables the control socket when set to `off`. The socket evaluates Lua with session access.
const LUNETTE_CONTROL: &str = "LUNETTE_CONTROL";

const XDG_STATE_HOME: &str = "XDG_STATE_HOME";

const XKB_DEFAULT_RULES: &str = "XKB_DEFAULT_RULES";
const XKB_DEFAULT_MODEL: &str = "XKB_DEFAULT_MODEL";
const XKB_DEFAULT_LAYOUT: &str = "XKB_DEFAULT_LAYOUT";
const XKB_DEFAULT_VARIANT: &str = "XKB_DEFAULT_VARIANT";
const XKB_DEFAULT_OPTIONS: &str = "XKB_DEFAULT_OPTIONS";

/// The file the screencast portal's restore tokens are kept in.
const TOKEN_FILE: &str = "screencast-tokens.toml";

/// Diagnostic settings for imported-image queue family and layout. Invalid values warn and use defaults.
const IMPORT_QUEUE_FAMILY: &str = "LUNETTE_IMPORT_QUEUE_FAMILY";
const IMPORT_LAYOUT: &str = "LUNETTE_IMPORT_LAYOUT";

/// The verbosity applied when `RUST_LOG` names none, or names something that does not parse.
const DEFAULT_LOG_LEVEL: LevelFilter = LevelFilter::INFO;

/// Module-data install prefix supplied by the build.
pub(crate) const PREFIX: &str = match option_env!("LUNETTE_PREFIX") {
    Some(path) => path,
    None => "/usr/local",
};

/// Overrides the installed Lua module data path.
const STDLIB_PATH: &str = "LUNETTE_STDLIB_PATH";

/// Overrides the configuration path. `--config-path` takes precedence.
const CONFIG_PATH: &str = "LUNETTE_CONFIG_PATH";

/// System configuration directory supplied by the build.
const SYSCONFDIR: &str = match option_env!("LUNETTE_SYSCONFDIR") {
    Some(path) => path,
    None => "/etc",
};

/// Inputs for resolving the module-data directory.
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

/// Resolves module data from `$LUNETTE_STDLIB_PATH` or `$PREFIX/share/lunette/lua`.
///
/// The override may be relative to the working directory. There is no `./lua` fallback, because it would make resolution depend on the launch directory.
fn module_data_directory(sources: &ModuleDataSources) -> PathBuf {
    sources
        .override_path
        .clone()
        .unwrap_or_else(|| sources.prefix.join("share").join("lunette").join("lua"))
}

/// Inputs for resolving configuration-directory candidates.
#[derive(Debug)]
struct ConfigDirectorySources {
    /// `$LUNETTE_CONFIG_PATH`, which may be relative to the process working directory.
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

/// Configuration directories in precedence order, ending with the always-present system directory.
#[derive(Debug)]
struct ConfigDirectoryCandidates {
    user: Vec<PathBuf>,
    system: PathBuf,
}

impl ConfigDirectoryCandidates {
    fn new(sources: &ConfigDirectorySources) -> Self {
        let user = [
            sources.override_path.clone(),
            sources
                .xdg_config_home
                .as_ref()
                .map(|xdg_config_home| xdg_config_home.join("lunette")),
            sources
                .home
                .as_ref()
                .map(|home| home.join(".config").join("lunette")),
        ];
        Self {
            user: user.into_iter().flatten().collect(),
            system: sources.sysconfdir.join("xdg").join("lunette"),
        }
    }

    fn iter(&self) -> impl Iterator<Item = &Path> {
        self.user
            .iter()
            .map(PathBuf::as_path)
            .chain(iter::once(self.system.as_path()))
    }

    fn highest(&self) -> &Path {
        self.user.first().unwrap_or(&self.system)
    }

    /// The first existing candidate, or the highest-priority candidate when none exists.
    fn select(&self) -> &Path {
        self.iter()
            .find(|candidate| candidate.is_dir())
            .unwrap_or_else(|| self.highest())
    }
}

/// Accepts an environment value only when it names something.
fn non_empty_path(value: Option<OsString>) -> Option<PathBuf> {
    value.filter(|value| !value.is_empty()).map(PathBuf::from)
}

/// Returns an environment path only when it is absolute, as required by XDG.
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
    fn wl_virtual_is_given_the_layout_the_default_seat_compiles() {
        let defaults = KeymapDefaults::new(KeymapConfig {
            layout: Some("de".to_owned()),
            ..KeymapConfig::default()
        });
        let seat = Keymap::compile(&KeymapConfig::default(), &defaults)
            .expect("the default seat's layout compiles");

        let uploaded = default_seat_keymap(&defaults).expect("a layout to upload");

        assert_eq!(
            uploaded.as_str(),
            seat.text().as_str(),
            "the default seat's first host keystroke would upload its layout again",
        );
    }

    #[test]
    fn a_desktop_layout_that_does_not_compile_leaves_wl_virtual_without_one() {
        let defaults = KeymapDefaults::new(KeymapConfig {
            layout: Some("this-is-not-a-layout".to_owned()),
            ..KeymapConfig::default()
        });

        assert_eq!(default_seat_keymap(&defaults), None);
    }

    /// `lunette-capture`'s token tests cover the version matrix. This covers what a session
    /// makes of a read that fails, a missing file, and a missing state directory.
    #[test]
    fn a_token_file_is_writable_only_when_it_was_read_or_is_absent() {
        // A first run needs somewhere to record what the first grant returns.
        let directory = TempDir::new().expect("a temporary directory can be created");
        let (store, file) = read_tokens(Some(directory.path()));
        assert!(store.is_empty());
        assert_eq!(
            file.map(|file| file.path().to_owned()),
            Some(directory.path().join(TOKEN_FILE)),
        );

        // Writing over a file that could not be read discards what it holds.
        fs::write(directory.path().join(TOKEN_FILE), "this is not toml {{{")
            .expect("the file can be written");
        let (store, file) = read_tokens(Some(directory.path()));
        assert!(store.is_empty());
        assert_eq!(file, None);

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
    fn the_host_socket_is_named_by_the_runtime_directory_and_display() {
        assert_eq!(
            socket(Some("/run/user/1000"), Some("wayland-1")),
            Some(PathBuf::from("/run/user/1000/wayland-1")),
        );
        // The protocol permits an absolute display, which is taken as it stands.
        assert_eq!(
            socket(None, Some("/tmp/custom/wayland-9")),
            Some(PathBuf::from("/tmp/custom/wayland-9")),
        );
        // A bare TTY or an X11-only session has no socket to name.
        assert_eq!(socket(Some("/run/user/1000"), None), None);
        assert_eq!(socket(Some("/run/user/1000"), Some("")), None);
        // Guessing /run/user/$UID would connect to a socket the session did not name.
        assert_eq!(socket(None, Some("wayland-1")), None);
        assert_eq!(socket(Some("relative"), Some("wayland-1")), None);
        assert_eq!(socket(Some(""), Some("wayland-1")), None);
    }

    #[test]
    fn the_state_directory_prefers_xdg_state_home_and_has_no_system_fallback() {
        assert_eq!(
            state_directory(&state_sources(Some("/state"), Some("/home/user"))),
            Some(PathBuf::from("/state/lunette")),
        );
        assert_eq!(
            state_directory(&state_sources(None, Some("/home/user"))),
            Some(PathBuf::from("/home/user/.local/state/lunette")),
        );
        // A restore token belongs to one user's session, so there is no system fallback.
        assert_eq!(state_directory(&state_sources(None, None)), None);
    }

    fn module_data(override_path: Option<&str>, prefix: &str) -> PathBuf {
        module_data_directory(&ModuleDataSources {
            override_path: override_path.map(PathBuf::from),
            prefix: PathBuf::from(prefix),
        })
    }

    #[test]
    fn module_data_is_the_override_when_set_and_the_prefix_otherwise() {
        assert_eq!(
            module_data(None, "/usr/local"),
            PathBuf::from("/usr/local/share/lunette/lua"),
        );
        // A working tree beats an installed copy without being shadowed by one.
        assert_eq!(
            module_data(Some("/src/lunette/lua"), "/usr"),
            PathBuf::from("/src/lunette/lua"),
        );
        // A relative override is taken as it stands, unlike the XDG variables,
        // which the specification requires to be absolute.
        assert_eq!(module_data(Some("lua"), "/usr"), PathBuf::from("lua"));
        // An empty override means unset. Taken literally it would mount the working directory.
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

    fn candidates(sources: &ConfigDirectorySources) -> Vec<PathBuf> {
        ConfigDirectoryCandidates::new(sources)
            .iter()
            .map(Path::to_path_buf)
            .collect()
    }

    #[test]
    fn configuration_candidates_are_listed_in_priority_order() {
        // A session pointed at a working copy still falls back to the installed configuration.
        let overridden = ConfigDirectorySources {
            override_path: Some(PathBuf::from("etc/xdg/lunette")),
            ..sources(Some("/xdg"), Some("/home/user"))
        };
        assert_eq!(
            candidates(&overridden),
            vec![
                Path::new("etc/xdg/lunette"),
                Path::new("/xdg/lunette"),
                Path::new("/home/user/.config/lunette"),
                Path::new("/etc/xdg/lunette"),
            ]
        );

        // A relative override is taken as it stands, unlike the XDG variables,
        // which are ignored unless absolute.
        let relative = ConfigDirectorySources {
            override_path: Some(PathBuf::from("etc/xdg/lunette")),
            ..sources(None, None)
        };
        assert_eq!(
            ConfigDirectoryCandidates::new(&relative).highest(),
            Path::new("etc/xdg/lunette")
        );

        assert_eq!(
            candidates(&sources(Some("/xdg"), Some("/home/user"))),
            vec![
                Path::new("/xdg/lunette"),
                Path::new("/home/user/.config/lunette"),
                Path::new("/etc/xdg/lunette"),
            ]
        );
        assert_eq!(
            candidates(&sources(None, Some("/home/user"))),
            vec![
                Path::new("/home/user/.config/lunette"),
                Path::new("/etc/xdg/lunette"),
            ]
        );
        assert_eq!(
            candidates(&sources(None, None)),
            vec![Path::new("/etc/xdg/lunette")]
        );
    }

    #[test]
    fn selection_falls_back_to_the_highest_priority_candidate() {
        let candidates = ConfigDirectoryCandidates::new(&ConfigDirectorySources {
            sysconfdir: PathBuf::from("/nor/is/this"),
            ..sources(
                Some("/definitely/not/a/directory"),
                Some("/also/not/a/directory"),
            )
        });
        assert_eq!(
            candidates.select(),
            Path::new("/definitely/not/a/directory/lunette")
        );
    }

    /// `lunette check` with no paths reads the directory a session would load.
    #[test]
    fn check_without_paths_reads_the_configuration_a_session_would_load() {
        let xdg = TempDir::new().expect("a temporary directory");
        let home = TempDir::new().expect("a temporary directory");
        let configuration = home.path().join(".config").join("lunette");
        fs::create_dir_all(&configuration).expect("the configuration directory");
        fs::write(configuration.join("main.luau"), "").expect("main.luau");

        // `$XDG_CONFIG_HOME/lunette` is not there, so the search passes it.
        let candidates =
            ConfigDirectoryCandidates::new(&sources(xdg.path().to_str(), home.path().to_str()));
        let checked = check::targets(&[], candidates.select()).expect("the files");
        assert_eq!(checked, vec![configuration.join("main.luau")]);
    }
}
