//! Linux-only: profiles benchmark update/draw callbacks with Luau sampling and optional perf FIFO control.

pub mod jit_symbols;
/// Linux-only: samples benchmark Luau stacks at VM safepoints using the owning thread's CPU clock.
mod luau_sampler;
/// Parses perf control acknowledgements, including an optional trailing NUL byte.
mod perf_ack;
mod session;

pub use session::Session;
