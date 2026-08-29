//! The build script adds an rpath for LÖVR's shared libraries to the
//! generator binary, as `crates/lunette/build.rs` does.
//! `lunette-lovr` builds `liblovr.so` and publishes its directories through
//! `cargo::metadata`. At runtime, the dynamic linker resolves `liblovr.so`
//! and the Luau symbols it embeds through the rpath.

use std::env;

const LOVR_DIRECTORY_VARS: [&str; 2] = ["DEP_LOVR_LIBRARY_DIR", "DEP_LOVR_STAGED_DIR"];

fn main() {
    // `lunette-lovr` emits `rustc-link-lib=dylib=lovr` to its own target.
    // Cargo forwards a linked package's link-lib directives to dependents.
    // The build script also emits it here. The crate links `liblovr.so`
    // even when Cargo does not forward the directive to a bin crate.
    println!("cargo::rustc-link-lib=dylib=lovr");

    for name in LOVR_DIRECTORY_VARS {
        let Some(directory) = env::var_os(name) else {
            println!("cargo::rustc-link-arg=-Wl,-rpath,/nonexistent");
            continue;
        };
        println!(
            "cargo::rustc-link-arg=-Wl,-rpath,{}",
            directory.to_string_lossy()
        );
    }
}
