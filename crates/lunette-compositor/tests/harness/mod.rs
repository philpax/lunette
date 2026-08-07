//! Shared setup for the logic-headless integration tests.
//!
//! These tests exist to hold one property: the compositor's logic runs with no
//! graphics device, no XR runtime, and no headset attached (`AC9.4`). They also
//! run with no listening socket, no filesystem path, and no read of the process
//! environment, because a test that needs `XDG_RUNTIME_DIR` is a test that can
//! collide with a real session.
//!
//! What makes that possible is the seam. `TestCompositor` builds the real event
//! loop, the real display, and the real handlers, but takes its clients over a
//! `UnixStream::pair()` and its buffer importer as a trait object. The fake
//! importer records what it was asked for and answers with a handle that is not
//! a real image, so nothing below it is reachable from this crate. If a test
//! here ever needs a GPU, the test is in the wrong crate.
//!
//! Every wait is a wait for a condition with a deadline, never for a duration.
//! Nothing here is a test about timing.

use lunette_compositor::{
    protocol::{PixelSize, WindowSnapshot},
    test_client::TestClient,
    testing::TestCompositor,
};

/// Every global lunette advertises, in the order `globals()` sorts them.
///
/// `wl_subcompositor` is here because `CompositorState::new` creates it
/// unconditionally, and `wp_viewporter` because xwayland-satellite refuses to
/// start without it — and because `wp_fractional_scale_manager_v1` is useless
/// without it, a client landing a fractionally scaled buffer at the right
/// logical size through `wp_viewport.set_destination`. Both decoration managers are here so GTK and Qt clients do
/// not draw their own titlebars inside a panel.
///
/// The four selection globals are all advertised whether or not a host desktop
/// is reachable: a session with no host still has a clipboard, it just does not
/// leave lunette.
pub const EXPECTED_GLOBALS: [&str; 15] = [
    "ext_data_control_manager_v1",
    "org_kde_kwin_server_decoration_manager",
    "wl_compositor",
    "wl_data_device_manager",
    "wl_output",
    "wl_seat",
    "wl_shm",
    "wl_subcompositor",
    "wp_fractional_scale_manager_v1",
    "wp_viewporter",
    "xdg_wm_base",
    "zwlr_data_control_manager_v1",
    "zwp_linux_dmabuf_v1",
    "zwp_primary_selection_device_manager_v1",
    "zxdg_decoration_manager_v1",
];

/// The size the shared window is committed at.
pub const WINDOW_SIZE: PixelSize = PixelSize::new(640, 480);

/// A compositor with one mapped window, and the client that owns it.
///
/// The client commits with no buffer, waits for `xdg_surface.configure`, and
/// only then attaches — the order `TestClient::open_toplevel` enforces, and the
/// usual way these tests fail confusingly when it is wrong.
pub fn with_one_window() -> (TestCompositor, TestClient) {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, WINDOW_SIZE);
    (compositor, client)
}

/// The only window in the snapshot, or a failure naming what was there instead.
pub fn only_window(compositor: &TestCompositor) -> WindowSnapshot {
    let snapshot = compositor.snapshot();
    assert_eq!(
        snapshot.windows.len(),
        1,
        "expected exactly one window, found {:?}",
        snapshot.windows
    );
    snapshot.windows[0].clone()
}
