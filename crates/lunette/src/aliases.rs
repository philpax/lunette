//! The module roots a configuration resolves by name.
//!
//! `require '@mullion/panel'` resolves twice. The running session resolves
//! it from LÖVR's virtual filesystem. In the checker, Luau resolves it from
//! a `.luaurc` on disk, as an editor does. The two mechanisms are
//! independent, so the set of roots is stated once and both derive from it.
//! With the roots stated twice, a root added to one mechanism is a root the
//! other silently does not have, and the configuration then runs but cannot
//! be checked, or checks but does not run.
//!
//! The `.luaurc` files in the tree are generated from these aliases.
//! `lunette --dump-config` writes one beside the configuration it copies,
//! and a user's configuration resolves the same names their editor does.

use std::fmt::Write as _;

/// A root a configuration requires by name, and where that name resolves.
#[derive(Clone, Copy, Debug)]
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

/// The standard library's own module, written in Lua.
pub const MULLION: Alias = Alias {
    name: "mullion",
    directory: "mullion",
    resolution: Resolution::Mounted,
};

/// The native API, whose on-disk form is its declarations.
pub const LUNETTE: Alias = Alias {
    name: "lunette",
    directory: "lunette",
    resolution: Resolution::Native,
};

/// The specs, present in a development tree, absent from an installed one.
pub const SPEC: Alias = Alias {
    name: "spec",
    directory: "spec",
    resolution: Resolution::Mounted,
};

/// Every root, in the order a `.luaurc` states them.
pub const ALIASES: &[Alias] = &[MULLION, LUNETTE, SPEC];

impl Alias {
    /// The mount point a session gives a root it mounts.
    #[must_use]
    pub fn mount_point(&self) -> String {
        format!("@{}", self.name)
    }
}

/// Renders a `.luaurc` whose aliases resolve against `root`.
///
/// `root` is a path to the standard library, written as the file that carries
/// it must write it: relative to that file's own directory, since Luau resolves
/// an alias against that, or absolute where no relative path is stable.
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
