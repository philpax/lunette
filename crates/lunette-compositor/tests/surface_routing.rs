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

use harness::{WINDOW_SIZE, only_window, with_one_window};
use lunette_compositor::{
    config::DEFAULT_SEAT,
    protocol::{Command, PixelPoint, PixelSize, SinkId},
    test_client::{Driver, PointerEvent, TestClient},
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;
use wayland_client::{Proxy, backend::ObjectId, protocol::wl_pointer::WlPointer};

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

/// Withdraws the default seat's pointer, moves it to `position` on `sink`, and
/// returns the surface it enters with the surface-local position. Withdrawing
/// first makes every move produce an enter, even onto the surface it left.
fn enter_at(
    compositor: &mut TestCompositor,
    client: &mut TestClient,
    pointer: &WlPointer,
    sink: SinkId,
    position: (f64, f64),
) -> (ObjectId, f64, f64) {
    compositor.send(Command::PointerLeave { seat: DEFAULT_SEAT });
    client.settle_quiet(compositor);
    let before = enters(client.driver(), pointer).len();

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(position.0, position.1),
    });
    client.settle(compositor, |driver| enters(driver, pointer).len() > before);

    enters(client.driver(), pointer)
        .pop()
        .expect("the wait above returned because an enter arrived")
}

fn enters(driver: &Driver, pointer: &WlPointer) -> Vec<(ObjectId, f64, f64)> {
    driver
        .events(pointer)
        .into_iter()
        .filter_map(|event| match event {
            PointerEvent::Enter { surface, x, y, .. } => Some((surface, x, y)),
            _ => None,
        })
        .collect()
}

#[test]
fn an_input_region_narrows_a_subsurface_rather_than_replacing_it() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let child = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    client.set_input_region(&mut compositor, &child, &[(0, 0, 10, 10)]);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");
    let (x, y) = (
        f64::from(SUBSURFACE_ORIGIN.0),
        f64::from(SUBSURFACE_ORIGIN.1),
    );

    let (inside, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (x + 5.0, y + 5.0),
    );
    assert_eq!(inside, child.id(), "a point inside the region missed it");

    let (outside, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (x + 25.0, y + 20.0),
    );
    assert_eq!(
        outside, toplevel,
        "a point inside the buffer but outside the region went to the subsurface"
    );
}

#[test]
fn a_subsurface_with_an_empty_input_region_passes_the_point_to_the_surface_beneath() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let below = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    let transparent = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    client.set_input_region(&mut compositor, &transparent, &[]);
    let sink = only_window(&compositor).sink;

    let (entered, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (
            f64::from(SUBSURFACE_ORIGIN.0) + 5.0,
            f64::from(SUBSURFACE_ORIGIN.1) + 5.0,
        ),
    );
    assert_ne!(
        entered,
        transparent.id(),
        "a surface that accepts input nowhere swallowed the point"
    );
    assert_eq!(entered, below.id());
}

#[test]
fn a_subsurface_with_no_buffer_receives_nothing_even_with_an_input_region() {
    // A container subsurface has nothing drawn in it, so the window's surface
    // tree considers only surfaces with a buffer.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let container = client.open_bufferless_subsurface(&mut compositor, SUBSURFACE_ORIGIN);
    client.set_input_region(&mut compositor, &container, &[(0, 0, 40, 30)]);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");

    let (entered, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (
            f64::from(SUBSURFACE_ORIGIN.0) + 5.0,
            f64::from(SUBSURFACE_ORIGIN.1) + 5.0,
        ),
    );
    assert_eq!(entered, toplevel);
    assert_ne!(entered, container.id());
}

#[test]
fn a_fractional_point_lands_in_the_pixel_it_falls_inside() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let child = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    client.set_input_region(&mut compositor, &child, &[(2, 2, 1, 1)]);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");
    let (x, y) = (
        f64::from(SUBSURFACE_ORIGIN.0),
        f64::from(SUBSURFACE_ORIGIN.1),
    );

    let (inside, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (x + 2.9, y + 2.1),
    );
    assert_eq!(
        inside,
        child.id(),
        "a fractional coordinate did not belong to the pixel below it"
    );

    let (beside, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (x + 3.0, y + 2.0),
    );
    assert_eq!(beside, toplevel);
}

#[test]
fn a_popup_reaching_past_the_window_still_receives_the_point() {
    // Popups are tested before the window's bounds, because a popup can
    // extend beyond its toplevel.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let origin = (
        i32::try_from(WINDOW_SIZE.width).expect("a protocol width") - 20,
        10,
    );
    let popup = client.open_popup(&mut compositor, origin, POPUP_SIZE);
    let sink = only_window(&compositor).sink;

    let (entered, x, y) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (f64::from(WINDOW_SIZE.width) + 30.0, 20.0),
    );
    assert_eq!(entered, popup.id());
    assert_eq!((x, y), (50.0, 10.0));
}

#[test]
fn a_nested_popup_wins_over_the_popup_that_opened_it() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let menu = client.open_popup(&mut compositor, (10, 10), PixelSize::new(200, 200));
    let submenu =
        client.open_nested_popup(&mut compositor, &menu, (50, 50), PixelSize::new(80, 80));
    let sink = only_window(&compositor).sink;

    let (over_both, x, y) = enter_at(&mut compositor, &mut client, &pointer, sink, (70.0, 70.0));
    assert_eq!(
        over_both,
        submenu.id(),
        "the point is inside both popups, and the deeper one is on top"
    );
    assert_eq!((x, y), (10.0, 10.0));

    let (over_menu, _, _) = enter_at(&mut compositor, &mut client, &pointer, sink, (15.0, 15.0));
    assert_eq!(over_menu, menu.id());
}

#[test]
fn a_popup_with_no_buffer_but_an_input_region_still_receives() {
    // An explicit input region lets a popup claim input without a buffer.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let invisible =
        client.open_bufferless_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE, &[(0, 0, 20, 20)]);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");
    let (x, y) = (f64::from(POPUP_ORIGIN.0), f64::from(POPUP_ORIGIN.1));

    let (inside, local_x, local_y) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (x + 5.0, y + 5.0),
    );
    assert_eq!(inside, invisible.id());
    assert_eq!((local_x, local_y), (5.0, 5.0));

    let (outside, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (x + 30.0, y + 30.0),
    );
    assert_eq!(
        outside, toplevel,
        "outside its region the popup claims nothing, so the window has the point"
    );
}

#[test]
fn a_point_left_of_or_above_a_popup_is_not_in_it_even_inside_its_input_region() {
    // A negative surface-local coordinate is refused before the input region
    // is consulted, so the point falls through to the window.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let invisible = client.open_bufferless_popup(
        &mut compositor,
        POPUP_ORIGIN,
        POPUP_SIZE,
        &[(-5, -5, 20, 20)],
    );
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");

    let (entered, _, _) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        sink,
        (
            f64::from(POPUP_ORIGIN.0) - 2.0,
            f64::from(POPUP_ORIGIN.1) + 2.0,
        ),
    );
    assert_eq!(entered, toplevel);
    assert_ne!(entered, invisible.id());
}

#[test]
fn the_far_edges_of_the_window_still_reach_the_toplevel() {
    // WayVR tests the window's bounds as a closed range, so a coordinate equal
    // to the width or height is inside.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let toplevel = client.surface_id().expect("a toplevel was opened");
    let corner = (f64::from(WINDOW_SIZE.width), f64::from(WINDOW_SIZE.height));

    let (entered, x, y) = enter_at(&mut compositor, &mut client, &pointer, sink, corner);
    assert_eq!(entered, toplevel);
    assert_eq!((x, y), corner);
}
