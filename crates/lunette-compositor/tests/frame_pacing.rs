//! Exercises frame pacing through a real `wayland-client`: withholding a
//! `wl_surface.frame` callback is observable only when its `done` event does not
//! arrive.
//!
//! Pacing uses `TestCompositor::advance_clock` to move the compositor's virtual
//! clock explicitly, so the tests do not sleep to reach a pacing deadline.

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

    // The first callback is due immediately; pacing starts when the first callback
    // is sent.
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

    // Each commit adds a callback to the pending list rather than replacing it, so
    // the deadline answers all three.
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

#[test]
fn a_throttled_client_still_receives_input_while_its_frame_is_withheld() {
    let (mut compositor, mut client) = with_one_window();
    let surface = client.surface().cloned().expect("a toplevel");
    let window = only_window(&compositor);
    pace(&compositor, window.surface, limited(1.0));
    client.settle_quiet(&mut compositor);

    let pointer = client.open_pointer(&mut compositor);
    expect_frame(&mut compositor, &mut client);

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

    // The rate change preserves the last-send time, so the 1 Hz deadline remains
    // 500 ms away after the clock advances by 500 ms.
    pace(&compositor, surface, limited(1.0));
    client.settle_quiet(&mut compositor);
    compositor.advance_clock(Duration::from_millis(500));
    expect_no_frame(&mut compositor, &mut client);

    pace(&compositor, surface, limited(60.0));
    client.settle_quiet(&mut compositor);

    // Raising the rate uses a new 60 Hz interval from the last send, rather than
    // waiting for the old 1 Hz deadline.
    compositor.advance_clock(Duration::from_millis(17));
    expect_frame(&mut compositor, &mut client);
}

#[test]
fn pacing_set_for_a_surface_that_has_gone_is_dropped() {
    let (mut compositor, client) = with_one_window();
    let surface = only_window(&compositor).surface;

    drop(client);
    compositor.step();

    // Surface identifiers are not reused, so a stale command cannot affect a later
    // surface and is dropped after destruction.
    pace(&compositor, surface, limited(1.0));
    compositor.step();
}
