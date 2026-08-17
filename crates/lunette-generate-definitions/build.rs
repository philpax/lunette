//! Gives the generator binary an rpath reaching LÖVR's shared libraries, the
//! same way `crates/lunette/build.rs` does. `lunette-lovr` builds `liblovr.so`
//! and publishes its directories through `cargo::metadata`; this keeps the
//! binary able to find it (and the Luau symbols it embeds) at runtime.

use std::env;

const LOVR_DIRECTORY_VARS: [&str; 2] = ["DEP_LOVR_LIBRARY_DIR", "DEP_LOVR_STAGED_DIR"];

fn main() {
    // `lunette-lovr` emits `rustc-link-lib=dylib=lovr` to its own target;
    // Cargo forwards a linked package's link-lib directives to dependents,
    // but emit it here too so this crate links `liblovr.so` even if the
    // forwarding is skipped for a bin crate.
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
