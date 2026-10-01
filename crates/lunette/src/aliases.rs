//! Module roots and installation metadata.
//!
//! A module root has one alias and one already-resolved source path. The
//! application resolves paths before constructing [`ModuleRoots`]; this module
//! validates the names and describes how each root is resolved at runtime.
//!
//! The `.luaurc` files and the installer use the same descriptors. Keeping the
//! lists here prevents a root from being available to the checker but absent
//! from a running session, or installed at a path no configuration names.

use std::{collections::HashSet, fmt, fmt::Write as _, path::PathBuf};

/// A root a configuration requires by name, and where that name resolves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Alias {
    /// The name that follows the `@`.
    pub name: &'static str,
    /// The directory under the standard-library root. The checker reads it,
    /// and the session mounts it for a mounted root.
    pub directory: &'static str,
    /// How a running session resolves the name.
    pub resolution: Resolution,
}

/// How a running session resolves a root.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// Mounted into LÖVR's virtual filesystem under the alias.
    Mounted,
    /// Registered natively through `package.preload`. The directory holds the
    /// generated declarations, which the checker reads and the session never
    /// does. At runtime, no file on disk resolves `require '@lunette'`.
    Native,
}

/// The native API, whose on-disk form is its declarations.
pub const LUNETTE: Alias = Alias {
    name: "lunette",
    directory: "lunette",
    resolution: Resolution::Native,
};

/// The single plugin facade mounted by a running session.
pub const LUNETTE_PLUGIN: Alias = Alias {
    name: "lunette-plugin",
    directory: "lunette-plugin",
    resolution: Resolution::Mounted,
};

/// Types shared by the plugin facade and plugin implementations.
pub const LUNETTE_CONTRACTS: Alias = Alias {
    name: "lunette-contracts",
    directory: "lunette-contracts",
    resolution: Resolution::Mounted,
};

/// Plugin implementations mounted by a running session.
pub const LUNETTE_PLUGINS: Alias = Alias {
    name: "lunette-plugins",
    directory: "lunette-plugins",
    resolution: Resolution::Mounted,
};

/// The shipped desktop: its consumers and the composition that starts them.
/// The default configuration requires it; safe mode does not.
pub const LUNETTE_DESKTOP: Alias = Alias {
    name: "lunette-desktop",
    directory: "lunette-desktop",
    resolution: Resolution::Mounted,
};

/// The standard library's own module, written in Lua.
pub const MULLION: Alias = Alias {
    name: "mullion",
    directory: "mullion",
    resolution: Resolution::Mounted,
};

/// The specs, present in a development tree, absent from an installed one.
pub const SPEC: Alias = Alias {
    name: "spec",
    directory: "spec",
    resolution: Resolution::Mounted,
};

/// Every development root, in the order a `.luaurc` states them.
pub const DEVELOPMENT_ALIASES: &[Alias] = &[
    LUNETTE,
    LUNETTE_PLUGIN,
    LUNETTE_CONTRACTS,
    LUNETTE_PLUGINS,
    LUNETTE_DESKTOP,
    MULLION,
    SPEC,
];

/// Every installed root, in the order a `.luaurc` states them.
pub const INSTALLED_ALIASES: &[Alias] = &[
    LUNETTE,
    LUNETTE_PLUGIN,
    LUNETTE_CONTRACTS,
    LUNETTE_PLUGINS,
    LUNETTE_DESKTOP,
    MULLION,
];

/// Every root, retained as the compatibility name used by existing callers.
pub const ALIASES: &[Alias] = DEVELOPMENT_ALIASES;

/// A root with the source path already resolved by its caller.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleRoot {
    /// The alias exposed to Luau.
    pub alias: String,
    /// The already-resolved directory containing the root's modules.
    pub source: PathBuf,
    /// How the running session resolves the root.
    pub resolution: Resolution,
}

/// The compatibility name for a resolved module root description.
pub type ResolvedRoot = ModuleRoot;

/// The compatibility name for a resolved module root description.
pub type RootDescription = ModuleRoot;

impl ModuleRoot {
    /// Describes a mounted root without resolving or fetching its source path.
    #[must_use]
    pub fn mounted(alias: impl Into<String>, source: impl Into<PathBuf>) -> Self {
        Self {
            alias: alias.into(),
            source: source.into(),
            resolution: Resolution::Mounted,
        }
    }

    /// Describes a native root without resolving or fetching its source path.
    #[must_use]
    pub fn native(alias: impl Into<String>, source: impl Into<PathBuf>) -> Self {
        Self {
            alias: alias.into(),
            source: source.into(),
            resolution: Resolution::Native,
        }
    }

    /// The mount point a session gives this root.
    #[must_use]
    pub fn mount_point(&self) -> String {
        format!("@{}", self.alias)
    }

    /// Whether the root is optional in a source tree or installation.
    #[must_use]
    pub fn optional(&self) -> bool {
        self.alias == MULLION.name || self.alias == SPEC.name
    }

    /// Whether the root is required in a shipped installation.
    #[must_use]
    pub fn required_for_installation(&self) -> bool {
        !self.optional() && self.resolution != Resolution::Native
    }
}

/// A validated collection of resolved module roots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleRoots {
    roots: Vec<ModuleRoot>,
}

impl ModuleRoots {
    /// Validates a collection of resolved roots.
    pub fn try_new(roots: impl IntoIterator<Item = ModuleRoot>) -> Result<Self, RootError> {
        let mut roots = roots.into_iter().collect::<Vec<_>>();
        validate_roots(&roots)?;
        roots.shrink_to_fit();
        Ok(Self { roots })
    }

    /// Builds the development roots below an already-resolved standard-library
    /// directory. The spec root is retained here and omitted by [`Self::installed`].
    #[must_use]
    pub fn development(source: impl Into<PathBuf>) -> Self {
        Self::from_aliases(source.into(), DEVELOPMENT_ALIASES)
    }

    /// Builds the installed roots below an already-resolved standard-library
    /// directory. The development-only spec root is not included.
    #[must_use]
    pub fn installed(source: impl Into<PathBuf>) -> Self {
        Self::from_aliases(source.into(), INSTALLED_ALIASES)
    }

    /// Returns every validated root in configuration order.
    pub fn iter(&self) -> impl Iterator<Item = &ModuleRoot> {
        self.roots.iter()
    }

    /// Returns roots that a coordinator should mount.
    pub fn mounted(&self) -> impl Iterator<Item = &ModuleRoot> {
        self.roots
            .iter()
            .filter(|root| root.resolution == Resolution::Mounted)
    }

    /// Returns the mounted roots that must be available for this model to be complete.
    pub fn required(&self) -> impl Iterator<Item = &ModuleRoot> {
        self.mounted()
            .filter(|root| root.required_for_installation())
    }

    /// Returns the roots as a slice for callers that need indexed access.
    #[must_use]
    pub fn as_slice(&self) -> &[ModuleRoot] {
        &self.roots
    }

    fn from_aliases(source: PathBuf, aliases: &[Alias]) -> Self {
        let roots = aliases
            .iter()
            .map(|alias| ModuleRoot {
                alias: alias.name.to_owned(),
                source: source.join(alias.directory),
                resolution: alias.resolution,
            })
            .collect::<Vec<_>>();
        Self::try_new(roots)
            .unwrap_or_else(|error| panic!("the built-in module roots are invalid: {error}"))
    }
}

impl TryFrom<Vec<ModuleRoot>> for ModuleRoots {
    type Error = RootError;

    fn try_from(roots: Vec<ModuleRoot>) -> Result<Self, Self::Error> {
        Self::try_new(roots)
    }
}

/// Why a collection of module roots is invalid.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RootError {
    /// A root has no alias.
    EmptyAlias,
    /// A root has an alias that cannot be used in a Luau require path.
    InvalidAlias(String),
    /// A root has no source path.
    EmptySource(String),
    /// Two roots expose the same alias.
    DuplicateAlias(String),
    /// A reserved native or facade alias was given the wrong resolution.
    ReservedAlias {
        /// The reserved alias.
        alias: String,
        /// The resolution requested by the caller.
        resolution: Resolution,
    },
}

impl fmt::Display for RootError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyAlias => formatter.write_str("module roots: an alias is empty"),
            Self::InvalidAlias(alias) => {
                write!(formatter, "module roots: `{alias}` is not a valid alias")
            }
            Self::EmptySource(alias) => {
                write!(
                    formatter,
                    "module roots: `{alias}` has an empty source path"
                )
            }
            Self::DuplicateAlias(alias) => {
                write!(
                    formatter,
                    "module roots: `{alias}` is declared more than once"
                )
            }
            Self::ReservedAlias { alias, resolution } => write!(
                formatter,
                "module roots: reserved `{alias}` cannot use {resolution:?} resolution"
            ),
        }
    }
}

impl std::error::Error for RootError {}

/// An installable source tree and its destination below `$PREFIX/share/lunette`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InstallArtifact {
    /// A source path in the repository.
    pub source: &'static str,
    /// A destination path relative to the installed lunette data directory.
    pub destination: &'static str,
    /// Whether installation must fail when the source is absent.
    pub required: bool,
}

/// The source and destination paths that make up an installed Luau runtime.
///
/// Directory entries are copied recursively by the installer, but only `.lua`
/// and `.luau` files are accepted from them. The manifest deliberately does not
/// include `lua/spec` or test/probe paths.
pub const INSTALL_ARTIFACTS: &[InstallArtifact] = &[
    InstallArtifact {
        source: "lua/lunette",
        destination: "lua/lunette",
        required: true,
    },
    InstallArtifact {
        source: "lua/lunette-plugin",
        destination: "lua/lunette-plugin",
        required: true,
    },
    InstallArtifact {
        source: "lua/lunette-contracts",
        destination: "lua/lunette-contracts",
        required: true,
    },
    InstallArtifact {
        source: "lua/lunette-plugins",
        destination: "lua/lunette-plugins",
        required: true,
    },
    InstallArtifact {
        source: "lua/lunette-desktop",
        destination: "lua/lunette-desktop",
        required: true,
    },
    InstallArtifact {
        source: "lua/mullion",
        destination: "lua/mullion",
        required: false,
    },
    InstallArtifact {
        source: "etc/lunette/definitions.luau",
        destination: "definitions.luau",
        required: true,
    },
    InstallArtifact {
        source: "etc/lunette/installed.luaurc",
        destination: "lua/.luaurc",
        required: true,
    },
];

/// Returns the canonical install artifact manifest.
pub fn install_artifacts() -> impl Iterator<Item = &'static InstallArtifact> {
    INSTALL_ARTIFACTS.iter()
}

/// Renders the install manifest as tab-separated source and destination paths.
///
/// The format is intentionally small and stable so Make and other install
/// tooling can consume the Rust-owned manifest without duplicating its paths.
#[must_use]
pub fn install_manifest() -> String {
    let mut output = String::new();
    for artifact in INSTALL_ARTIFACTS {
        let _ = writeln!(
            output,
            "{}\t{}\t{}",
            artifact.source, artifact.destination, artifact.required
        );
    }
    output
}

impl Alias {
    /// The mount point a root gives a session.
    #[must_use]
    pub fn mount_point(&self) -> String {
        format!("@{}", self.name)
    }
}

/// Renders a development `.luaurc` whose aliases resolve against `root`.
///
/// This function retains the original API and includes the development-only
/// spec root. Use [`installed_luaurc`] for a configuration shipped separately
/// from the development tree.
#[must_use]
pub fn luaurc(root: &str) -> String {
    render_luaurc(root, DEVELOPMENT_ALIASES)
}

/// Renders an installed `.luaurc`, excluding the development-only spec root.
#[must_use]
pub fn installed_luaurc(root: &str) -> String {
    render_luaurc(root, INSTALLED_ALIASES)
}

/// Compatibility spelling for callers that put the mode before the noun.
#[must_use]
pub fn luaurc_installed(root: &str) -> String {
    installed_luaurc(root)
}

/// Returns the static development descriptors for a coordinator that resolves
/// paths itself.
pub fn development_aliases() -> impl Iterator<Item = &'static Alias> {
    DEVELOPMENT_ALIASES.iter()
}

/// Returns the static installed descriptors.
pub fn installed_aliases() -> impl Iterator<Item = &'static Alias> {
    INSTALLED_ALIASES.iter()
}

fn render_luaurc(root: &str, aliases: &[Alias]) -> String {
    let mut out = String::from("{\n  \"languageMode\": \"strict\",\n  \"aliases\": {\n");
    for (index, alias) in aliases.iter().enumerate() {
        let separator = if index + 1 == aliases.len() { "" } else { "," };
        let _ = writeln!(
            out,
            "    \"{}\": \"{root}/{}\"{separator}",
            alias.name, alias.directory
        );
    }
    out.push_str("  }\n}\n");
    out
}

fn validate_roots(roots: &[ModuleRoot]) -> Result<(), RootError> {
    let mut aliases = HashSet::with_capacity(roots.len());
    for root in roots {
        if root.alias.is_empty() {
            return Err(RootError::EmptyAlias);
        }
        if !valid_alias(&root.alias) {
            return Err(RootError::InvalidAlias(root.alias.clone()));
        }
        if root.source.as_os_str().is_empty() {
            return Err(RootError::EmptySource(root.alias.clone()));
        }
        if !aliases.insert(root.alias.clone()) {
            return Err(RootError::DuplicateAlias(root.alias.clone()));
        }
        if let Some(expected) = reserved_resolution(&root.alias)
            && root.resolution != expected
        {
            return Err(RootError::ReservedAlias {
                alias: root.alias.clone(),
                resolution: root.resolution,
            });
        }
    }

    Ok(())
}

fn valid_alias(alias: &str) -> bool {
    alias.bytes().enumerate().all(|(index, byte)| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || (index > 0 && byte == b'-')
    })
}

fn reserved_resolution(alias: &str) -> Option<Resolution> {
    DEVELOPMENT_ALIASES
        .iter()
        .find(|root| root.name == alias)
        .map(|root| root.resolution)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn module_root_resolution_matrix() {
        let development = ModuleRoots::development("/resolved/lunette");
        assert_eq!(
            development
                .iter()
                .map(|root| root.alias.as_str())
                .collect::<Vec<_>>(),
            vec![
                "lunette",
                "lunette-plugin",
                "lunette-contracts",
                "lunette-plugins",
                "lunette-desktop",
                "mullion",
                "spec",
            ]
        );
        assert_eq!(
            development
                .iter()
                .map(|root| root.resolution)
                .collect::<Vec<_>>(),
            vec![
                Resolution::Native,
                Resolution::Mounted,
                Resolution::Mounted,
                Resolution::Mounted,
                Resolution::Mounted,
                Resolution::Mounted,
                Resolution::Mounted,
            ]
        );

        let installed = ModuleRoots::installed("/resolved/lunette");
        assert_eq!(
            installed
                .iter()
                .map(|root| root.alias.as_str())
                .collect::<Vec<_>>(),
            vec![
                "lunette",
                "lunette-plugin",
                "lunette-contracts",
                "lunette-plugins",
                "lunette-desktop",
                "mullion",
            ]
        );
        assert!(installed.iter().all(|root| root.alias != SPEC.name));
        assert_eq!(
            installed
                .required()
                .map(|root| root.alias.as_str())
                .collect::<Vec<_>>(),
            vec![
                "lunette-plugin",
                "lunette-contracts",
                "lunette-plugins",
                "lunette-desktop"
            ]
        );
        assert!(
            installed
                .iter()
                .find(|root| root.alias == MULLION.name)
                .is_some_and(ModuleRoot::optional)
        );
        assert_eq!(
            installed
                .mounted()
                .map(|root| root.mount_point())
                .collect::<Vec<_>>(),
            vec![
                "@lunette-plugin",
                "@lunette-contracts",
                "@lunette-plugins",
                "@lunette-desktop",
                "@mullion",
            ]
        );
    }

    #[test]
    fn duplicate_root_rejected() {
        let result = ModuleRoots::try_new([
            ModuleRoot::mounted("lunette-plugin", "/one"),
            ModuleRoot::mounted("lunette-plugin", "/two"),
        ]);
        assert!(
            matches!(result, Err(RootError::DuplicateAlias(alias)) if alias == "lunette-plugin")
        );
    }

    #[test]
    fn native_and_facade_shadowing_is_rejected() {
        let native = ModuleRoots::try_new([ModuleRoot::mounted("lunette", "/native")]);
        assert!(matches!(native, Err(RootError::ReservedAlias { .. })));

        let facade = ModuleRoots::try_new([ModuleRoot::native("lunette-plugin", "/facade")]);
        assert!(matches!(facade, Err(RootError::ReservedAlias { .. })));
    }

    #[test]
    fn installed_plugin_artifact_layout() {
        assert_eq!(
            INSTALL_ARTIFACTS,
            &[
                InstallArtifact {
                    source: "lua/lunette",
                    destination: "lua/lunette",
                    required: true,
                },
                InstallArtifact {
                    source: "lua/lunette-plugin",
                    destination: "lua/lunette-plugin",
                    required: true,
                },
                InstallArtifact {
                    source: "lua/lunette-contracts",
                    destination: "lua/lunette-contracts",
                    required: true,
                },
                InstallArtifact {
                    source: "lua/lunette-plugins",
                    destination: "lua/lunette-plugins",
                    required: true,
                },
                InstallArtifact {
                    source: "lua/lunette-desktop",
                    destination: "lua/lunette-desktop",
                    required: true,
                },
                InstallArtifact {
                    source: "lua/mullion",
                    destination: "lua/mullion",
                    required: false,
                },
                InstallArtifact {
                    source: "etc/lunette/definitions.luau",
                    destination: "definitions.luau",
                    required: true,
                },
                InstallArtifact {
                    source: "etc/lunette/installed.luaurc",
                    destination: "lua/.luaurc",
                    required: true,
                },
            ]
        );
        assert!(
            INSTALL_ARTIFACTS
                .iter()
                .all(|artifact| !artifact.source.starts_with("lua/spec"))
        );
        assert!(INSTALL_ARTIFACTS.iter().all(|artifact| {
            artifact.source.ends_with(".lua")
                || artifact.source.ends_with(".luau")
                || artifact.source.starts_with("lua/")
                || artifact.source == "etc/lunette/installed.luaurc"
        }));
        assert!(INSTALL_ARTIFACTS.iter().all(|artifact| {
            !artifact.source.contains("probe") && !artifact.source.starts_with("crates/")
        }));
    }

    #[test]
    fn development_luaurc_includes_spec_and_installed_luaurc_does_not() {
        assert!(luaurc(".").contains("\"spec\": \"./spec\""));
        assert!(!installed_luaurc(".").contains("\"spec\""));
        assert!(
            installed_luaurc("/usr/local/share/lunette/lua")
                .contains("\"lunette-plugin\": \"/usr/local/share/lunette/lua/lunette-plugin\"")
        );
    }

    #[test]
    fn a_relative_root_is_written_as_it_is_given() {
        assert_eq!(
            luaurc("."),
            "{\n  \"languageMode\": \"strict\",\n  \"aliases\": {\n    \"lunette\": \
             \"./lunette\",\n    \"lunette-plugin\": \"./lunette-plugin\",\n    \"lunette-contracts\": \"./lunette-contracts\",\n    \"lunette-plugins\": \"./lunette-plugins\",\n    \"lunette-desktop\": \"./lunette-desktop\",\n    \"mullion\": \"./mullion\",\n    \"spec\": \"./spec\"\n  }\n}\n"
        );
    }

    #[test]
    fn distinct_aliases_may_share_a_resolved_source() -> Result<(), RootError> {
        let roots = ModuleRoots::try_new([
            ModuleRoot::mounted("first", "/same"),
            ModuleRoot::mounted("second", "/same"),
        ])?;
        assert_eq!(roots.iter().count(), 2);
        Ok(())
    }
}
