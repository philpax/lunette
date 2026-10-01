//! Relative `require` in a running session.
//!
//! LÖVR's loader resolves a name from the filesystem root, while the checker
//! resolves `./` and `../` against the requiring file. [`install`] wraps
//! `require` so the session agrees with the checker and keys `package.loaded`
//! by the resolved name. [`path`] holds the rules as a pure function.

mod hook;
pub mod path;

pub use hook::install;
pub use path::{Requirer, ResolveError, ResolveErrorKind, resolve};
