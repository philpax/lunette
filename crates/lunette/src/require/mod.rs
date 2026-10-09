//! Relative `require` resolution for running sessions.
//!
//! LÖVR resolves names from the filesystem root, so [`install`] resolves `./` and
//! `../` against the requiring file and keys `package.loaded` by the resolved name.

mod hook;
mod path;

pub use hook::install;
