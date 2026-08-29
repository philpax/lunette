//! The harness runs the real compositor with a client connected over an in-process
//! `UnixStream::pair()` and a fake buffer importer, so these protocol tests do not
//! require a GPU.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use harness::{only_window, with_one_window};
use lunette_compositor::{
    protocol::{Command, PixelPoint, PixelSize},
    state::DEFAULT_SEAT,
    test_client::PointerEvent,
};
use pretty_assertions::assert_eq;
use wayland_client::Proxy;

/// The popup's top-left corner in the toplevel's coordinate space.
/// Pointer events use coordinates relative to this origin.
const POPUP_ORIGIN: (i32, i32) = (100, 80);

const POPUP_SIZE: PixelSize = PixelSize::new(120, 60);

#[test]
fn a_click_over_a_popup_is_delivered_to_the_popup_in_surface_local_coordinates() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let popup = client.open_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(
            f64::from(POPUP_ORIGIN.0) + 10.0,
            f64::from(POPUP_ORIGIN.1) + 20.0,
        ),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, x, y) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_eq!(
        entered,
        popup.id(),
        "the click went to the window under the popup rather than to the popup"
    );
    assert_eq!(
        (x, y),
        (10.0, 20.0),
        "the popup was told a position in the window's frame rather than its own"
    );
}

#[test]
fn a_click_beside_a_popup_still_reaches_the_window() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let popup = client.open_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(5.0, 5.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, x, y) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_eq!(entered, toplevel, "the popup swallowed a click outside it");
    assert_ne!(entered, popup.id());
    assert_eq!((x, y), (5.0, 5.0));
}

#[test]
fn a_popup_that_has_not_acknowledged_its_configure_does_not_take_the_click() {
    // The client has not acknowledged the popup's configure, so its geometry is
    // not agreed. It has no buffer, but its explicit input region would otherwise
    // make it a pointer target. Hit-testing excludes unconfigured popups.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let popup = client.open_unconfigured_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(10.0, 20.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, _, _) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_ne!(
        entered,
        popup.id(),
        "a popup that never answered its configure took the click",
    );
    assert_eq!(entered, toplevel);
}

#[test]
fn moving_from_the_window_onto_a_popup_leaves_the_window_and_enters_the_popup() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let popup = client.open_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(5.0, 5.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(
            f64::from(POPUP_ORIGIN.0) + 1.0,
            f64::from(POPUP_ORIGIN.1) + 1.0,
        ),
    });
    client.settle(&mut compositor, |driver| {
        driver.events(&pointer).iter().any(
            |event| matches!(event, PointerEvent::Enter { surface, .. } if *surface == popup.id()),
        )
    });

    let events = client.driver().events(&pointer);
    assert!(
        events.contains(&PointerEvent::Leave {
            surface: toplevel.clone()
        }),
        "the window was never told the pointer had gone: {events:?}"
    );
}

/// Subsurface origin in the toplevel's coordinate space.
const SUBSURFACE_ORIGIN: (i32, i32) = (100, 50);

const SUBSURFACE_SIZE: PixelSize = PixelSize::new(40, 30);

#[test]
fn a_click_over_a_subsurface_is_delivered_to_it_in_its_own_coordinates() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let child = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(
            f64::from(SUBSURFACE_ORIGIN.0) + 3.0,
            f64::from(SUBSURFACE_ORIGIN.1) + 4.0,
        ),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, x, y) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_eq!(
        entered,
        child.id(),
        "the click went to the toplevel rather than to the subsurface over it"
    );
    assert_eq!(
        (x, y),
        (3.0, 4.0),
        "the subsurface's position was not subtracted from the click"
    );
}

#[test]
fn a_click_beside_a_subsurface_reaches_the_toplevel() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let child = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(10.0, 10.0),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, _, _) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_eq!(entered, toplevel);
    assert_ne!(entered, child.id());
}
