//! Runs each Lua test file under `lua/` and `dev/` as a separate test, in a fresh Lua state
//! with module roots from the working tree. [`meta`] tests the runner itself.

// `lovr.math` and the Luau C API come from `liblovr.so`, which this crate's
// link directives name.
extern crate lunette_lovr;

mod discover;
mod installed;
mod meta;
// The custom Lua harness uses the installed scan, not the support's Rust tests or Markdown checks.
#[expect(
    dead_code,
    unused_imports,
    reason = "shared support includes Rust tests and documentation checks unused by the custom Lua harness"
)]
#[path = "../support/plugin_dependencies/mod.rs"]
mod plugin_dependencies;
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
                    run_file(&roots, &file).map_err(Failed::from)
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

fn run_file(roots: &state::Roots, file: &discover::TestFile) -> Result<(), String> {
    let lua =
        state::new(roots).map_err(|error| format!("the test state could not be built: {error}"))?;
    if file.source == discover::Source::Development {
        state::use_configuration(&lua, roots.repository.join("dev")).map_err(|error| {
            format!("the development configuration could not be selected: {error}")
        })?;
    }
    run::module(&lua, &file.module)
}

/// The working tree that contains the `lua/` directory under test.
fn repository() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .map_or_else(|| PathBuf::from("."), Path::to_path_buf)
}
