//! Linux-only: the lunette binary, which boots LÖVR, runs the Lua session, and
//! orchestrates the compositor and capture subsystems.
//!
//! The binary is the sole environment reader and `tracing` subscriber owner. It
//! retains the host's `WAYLAND_DISPLAY` for the pinned capture client and removes
//! `WAYLAND_SOCKET` before any worker starts. Hosted applications receive lunette's
//! display settings explicitly from the compositor's spawner.

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
    hid::{self, HidConfig},
    mirror::{MirrorSet, screencopy::WlxClient},
    monitor::OutputWatcher,
    portal::{
        CursorPolicy, PortalError, RequestId, RequestProgress, ScreenCastPortal, SessionRequest,
        WlxPortal,
    },
    tokens::{self, Loaded, TokenFile},
};
use lunette_compositor::{
    client::{XwaylandSatellite, listen},
    protocol::{KeymapConfig, KeymapDefaults},
    selection::DataControlSource,
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

        // The copied `.luaurc` names the module data absolutely, because readers may use another
        // working directory.
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

    // SAFETY: no application worker has started. The logging subscriber and
    // configuration resolution above do not spawn threads.
    let host_socket = unsafe { prepare_host_display() };

    // Bind before LÖVR starts. Failure disables `lunctl` but does not stop the session.
    let control = match absolute_path(env::var_os(XDG_RUNTIME_DIR)) {
        Some(runtime_directory) => {
            // Non-UTF-8 settings do not equal `on`. Lossy conversion keeps them distinct from
            // unset.
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
        name.wayland().to_string_lossy()
    );

    let (mirrors, sinks, desktop): (
        Rc<dyn MirrorRegistry>,
        Rc<dyn HostSinks>,
        Option<HostDesktop>,
    ) = match host_socket
        .as_deref()
        .and_then(|socket| open_host(socket, state_directory.as_deref()))
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
        keymap_defaults: keymap_defaults_from_environment(),
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

/// Opens host monitor capture and input. Returns `None` when host outputs or the portal are
/// unavailable; the session can still serve Wayland clients without host integration.
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

    let portal = AvailablePortal(WlxPortal::connect().inspect_err(|error| {
        warn!("{error}; portal fallback is unavailable; direct capture remains available");
    }));

    let (stored, tokens) = read_tokens(state_directory);

    // `wl_virtual` requires an uploaded keymap before its first keystroke. Without a keymap
    // builder, the provider falls back to uinput.
    let input = hid::open(&HidConfig::default());
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
        mirrors: Rc::new(HostMirrors::new(MirrorSet::new(
            portal,
            CursorPolicy::Visible,
            stored,
        ))),
        pointer: Rc::new(HostPointer::new(input)),
        outputs,
        tokens,
    })
}

/// Loads restore tokens and returns a write handle only for compatible data.
///
/// Files from a later version remain untouched, preserving fields that older code does not know.
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
/// The pinned client's constructor connects through the retained host display.
/// Removing `WAYLAND_SOCKET` here prevents its later constructor from mutating
/// the environment after application workers have started.
///
/// # Safety
///
/// The process must be single-threaded. A concurrent environment read can access
/// memory freed by `std::env::remove_var`.
unsafe fn prepare_host_display() -> Option<PathBuf> {
    let socket = host_wayland_socket(
        env::var_os(XDG_RUNTIME_DIR).as_deref(),
        env::var_os(WAYLAND_DISPLAY).as_deref(),
    );

    // SAFETY: the caller guarantees single-threaded startup. Upstream's constructor
    // removes WAYLAND_SOCKET when present, so remove it before any worker exists.
    // Hosted clients receive lunette's display explicitly through the spawner.
    unsafe { env::remove_var("WAYLAND_SOCKET") };

    socket
}

/// Constructs the pinned environment-based client at the application boundary.
fn upstream_capture_client() -> Option<WlxClient> {
    // Startup removes WAYLAND_SOCKET, so connect_to_env only reads the environment.
    // Missing required upstream globals currently panic; setup falls back to the portal.
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
/// An unset or empty value remains absent so libxkbcommon uses its compiled-in default. The names
/// are retained because the compiled keymap does not expose which RMLVO layout produced it.
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
/// The token writer creates files through a sibling temporary file and reports write failures.
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

/// Diagnostic settings for imported-image queue family and layout. Invalid values warn and use
/// defaults.
const IMPORT_QUEUE_FAMILY: &str = "LUNETTE_IMPORT_QUEUE_FAMILY";
const IMPORT_LAYOUT: &str = "LUNETTE_IMPORT_LAYOUT";

/// The verbosity applied when `RUST_LOG` names none, or names something that
/// does not parse.
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
/// The override takes precedence and may be relative to the process working directory. There is no
/// `./lua` fallback because it would make module resolution depend on the launch directory.
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

/// Configuration directories in precedence order, ending with the system directory, which is
/// always present.
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
        // Writing an older schema would discard fields from the newer file.
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
        // The development loop for the Lua module roots: a working tree beats
        // an installed copy without being shadowed by one.
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

    fn candidates(sources: &ConfigDirectorySources) -> Vec<PathBuf> {
        ConfigDirectoryCandidates::new(sources)
            .iter()
            .map(Path::to_path_buf)
            .collect()
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
            candidates(&sources),
            vec![
                Path::new("etc/xdg/lunette"),
                Path::new("/xdg/lunette"),
                Path::new("/home/user/.config/lunette"),
                Path::new("/etc/xdg/lunette"),
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
            ConfigDirectoryCandidates::new(&sources).highest(),
            Path::new("etc/xdg/lunette")
        );
    }

    #[test]
    fn all_three_candidates_appear_in_priority_order() {
        assert_eq!(
            candidates(&sources(Some("/xdg"), Some("/home/user"))),
            vec![
                Path::new("/xdg/lunette"),
                Path::new("/home/user/.config/lunette"),
                Path::new("/etc/xdg/lunette"),
            ]
        );
    }

    #[test]
    fn an_unset_variable_drops_its_candidate() {
        assert_eq!(
            candidates(&sources(None, Some("/home/user"))),
            vec![
                Path::new("/home/user/.config/lunette"),
                Path::new("/etc/xdg/lunette"),
            ]
        );
    }

    #[test]
    fn the_system_candidate_is_always_present() {
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

    /// `lunette check` with no paths reads the directory a session would
    /// load: the first existing candidate, unless `--config-path` names one.
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

        let named = xdg.path().join("named");
        fs::create_dir_all(&named).expect("the named directory");
        fs::write(named.join("main.luau"), "").expect("main.luau");
        let checked = check::targets(&[], &named).expect("the files");
        assert_eq!(checked, vec![named.join("main.luau")]);
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
