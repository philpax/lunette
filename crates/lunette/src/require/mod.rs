//! Relative `require` in a running session.
//!
//! LÖVR's loader takes a module name as a path from the root of its virtual
//! filesystem and knows nothing of the chunk that asked for it. The checker
//! resolves `./` and `../` against the requiring file, as Luau's
//! require-by-string rules say. Left alone, the two agree only for a module at
//! the configuration root. [`install`] wraps `require` so the session resolves
//! a relative path the way the checker does, and passes the loader the
//! resolved name, which also keys `package.loaded`: two files that require
//! `./util` from different directories get two modules.
//!
//! [`path`] holds the rules as a pure function.

mod hook;
pub mod path;

pub use hook::install;
pub use path::{Requirer, ResolveError, ResolveErrorKind, resolve};
