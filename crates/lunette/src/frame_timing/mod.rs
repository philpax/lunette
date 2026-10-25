//! Opt-in coherent CPU frame observation owned by the host, with no callback rebinding or GPU readbacks.

#[cfg(test)]
mod branch_tests;
mod host;
#[cfg(test)]
mod tests;

#[cfg(test)]
use host::publish;
pub(crate) use host::{FrameTiming, Listener, clear, observe};
pub use host::{active, collected, install, instrument_boot, publish_reported, sampler};
