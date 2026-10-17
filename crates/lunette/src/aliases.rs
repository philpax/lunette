//! Module roots, session mounts, and installation metadata.
//!
//! The checker, session, and installer derive root configuration from these descriptors.

use std::{fmt::Write as _, path::PathBuf};

/// A root a configuration requires by name, and where that name resolves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Alias {
    /// The alias, which is also the root's directory under the standard-library root.
    pub name: &'static str,
    pub resolution: Resolution,
}

/// How a running session resolves a root.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// Mounted into LÖVR's virtual filesystem under the alias.
    Mounted,
    /// Registered natively through `package.preload`. The directory holds the
    /// generated declarations, which only the checker reads.
    Native,
}

/// The native API, whose on-disk form is its declarations.
pub const LUNETTE: Alias = Alias {
    name: "lunette",
    resolution: Resolution::Native,
};

/// The single plugin facade mounted by a running session.
pub const LUNETTE_PLUGIN: Alias = Alias {
    name: "lunette-plugin",
    resolution: Resolution::Mounted,
};

/// Types shared by the plugin facade and plugin implementations.
pub const LUNETTE_CONTRACTS: Alias = Alias {
    name: "lunette-contracts",
    resolution: Resolution::Mounted,
};

/// Every built-in plugin, provider or consumer, mounted by a running session.
pub const LUNETTE_PLUGINS: Alias = Alias {
    name: "lunette-plugins",
    resolution: Resolution::Mounted,
};

/// The shipped desktop: the entry list that composes the built-in plugins.
/// The default configuration requires it; safe mode does not.
pub const LUNETTE_DESKTOP: Alias = Alias {
    name: "lunette-desktop",
    resolution: Resolution::Mounted,
};

/// The test scaffolding, present only in a development tree.
pub const TESTING: Alias = Alias {
    name: "testing",
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleRoot {
    pub alias: String,
    /// The already-resolved directory containing the root's modules.
    pub source: PathBuf,
    pub resolution: Resolution,
}

impl ModuleRoot {
    #[must_use]
    pub fn mount_point(&self) -> String {
        format!("@{}", self.alias)
    }

    /// Whether a session requires the root. Only the development-only testing
    /// root is optional.
    #[must_use]
    pub fn required(&self) -> bool {
        self.alias != TESTING.name
    }
}

/// A collection of resolved module roots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModuleRoots {
    roots: Vec<ModuleRoot>,
}

impl ModuleRoots {
    /// Builds the development roots, including testing, below an already-resolved
    /// standard-library directory.
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
                source: source.join(alias.name),
                resolution: alias.resolution,
            })
            .collect();
        Self { roots }
    }
}

/// An explicit file installed below `$PREFIX/share/lunette`, including assets
/// within module roots.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InstallArtifact {
    /// A source path in the repository.
    pub source: &'static str,
    /// A destination path relative to the installed lunette data directory.
    pub destination: &'static str,
}

/// The explicit files an installed Luau runtime needs, including non-Luau assets.
/// Every installed root's directory is installed from `lua/` to `lua/`; the
/// manifest derives those directory entries from [`INSTALLED_ALIASES`].
pub const INSTALL_ARTIFACTS: &[InstallArtifact] = &[
    InstallArtifact {
        source: "etc/lunette/definitions.luau",
        destination: "definitions.luau",
    },
    InstallArtifact {
        source: "etc/lunette/installed.luaurc",
        destination: "lua/.luaurc",
    },
    InstallArtifact {
        source: "lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf",
        destination: "lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-Regular.ttf",
    },
    InstallArtifact {
        source: "lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-Medium.ttf",
        destination: "lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-Medium.ttf",
    },
    InstallArtifact {
        source: "lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-SemiBold.ttf",
        destination: "lua/lunette-plugins/ui/standard/fonts/IBMPlexSans-SemiBold.ttf",
    },
    InstallArtifact {
        source: "lua/lunette-plugins/ui/standard/fonts/Iosevka-Regular.ttf",
        destination: "lua/lunette-plugins/ui/standard/fonts/Iosevka-Regular.ttf",
    },
    InstallArtifact {
        source: "lua/lunette-plugins/ui/standard/fonts/OFL-IBMPlex.txt",
        destination: "lua/lunette-plugins/ui/standard/fonts/OFL-IBMPlex.txt",
    },
    InstallArtifact {
        source: "lua/lunette-plugins/ui/standard/fonts/OFL-Iosevka.md",
        destination: "lua/lunette-plugins/ui/standard/fonts/OFL-Iosevka.md",
    },
    InstallArtifact {
        source: "vendor/lovr/deps/openvr/LICENSE",
        destination: "licenses/OpenVR.txt",
    },
];

/// Lists the install manifest as source and destination paths.
///
/// Module roots include `.luau` files outside `tests` directories. Explicit files
/// are installed regardless of extension. The testing root is not installed.
#[must_use]
pub fn install_manifest() -> Vec<(String, String)> {
    let roots = INSTALLED_ALIASES.iter().map(|alias| {
        let directory = format!("lua/{}", alias.name);
        (directory.clone(), directory)
    });
    let artifacts = INSTALL_ARTIFACTS
        .iter()
        .map(|artifact| (artifact.source.to_owned(), artifact.destination.to_owned()));
    roots.chain(artifacts).collect()
}

/// Renders a development `.luaurc`, including the testing root, whose aliases resolve against `root`.
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
        let _ = writeln!(out, "    \"{0}\": \"{root}/{0}\"{separator}", alias.name);
    }
    out.push_str("  }\n}\n");
    out
}
