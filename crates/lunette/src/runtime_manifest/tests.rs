//! Deterministic loader-selection and Monado metadata regressions.

// Test failures include the discovery error at the assertion site.
#![expect(clippy::expect_used, reason = "tests assert successful discovery")]

use std::{
    collections::BTreeMap,
    error::Error,
    io,
    path::{Path, PathBuf},
};

use super::discovery::{
    Architecture, DiscoveryError, Environment, EnvironmentConfig, FileSystem, LoaderConfig,
    SearchConfig, SelectedManifest, select_manifest,
};

const VALID: &[u8] = br#"{
    "file_format_version": "1.0.0",
    "runtime": {"library_path": "libopenxr_monado.so", "MND_libmonado_path": "libmonado.so"}
}"#;

#[derive(Default)]
struct FakeFileSystem {
    files: BTreeMap<PathBuf, Vec<u8>>,
    canonical: BTreeMap<PathBuf, PathBuf>,
    read_error: Option<io::ErrorKind>,
    canonical_error: Option<io::ErrorKind>,
}

impl FakeFileSystem {
    fn insert(&mut self, path: &str, bytes: &[u8]) {
        self.files.insert(path.into(), bytes.to_vec());
    }
}

impl FileSystem for FakeFileSystem {
    fn exists(&self, path: &Path) -> bool {
        let path = self.canonical.get(path).map_or(path, PathBuf::as_path);
        self.files.contains_key(path)
    }

    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        if let Some(kind) = self.read_error {
            return Err(kind.into());
        }
        let path = self.canonical.get(path).map_or(path, PathBuf::as_path);
        self.files
            .get(path)
            .cloned()
            .ok_or(io::ErrorKind::NotFound.into())
    }

    fn canonicalize(&self, path: &Path) -> io::Result<PathBuf> {
        if let Some(kind) = self.canonical_error {
            return Err(kind.into());
        }
        if let Some(path) = self.canonical.get(path) {
            return Ok(path.clone());
        }
        if self.files.contains_key(path) {
            return Ok(path.to_path_buf());
        }
        Err(io::ErrorKind::NotFound.into())
    }
}

fn config() -> LoaderConfig {
    LoaderConfig {
        current_directory: "/work".into(),
        architecture: Architecture::X86_64,
        environment: Environment::Use(EnvironmentConfig::default()),
        search: SearchConfig::default(),
    }
}

fn selected(filesystem: &FakeFileSystem, config: &LoaderConfig) -> SelectedManifest {
    select_manifest(config, filesystem)
        .expect("valid configuration")
        .expect("selected manifest")
}

#[test]
fn absent_runtime_returns_none() {
    assert_eq!(
        select_manifest(&config(), &FakeFileSystem::default()).expect("valid config"),
        None
    );
}

#[test]
fn override_is_exclusive_even_when_missing_and_relative() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
    let mut config = config();
    config.environment = Environment::Use(EnvironmentConfig {
        xr_runtime_json: Some("runtime.json".into()),
        ..EnvironmentConfig::default()
    });
    let error =
        select_manifest(&config, &filesystem).expect_err("missing override is not replaced");
    assert!(
        matches!(&error, DiscoveryError::Canonicalize { path, .. } if path == Path::new("/work/runtime.json"))
    );
    assert!(error.source().is_some());
}

#[test]
fn every_combination_preserves_directory_then_architecture_precedence() {
    let mut config = config();
    config.environment = Environment::Use(EnvironmentConfig {
        xdg_config_home: Some("/user".into()),
        xdg_config_dirs: Some("/first:/second".into()),
        ..EnvironmentConfig::default()
    });
    let paths = [
        "/user/openxr/1/active_runtime.x86_64.json",
        "/user/openxr/1/active_runtime.json",
        "/first/openxr/1/active_runtime.x86_64.json",
        "/first/openxr/1/active_runtime.json",
        "/second/openxr/1/active_runtime.x86_64.json",
        "/second/openxr/1/active_runtime.json",
        "/etc/openxr/1/active_runtime.x86_64.json",
        "/etc/openxr/1/active_runtime.json",
    ];
    for mask in 0_u16..256 {
        let mut filesystem = FakeFileSystem::default();
        for (index, path) in paths.iter().enumerate() {
            if mask & (1 << index) != 0 {
                filesystem.insert(path, VALID);
            }
        }
        let manifest = select_manifest(&config, &filesystem).expect("valid configuration");
        let expected = paths
            .iter()
            .enumerate()
            .find(|(index, _)| mask & (1 << index) != 0);
        assert_eq!(
            manifest.as_ref().map(SelectedManifest::path),
            expected.map(|(_, path)| Path::new(path))
        );
    }
}

#[test]
fn empty_overrides_use_home_and_default_directories() {
    let mut config = config();
    config.environment = Environment::Use(EnvironmentConfig {
        xr_runtime_json: Some("".into()),
        xdg_config_home: Some("".into()),
        home: Some("/home/session".into()),
        xdg_config_dirs: Some("".into()),
    });
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/etc/xdg/openxr/1/active_runtime.json", VALID);
    assert_eq!(
        selected(&filesystem, &config).path(),
        Path::new("/etc/xdg/openxr/1/active_runtime.json")
    );
    filesystem.insert("/home/session/.config/openxr/1/active_runtime.json", VALID);
    assert_eq!(
        selected(&filesystem, &config).path(),
        Path::new("/home/session/.config/openxr/1/active_runtime.json")
    );
}

#[test]
fn empty_list_entries_are_skipped_but_relative_entries_are_used() {
    let mut config = config();
    config.environment = Environment::Use(EnvironmentConfig {
        xdg_config_dirs: Some(":relative::/last:".into()),
        ..EnvironmentConfig::default()
    });
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/work/openxr/1/active_runtime.json", VALID);
    filesystem.insert("/etc/xdg/openxr/1/active_runtime.json", VALID);
    assert!(
        select_manifest(&config, &filesystem)
            .expect("valid config")
            .is_none()
    );
    filesystem.insert("/work/relative/openxr/1/active_runtime.json", VALID);
    assert_eq!(
        selected(&filesystem, &config).path(),
        Path::new("/work/relative/openxr/1/active_runtime.json")
    );
    config.environment = Environment::Use(EnvironmentConfig {
        xdg_config_home: Some("relative".into()),
        ..EnvironmentConfig::default()
    });
    assert_eq!(
        selected(&filesystem, &config).path(),
        Path::new("/work/relative/openxr/1/active_runtime.json")
    );
}

#[test]
fn secure_execution_ignores_all_environment_paths() {
    let mut config = config();
    config.environment = Environment::Ignore;
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/work/openxr/1/active_runtime.json", VALID);
    filesystem.insert("/etc/xdg/openxr/1/active_runtime.json", VALID);
    filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
    assert_eq!(
        selected(&filesystem, &config).path(),
        Path::new("/etc/xdg/openxr/1/active_runtime.json")
    );
}

#[test]
fn compiled_system_directory_precedes_extra_etc_directory() {
    let mut config = config();
    config.search.system_config_dirs = vec!["/usr/local/etc".into(), "/etc".into()];
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/usr/local/etc/openxr/1/active_runtime.json", VALID);
    filesystem.insert("/etc/openxr/1/active_runtime.x86_64.json", VALID);
    assert_eq!(
        selected(&filesystem, &config).path(),
        Path::new("/usr/local/etc/openxr/1/active_runtime.json")
    );
}

#[test]
fn architecture_suffix_is_the_loader_abi_spelling() {
    for (architecture, suffix) in [
        (Architecture::X86_64, "x86_64"),
        (Architecture::I686, "i686"),
        (Architecture::Aarch64, "aarch64"),
    ] {
        let mut config = config();
        config.architecture = architecture;
        let path = format!("/etc/openxr/1/active_runtime.{suffix}.json");
        let mut filesystem = FakeFileSystem::default();
        filesystem.insert(&path, VALID);
        filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
        assert_eq!(selected(&filesystem, &config).path(), Path::new(&path));
    }
}

#[test]
fn malformed_selected_manifest_never_falls_through() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/etc/xdg/openxr/1/active_runtime.x86_64.json", b"{");
    filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
    let manifest = selected(&filesystem, &config());
    assert_eq!(
        manifest.path(),
        Path::new("/etc/xdg/openxr/1/active_runtime.x86_64.json")
    );
    let error = manifest
        .monado_library(&filesystem)
        .expect_err("malformed JSON");
    assert!(matches!(error, DiscoveryError::Json { .. }));
    assert!(error.source().is_some());
}

#[test]
fn missing_or_invalid_required_fields_are_structured_errors() {
    for contents in [
        "null",
        "[]",
        "{}",
        r#"{"file_format_version":"2.0.0"}"#,
        r#"{"file_format_version":"1.0.0"}"#,
        r#"{"file_format_version":"1.0.0","runtime":[]}"#,
        r#"{"file_format_version":"1.0.0","runtime":{}}"#,
        r#"{"file_format_version":"1.0.0","runtime":{"library_path":null}}"#,
    ] {
        let mut filesystem = FakeFileSystem::default();
        filesystem.insert("/etc/openxr/1/active_runtime.json", contents.as_bytes());
        assert!(matches!(
            selected(&filesystem, &config()).monado_library(&filesystem),
            Err(DiscoveryError::InvalidField { .. })
        ));
    }
}

#[test]
fn absent_monado_field_is_an_ordinary_openxr_runtime() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert(
        "/etc/openxr/1/active_runtime.json",
        br#"{
        "file_format_version":"1.0.0", "runtime":{"library_path":"libother.so"}
    }"#,
    );
    assert_eq!(
        selected(&filesystem, &config())
            .monado_library(&filesystem)
            .expect("ordinary runtime"),
        None
    );
}

#[test]
fn invalid_monado_values_do_not_become_global_library_searches() {
    for value in ["null", "42", "[]", "{}", r#""""#, r#""bad\u0000path""#] {
        let contents = format!(
            r#"{{"file_format_version":"1.0.0","runtime":{{"library_path":"runtime.so","MND_libmonado_path":{value}}}}}"#
        );
        let mut filesystem = FakeFileSystem::default();
        filesystem.insert("/etc/openxr/1/active_runtime.json", contents.as_bytes());
        assert!(matches!(
            selected(&filesystem, &config()).monado_library(&filesystem),
            Err(DiscoveryError::InvalidField {
                field: "runtime.MND_libmonado_path",
                ..
            })
        ));
    }
}

#[test]
fn bare_and_relative_libraries_resolve_beside_real_manifest() {
    for library in ["libmonado.so", "../lib/libmonado.so"] {
        let mut filesystem = FakeFileSystem::default();
        let contents = format!(
            r#"{{"file_format_version":"1.0.0","runtime":{{"library_path":"runtime.so","MND_libmonado_path":"{library}"}}}}"#
        );
        filesystem.insert("/opt/runtime/manifest.json", contents.as_bytes());
        filesystem.canonical.insert(
            "/etc/openxr/1/active_runtime.json".into(),
            "/opt/runtime/manifest.json".into(),
        );
        assert_eq!(
            selected(&filesystem, &config())
                .monado_library(&filesystem)
                .expect("relative library"),
            Some(Path::new("/opt/runtime").join(library))
        );
    }
}

#[test]
fn canonicalization_failure_disables_discovery_without_fallback() {
    let mut filesystem = FakeFileSystem {
        canonical_error: Some(io::ErrorKind::PermissionDenied),
        ..FakeFileSystem::default()
    };
    filesystem.insert("/etc/xdg/openxr/1/active_runtime.json", VALID);
    filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
    let error = select_manifest(&config(), &filesystem).expect_err("canonicalization is required");
    assert!(matches!(&error, DiscoveryError::Canonicalize { path, .. }
        if path == Path::new("/etc/xdg/openxr/1/active_runtime.json")));
    assert!(error.source().is_some());
}

#[test]
fn switching_active_runtime_symlink_preserves_manifest_and_library_pair() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/opt/runtime-a/manifest.json", VALID);
    filesystem.insert(
        "/opt/runtime-b/manifest.json",
        br#"{
        "file_format_version":"1.0.0",
        "runtime":{"library_path":"other.so","MND_libmonado_path":"other-control.so"}
    }"#,
    );
    let active = PathBuf::from("/etc/openxr/1/active_runtime.json");
    filesystem
        .canonical
        .insert(active.clone(), "/opt/runtime-a/manifest.json".into());
    let manifest = selected(&filesystem, &config());
    filesystem
        .canonical
        .insert(active, "/opt/runtime-b/manifest.json".into());
    assert_eq!(manifest.path(), Path::new("/opt/runtime-a/manifest.json"));
    manifest
        .validate(&filesystem)
        .expect("symlink switch does not alter pinned content");
    assert_eq!(
        manifest
            .monado_library(&filesystem)
            .expect("pinned metadata"),
        Some("/opt/runtime-a/libmonado.so".into())
    );
}

#[test]
fn manifest_edits_are_rejected_before_native_configuration() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
    let manifest = selected(&filesystem, &config());
    manifest.validate(&filesystem).expect("unchanged snapshot");
    filesystem.insert("/etc/openxr/1/active_runtime.json", b"{}");
    assert!(matches!(
        manifest.validate(&filesystem),
        Err(DiscoveryError::ContentChanged { .. })
    ));
    assert!(matches!(
        manifest.monado_library(&filesystem),
        Err(DiscoveryError::ContentChanged { .. })
    ));
}

#[test]
fn relative_canonical_path_is_rejected_before_metadata_read() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert("relative.json", VALID);
    filesystem.canonical.insert(
        "/etc/openxr/1/active_runtime.json".into(),
        "relative.json".into(),
    );
    assert!(matches!(
        select_manifest(&config(), &filesystem),
        Err(DiscoveryError::InvalidCanonicalPath { .. })
    ));
}

#[test]
fn absolute_library_is_preserved_without_filesystem_search() {
    let mut filesystem = FakeFileSystem::default();
    filesystem.insert(
        "/etc/openxr/1/active_runtime.json",
        br#"{
        "file_format_version":"1.0.0",
        "runtime":{"library_path":"runtime.so","MND_libmonado_path":"/opt/lib/libmonado.so"}
    }"#,
    );
    assert_eq!(
        selected(&filesystem, &config())
            .monado_library(&filesystem)
            .expect("absolute library"),
        Some("/opt/lib/libmonado.so".into())
    );
}

#[test]
fn read_errors_keep_manifest_context_and_cause() {
    let mut filesystem = FakeFileSystem {
        read_error: Some(io::ErrorKind::PermissionDenied),
        ..FakeFileSystem::default()
    };
    filesystem.insert("/etc/openxr/1/active_runtime.json", VALID);
    let error = select_manifest(&config(), &filesystem).expect_err("unreadable manifest");
    assert!(
        error
            .to_string()
            .contains("/etc/openxr/1/active_runtime.json")
    );
    assert!(error.source().is_some());
}

#[test]
fn stage_mapping_is_certified_only_when_the_client_option_is_disabled() {
    for setting in [None, Some("0"), Some("false")] {
        assert!(super::monado_stage_unmapped(
            setting.map(std::ffi::OsStr::new)
        ));
    }
    for setting in ["", "1", "true", "yes", "FALSE", "false ", "unknown"] {
        assert!(!super::monado_stage_unmapped(Some(std::ffi::OsStr::new(
            setting
        ))));
    }
}

#[test]
fn relative_current_directory_is_rejected() {
    let mut config = config();
    config.current_directory = "relative".into();
    assert!(matches!(
        select_manifest(&config, &FakeFileSystem::default()),
        Err(DiscoveryError::RelativeCurrentDirectory { .. })
    ));
}
