//! Linux-only: applies the vendored OpenXR loader's manifest precedence and reads Monado metadata.

use std::{
    error::Error,
    ffi::OsString,
    fmt, fs, io,
    path::{Path, PathBuf},
};

use serde_json::Value;

#[derive(Clone, Debug)]
pub struct LoaderConfig {
    pub current_directory: PathBuf,
    pub architecture: Architecture,
    pub environment: Environment,
    pub search: SearchConfig,
}

/// The OpenXR loader ABI suffix.
#[derive(Clone, Copy, Debug)]
pub enum Architecture {
    #[cfg(any(test, not(any(target_arch = "x86", target_arch = "aarch64"))))]
    X86_64,
    #[cfg(any(test, target_arch = "x86"))]
    I686,
    #[cfg(any(test, target_arch = "aarch64"))]
    Aarch64,
}

/// Secure execution must use `Ignore`: explicit loader properties bypass secure_getenv.
#[derive(Clone, Debug)]
pub enum Environment {
    Ignore,
    Use(EnvironmentConfig),
}

#[derive(Clone, Debug, Default)]
pub struct EnvironmentConfig {
    pub xr_runtime_json: Option<PathBuf>,
    pub xdg_config_home: Option<PathBuf>,
    pub home: Option<PathBuf>,
    pub xdg_config_dirs: Option<OsString>,
}

/// These directories must match the native loader's build-time configuration.
#[derive(Clone, Debug)]
pub struct SearchConfig {
    pub fallback_config_dirs: Vec<PathBuf>,
    /// SYSCONFDIR followed by EXTRASYSCONFDIR when the loader defines it.
    pub system_config_dirs: Vec<PathBuf>,
}

impl Default for SearchConfig {
    fn default() -> Self {
        Self {
            fallback_config_dirs: vec![PathBuf::from("/etc/xdg")],
            system_config_dirs: vec![PathBuf::from("/etc")],
        }
    }
}

/// A canonical manifest path and its metadata snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectedManifest {
    path: PathBuf,
    bytes: Vec<u8>,
}

impl SelectedManifest {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn contents(&self) -> &[u8] {
        &self.bytes
    }

    /// Detects manifest edits before native configuration; later filesystem mutations can still race.
    pub fn validate(&self, filesystem: &impl FileSystem) -> Result<(), DiscoveryError> {
        let bytes = filesystem
            .read(&self.path)
            .map_err(|source| DiscoveryError::Read {
                path: self.path.clone(),
                source,
            })?;
        if bytes != self.bytes {
            return Err(DiscoveryError::ContentChanged {
                path: self.path.clone(),
            });
        }
        Ok(())
    }

    /// Relative libraries resolve beside the canonical manifest, never through global dlopen search.
    pub fn monado_library(
        &self,
        filesystem: &impl FileSystem,
    ) -> Result<Option<PathBuf>, DiscoveryError> {
        self.validate(filesystem)?;
        let root: Value =
            serde_json::from_slice(self.contents()).map_err(|source| DiscoveryError::Json {
                path: self.path.clone(),
                source,
            })?;
        let invalid = |field| DiscoveryError::InvalidField {
            path: self.path.clone(),
            field,
        };
        if root.get("file_format_version").and_then(Value::as_str) != Some("1.0.0") {
            return Err(invalid("file_format_version"));
        }
        let runtime = root
            .get("runtime")
            .and_then(Value::as_object)
            .ok_or_else(|| invalid("runtime"))?;
        runtime
            .get("library_path")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty() && !value.contains('\0'))
            .ok_or_else(|| invalid("runtime.library_path"))?;
        let Some(monado) = runtime.get("MND_libmonado_path") else {
            return Ok(None);
        };
        let monado = monado
            .as_str()
            .filter(|value| !value.is_empty() && !value.contains('\0'))
            .ok_or_else(|| invalid("runtime.MND_libmonado_path"))?;
        let library = Path::new(monado);
        if library.is_absolute() {
            return Ok(Some(library.to_path_buf()));
        }
        let directory = self
            .path
            .parent()
            .ok_or_else(|| invalid("manifest directory"))?;
        Ok(Some(directory.join(library)))
    }
}

/// Existence follows symlinks and treats inaccessible candidates as absent, matching the loader.
pub trait FileSystem {
    fn exists(&self, path: &Path) -> bool;
    fn read(&self, path: &Path) -> io::Result<Vec<u8>>;
    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf>;
}

pub struct SystemFileSystem;

impl FileSystem for SystemFileSystem {
    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }

    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        fs::read(path)
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        fs::canonicalize(path)
    }
}

/// Selection does not fall through on invalid JSON or a missing XR_RUNTIME_JSON override.
pub fn select_manifest(
    config: &LoaderConfig,
    filesystem: &impl FileSystem,
) -> Result<Option<SelectedManifest>, DiscoveryError> {
    if !config.current_directory.is_absolute() {
        return Err(DiscoveryError::RelativeCurrentDirectory {
            path: config.current_directory.clone(),
        });
    }
    let absolute = |path: &Path| config.current_directory.join(path);
    let environment = match &config.environment {
        Environment::Ignore => None,
        Environment::Use(environment) => Some(environment),
    };
    if let Some(path) = environment.and_then(|value| nonempty(value.xr_runtime_json.as_deref())) {
        return pin_manifest(absolute(path), filesystem).map(Some);
    }
    let user_directory = environment.and_then(|value| {
        nonempty(value.xdg_config_home.as_deref())
            .map(Path::to_path_buf)
            .or_else(|| nonempty(value.home.as_deref()).map(|home| home.join(".config")))
    });
    let config_dirs = environment
        .and_then(|value| value.xdg_config_dirs.as_deref())
        .filter(|value| !value.is_empty())
        .map(|value| {
            std::env::split_paths(value)
                .filter(|path| !path.as_os_str().is_empty())
                .collect::<Vec<_>>()
        });
    let directories = user_directory
        .iter()
        .chain(
            config_dirs
                .as_ref()
                .unwrap_or(&config.search.fallback_config_dirs),
        )
        .chain(&config.search.system_config_dirs);
    let decorated = format!("active_runtime.{}.json", config.architecture.suffix());
    for directory in directories {
        let directory = absolute(directory).join("openxr/1");
        for filename in [&decorated, "active_runtime.json"] {
            let path = directory.join(filename);
            if filesystem.exists(&path) {
                return pin_manifest(path, filesystem).map(Some);
            }
        }
    }
    Ok(None)
}

#[derive(Debug)]
pub enum DiscoveryError {
    RelativeCurrentDirectory {
        path: PathBuf,
    },
    InvalidCanonicalPath {
        path: PathBuf,
    },
    Canonicalize {
        path: PathBuf,
        source: io::Error,
    },
    ContentChanged {
        path: PathBuf,
    },
    Read {
        path: PathBuf,
        source: io::Error,
    },
    Json {
        path: PathBuf,
        source: serde_json::Error,
    },
    InvalidField {
        path: PathBuf,
        field: &'static str,
    },
}

impl fmt::Display for DiscoveryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RelativeCurrentDirectory { path } => write!(
                formatter,
                "runtime manifest: current directory {} is not absolute",
                path.display()
            ),
            Self::InvalidCanonicalPath { path } => write!(
                formatter,
                "runtime manifest: canonical path {} is not absolute",
                path.display()
            ),
            Self::Canonicalize { path, source } => write!(
                formatter,
                "runtime manifest: canonicalize {}: {source}",
                path.display()
            ),
            Self::ContentChanged { path } => write!(
                formatter,
                "runtime manifest: {} changed after discovery",
                path.display()
            ),
            Self::Read { path, source } => write!(
                formatter,
                "runtime manifest: read {}: {source}",
                path.display()
            ),
            Self::Json { path, source } => write!(
                formatter,
                "runtime manifest: parse {}: {source}",
                path.display()
            ),
            Self::InvalidField { path, field } => write!(
                formatter,
                "runtime manifest: {}: missing, invalid, or unsupported {field}",
                path.display()
            ),
        }
    }
}

impl Error for DiscoveryError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Canonicalize { source, .. } | Self::Read { source, .. } => Some(source),
            Self::Json { source, .. } => Some(source),
            _ => None,
        }
    }
}

impl Architecture {
    fn suffix(self) -> &'static str {
        match self {
            #[cfg(any(test, not(any(target_arch = "x86", target_arch = "aarch64"))))]
            Self::X86_64 => "x86_64",
            #[cfg(any(test, target_arch = "x86"))]
            Self::I686 => "i686",
            #[cfg(any(test, target_arch = "aarch64"))]
            Self::Aarch64 => "aarch64",
        }
    }
}

fn pin_manifest(
    path: PathBuf,
    filesystem: &impl FileSystem,
) -> Result<SelectedManifest, DiscoveryError> {
    let path = filesystem
        .canonicalize(&path)
        .map_err(|source| DiscoveryError::Canonicalize { path, source })?;
    if !path.is_absolute() {
        return Err(DiscoveryError::InvalidCanonicalPath { path });
    }
    let bytes = filesystem
        .read(&path)
        .map_err(|source| DiscoveryError::Read {
            path: path.clone(),
            source,
        })?;
    Ok(SelectedManifest { path, bytes })
}

fn nonempty(path: Option<&Path>) -> Option<&Path> {
    path.filter(|path| !path.as_os_str().is_empty())
}
