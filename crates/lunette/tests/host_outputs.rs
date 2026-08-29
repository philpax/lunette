//! The output enumeration against a real Wayland compositor.
//!
//! `lunette_capture::monitor::outputs` is unit-tested over its pure
//! accumulator, which covers every decision it makes but nothing about the
//! protocol exchange that feeds it. These tests are the other half: a real
//! `wl_registry`, a real `wl_output`, real events over a real socket, and the
//! roster that comes out.
//!
//! The compositor is lunette's own. Its buffer importer is a fake, so it
//! requires no graphics device, no XR runtime, no display, and no listening
//! socket. The tests run on a machine at a bare TTY.
//!
//! Threading: `TestCompositor` is driven by the test stepping it, and the
//! enumeration's two round trips block until the compositor answers. The
//! enumeration runs on a thread of its own, and the test steps the compositor
//! until the thread finishes. The client end of the pair is put back into
//! blocking mode for that reason: `TestCompositor::connect` sets it
//! non-blocking because its usual caller runs on the compositor's own thread,
//! which is not the case here.

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
/// A deadline on a condition, not a wait for a duration. The loop later steps
/// until the enumeration finishes; this bounds how long a broken exchange
/// hangs the suite.
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
    // A mirrored monitor reports the resolution of the output behind it.
    let (roster, _) = enumerate(config(PixelSize::new(2560, 1440)));

    assert_eq!(
        roster.monitors()[0].pixels(),
        PixelExtent::new(2560, 1440),
        "the mode reached the roster unchanged",
    );
}

#[test]
fn a_mode_change_is_carried_through_to_the_roster() {
    // Two separate runs against two configurations. A single assertion
    // against a constant would pass even if the size were invented.
    let (small, _) = enumerate(config(PixelSize::new(1280, 720)));
    let (large, _) = enumerate(config(PixelSize::new(3840, 2160)));

    assert_eq!(small.monitors()[0].pixels(), PixelExtent::new(1280, 720));
    assert_eq!(large.monitors()[0].pixels(), PixelExtent::new(3840, 2160));
}

#[test]
fn the_logical_size_is_derived_when_the_compositor_offers_no_xdg_output() {
    // lunette's compositor advertises no `zxdg_output_manager_v1`. The
    // fallback runs against a real compositor, with no hand-built set of
    // events: the logical size comes from `wl_output.mode` divided by
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
    // The compositor sets `Transform::Normal`, and the roster must report it
    // unchanged; the far end does not default it.
    let (roster, _) = enumerate(CompositorConfig::default());

    assert_eq!(roster.monitors()[0].transform(), SurfaceTransform::Normal);
}

#[test]
fn an_output_name_that_is_not_a_connector_is_not_stored_as_one() {
    // The compositor names its output `lunette-0`, which is not a DRM
    // connector type; the monitor is identified by its descriptor.
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
/// Returns the roster and whether logical geometry was reported or derived;
/// every caller here checks the second value to see which path ran.
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
