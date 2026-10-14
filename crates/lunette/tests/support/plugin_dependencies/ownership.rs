//! Assigns each maintained source a precise owner and visibility boundary.

use std::path::{Component, Path};

use crate::plugin_dependencies::catalog::{
    EXTENSION_SUPPORT, LIBRARIES, LIBRARY_TESTS, LibraryDomain, PLUGINS,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Owner {
    Native,
    Facade,
    Contracts,
    Plugin(&'static str),
    Library(&'static str, LibraryDomain),
    Extension(&'static str),
    Desktop,
    Configuration,
    Example(String),
    Development(String),
    Testing,
    GraphicsTests,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Visibility {
    Public,
    Private,
    Test,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Entry,
    Config,
    Extension,
    Library,
    Implementation,
    Test,
    Support,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ownership {
    pub owner: Owner,
    pub visibility: Visibility,
    pub role: Role,
}

pub fn ownership(path: &Path) -> Result<Ownership, String> {
    if path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err("module path must be normalized and repository-relative".into());
    }
    let path = path.to_str().ok_or("module path is not UTF-8")?;
    if !path.ends_with(".luau") {
        return Err("module is not a Luau source".into());
    }
    if let Some(relative) = path.strip_prefix("lua/lunette-plugins/") {
        return plugin_ownership(relative);
    }
    for (root, owner) in [
        ("lua/lunette/", Owner::Native),
        ("lua/lunette-plugin/", Owner::Facade),
        ("lua/lunette-contracts/", Owner::Contracts),
        ("lua/lunette-desktop/", Owner::Desktop),
        ("lua/testing/", Owner::Testing),
        ("etc/xdg/lunette/", Owner::Configuration),
        (
            "crates/lunette/tests/graphics/fixtures/",
            Owner::GraphicsTests,
        ),
    ] {
        if let Some(relative) = path.strip_prefix(root) {
            let test = is_test(relative) || matches!(owner, Owner::GraphicsTests);
            let visibility = if test {
                Visibility::Test
            } else {
                Visibility::Public
            };
            let role = if test { Role::Test } else { Role::Support };
            return Ok(Ownership {
                owner,
                visibility,
                role,
            });
        }
    }
    if let Some(relative) = path.strip_prefix("examples/") {
        let name = relative
            .split('/')
            .next()
            .ok_or("example has no directory")?;
        return Ok(local_owner(Owner::Example(name.into()), relative));
    }
    if let Some(relative) = path.strip_prefix("dev/") {
        let owner = match relative.strip_prefix("plugins/") {
            Some(plugin) => Owner::Development(
                plugin
                    .split('/')
                    .next()
                    .ok_or("development plugin has no directory")?
                    .into(),
            ),
            None => Owner::Development("configuration".into()),
        };
        return Ok(local_owner(owner, relative));
    }
    Err("source has no declared owner".into())
}

pub fn public_plugin_files() -> Vec<String> {
    let mut paths = Vec::new();
    for plugin in PLUGINS {
        paths.push(format!("lua/lunette-plugins/{}/init.luau", plugin.leaf));
        if plugin.config {
            paths.push(format!("lua/lunette-plugins/{}/config.luau", plugin.leaf));
        }
        paths.extend(
            plugin
                .extensions
                .iter()
                .map(|extension| format!("lua/lunette-plugins/{}/{extension}.luau", plugin.leaf)),
        );
    }
    paths.extend(
        LIBRARIES
            .iter()
            .map(|library| format!("lua/lunette-plugins/{}.luau", library.module)),
    );
    paths
}

fn plugin_ownership(relative: &str) -> Result<Ownership, String> {
    let source = format!("lua/lunette-plugins/{relative}");
    if let Some(test) = LIBRARY_TESTS.iter().find(|test| test.source == source) {
        let library = LIBRARIES
            .iter()
            .find(|library| library.module == test.module)
            .ok_or("library test refers to an undeclared library")?;
        return Ok(Ownership {
            owner: Owner::Library(library.module, library.domain),
            visibility: Visibility::Test,
            role: Role::Test,
        });
    }
    for library in LIBRARIES {
        if relative == format!("{}.luau", library.module) {
            return Ok(Ownership {
                owner: Owner::Library(library.module, library.domain),
                visibility: Visibility::Public,
                role: Role::Library,
            });
        }
    }
    for library in EXTENSION_SUPPORT {
        if relative == format!("{}.luau", library.module) {
            let plugin = PLUGINS
                .iter()
                .find(|plugin| library.module.starts_with(&format!("{}/", plugin.leaf)))
                .ok_or("extension support has no owning plugin")?;
            return Ok(Ownership {
                owner: Owner::Extension(plugin.leaf),
                visibility: Visibility::Private,
                role: Role::Library,
            });
        }
    }
    for plugin in PLUGINS {
        let Some(rest) = relative.strip_prefix(&format!("{}/", plugin.leaf)) else {
            continue;
        };
        let (owner, visibility, role) = if is_test(rest) {
            (Owner::Plugin(plugin.leaf), Visibility::Test, Role::Test)
        } else if rest == "init.luau" {
            (Owner::Plugin(plugin.leaf), Visibility::Public, Role::Entry)
        } else if rest == "config.luau" && plugin.config {
            (Owner::Plugin(plugin.leaf), Visibility::Public, Role::Config)
        } else if plugin
            .extensions
            .iter()
            .any(|extension| rest == format!("{extension}.luau"))
        {
            (
                Owner::Extension(plugin.leaf),
                Visibility::Public,
                Role::Extension,
            )
        } else if rest.starts_with("private/") {
            (
                Owner::Plugin(plugin.leaf),
                Visibility::Private,
                Role::Implementation,
            )
        } else {
            return Err(format!(
                "undeclared export in {}; implementation belongs below private/",
                plugin.leaf
            ));
        };
        return Ok(Ownership {
            owner,
            visibility,
            role,
        });
    }
    Err("plugin category file has no declared leaf or exact library export".into())
}

fn local_owner(owner: Owner, relative: &str) -> Ownership {
    Ownership {
        owner,
        visibility: if is_test(relative) {
            Visibility::Test
        } else {
            Visibility::Private
        },
        role: if is_test(relative) {
            Role::Test
        } else {
            Role::Implementation
        },
    }
}

fn is_test(relative: &str) -> bool {
    relative.split('/').any(|part| part == "tests")
}
