//! These tests verify pointer events at the Wayland client boundary.
//!
//! The client records protocol events, not compositor focus state. The
//! harness uses an in-process socketpair and a fake importer, so these tests
//! require no GPU.

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
    config::DEFAULT_SEAT,
    protocol::{Command, PixelPoint, PointerButton, ScrollAxis, ScrollDelta, SeatId, SinkId},
    test_client::{AxisSource, PointerEvent, TestClient},
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_pointer::WlPointer;

/// `BTN_LEFT`, the evdev code a left click carries on the wire.
const BTN_LEFT: u32 = 0x110;

const AIM: (f64, f64) = (12.0, 34.0);

#[test]
fn a_pointer_aimed_at_a_sink_enters_that_sink_s_surface_in_surface_local_coordinates() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let surface = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    let (entered, x, y) = client
        .driver()
        .first_enter(&pointer)
        .expect("the wait above returned because an enter arrived");
    assert_eq!(
        entered, surface,
        "the pointer entered a surface other than the one behind the sink"
    );
    // The test window starts at the sink origin, so the sink position is already
    // surface-local. A translation would indicate incorrect routing.
    assert_eq!((x, y), AIM);
}

#[test]
fn a_pointer_moving_within_a_window_reports_its_motion_to_a_relative_pointer() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let relative = client.open_relative_pointer(&mut compositor, &pointer);
    let sink = only_window(&compositor).sink;

    for position in [PixelPoint::new(AIM.0, AIM.1), PixelPoint::new(30.0, 40.0)] {
        compositor.send(Command::Pointer {
            seat: DEFAULT_SEAT,
            sink,
            position,
        });
    }
    client.settle(&mut compositor, |driver| {
        driver.relative_motions(&relative).len() >= 2
    });

    assert_eq!(
        client.driver().relative_motions(&relative),
        vec![(0.0, 0.0), (30.0 - AIM.0, 40.0 - AIM.1)],
        "the first motion enters the window and moves nowhere relative to it"
    );
}

#[test]
fn a_click_over_a_sink_is_delivered_as_a_press_and_a_release() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: true,
    });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: false,
    });
    client.settle(&mut compositor, |driver| {
        driver.buttons(&pointer).len() == 2
    });

    assert_eq!(
        client.driver().buttons(&pointer),
        [(BTN_LEFT, true), (BTN_LEFT, false)]
    );
}

#[test]
fn every_button_reaches_the_client_as_its_own_evdev_code() {
    let (mut compositor, mut client, sink, pointer) = with_pointer_over_a_window();

    let buttons = [
        (PointerButton::Left, 0x110),
        (PointerButton::Right, 0x111),
        (PointerButton::Middle, 0x112),
        (PointerButton::Back, 0x113),
        (PointerButton::Forward, 0x114),
    ];
    for (button, _) in buttons {
        compositor.send(Command::Button {
            seat: DEFAULT_SEAT,
            sink,
            button,
            pressed: true,
        });
    }
    client.settle(&mut compositor, |driver| {
        driver.buttons(&pointer).len() == buttons.len()
    });

    assert_eq!(
        client.driver().buttons(&pointer),
        buttons.map(|(_, code)| (code, true)),
        "each button carries the evdev code applications expect, back and forward included"
    );
}

#[test]
fn withdrawing_the_pointer_leaves_the_surface_it_had_entered() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let surface = client.surface_id().expect("a toplevel was opened");

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    compositor.send(Command::PointerLeave { seat: DEFAULT_SEAT });
    client.settle(&mut compositor, |driver| {
        driver
            .events(&pointer)
            .iter()
            .any(|event| matches!(event, PointerEvent::Leave { .. }))
    });

    assert!(
        client
            .driver()
            .events(&pointer)
            .contains(&PointerEvent::Leave { surface }),
        "the leave named a surface other than the one entered: {:?}",
        client.driver().events(&pointer)
    );
}

#[test]
fn a_release_reaches_the_pressed_window_after_the_pointer_has_moved_off_it() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: true,
    });
    // Lua withdraws the pointer from a panel it leaves, and releases on the
    // sink it pressed.
    compositor.send(Command::PointerLeave { seat: DEFAULT_SEAT });
    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: false,
    });
    client.settle(&mut compositor, |driver| {
        driver.buttons(&pointer).len() == 2
    });

    assert_eq!(
        client.driver().buttons(&pointer),
        [(BTN_LEFT, true), (BTN_LEFT, false)]
    );
}

#[test]
fn a_release_without_a_press_is_refused_where_the_pointer_is_not() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Button {
        seat: DEFAULT_SEAT,
        sink,
        button: PointerButton::Left,
        pressed: false,
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(client.driver().buttons(&pointer), []);
}

/// Sets up a client with the default seat's pointer over its window.
///
/// The pointer must enter a window before the client can receive an axis event.
fn with_pointer_over_a_window() -> (TestCompositor, TestClient, SinkId, WlPointer) {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    client.settle(&mut compositor, |driver| {
        driver.first_enter(&pointer).is_some()
    });

    (compositor, client, sink, pointer)
}

#[test]
fn a_continuous_scroll_reaches_the_client_as_a_distance_on_the_axis_it_named() {
    // Exercise both axes to detect routing that handles vertical scrolling but
    // drops horizontal scrolling.
    for (axis, distance) in [(ScrollAxis::Vertical, -15.0), (ScrollAxis::Horizontal, 7.5)] {
        let (mut compositor, mut client, sink, pointer) = with_pointer_over_a_window();

        compositor.send(Command::Scroll {
            seat: DEFAULT_SEAT,
            sink,
            axis,
            delta: ScrollDelta::Continuous(distance),
        });
        client.settle(&mut compositor, |driver| {
            driver
                .events(&pointer)
                .iter()
                .any(|event| matches!(event, PointerEvent::Axis { .. }))
        });

        let events = client.driver().events(&pointer);
        assert!(
            events.contains(&PointerEvent::Axis {
                axis,
                value: distance
            }),
            "a continuous {axis:?} scroll of {distance} did not arrive: {events:?}",
        );
        assert!(
            events.contains(&PointerEvent::AxisSource {
                source: AxisSource::Continuous
            }),
            "the source was not reported as continuous: {events:?}",
        );
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, PointerEvent::AxisDiscrete { .. })),
            "a continuous scroll was reported as notches: {events:?}",
        );
    }
}

#[test]
fn a_discrete_scroll_reaches_the_client_as_notches_and_a_distance() {
    // Clients before `wl_pointer` version 5 receive only `axis`; each wheel
    // detent is reported as fifteen surface-local units, WayVR's value.
    for (axis, steps) in [(ScrollAxis::Vertical, 2), (ScrollAxis::Horizontal, -1)] {
        let (mut compositor, mut client, sink, pointer) = with_pointer_over_a_window();

        compositor.send(Command::Scroll {
            seat: DEFAULT_SEAT,
            sink,
            axis,
            delta: ScrollDelta::Discrete(steps),
        });
        client.settle(&mut compositor, |driver| {
            driver
                .events(&pointer)
                .iter()
                .any(|event| matches!(event, PointerEvent::AxisDiscrete { .. }))
        });

        let events = client.driver().events(&pointer);
        assert!(
            events.contains(&PointerEvent::AxisDiscrete { axis, steps }),
            "a discrete {axis:?} scroll of {steps} did not arrive: {events:?}",
        );
        assert!(
            events.contains(&PointerEvent::Axis {
                axis,
                value: f64::from(steps) * 15.0
            }),
            "the notches carried no distance: {events:?}",
        );
        assert!(
            events.contains(&PointerEvent::AxisSource {
                source: AxisSource::Wheel
            }),
            "the source was not reported as a wheel: {events:?}",
        );
    }
}

#[test]
fn a_scroll_over_a_sink_the_seats_pointer_is_not_on_reaches_no_client() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    // A sink does not target a client until the seat's pointer has entered it.
    compositor.send(Command::Scroll {
        seat: DEFAULT_SEAT,
        sink,
        axis: ScrollAxis::Vertical,
        delta: ScrollDelta::Continuous(15.0),
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().events(&pointer),
        [],
        "a scroll was delivered to a sink the pointer had never entered",
    );
}

#[test]
fn an_input_serial_never_collides_with_one_smithay_minted_itself() {
    // Smithay owns one global serial counter for configure, keyboard, modifier,
    // popup-grab, and pointer events. A separate counter could collide with a
    // configure serial and invalidate an `xdg_popup.grab`.
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    client.settle(&mut compositor, |driver| {
        driver.enter_serial(&pointer).is_some()
    });

    let configures = client.driver().configure_serials();
    let enter = client
        .driver()
        .enter_serial(&pointer)
        .expect("the wait above returned because an enter arrived");

    assert!(!configures.is_empty(), "the window was never configured");
    assert!(
        !configures.contains(&enter),
        "the pointer enter quoted serial {enter}, which is also a configure serial: {configures:?}",
    );
}

#[test]
fn input_addressed_to_a_seat_that_does_not_exist_reaches_no_client() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;
    let absent = SeatId::new(99).expect("a non-zero identifier");

    compositor.send(Command::Pointer {
        seat: absent,
        sink,
        position: PixelPoint::new(AIM.0, AIM.1),
    });
    compositor.send(Command::Button {
        seat: absent,
        sink,
        button: PointerButton::Left,
        pressed: true,
    });
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().events(&pointer),
        [],
        "a command naming a seat that was never created must be refused, not routed"
    );
}
