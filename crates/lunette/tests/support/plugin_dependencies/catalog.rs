//! Declared ownership and supported imports for the shipped plugin hierarchy.
//!
//! This inventory validates source boundaries; it does not discover or activate runtime plugins.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plugin {
    pub previous: &'static str,
    pub leaf: &'static str,
    pub config: bool,
    pub extensions: &'static [&'static str],
}

pub const CATEGORIES: &[&str] = &[
    "audio",
    "diagnostics",
    "environment",
    "graphics",
    "input",
    "interaction",
    "layout",
    "lifecycle",
    "menu",
    "pacing",
    "panels",
    "registration",
    "scale",
    "session",
    "theme",
    "ui",
    "window",
    "workspace",
];

pub const PLUGINS: &[Plugin] = &[
    Plugin {
        previous: "audio",
        leaf: "audio/capture",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "audio-analysis",
        leaf: "audio/analysis",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "errors",
        leaf: "diagnostics/error-stream",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/errors",
        leaf: "diagnostics/error-display",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/backdrop",
        leaf: "environment/backdrop",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/hint",
        leaf: "environment/empty-desktop-hint",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "bindings",
        leaf: "input/bindings",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "focus",
        leaf: "input/focus",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/input",
        leaf: "input/physical-routing",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "keyboard",
        leaf: "input/keyboard",
        config: true,
        extensions: &["legend", "hooks"],
    },
    Plugin {
        previous: "keyboard-display",
        leaf: "input/keyboard-display",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "laser",
        leaf: "input/laser",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/pointing",
        leaf: "input/hand-pointers",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "surfaces",
        leaf: "interaction/surfaces",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "interaction",
        leaf: "interaction/pointers",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "drops",
        leaf: "interaction/drops",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "layouts",
        leaf: "layout/catalog",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "layout/arc",
        leaf: "layout/arc",
        config: true,
        extensions: &["geometry"],
    },
    Plugin {
        previous: "desktop/arrange",
        leaf: "layout/arrange",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "arrangement",
        leaf: "layout/persistence",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "menu",
        leaf: "menu/action-registry",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/menu",
        leaf: "menu/wrist-menu",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "pacing",
        leaf: "pacing/service",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/pacing",
        leaf: "pacing/controller",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "panels",
        leaf: "panels/service",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/render",
        leaf: "panels/renderer",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/decorations",
        leaf: "panels/decorations",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/monitors",
        leaf: "panels/monitors",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "scale",
        leaf: "scale/service",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/scale",
        leaf: "scale/output-controller",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "frame",
        leaf: "session/frame",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/actions",
        leaf: "session/menu-actions",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/manager",
        leaf: "session/plugin-manager",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "theme",
        leaf: "theme/resolver",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "themes",
        leaf: "theme/catalog",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "theme/standard",
        leaf: "theme/standard",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "theme/arcade",
        leaf: "theme/arcade",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/theme",
        leaf: "theme/selector",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "ui",
        leaf: "ui/toolkit",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "rules",
        leaf: "window/rule-resolver",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/rules",
        leaf: "window/configured-rules",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "placement",
        leaf: "window/placement",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "adoption",
        leaf: "window/adoption",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/adoption",
        leaf: "window/adoption-controller",
        config: true,
        extensions: &[],
    },
    Plugin {
        previous: "tags",
        leaf: "workspace/tags",
        config: false,
        extensions: &[],
    },
    Plugin {
        previous: "desktop/workspaces",
        leaf: "workspace/controller",
        config: true,
        extensions: &[],
    },
];

/// Libraries have exact exports; other files in their category are not implicitly public.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Library {
    pub module: &'static str,
    pub domain: LibraryDomain,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibraryDomain {
    Graphics,
    Registration,
    Lifecycle,
    Diagnostics,
    ThemeConfiguration,
    UiConfiguration,
    Picking,
    KeyboardHooks,
}

pub const LIBRARIES: &[Library] = &[
    Library {
        module: "graphics/pass-state",
        domain: LibraryDomain::Graphics,
    },
    Library {
        module: "graphics/client-pixels",
        domain: LibraryDomain::Graphics,
    },
    Library {
        module: "graphics/rounded-geometry",
        domain: LibraryDomain::Graphics,
    },
    Library {
        module: "graphics/rounded-drawing",
        domain: LibraryDomain::Graphics,
    },
    Library {
        module: "registration/listeners",
        domain: LibraryDomain::Registration,
    },
    Library {
        module: "registration/registry",
        domain: LibraryDomain::Registration,
    },
    Library {
        module: "lifecycle/cleanup",
        domain: LibraryDomain::Lifecycle,
    },
    Library {
        module: "diagnostics/protected-call",
        domain: LibraryDomain::Diagnostics,
    },
    Library {
        module: "diagnostics/desktop-logging",
        domain: LibraryDomain::Diagnostics,
    },
    Library {
        module: "theme/configuration",
        domain: LibraryDomain::ThemeConfiguration,
    },
    Library {
        module: "theme/base",
        domain: LibraryDomain::ThemeConfiguration,
    },
    Library {
        module: "ui/titlebar-configuration",
        domain: LibraryDomain::UiConfiguration,
    },
    Library {
        module: "interaction/picking",
        domain: LibraryDomain::Picking,
    },
];

/// The extension owns shared bounds without exposing the private keyboard renderer.
pub const EXTENSION_SUPPORT: &[Library] = &[Library {
    module: "input/keyboard/legend-bounds",
    domain: LibraryDomain::KeyboardHooks,
}];

pub const CONTRACT_SCHEMAS: &[&str] = &["theme", "frame-style", "titlebar-style", "rules"];

/// The scanner covers maintained code, including sources outside the alias-config tree.
pub const SOURCE_ROOTS: &[&str] = &[
    "lua/lunette",
    "lua/lunette-plugin",
    "lua/lunette-contracts",
    "lua/lunette-plugins",
    "lua/lunette-desktop",
    "lua/testing",
    "etc/xdg/lunette",
    "examples",
    "dev",
    "crates/lunette/tests/graphics/fixtures",
];

/// Category and leaf guides are derived from this inventory, without consulting Git history.
pub const DOCUMENTATION_FILES: &[&str] = &[
    "CONTRIBUTING.md",
    "lua/lunette-plugins/README.md",
    "lua/lunette-contracts/README.md",
    "lua/lunette-contracts/schemas/README.md",
    "docs/development/standard-plugins.md",
    "docs/development/build-and-development.md",
    "docs/users/desktop-configuration.md",
    "docs/users/runtime-manager.md",
];
pub const DOCUMENTATION_DIRECTORIES: &[&str] = &["docs/plugins"];

pub const REMOVED_HELPERS: &[&str] = &[
    "cleanup",
    "listeners",
    "registry",
    "protected",
    "pass-state",
    "client-pixels",
    "theme/descriptors",
    "theme/frame-style",
    "theme/rounded-geometry",
    "theme/drawing",
    "desktop/logging",
];

/// Test access is an exact edge, rather than access to an entire implementation directory.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WhiteboxEdge {
    pub source: &'static str,
    pub target: &'static str,
    pub rationale: &'static str,
}

pub const WHITEBOX_EDGES: &[WhiteboxEdge] = &[
    WhiteboxEdge {
        source: "crates/lunette/tests/graphics/fixtures/aurora-bands.luau",
        target: "environment/backdrop/private/rendering/shader.luau",
        rationale: "The real graphics fixture compiles the backdrop shader with band specialization.",
    },
    WhiteboxEdge {
        source: "crates/lunette/tests/graphics/fixtures/aurora-bands.luau",
        target: "environment/backdrop/private/rendering/model.luau",
        rationale: "The real graphics fixture drives the shader from the backdrop model.",
    },
    WhiteboxEdge {
        source: "crates/lunette/tests/graphics/fixtures/aurora-baseline.luau",
        target: "environment/backdrop/private/rendering/model.luau",
        rationale: "The baseline fixture compares rendered response with the backdrop model.",
    },
    WhiteboxEdge {
        source: "crates/lunette/tests/graphics/fixtures/support/aurora.luau",
        target: "environment/backdrop/private/rendering/model.luau",
        rationale: "The graphics support module retains the actual backdrop transition model.",
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Preloaded {
    Native,
    TestHost,
}

impl Preloaded {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Native => "@lunette",
            Self::TestHost => "@testing/host",
        }
    }
}

/// Only the observation API receives the overlay; ordinary checking keeps its configuration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AliasContext {
    SourceConfiguration,
    DevelopmentRoots,
    InstalledRoots,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResolutionContext {
    pub aliases: AliasContext,
    pub preloads: &'static [Preloaded],
}

pub const PRODUCTION_CONTEXT: ResolutionContext = ResolutionContext {
    aliases: AliasContext::SourceConfiguration,
    preloads: &[Preloaded::Native],
};
pub const TEST_CONTEXT: ResolutionContext = ResolutionContext {
    aliases: AliasContext::SourceConfiguration,
    preloads: &[Preloaded::Native, Preloaded::TestHost],
};
pub const GRAPHICS_CONTEXT: ResolutionContext = ResolutionContext {
    aliases: AliasContext::DevelopmentRoots,
    preloads: &[Preloaded::Native, Preloaded::TestHost],
};
pub const INSTALLED_CONTEXT: ResolutionContext = ResolutionContext {
    aliases: AliasContext::InstalledRoots,
    preloads: &[Preloaded::Native],
};

/// A runner load resolves under one configuration, not an alias inferred from the request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConfiguredLoad {
    pub source: &'static str,
    pub literal: &'static str,
    pub configuration: &'static str,
    pub target: &'static str,
}

pub const CONFIGURED_LOADS: &[ConfiguredLoad] = &[
    ConfiguredLoad {
        source: "dev/tests/startup.luau",
        literal: "conf",
        configuration: "dev",
        target: "dev/conf.luau",
    },
    ConfiguredLoad {
        source: "dev/tests/startup.luau",
        literal: "main",
        configuration: "dev",
        target: "dev/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_audio_composition.luau",
        literal: "tests/composition",
        configuration: "examples/audio-backdrop",
        target: "examples/audio-backdrop/tests/composition.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_audio_consumer.luau",
        literal: "tests/consumer",
        configuration: "examples/audio-backdrop",
        target: "examples/audio-backdrop/tests/consumer.luau",
    },
    ConfiguredLoad {
        source: "examples/audio-backdrop/tests/composition.luau",
        literal: "main",
        configuration: "examples/audio-backdrop",
        target: "examples/audio-backdrop/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_desktop.luau",
        literal: "main",
        configuration: "examples/desktop",
        target: "examples/desktop/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_desktop.luau",
        literal: "hide-windows",
        configuration: "examples/desktop",
        target: "examples/desktop/hide-windows.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_desktop.luau",
        literal: "save-menu",
        configuration: "examples/desktop",
        target: "examples/desktop/save-menu.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_first_plugin.luau",
        literal: "main",
        configuration: "examples/first-plugin",
        target: "examples/first-plugin/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_keyboard.luau",
        literal: "main",
        configuration: "examples/keyboard",
        target: "examples/keyboard/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_keyboard.luau",
        literal: "split",
        configuration: "examples/keyboard",
        target: "examples/keyboard/split.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_layout.luau",
        literal: "main",
        configuration: "examples/layout",
        target: "examples/layout/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_layout.luau",
        literal: "grid",
        configuration: "examples/layout",
        target: "examples/layout/grid.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_theme.luau",
        literal: "main",
        configuration: "examples/theme",
        target: "examples/theme/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_theme.luau",
        literal: "dusk",
        configuration: "examples/theme",
        target: "examples/theme/dusk.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_ui.luau",
        literal: "main",
        configuration: "examples/ui",
        target: "examples/ui/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/example_ui.luau",
        literal: "form",
        configuration: "examples/ui",
        target: "examples/ui/form.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-desktop/tests/startup.luau",
        literal: "main",
        configuration: "etc/xdg/lunette",
        target: "etc/xdg/lunette/main.luau",
    },
    ConfiguredLoad {
        source: "lua/lunette-plugins/environment/backdrop/tests/reloads.luau",
        literal: "main",
        configuration: "lua/lunette-plugins/environment/backdrop/tests/support/source-reload",
        target: "lua/lunette-plugins/environment/backdrop/tests/support/source-reload/main.luau",
    },
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConfigurationSwitch {
    pub source: &'static str,
    pub configuration: &'static str,
}

pub const CONFIGURATION_SWITCHES: &[ConfigurationSwitch] = &[
    ConfigurationSwitch {
        source: "dev/tests/startup.luau",
        configuration: "dev",
    },
    ConfigurationSwitch {
        source: "examples/audio-backdrop/tests/composition.luau",
        configuration: "examples/audio-backdrop",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_audio_composition.luau",
        configuration: "examples/audio-backdrop",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_audio_consumer.luau",
        configuration: "examples/audio-backdrop",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_desktop.luau",
        configuration: "examples/desktop",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_first_plugin.luau",
        configuration: "examples/first-plugin",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_keyboard.luau",
        configuration: "examples/keyboard",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_layout.luau",
        configuration: "examples/layout",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_theme.luau",
        configuration: "examples/theme",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/example_ui.luau",
        configuration: "examples/ui",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/startup.luau",
        configuration: "etc/xdg/lunette",
    },
    ConfigurationSwitch {
        source: "lua/lunette-desktop/tests/startup.luau",
        configuration: "lua/lunette-desktop/tests/support/vr-reload",
    },
    ConfigurationSwitch {
        source: "lua/lunette-plugins/environment/backdrop/tests/reloads.luau",
        configuration: "lua/lunette-plugins/environment/backdrop/tests/support/source-reload",
    },
];

pub const TEST_HOST_SOURCES: &[&str] = &["lua/testing/init.luau", "lua/testing/native.luau"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LibraryTest {
    pub source: &'static str,
    pub module: &'static str,
}

pub const LIBRARY_TESTS: &[LibraryTest] = &[LibraryTest {
    source: "lua/lunette-plugins/registration/tests/listeners.luau",
    module: "registration/listeners",
}];

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn inventory_is_complete_and_unambiguous() {
        assert_eq!(CATEGORIES.len(), 18);
        assert_eq!(PLUGINS.len(), 46);
        assert_eq!(PLUGINS.iter().filter(|plugin| plugin.config).count(), 28);
        let categories: BTreeSet<_> = CATEGORIES.iter().copied().collect();
        assert_eq!(categories.len(), CATEGORIES.len());
        let leaves: BTreeSet<_> = PLUGINS.iter().map(|plugin| plugin.leaf).collect();
        let previous: BTreeSet<_> = PLUGINS.iter().map(|plugin| plugin.previous).collect();
        assert_eq!(leaves.len(), PLUGINS.len());
        assert_eq!(previous.len(), PLUGINS.len());
        for plugin in PLUGINS {
            let Some((category, leaf)) = plugin.leaf.split_once('/') else {
                panic!("plugin leaf has no category: {}", plugin.leaf);
            };
            assert!(categories.contains(category), "{}", plugin.leaf);
            assert!(!leaf.contains('/'), "{}", plugin.leaf);
        }
        let libraries: BTreeSet<_> = LIBRARIES.iter().map(|library| library.module).collect();
        assert_eq!(libraries.len(), LIBRARIES.len());
        for library in LIBRARIES {
            assert!(!leaves.contains(library.module));
            assert!(
                library
                    .module
                    .split('/')
                    .next()
                    .is_some_and(|category| categories.contains(category))
            );
        }
        let edges: BTreeSet<_> = WHITEBOX_EDGES
            .iter()
            .map(|edge| (edge.source, edge.target))
            .collect();
        assert_eq!(edges.len(), WHITEBOX_EDGES.len());
        assert!(WHITEBOX_EDGES.iter().all(|edge| !edge.rationale.is_empty()));
    }
}
