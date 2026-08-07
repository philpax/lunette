//! How often a client is answered its `wl_surface.frame` callbacks.
//!
//! Driven over a real `wayland-client`, because withholding is only observable
//! on the wire: from the compositor's own side a withheld callback and an
//! answered one look the same until the `done` does or does not arrive.
//!
//! `lunette-v1.AC7.3` has two halves and the second is the harder one. A panel
//! outside the view is throttled toward the floor, *and* its client keeps
//! processing input rather than appearing hung. A rate of zero would satisfy
//! the first and fail the second: a client answered no frame callbacks stops
//! pumping its event loop, and a window that is frozen but alive is worse than
//! one costing a frame a second. So the floor is 1 Hz, and the tests below hold
//! both halves.
//!
//! Time is virtual. `TestCompositor::advance_clock` moves the compositor's own
//! clock, which is the only clock pacing is measured against, so nothing here
//! sleeps and nothing here races the machine it runs on.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use std::time::Duration;

use lunette_compositor::{
    protocol::{Command, FramePacing, FrameRate, PixelPoint, PointerButton, SurfaceId},
    state::DEFAULT_SEAT,
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;
use wayland_client::Proxy;

use crate::harness::{only_window, with_one_window};

fn limited(hertz: f64) -> FramePacing {
    FramePacing::Limited(FrameRate::new(hertz).expect("the test names a positive rate"))
}

fn pace(compositor: &TestCompositor, surface: SurfaceId, pacing: FramePacing) {
    compositor.send(Command::SetFramePacing { surface, pacing });
}

/// Asks for a frame and runs both ends until it is answered, failing if the
/// compositor withholds it.
fn expect_frame(compositor: &mut TestCompositor, client: &mut TestClient) {
    let surface = client
        .surface()
        .cloned()
        .expect("the harness opened a toplevel");
    let before = client.frames(&surface).len();

    client.request_frame(&surface);
    client.settle(compositor, |driver| {
        driver.frames(&surface.id()).len() > before
    });
}

/// Asks for a frame and runs both ends a fixed number of rounds, expecting it
/// to be withheld.
fn expect_no_frame(compositor: &mut TestCompositor, client: &mut TestClient) {
    let surface = client
        .surface()
        .cloned()
        .expect("the harness opened a toplevel");
    let before = client.frames(&surface).len();

    client.request_frame(&surface);
    client.settle_quiet(compositor);

    assert_eq!(
        client.frames(&surface).len(),
        before,
        "the surface was answered a frame callback it was not yet due"
    );
}

#[test]
fn a_surface_nobody_paced_is_answered_every_frame() {
    let (mut compositor, mut client) = with_one_window();

    for _ in 0..5 {
        expect_frame(&mut compositor, &mut client);
    }

    let surface = client.surface().cloned().expect("a toplevel");
    assert_eq!(
        client.frames(&surface).len(),
        5,
        "throttling is something Lua asks for, not a client's default"
    );
}

#[test]
fn an_unthrottled_surface_is_answered_every_frame() {
    let (mut compositor, mut client) = with_one_window();
    pace(
        &compositor,
        only_window(&compositor).surface,
        FramePacing::Unthrottled,
    );
    client.settle_quiet(&mut compositor);

    for _ in 0..3 {
        expect_frame(&mut compositor, &mut client);
    }
}

#[test]
fn a_ten_hertz_surface_is_answered_once_per_interval() {
    let (mut compositor, mut client) = with_one_window();
    pace(&compositor, only_window(&compositor).surface, limited(10.0));
    client.settle_quiet(&mut compositor);

    // The first is owed at once: a client's opening frame does not wait out an
    // interval it was not present for.
    expect_frame(&mut compositor, &mut client);

    expect_no_frame(&mut compositor, &mut client);
    compositor.advance_clock(Duration::from_millis(99));
    expect_no_frame(&mut compositor, &mut client);

    compositor.advance_clock(Duration::from_millis(1));
    expect_frame(&mut compositor, &mut client);

    expect_no_frame(&mut compositor, &mut client);
    compositor.advance_clock(Duration::from_millis(100));
    expect_frame(&mut compositor, &mut client);
}

#[test]
fn every_withheld_callback_is_answered_when_the_surface_comes_due() {
    let (mut compositor, mut client) = with_one_window();
    let surface = client.surface().cloned().expect("a toplevel");
    pace(&compositor, only_window(&compositor).surface, limited(10.0));
    client.settle_quiet(&mut compositor);

    expect_frame(&mut compositor, &mut client);
    let answered = client.frames(&surface).len();

    // Three commits inside one interval. smithay's `SurfaceAttributes::
    // merge_into` extends the callback list rather than replacing it, so all
    // three are still owed when the interval elapses.
    for _ in 0..3 {
        client.request_frame(&surface);
        client.settle_quiet(&mut compositor);
    }
    assert_eq!(client.frames(&surface).len(), answered);

    compositor.advance_clock(Duration::from_millis(100));
    client.settle(&mut compositor, |driver| {
        driver.frames(&surface.id()).len() == answered + 3
    });
}

#[test]
fn a_rate_below_the_floor_is_answered_once_a_second() {
    let (mut compositor, mut client) = with_one_window();
    pace(&compositor, only_window(&compositor).surface, limited(0.01));
    client.settle_quiet(&mut compositor);

    expect_frame(&mut compositor, &mut client);

    compositor.advance_clock(Duration::from_millis(999));
    expect_no_frame(&mut compositor, &mut client);

    compositor.advance_clock(Duration::from_millis(1));
    expect_frame(&mut compositor, &mut client);
}

/// The second half of `lunette-v1.AC7.3`: a throttled client is slow, not hung.
#[test]
fn a_throttled_client_still_receives_input_while_its_frame_is_withheld() {
    let (mut compositor, mut client) = with_one_window();
    let surface = client.surface().cloned().expect("a toplevel");
    let window = only_window(&compositor);
    pace(&compositor, window.surface, limited(1.0));
    client.settle_quiet(&mut compositor);

    let pointer = client.open_pointer(&mut compositor);
    expect_frame(&mut compositor, &mut client);

    // Withheld: the client has asked for a frame and will not get one for
    // nearly a second.
    client.request_frame(&surface);
    client.settle_quiet(&mut compositor);
    assert_eq!(client.frames(&surface).len(), 1);

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink: window.sink,
        position: PixelPoint::new(32.0, 32.0),
    });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink: window.sink,
        button: PointerButton::Left,
        pressed: true,
    });

    client.settle(&mut compositor, |driver| {
        driver.buttons(&pointer).len() == 1
    });

    assert_eq!(
        client.frames(&surface).len(),
        1,
        "the click arrived without the withheld frame callback arriving with it"
    );
}

#[test]
fn returning_a_surface_to_view_answers_it_without_serving_out_the_slow_interval() {
    let (mut compositor, mut client) = with_one_window();
    let surface = only_window(&compositor).surface;
    pace(&compositor, surface, limited(60.0));
    client.settle_quiet(&mut compositor);

    expect_frame(&mut compositor, &mut client);

    // Out of view, then back before a second has passed. The 60 Hz budget was
    // met long ago, so the client is answered on the next tick rather than
    // waiting out an interval it is no longer under.
    pace(&compositor, surface, limited(1.0));
    client.settle_quiet(&mut compositor);
    compositor.advance_clock(Duration::from_millis(500));
    expect_no_frame(&mut compositor, &mut client);

    pace(&compositor, surface, limited(60.0));
    client.settle_quiet(&mut compositor);
    expect_frame(&mut compositor, &mut client);
}

#[test]
fn pacing_set_for_a_surface_that_has_gone_is_dropped() {
    let (mut compositor, client) = with_one_window();
    let surface = only_window(&compositor).surface;

    drop(client);
    compositor.step();

    // The surface's identifier is never reused, so recording pacing for it
    // would keep an entry nothing could ever match again. The command is
    // accepted and dropped rather than reported: Lua reaching a window a frame
    // after it closed is ordinary.
    pace(&compositor, surface, limited(1.0));
    compositor.step();
}
