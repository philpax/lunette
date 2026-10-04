//! Relative `require` resolution for running sessions.
//!
//! LÖVR resolves names from the filesystem root. [`install`] resolves `./` and
//! `../` against the requiring file and keys `package.loaded` by the resolved
//! name. [`path`] defines the resolution rules.

mod hook;
pub mod path;

pub use hook::install;
pub use path::{Requirer, ResolveError, ResolveErrorKind, resolve};
