//! Linux-only: adds rpath entries for LÖVR's shared libraries to the executable.
//!
//! `lunette-lovr` finds `liblovr.so` and the staged `bin/` tree beside it.
//! The `cargo::rustc-link-arg` directives it emits apply to its own package's targets.
//! The executable receives none of them. It republishes both directories
//! through `cargo::metadata`. Cargo forwards them here as `DEP_LOVR_*`.
//! The variables become rpath entries for the executable.

use std::env;

/// These are the metadata keys `crates/lunette-lovr/build.rs` publishes, in the form
/// Cargo forwards them under the `links = "lovr"` declaration.
const LOVR_DIRECTORY_VARS: [&str; 2] = ["DEP_LOVR_LIBRARY_DIR", "DEP_LOVR_STAGED_DIR"];

fn main() {
    // Libraries never read the environment. A build script is not a library:
    // Cargo passes `DEP_LOVR_*` through no other channel.
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

    // These entries cover the packaged cases. Cargo passes each string
    // to `rustc -C link-arg` with no shell involved, so the literal `$ORIGIN`
    // reaches the dynamic linker intact.
    //
    // `$ORIGIN` is the rpath for the single-directory layout an
    // AppImage-style bundle uses. `$ORIGIN/../lib/lunette` is the rpath for
    // the installed layout the `Makefile` produces. The executable is in
    // `$PREFIX/bin` in that layout, and the libraries are in the prefix's
    // library directory. `liblovr.so` has its own `$ORIGIN`, so it resolves
    // its sibling libraries from whichever of the two directories the loader
    // finds it in.
    for entry in ["$ORIGIN", "$ORIGIN/../lib/lunette"] {
        println!("cargo::rustc-link-arg=-Wl,-rpath,{entry}");
    }
}
