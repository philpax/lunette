//! Runs every Lua test file under `lua/`, each as a test of its own.
//!
//! A test file is a `.luau` file directly inside a directory named `tests`;
//! its helpers live in that directory's `support/` subdirectory and are not
//! test files. [`discover`] states the rule. Each file runs in a fresh Lua
//! state that [`state`] builds: the module roots resolve as a session resolves
//! them, `lovr.math` is LÖVR's own, and `@testing/host` carries what only the
//! host can do. The file returns a suite of cases, and [`run`] runs every case
//! and fails the file when it returns no suite, defines no cases, a case
//! raises, or a plugin failure is reported that no case took.
//!
//! The state is in-process rather than a session of the binary: the module
//! sources are read from the working tree, the native plugin runtime is the
//! real one, and the rest of the native API is the fake in `lua/testing/`.
//! [`meta`] holds the runner's own tests, which run beside the files.

// `lovr.math` and the Luau C API come from `liblovr.so`, which this crate's
// link directives name.
extern crate lunette_lovr;

mod discover;
mod meta;
mod run;
mod state;

use std::{
    path::{Path, PathBuf},
    process::ExitCode,
};

use libtest_mimic::{Arguments, Failed, Trial};

fn main() -> ExitCode {
    let arguments = Arguments::from_args();
    let roots = state::Roots::of_repository(repository());
    let mut trials = match discover::test_files(&roots.lua) {
        Ok(files) => files
            .into_iter()
            .map(|file| {
                let roots = roots.clone();
                Trial::test(file.name.clone(), move || {
                    run::file(&roots, &file).map_err(Failed::from)
                })
            })
            .collect::<Vec<_>>(),
        Err(error) => vec![Trial::test("discovery", move || {
            Err(Failed::from(error.to_string()))
        })],
    };
    trials.extend(meta::trials(&roots));
    libtest_mimic::run(&arguments, trials).exit_code()
}

/// The working tree the runner was built from. The tests cover its `lua/`
/// directory as it stands, with no copy assembled for them.
fn repository() -> PathBuf {
    // `crates/lunette` is two levels below the workspace root.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}
