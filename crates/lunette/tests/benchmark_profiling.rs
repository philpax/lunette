//! Linux-only: runs benchmark sampler regressions under the normal integration-test harness.

#![cfg(target_os = "linux")]

// The external Luau C API is supplied by this crate's liblovr link directives.
extern crate lunette_lovr;

// The harness-free benchmark also sets cfg(test), so only this integration target includes tests.
/// Linux-only: samples benchmark Luau stacks at VM safepoints using the owning thread's CPU clock.
mod luau_sampler {
    include!("../benches/profiling/luau_sampler.rs");

    // Test failures may use expect to name the invariant that the fixture requires.
    #[expect(clippy::expect_used, reason = "test fixtures name required invariants")]
    mod tests {
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/benches/profiling/luau_sampler/tests.rs"
        ));
    }
}

/// Parses perf control acknowledgements, including an optional trailing NUL byte.
mod perf_ack {
    include!("../benches/profiling/perf_ack.rs");

    mod tests {
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/benches/profiling/perf_ack/tests.rs"
        ));
    }
}
