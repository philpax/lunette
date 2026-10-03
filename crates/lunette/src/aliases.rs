//! Module roots and installation metadata.
//!
//! The checker's `.luaurc` files, the session's mounts, and the installer all
//! derive from these descriptors, so the three cannot disagree about a root.
//! Paths arrive already resolved.

use std::{fmt::Write as _, path::PathBuf};

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

/// Every built-in plugin, provider or consumer, mounted by a running session.
pub const LUNETTE_PLUGINS: Alias = Alias {
    name: "lunette-plugins",
    directory: "lunette-plugins",
    resolution: Resolution::Mounted,
};

/// The shipped desktop: the entry list that composes the built-in plugins.
/// The default configuration requires it; safe mode does not.
pub const LUNETTE_DESKTOP: Alias = Alias {
    name: "lunette-desktop",
    directory: "lunette-desktop",
    resolution: Resolution::Mounted,
};

/// The test scaffolding, present in a development tree, absent from an
/// installed one. Test files require it; no installed module does.
pub const TESTING: Alias = Alias {
    name: "testing",
    directory: "testing",
    resolution: Resolution::Mounted,
};

/// Every development root, in the order a `.luaurc` states them.
pub const DEVELOPMENT_ALIASES: &[Alias] = &[
    LUNETTE,
    LUNETTE_PLUGIN,
    LUNETTE_CONTRACTS,
    LUNETTE_PLUGINS,
    LUNETTE_DESKTOP,
    TESTING,
];

/// Every installed root, in the order a `.luaurc` states them.
pub const INSTALLED_ALIASES: &[Alias] = &[
    LUNETTE,
    LUNETTE_PLUGIN,
    LUNETTE_CONTRACTS,
    LUNETTE_PLUGINS,
    LUNETTE_DESKTOP,
];

/// A root with the source path already resolved by its caller.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleRoot {
    pub alias: String,
    /// The already-resolved directory containing the root's modules.
    pub source: PathBuf,
    pub resolution: Resolution,
}

impl ModuleRoot {
    /// The mount point a session gives this root.
    #[must_use]
    pub fn mount_point(&self) -> String {
        format!("@{}", self.alias)
    }

    /// Whether the root is optional in a source tree or installation. Only the
    /// development-only testing root is.
    #[must_use]
    pub fn optional(&self) -> bool {
        self.alias == TESTING.name
    }

    /// Whether the root is required in a shipped installation.
    #[must_use]
    pub fn required_for_installation(&self) -> bool {
        !self.optional() && self.resolution != Resolution::Native
    }
}

/// A collection of resolved module roots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleRoots {
    roots: Vec<ModuleRoot>,
}

impl ModuleRoots {
    /// Builds the development roots below an already-resolved standard-library
    /// directory. The testing root is retained here and omitted by [`Self::installed`].
    #[must_use]
    pub fn development(source: impl Into<PathBuf>) -> Self {
        Self::from_aliases(source.into(), DEVELOPMENT_ALIASES)
    }

    /// Builds the installed roots below an already-resolved standard-library
    /// directory. The development-only testing root is not included.
    #[must_use]
    pub fn installed(source: impl Into<PathBuf>) -> Self {
        Self::from_aliases(source.into(), INSTALLED_ALIASES)
    }

    /// Returns every root in configuration order.
    pub fn iter(&self) -> impl Iterator<Item = &ModuleRoot> {
        self.roots.iter()
    }

    /// Returns roots that a coordinator should mount.
    pub fn mounted(&self) -> impl Iterator<Item = &ModuleRoot> {
        self.roots
            .iter()
            .filter(|root| root.resolution == Resolution::Mounted)
    }

    fn from_aliases(source: PathBuf, aliases: &[Alias]) -> Self {
        let roots = aliases
            .iter()
            .map(|alias| ModuleRoot {
                alias: alias.name.to_owned(),
                source: source.join(alias.directory),
                resolution: alias.resolution,
            })
            .collect();
        Self { roots }
    }
}

/// A file installed beside the module roots, and its destination below
/// `$PREFIX/share/lunette`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InstallArtifact {
    /// A source path in the repository.
    pub source: &'static str,
    /// A destination path relative to the installed lunette data directory.
    pub destination: &'static str,
}

/// The files an installed Luau runtime needs besides its module roots. Every
/// installed root's directory is installed from `lua/` to `lua/`; the
/// manifest derives those entries from [`INSTALLED_ALIASES`].
pub const INSTALL_ARTIFACTS: &[InstallArtifact] = &[
    InstallArtifact {
        source: "etc/lunette/definitions.luau",
        destination: "definitions.luau",
    },
    InstallArtifact {
        source: "etc/lunette/installed.luaurc",
        destination: "lua/.luaurc",
    },
];

/// Renders the install manifest as tab-separated source and destination
/// paths, so Make consumes the Rust-owned manifest rather than restating it.
/// A directory contributes only its `.luau` files outside its `tests`
/// directories, and `lua/testing` is never listed.
#[must_use]
pub fn install_manifest() -> String {
    let mut output = String::new();
    for alias in INSTALLED_ALIASES {
        let _ = writeln!(output, "lua/{0}\tlua/{0}", alias.directory);
    }
    for artifact in INSTALL_ARTIFACTS {
        let _ = writeln!(output, "{}\t{}", artifact.source, artifact.destination);
    }
    output
}

/// Renders a development `.luaurc` whose aliases resolve against `root`.
///
/// This includes the development-only testing root; [`installed_luaurc`] omits it.
#[must_use]
pub fn luaurc(root: &str) -> String {
    render_luaurc(root, DEVELOPMENT_ALIASES)
}

/// Renders an installed `.luaurc`, excluding the development-only testing root.
#[must_use]
pub fn installed_luaurc(root: &str) -> String {
    render_luaurc(root, INSTALLED_ALIASES)
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

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

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
                "testing",
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
            ]
        );
        assert!(installed.iter().all(|root| root.alias != TESTING.name));
        assert_eq!(
            installed
                .mounted()
                .filter(|root| root.required_for_installation())
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
            !installed.iter().any(ModuleRoot::optional),
            "every installed root is required"
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
            ]
        );
    }

    /// Every alias is a name a Luau require path can carry, no two roots
    /// share an alias or a directory, and the installed roots are development
    /// roots with the same resolution.
    #[test]
    fn the_built_in_roots_are_distinct_valid_aliases() {
        let valid = |name: &str| {
            !name.is_empty()
                && name.bytes().enumerate().all(|(index, byte)| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || (index > 0 && byte == b'-')
                })
        };
        let mut names = HashSet::new();
        let mut directories = HashSet::new();
        for alias in DEVELOPMENT_ALIASES {
            assert!(valid(alias.name), "{} is a valid alias", alias.name);
            assert!(names.insert(alias.name), "{} is unique", alias.name);
            assert!(
                directories.insert(alias.directory),
                "{} is unique",
                alias.directory
            );
        }
        assert!(
            INSTALLED_ALIASES
                .iter()
                .all(|alias| DEVELOPMENT_ALIASES.contains(alias))
        );
    }

    #[test]
    fn the_install_manifest_lists_every_installed_root_and_not_testing() {
        let manifest = install_manifest();
        for alias in INSTALLED_ALIASES {
            let line = format!("lua/{0}\tlua/{0}", alias.directory);
            assert!(manifest.lines().any(|entry| entry == line), "{line}");
        }
        assert!(!manifest.contains("testing"));
    }

    #[test]
    fn development_luaurc_includes_testing_and_installed_luaurc_does_not() {
        assert!(luaurc(".").contains("\"testing\": \"./testing\""));
        assert!(!installed_luaurc(".").contains("\"testing\""));
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
             \"./lunette\",\n    \"lunette-plugin\": \"./lunette-plugin\",\n    \"lunette-contracts\": \"./lunette-contracts\",\n    \"lunette-plugins\": \"./lunette-plugins\",\n    \"lunette-desktop\": \"./lunette-desktop\",\n    \"testing\": \"./testing\"\n  }\n}\n"
        );
    }
}
