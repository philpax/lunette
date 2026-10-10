//! A window's snapshot reports its popups and subsurfaces where the pointer
//! reaches them, so a consumer can draw what the compositor hit-tests.
//!
//! The harness runs the real compositor with a client connected over an
//! in-process `UnixStream::pair()` and a fake buffer importer, so these tests do
//! not require a GPU.

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
    protocol::{
        ChildKind, ChildSurface, Command, PixelPoint, PixelSize, SourceCrop, Stacking,
        SurfaceOffset,
    },
    test_client::TestClient,
    testing::TestCompositor,
};
use pretty_assertions::assert_eq;
use wayland_client::{Proxy, backend::ObjectId, protocol::wl_pointer::WlPointer};

const POPUP_ORIGIN: (i32, i32) = (100, 80);
const POPUP_SIZE: PixelSize = PixelSize::new(120, 60);
const SUBSURFACE_ORIGIN: (i32, i32) = (30, 40);
const SUBSURFACE_SIZE: PixelSize = PixelSize::new(50, 20);

fn children(compositor: &TestCompositor) -> Vec<ChildSurface> {
    only_window(compositor).children
}

/// What the snapshot reports, without the identifiers a test cannot predict.
fn shapes(compositor: &TestCompositor) -> Vec<(ChildKind, Stacking, SurfaceOffset, PixelSize)> {
    children(compositor)
        .iter()
        .map(|child| (child.kind, child.stacking, child.position, child.size))
        .collect()
}

fn offset((x, y): (i32, i32)) -> SurfaceOffset {
    SurfaceOffset { x, y }
}

/// Moves the default seat's pointer onto `position` of the only window, and
/// returns the surface it enters with the surface-local position.
fn enter_at(
    compositor: &mut TestCompositor,
    client: &mut TestClient,
    pointer: &WlPointer,
    position: (f64, f64),
) -> (ObjectId, f64, f64) {
    let sink = only_window(compositor).sink;
    compositor.send(Command::Pointer {
        seat: DEFAULT_SEAT,
        sink,
        position: PixelPoint::new(position.0, position.1),
    });
    client.settle(compositor, |driver| driver.first_enter(pointer).is_some());
    client
        .driver()
        .first_enter(pointer)
        .expect("the wait above returned because an enter arrived")
}

#[test]
fn a_window_without_popups_or_subsurfaces_reports_no_children() {
    let (compositor, _client) = with_one_window();

    assert_eq!(children(&compositor), Vec::new());
}

#[test]
fn a_popup_is_reported_above_the_window_at_its_origin() {
    let (mut compositor, mut client) = with_one_window();
    client.open_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);

    let reported = children(&compositor);
    assert_eq!(
        shapes(&compositor),
        vec![(
            ChildKind::Popup,
            Stacking::Above,
            offset(POPUP_ORIGIN),
            POPUP_SIZE
        )]
    );
    assert_eq!(reported[0].source_crop, SourceCrop::FULL);
    assert_ne!(
        reported[0].surface,
        only_window(&compositor).surface,
        "the popup has a surface of its own"
    );
}

#[test]
fn a_subsurface_is_reported_at_its_position() {
    let (mut compositor, mut client) = with_one_window();
    client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);

    assert_eq!(
        shapes(&compositor),
        vec![(
            ChildKind::Subsurface,
            Stacking::Above,
            offset(SUBSURFACE_ORIGIN),
            SUBSURFACE_SIZE
        )]
    );
}

#[test]
fn a_subsurface_placed_below_its_parent_is_reported_below_and_first() {
    let (mut compositor, mut client) = with_one_window();
    let below = client.open_subsurface(&mut compositor, (0, 0), SUBSURFACE_SIZE);
    client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);
    client.place_subsurface_below_parent(&mut compositor, &below);

    let stacking: Vec<_> = children(&compositor)
        .iter()
        .map(|child| (child.stacking, child.position))
        .collect();
    assert_eq!(
        stacking,
        vec![
            (Stacking::Below, offset((0, 0))),
            (Stacking::Above, offset(SUBSURFACE_ORIGIN)),
        ],
        "children are listed in the order they are drawn, bottom first",
    );
}

#[test]
fn a_nested_popup_follows_its_parent_at_the_accumulated_origin() {
    let (mut compositor, mut client) = with_one_window();
    let menu = client.open_popup(&mut compositor, (10, 10), PixelSize::new(200, 200));
    client.open_nested_popup(&mut compositor, &menu, (50, 50), PixelSize::new(80, 80));

    let positions: Vec<_> = children(&compositor)
        .iter()
        .map(|child| child.position)
        .collect();
    assert_eq!(positions, vec![offset((10, 10)), offset((60, 60))]);
}

#[test]
fn popups_are_drawn_above_every_subsurface() {
    let (mut compositor, mut client) = with_one_window();
    client.open_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);
    client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);

    let kinds: Vec<_> = children(&compositor)
        .iter()
        .map(|child| child.kind)
        .collect();
    assert_eq!(kinds, vec![ChildKind::Subsurface, ChildKind::Popup]);
}

#[test]
fn a_child_without_content_is_not_reported() {
    let (mut compositor, mut client) = with_one_window();
    client.open_bufferless_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE, &[(0, 0, 10, 10)]);
    client.open_bufferless_subsurface(&mut compositor, SUBSURFACE_ORIGIN);

    assert_eq!(children(&compositor), Vec::new());
}

#[test]
fn an_unmapped_popup_leaves_the_next_snapshot() {
    let (mut compositor, mut client) = with_one_window();
    let popup = client.open_popup(&mut compositor, POPUP_ORIGIN, POPUP_SIZE);
    assert_eq!(children(&compositor).len(), 1);

    client.unmap_surface(&mut compositor, &popup);

    assert_eq!(children(&compositor), Vec::new());
}

#[test]
fn a_moved_subsurface_is_reported_at_its_new_position() {
    // The move commits no new buffer, so only the tree has changed.
    let (mut compositor, mut client) = with_one_window();
    let child = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);

    client.move_subsurface(&mut compositor, &child, (200, 100));

    assert_eq!(
        children(&compositor)
            .iter()
            .map(|child| child.position)
            .collect::<Vec<_>>(),
        vec![offset((200, 100))]
    );
}

#[test]
fn the_pointer_reaches_a_popup_where_the_snapshot_places_it() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let menu = client.open_popup(&mut compositor, (10, 10), PixelSize::new(200, 200));
    let submenu =
        client.open_nested_popup(&mut compositor, &menu, (50, 50), PixelSize::new(80, 80));

    let reported = children(&compositor);
    let deepest = reported.last().expect("two popups are reported");
    let (entered, x, y) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        (
            f64::from(deepest.position.x) + 2.0,
            f64::from(deepest.position.y) + 3.0,
        ),
    );
    assert_eq!(entered, submenu.id());
    assert_eq!((x, y), (2.0, 3.0));
}

#[test]
fn the_pointer_reaches_a_subsurface_where_the_snapshot_places_it() {
    let (mut compositor, mut client) = with_one_window();
    let pointer = client.open_pointer(&mut compositor);
    let child = client.open_subsurface(&mut compositor, SUBSURFACE_ORIGIN, SUBSURFACE_SIZE);

    let reported = children(&compositor);
    let (entered, x, y) = enter_at(
        &mut compositor,
        &mut client,
        &pointer,
        (
            f64::from(reported[0].position.x) + 1.0,
            f64::from(reported[0].position.y) + 1.0,
        ),
    );
    assert_eq!(entered, child.id());
    assert_eq!((x, y), (1.0, 1.0));
}
