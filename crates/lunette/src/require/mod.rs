//! Relative `require` resolution for running sessions.
//!
//! LÖVR resolves names from the filesystem root. [`install`] resolves `./` and
//! `../` against the requiring file and keys `package.loaded` by the resolved
//! name. The `path` module defines the resolution rules.

mod hook;
mod path;

pub use hook::install;
