//! The output enumeration against a real Wayland compositor.
//!
//! `lunette_capture::monitor::outputs` is unit-tested over its pure accumulator,
//! which covers every decision it makes but nothing about the protocol exchange
//! that feeds it. This is the other half: a real `wl_registry`, a real
//! `wl_output`, real events over a real socket, and the roster that comes out.
//!
//! The compositor is lunette's own. It needs no graphics device — its buffer
//! importer is a fake — no XR runtime, no display, and no listening socket, so
//! this runs on a machine at a bare TTY.
//!
//! # Which side is on which thread
//!
//! `TestCompositor` is driven by the test stepping it, and the enumeration's two
//! round trips block until the compositor answers. So the enumeration goes on a
//! thread of its own and the test steps the compositor until it finishes.
//!
//! The client end of the pair is put back into blocking mode for that reason:
//! `TestCompositor::connect` sets it non-blocking because its usual caller lives
//! on the compositor's own thread, and that is exactly what is not true here.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    os::unix::net::UnixStream,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use lunette_capture::monitor::{OutputWatcher, PixelExtent, Roster, SurfaceTransform};
use lunette_compositor::{
    protocol::{OutputMode, OutputScale, PixelSize, RefreshRate},
    state::CompositorConfig,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

/// How long the compositor is stepped before the exchange is called stuck.
///
/// A deadline on a condition, not a wait for a duration: the loop below steps
/// until the enumeration finishes, and this only bounds how long a broken
/// exchange hangs the suite.
const DEADLINE: Duration = Duration::from_secs(10);

#[test]
fn the_compositors_only_output_is_enumerated_as_one_monitor() {
    let (roster, _) = enumerate(CompositorConfig::default());
    let monitors = roster.monitors();

    assert_eq!(monitors.len(), 1, "the compositor advertises one wl_output");
    assert_eq!(monitors[0].name().make(), Some("lunette"));
    assert_eq!(monitors[0].name().model(), Some("virtual display"));
}

#[test]
fn the_monitors_resolution_is_the_mode_the_compositor_set() {
    // `lunette-v1.AC3.1` is about this number: what a mirrored monitor reports
    // has to be the resolution of the output behind it.
    let (roster, _) = enumerate(config(PixelSize::new(2560, 1440)));

    assert_eq!(
        roster.monitors()[0].pixels(),
        PixelExtent::new(2560, 1440),
        "the mode reached the roster unchanged",
    );
}

#[test]
fn a_mode_change_is_carried_through_to_the_roster() {
    // Two runs against two configurations rather than one assertion against a
    // constant, so the test fails if the size is being invented rather than read.
    let (small, _) = enumerate(config(PixelSize::new(1280, 720)));
    let (large, _) = enumerate(config(PixelSize::new(3840, 2160)));

    assert_eq!(small.monitors()[0].pixels(), PixelExtent::new(1280, 720));
    assert_eq!(large.monitors()[0].pixels(), PixelExtent::new(3840, 2160));
}

#[test]
fn the_logical_size_is_derived_when_the_compositor_offers_no_xdg_output() {
    // lunette's compositor advertises no `zxdg_output_manager_v1`, so this
    // exercises the fallback against a real compositor rather than a hand-built
    // set of events: the logical size comes from `wl_output.mode` divided by
    // `wl_output.scale`, which is one here.
    let (roster, logical_geometry) = enumerate(config(PixelSize::new(2560, 1440)));

    assert!(
        !logical_geometry,
        "this test is about the fallback, and there is nothing to fall back from"
    );
    assert_eq!(roster.monitors()[0].size().width, 2560);
    assert_eq!(roster.monitors()[0].size().height, 1440);
}

#[test]
fn an_unrotated_output_reaches_the_roster_unrotated() {
    // The compositor sets `Transform::Normal`, and the value has to survive the
    // trip rather than being defaulted at the far end — which is what it was
    // doing before the enumeration existed.
    let (roster, _) = enumerate(CompositorConfig::default());

    assert_eq!(roster.monitors()[0].transform(), SurfaceTransform::Normal);
}

#[test]
fn an_output_name_that_is_not_a_connector_is_not_stored_as_one() {
    // The compositor names its output `lunette-0`, which is not a DRM connector
    // type, so the monitor is identified by its descriptor instead.
    let (roster, _) = enumerate(CompositorConfig::default());

    assert_eq!(roster.monitors()[0].name().connector(), None);
    assert_eq!(
        roster.monitors()[0].key().to_string(),
        "lunette virtual display",
    );
}

/// A configuration whose output runs at `size`, unscaled.
fn config(size: PixelSize) -> CompositorConfig {
    CompositorConfig {
        output: OutputMode {
            size,
            scale: OutputScale::new(1.0).expect("one is positive"),
            refresh: RefreshRate::from_millihertz(60_000),
        },
        ..CompositorConfig::default()
    }
}

/// Runs the enumeration against a compositor built from `config`.
///
/// Returns the roster and whether logical geometry was reported rather than
/// derived, which is the second thing every caller here wants to know.
fn enumerate(config: CompositorConfig) -> (Roster, bool) {
    let mut compositor = TestCompositor::with_config(config);
    let (stream, _client) = compositor.connect();
    stream
        .set_nonblocking(false)
        .expect("a socket pair accepts the flag");

    let watching = watch(stream);

    let deadline = Instant::now() + DEADLINE;
    while !watching.is_finished() {
        assert!(
            Instant::now() < deadline,
            "the compositor never answered the output enumeration"
        );
        // A blocking wait on the event loop with a short timeout, so the loop
        // does not spin: what it is waiting for is the watcher's requests
        // arriving, not the clock.
        compositor.step_for(Duration::from_millis(5));
    }

    let watcher = watching
        .join()
        .expect("the enumeration thread does not panic")
        .expect("lunette's own compositor answers the enumeration");

    (watcher.outputs().roster(), watcher.has_logical_geometry())
}

fn watch(
    stream: UnixStream,
) -> JoinHandle<Result<OutputWatcher, lunette_capture::monitor::OutputError>> {
    thread::spawn(move || OutputWatcher::from_stream(stream))
}
