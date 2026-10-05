//! Runs each Lua test file under `lua/` and `dev/` as a separate test.
//!
//! Test files are `.luau` files directly inside `tests` directories. Helpers belong under
//! `tests/support`. Each file runs in a fresh Lua state with module roots from the working
//! tree, LÖVR's `lovr.math`, the native plugin runtime, and the fake API in `lua/testing/`.
//! The runner fails when a file returns no suite, defines no cases, a case raises, or a
//! plugin failure remains unreported after its case.
//!
//! The tests use an in-process state to load working-tree modules. [`meta`] tests the
//! runner's own behavior.

// `lovr.math` and the Luau C API come from `liblovr.so`, which this crate's
// link directives name.
extern crate lunette_lovr;

mod discover;
mod installed;
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
    let mut trials = match discover::test_files(&roots.repository) {
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
    trials.push(installed::trial(roots.clone()));
    trials.extend(meta::trials(&roots));
    libtest_mimic::run(&arguments, trials).exit_code()
}

/// Returns the working tree that contains the `lua/` directory under test.
fn repository() -> PathBuf {
    // `crates/lunette` is two levels below the workspace root.
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}
