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

    // For the packaged case, where the libraries ship beside the executable.
    // Cargo passes the string to `rustc -C link-arg` with no shell involved, so
    // the literal `$ORIGIN` reaches the dynamic linker intact.
    println!("cargo::rustc-link-arg=-Wl,-rpath,$ORIGIN");
}
