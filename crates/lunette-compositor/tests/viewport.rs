//! `wp_viewport` cropping and scaling, observed through the snapshot and the
//! client's pointer events.
//!
//! A client that follows `wp_fractional_scale_v1` renders a buffer larger than
//! its surface and sets the viewport destination to the surface's size. The
//! surface's size, and the space its pointer coordinates are in, is that
//! destination.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use harness::only_window;
use lunette_compositor::{
    config::DEFAULT_SEAT,
    protocol::{Command, PixelPoint, PixelSize, SourceCrop},
    test_client::{OutputTransform, PointerEvent, TestClient},
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;

/// The buffer every case commits, larger than any surface it is shown at.
const BUFFER: PixelSize = PixelSize::new(400, 300);

fn with_toplevel() -> (TestCompositor, TestClient) {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    (compositor, client)
}

#[test]
fn a_viewport_destination_is_the_window_s_size() {
    let (mut compositor, mut client) = with_toplevel();

    client.set_viewport_destination(200, 150);
    client.attach_buffer(&mut compositor, BUFFER);

    assert_eq!(only_window(&compositor).size, PixelSize::new(200, 150));
}

#[test]
fn pointer_coordinates_are_in_the_viewport_destination_s_space() {
    let (mut compositor, mut client) = with_toplevel();
    client.set_viewport_destination(200, 150);
    client.attach_buffer(&mut compositor, BUFFER);
    let pointer = client.open_pointer(&mut compositor);
    let sink = only_window(&compositor).sink;

    // Inside the buffer but outside the destination, the point is past the
    // window's edge.
    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(300.0, 200.0),
    });
    client.settle_quiet(&mut compositor);
    let entered = |events: Vec<PointerEvent>| {
        events.into_iter().find_map(|event| match event {
            PointerEvent::Enter { x, y, .. } => Some((x, y)),
            _ => None,
        })
    };
    assert_eq!(entered(client.driver().events(&pointer)), None);

    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(150.0, 100.0),
    });
    client.settle(&mut compositor, |driver| {
        driver
            .events(&pointer)
            .iter()
            .any(|event| matches!(event, PointerEvent::Enter { .. }))
    });
    assert_eq!(
        entered(client.driver().events(&pointer)),
        Some((150.0, 100.0))
    );
}

#[test]
fn a_window_without_a_viewport_shows_its_whole_buffer() {
    let (mut compositor, mut client) = with_toplevel();

    client.attach_buffer(&mut compositor, BUFFER);

    let window = only_window(&compositor);
    assert_eq!(window.size, BUFFER);
    assert_eq!(window.source_crop, SourceCrop::FULL);
}

#[test]
fn a_viewport_source_crops_the_window_to_its_rectangle() {
    let (mut compositor, mut client) = with_toplevel();

    client.set_viewport_source((100.0, 75.0, 200.0, 150.0));
    client.attach_buffer(&mut compositor, BUFFER);

    let window = only_window(&compositor);
    assert_eq!(
        window.size,
        PixelSize::new(200, 150),
        "without a destination, the source rectangle's size is the surface's"
    );
    assert_eq!(
        window.source_crop,
        SourceCrop::new(0.25, 0.25, 0.75, 0.75).expect("the edges are ordered")
    );
}

#[test]
fn a_viewport_source_and_destination_crop_and_then_scale() {
    let (mut compositor, mut client) = with_toplevel();

    client.set_viewport_source((0.0, 0.0, 200.0, 300.0));
    client.set_viewport_destination(100, 150);
    client.attach_buffer(&mut compositor, BUFFER);

    let window = only_window(&compositor);
    assert_eq!(window.size, PixelSize::new(100, 150));
    assert_eq!(
        window.source_crop,
        SourceCrop::new(0.0, 0.0, 0.5, 1.0).expect("the edges are ordered")
    );
}

#[test]
fn a_crop_committed_without_a_new_buffer_reaches_the_snapshot() {
    let (mut compositor, mut client) = with_toplevel();
    client.attach_buffer(&mut compositor, BUFFER);

    client.set_viewport_source((200.0, 150.0, 200.0, 150.0));
    client.commit_toplevel(&mut compositor);

    let window = only_window(&compositor);
    assert_eq!(window.size, PixelSize::new(200, 150));
    assert_eq!(
        window.source_crop,
        SourceCrop::new(0.5, 0.5, 1.0, 1.0).expect("the edges are ordered")
    );
}

#[test]
fn a_viewport_source_outside_the_buffer_is_a_protocol_error() {
    let (mut compositor, mut client) = with_toplevel();

    client.set_viewport_source((300.0, 0.0, 200.0, 100.0));
    client.attach_buffer(&mut compositor, BUFFER);
    client.settle_quiet(&mut compositor);

    assert!(client.is_disconnected());
}

#[test]
fn a_quarter_turned_buffer_is_cropped_in_its_turned_axes() {
    // A buffer 300 wide and 400 tall, turned a quarter, is a surface 400 wide
    // and 300 tall, so a source rectangle reaching x = 400 is inside it.
    let (mut compositor, mut client) = with_toplevel();

    client.set_buffer_transform(OutputTransform::_90);
    client.set_viewport_source((200.0, 0.0, 200.0, 300.0));
    client.attach_buffer(&mut compositor, PixelSize::new(300, 400));

    assert!(!client.is_disconnected());
    let window = only_window(&compositor);
    assert_eq!(window.size, PixelSize::new(200, 300));
    assert_eq!(
        window.source_crop,
        SourceCrop::new(0.5, 0.0, 1.0, 1.0).expect("the edges are ordered")
    );
}
