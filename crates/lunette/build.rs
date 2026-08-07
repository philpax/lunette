//! Linux-only: gives the binary an rpath reaching LÖVR's shared libraries.
//!
//! `lunette-lovr` finds `liblovr.so` and the staged `bin/` tree beside it, but
//! the `cargo::rustc-link-arg` directives it emits apply to its own package's
//! targets only. It republishes both directories through `cargo::metadata`,
//! which Cargo forwards here as `DEP_LOVR_*`, and this is where they become
//! rpath entries on the executable that actually needs them.

use std::env;

/// The metadata keys `crates/lunette-lovr/build.rs` publishes, in the form
/// Cargo forwards them under the `links = "lovr"` declaration.
const LOVR_DIRECTORY_VARS: [&str; 2] = ["DEP_LOVR_LIBRARY_DIR", "DEP_LOVR_STAGED_DIR"];

fn main() {
    // A build script is the sanctioned exception to the rule that a library
    // never reads the environment: Cargo passes `DEP_LOVR_*` through no other
    // channel.
    for name in LOVR_DIRECTORY_VARS {
        let Some(directory) = env::var_os(name) else {
            println!(
                "cargo::error={name} is unset. It is published by crates/lunette-lovr/build.rs \
                 through `cargo::metadata`, which requires `links = \"lovr\"` in that crate's \
                 manifest."
            );
            continue;
        };
        println!(
            "cargo::rustc-link-arg=-Wl,-rpath,{}",
            directory.to_string_lossy()
        );
    }

    // For the packaged cases. Cargo passes each string to `rustc -C link-arg`
    // with no shell involved, so the literal `$ORIGIN` reaches the dynamic
    // linker intact.
    //
    // `$ORIGIN` covers the single-directory layout an AppImage-style bundle
    // uses. `$ORIGIN/../lib/lunette` covers the installed one the `Makefile`
    // produces, where the executable is in `$PREFIX/bin` and the libraries are
    // where a prefix keeps libraries. `liblovr.so` carries `$ORIGIN` of its own,
    // so it resolves its siblings from whichever of the two it was found in.
    for entry in ["$ORIGIN", "$ORIGIN/../lib/lunette"] {
        println!("cargo::rustc-link-arg=-Wl,-rpath,{entry}");
    }
}
