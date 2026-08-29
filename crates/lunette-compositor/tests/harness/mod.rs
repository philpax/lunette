//! Linux-only: shared setup for logic-headless Wayland integration tests.
//!
//! The harness runs the real display and handlers through a real Wayland client.
//! `TestCompositor` inserts one end of an in-process `UnixStream::pair()` and
//! runs the compositor on the calling thread. `TestClient` owns the other end,
//! which is nonblocking. No listener, socket path, runtime directory, or process
//! environment is involved.
//!
//! The compositor uses a fake `BufferImporter`, so these tests exercise protocol
//! and state handling without a graphics device, XR runtime, or headset. Client
//! and compositor conditions are polled with `DEADLINE` bounds; fixed sleeps are
//! not used.

use lunette_compositor::{
    protocol::{PixelSize, WindowSnapshot},
    test_client::TestClient,
    testing::TestCompositor,
};

/// Interface names advertised by the default compositor, in the sorted order
/// returned by `TestClient::globals`.
///
/// The selection globals stay advertised without a host compositor. A host
/// bridge changes selection forwarding, not the client-facing protocol surface.
pub const EXPECTED_GLOBALS: [&str; 16] = [
    "ext_data_control_manager_v1",
    "org_kde_kwin_server_decoration_manager",
    "wl_compositor",
    "wl_data_device_manager",
    "wl_output",
    "wl_seat",
    "wl_shm",
    "wl_subcompositor",
    "wp_content_type_manager_v1",
    "wp_fractional_scale_manager_v1",
    "wp_viewporter",
    "xdg_wm_base",
    "zwlr_data_control_manager_v1",
    "zwp_linux_dmabuf_v1",
    "zwp_primary_selection_device_manager_v1",
    "zxdg_decoration_manager_v1",
];

/// Pixel size used by the shared mapped-window fixture.
pub const WINDOW_SIZE: PixelSize = PixelSize::new(640, 480);

/// Returns a compositor and client with one mapped window.
///
/// `TestClient::open_toplevel` commits the surface without a buffer, waits for
/// `xdg_surface.configure`, and acknowledges it before `attach_buffer` commits
/// content. The returned client stays alive so it owns the Wayland objects and
/// socket for the caller's test.
pub fn with_one_window() -> (TestCompositor, TestClient) {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, WINDOW_SIZE);
    (compositor, client)
}

/// Returns the snapshot's only window.
///
/// The assertion includes the full window list when the snapshot has any count
/// other than one, which identifies the actual snapshot contents on failure.
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
