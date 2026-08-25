//! Tests replacing the graphics importer while Wayland clients remain connected.
//!
//! These logic-headless tests use a recording importer. The compositor thread
//! drops that importer during release; the frame thread waits for the release
//! acknowledgement before destroying the graphics device and supplies a new
//! importer during adoption.
//!
//! The compositor retains the display, client connections, and dmabuf
//! `wl_buffer`s across this exchange. Clients are owned by Rust outside the Lua
//! state, so replacing the graphics device does not disconnect them.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use lunette_compositor::{
    protocol::{Command, Event, PixelSize},
    state::{CompositorConfig, DmabufSupport},
    test_client::TestClient,
    testing::{ImportLog, TestCompositor, recording_importer},
};
use pretty_assertions::assert_eq;
use smithay::backend::allocator::{Format, Fourcc, Modifier};

/// Advertises one dmabuf format so the retained-buffer path is reachable. Shared-memory
/// buffers are released after their pixels are copied and are not part of restart adoption.
fn accepting_dmabuf() -> TestCompositor {
    TestCompositor::with_config(CompositorConfig {
        dmabuf: DmabufSupport {
            main_device: None,
            formats: vec![Format {
                code: Fourcc::Argb8888,
                modifier: Modifier::Linear,
            }],
        },
        ..CompositorConfig::default()
    })
}

/// Maps a client after importing its initial dmabuf, which gives the tests a retained buffer.
fn mapped_client(compositor: &mut TestCompositor) -> TestClient {
    let mut client = TestClient::connect(compositor);
    client.open_toplevel(compositor);
    client.attach_dmabuf(compositor, PixelSize::new(800, 600));
    client.settle(compositor, |driver| !driver.configure_serials().is_empty());
    compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::BufferImported { .. }))
    });
    client
}

fn release(compositor: &mut TestCompositor) {
    compositor.send(Command::ReleaseGraphics);
    compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::GraphicsReleased))
    });
}

fn adopt(compositor: &mut TestCompositor, log: &ImportLog) -> (usize, usize) {
    compositor.send(Command::AdoptGraphics {
        importer: recording_importer(log.clone()),
    });
    let events = compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::GraphicsAdopted { .. }))
    });

    events
        .into_iter()
        .find_map(|event| match event {
            Event::GraphicsAdopted { restored, failed } => Some((restored, failed)),
            _ => None,
        })
        .expect("the acknowledgement was waited for")
}

/// The release acknowledgement is the frame thread's permission to destroy the old device.
#[test]
fn releasing_the_device_leaves_the_client_connected_and_mapped() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);

    release(&mut compositor);

    // A round trip would fail if releasing the device disconnected the client.
    client.set_title(&mut compositor, "still here");
    client.settle(&mut compositor, |_| true);

    let snapshot = compositor.snapshot();
    assert_eq!(
        snapshot.windows.len(),
        1,
        "the window should have survived the device being given up"
    );
    assert_eq!(snapshot.windows[0].title.as_deref(), Some("still here"));
}

/// The compositor keeps the client's dmabuf while the graphics importer is absent, so adoption
/// can restore the surface without a new client commit.
#[test]
fn the_clients_buffer_is_retained_across_the_quiesce() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);
    let retained = client.driver().released.len();

    release(&mut compositor);
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().released.len(),
        retained,
        "no buffer should have been released: lunette is still holding the one it imported"
    );
}

/// A commit while the old importer is gone cannot produce an imported buffer; the client receives
/// the unimported buffer back and may commit another one after adoption.
#[test]
fn a_commit_while_the_device_is_gone_is_refused_and_the_buffer_handed_back() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);
    release(&mut compositor);

    let before = compositor.imports().dmabuf_count();
    let offered = client.attach_dmabuf(&mut compositor, PixelSize::new(800, 600));
    client.settle_quiet(&mut compositor);

    assert_eq!(
        compositor.imports().dmabuf_count(),
        before,
        "the importer was dropped with the device, so nothing can have reached one"
    );
    assert!(
        client.driver().released.contains(&offered),
        "a buffer that could not be imported is handed back, so the client may draw again"
    );
    assert!(
        compositor
            .drain_events()
            .iter()
            .all(|event| !matches!(event, Event::BufferImported { .. })),
        "nothing should have been reported as imported while there was no device"
    );
}

/// Adoption re-imports the retained dmabuf without a client commit and reports the restored
/// surface before its acknowledgement.
#[test]
fn adopting_a_device_re_imports_the_retained_buffer_without_the_client_drawing() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);
    let released_before = client.driver().released.len();

    release(&mut compositor);
    let adopted = ImportLog::default();
    let (restored, failed) = adopt(&mut compositor, &adopted);

    assert_eq!((restored, failed), (1, 0));
    assert_eq!(
        adopted.dmabuf_count(),
        1,
        "the retained buffer should have been imported against the new device"
    );

    client.settle_quiet(&mut compositor);
    assert_eq!(
        client.driver().released.len(),
        released_before,
        "the buffer lunette re-imported is one it is still sampling, so the client must not be \
         told it is free"
    );
}

/// A failed re-import is counted, releases the retained buffer to the client, and leaves the
/// client connection active.
#[test]
fn a_re_import_the_new_device_refuses_is_reported_and_the_buffer_released() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);

    release(&mut compositor);
    let adopted = ImportLog::default();
    adopted.refuse("the new device cannot import this modifier");
    let (restored, failed) = adopt(&mut compositor, &adopted);

    assert_eq!(
        (restored, failed),
        (0, 1),
        "the failure is counted rather than ending the restart"
    );

    client.settle_quiet(&mut compositor);
    assert!(
        !client.driver().released.is_empty(),
        "a buffer that cannot be re-imported is handed back, so the client can draw a fresh one"
    );

    // Wait for adoption before committing so the fresh buffer is not sent to the no-device
    // importer.
    let recovered = ImportLog::default();
    release(&mut compositor);
    assert_eq!(
        adopt(&mut compositor, &recovered),
        (0, 0),
        "the surface holds no buffer to restore, because the refused one was handed back"
    );

    client.attach_dmabuf(&mut compositor, PixelSize::new(800, 600));
    compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::BufferImported { .. }))
    });
    assert!(
        recovered.dmabuf_count() > 0,
        "the client's fresh buffer should have reached the new device"
    );
    assert_eq!(compositor.snapshot().windows.len(), 1);
}

/// The `wl_buffer` must be accepted while no device exists. Rejecting
/// `create_immed` with `INVALID_WL_BUFFER` would disconnect the client; the
/// commit defers image import until a device is available.
#[test]
fn a_dmabuf_created_during_the_quiesce_imports_once_a_device_arrives() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);
    release(&mut compositor);

    let created = client.create_dmabuf(&mut compositor, PixelSize::new(640, 480));

    // A round trip would fail if `create_immed` had disconnected the client.
    client.set_title(&mut compositor, "still here");
    client.settle(&mut compositor, |_| true);
    assert_eq!(
        compositor.snapshot().windows[0].title.as_deref(),
        Some("still here"),
        "accepting the create unimported is what keeps the client connected"
    );

    let adopted = ImportLog::default();
    adopt(&mut compositor, &adopted);
    let before = adopted.dmabuf_count();
    let released_before = client.driver().released.len();

    client.attach_created(&mut compositor, &created, PixelSize::new(640, 480));
    compositor.collect_events(|events| {
        events
            .iter()
            .any(|event| matches!(event, Event::BufferImported { .. }))
    });

    assert!(
        adopted.dmabuf_count() > before,
        "the buffer created while the device was gone should have reached the new device"
    );
    assert_eq!(
        client.driver().released.len(),
        released_before + 1,
        "the surface's previous buffer is handed back and the one just imported is not, because \
         lunette is now sampling it"
    );
    assert_eq!(compositor.snapshot().windows.len(), 1);
}

/// Release acknowledges an empty compositor so the frame thread can destroy the device only
/// after the importer has been dropped, even when no buffer was retained.
#[test]
fn a_release_with_nothing_imported_is_acknowledged() {
    let mut compositor = accepting_dmabuf();

    release(&mut compositor);

    let adopted = ImportLog::default();
    assert_eq!(adopt(&mut compositor, &adopted), (0, 0));
}
