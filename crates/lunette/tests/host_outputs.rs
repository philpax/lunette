//! The output enumeration against lunette's own Wayland compositor, covering the protocol
//! exchange the pure accumulator's unit tests do not.
//!
//! The enumeration blocks on round trips, so it runs on its own thread with a blocking socket
//! while the test steps the compositor.

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
/// Bounds how long a broken exchange hangs the suite.
const DEADLINE: Duration = Duration::from_secs(10);

#[test]
fn the_compositors_only_output_is_enumerated_as_one_unrotated_monitor() {
    let (roster, _) = enumerate(CompositorConfig::default());
    let monitors = roster.monitors();

    assert_eq!(monitors.len(), 1, "the compositor advertises one wl_output");
    assert_eq!(monitors[0].name().make(), Some("lunette"));
    assert_eq!(monitors[0].name().model(), Some("virtual display"));
    assert_eq!(monitors[0].transform(), SurfaceTransform::Normal);
    // `lunette-0` is not a DRM connector type, so the descriptor identifies
    // the monitor.
    assert_eq!(monitors[0].name().connector(), None);
    assert_eq!(monitors[0].key().to_string(), "lunette virtual display");
}

#[test]
fn a_mode_change_is_carried_through_to_the_roster() {
    // Several sizes, so a constant cannot pass.
    let (small, _) = enumerate(config(PixelSize::new(1280, 720)));
    let (large, _) = enumerate(config(PixelSize::new(3840, 2160)));
    let (mirrored, _) = enumerate(config(PixelSize::new(2560, 1440)));

    assert_eq!(small.monitors()[0].pixels(), PixelExtent::new(1280, 720));
    assert_eq!(large.monitors()[0].pixels(), PixelExtent::new(3840, 2160));
    assert_eq!(
        mirrored.monitors()[0].pixels(),
        PixelExtent::new(2560, 1440)
    );
}

#[test]
fn the_logical_size_is_derived_when_the_compositor_offers_no_xdg_output() {
    // lunette's compositor advertises no `zxdg_output_manager_v1`.
    let (roster, logical_geometry) = enumerate(config(PixelSize::new(2560, 1440)));

    assert!(
        !logical_geometry,
        "this test is about the fallback, and there is nothing to fall back from"
    );
    assert_eq!(roster.monitors()[0].size().width, 2560);
    assert_eq!(roster.monitors()[0].size().height, 1440);
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
/// Returns the roster and whether logical geometry was reported or derived.
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
        // A short blocking wait, so the loop does not spin.
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
