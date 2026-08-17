//! The module roots a configuration reaches by name.
//!
//! `require '@mullion/panel'` has to resolve twice: once in the running
//! session, where LÖVR's virtual filesystem answers it, and once in the
//! checker, where Luau reads a `.luaurc` from disk exactly as an editor does.
//! Those are different mechanisms and neither can see the other, so the set of
//! roots is stated here and both derive from it. Stated twice, a root added to
//! one is a root the other silently does not have, and the symptom is a
//! configuration that runs but cannot be checked, or checks but does not run.
//!
//! The `.luaurc` files in the tree are generated from this, and
//! `lunette --dump-config` writes one beside the configuration it copies, so a
//! user's own configuration resolves the same names their editor does.

use std::fmt::Write as _;

/// A root a configuration requires by name, and where that name resolves.
#[derive(Clone, Copy, Debug)]
pub struct Alias {
    /// The name that follows the `@`.
    pub name: &'static str,
    /// The directory under the standard-library root that holds it. It is what
    /// the checker reads, and for a mounted root it is also what the session
    /// mounts.
    pub directory: &'static str,
    /// How a running session answers the name.
    pub resolution: Resolution,
}

/// How a running session answers a root, which is not how the checker does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// Mounted into LÖVR's virtual filesystem under the alias.
    Mounted,
    /// Registered natively through `package.preload`. The directory holds the
    /// generated declarations, which the checker reads and the session never
    /// does: nothing on disk answers `require '@lunette'` at runtime.
    Native,
}

/// The standard library's own module, which is Lua.
pub const MULLION: Alias = Alias {
    name: "mullion",
    directory: "mullion",
    resolution: Resolution::Mounted,
};

/// The native API, which exists on disk only as its declarations.
pub const LUNETTE: Alias = Alias {
    name: "lunette",
    directory: "lunette",
    resolution: Resolution::Native,
};

/// The specs, which a development tree has and an installed one does not.
pub const SPEC: Alias = Alias {
    name: "spec",
    directory: "spec",
    resolution: Resolution::Mounted,
};

/// Every root, in the order a `.luaurc` states them.
pub const ALIASES: &[Alias] = &[MULLION, LUNETTE, SPEC];

impl Alias {
    /// The mount point a session gives this root, for the ones it mounts.
    #[must_use]
    pub fn mount_point(&self) -> String {
        format!("@{}", self.name)
    }
}

/// Renders a `.luaurc` whose aliases resolve against `root`.
///
/// `root` is a path to the standard library, written as the file that carries
/// it must write it: relative to that file's own directory, since that is what
/// Luau resolves an alias against, or absolute where no relative path is stable.
#[must_use]
pub fn luaurc(root: &str) -> String {
    let mut out = String::from("{\n  \"languageMode\": \"strict\",\n  \"aliases\": {\n");
    for (index, alias) in ALIASES.iter().enumerate() {
        let separator = if index + 1 == ALIASES.len() { "" } else { "," };
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
    use super::*;

    #[test]
    fn every_root_is_named_once() {
        let mut names: Vec<&str> = ALIASES.iter().map(|alias| alias.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), ALIASES.len(), "two roots share a name");
    }

    #[test]
    fn a_relative_root_is_written_as_it_is_given() {
        assert_eq!(
            luaurc("."),
            "{\n  \"languageMode\": \"strict\",\n  \"aliases\": {\n    \"mullion\": \
             \"./mullion\",\n    \"lunette\": \"./lunette\",\n    \"spec\": \"./spec\"\n  }\n}\n"
        );
    }

    #[test]
    fn an_absolute_root_reaches_an_installed_standard_library() {
        let rendered = luaurc("/usr/local/share/lunette/lua");
        assert!(rendered.contains("\"mullion\": \"/usr/local/share/lunette/lua/mullion\""));
        assert!(rendered.contains("\"lunette\": \"/usr/local/share/lunette/lua/lunette\""));
    }

    /// The one root whose directory holds declarations rather than the modules
    /// a session runs, which is why the checker and the session disagree about
    /// it and both are right.
    #[test]
    fn the_native_module_is_not_mounted() {
        assert_eq!(LUNETTE.resolution, Resolution::Native);
        assert_eq!(MULLION.resolution, Resolution::Mounted);
        assert_eq!(SPEC.resolution, Resolution::Mounted);
    }

    #[test]
    fn a_mount_point_is_the_name_a_require_uses() {
        assert_eq!(MULLION.mount_point(), "@mullion");
        assert_eq!(SPEC.mount_point(), "@spec");
    }
}
