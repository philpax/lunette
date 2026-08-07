//! Giving up the graphics device and taking a new one, with a client connected
//! throughout.
//!
//! `lunette-v1.AC5.5` asks for a restart that rebuilds the Lua state and the XR
//! session while clients stay connected. The half of that this file establishes
//! is the compositor's: the device the importer was built against is destroyed
//! and replaced, and the connection, the window, and the client's buffer are
//! unaffected. What lunette does with the images on its own side is
//! `crates/lunette/src/restart.rs`'s, and is tested there.
//!
//! Everything here runs with no graphics device at all. The importer is a
//! recording fake, which is exactly the seam the restart protocol operates on:
//! releasing the device *is* dropping the importer, so a fake importer is the
//! real subject rather than a stand-in for it.

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

/// A compositor that advertises a format a client can allocate, so the dmabuf
/// path is reachable. The shared-memory path has nothing to retain across a
/// restart, so every case here is a dmabuf one.
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

/// A compositor with one client whose toplevel is mapped and whose dmabuf has
/// been imported.
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

/// The two counts a `GraphicsAdopted` carries, once one has arrived.
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

/// The acknowledgement is what the frame thread destroys the device on, so it
/// has to arrive, and nothing about the client may change when it does.
#[test]
fn releasing_the_device_leaves_the_client_connected_and_mapped() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);

    release(&mut compositor);

    // A disconnected client's next round trip is what would fail here.
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

/// The buffer is what the re-import restores the surface from, so releasing it
/// during the quiesce would mean the client had to redraw after every restart.
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

/// Nothing may reach the importer between the release and the adopt, because
/// the device it would import against no longer exists.
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

/// The property AC5.5 rests on: the client drew nothing, and its surface has
/// its content back.
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

/// A restart is not something a session should end over, so one surface losing
/// its content is reported and survived.
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

    // The session continues: the client is connected, and its next commit is
    // imported normally once a device that does not refuse arrives. The adopt
    // is waited for before the commit, so the two cannot be dispatched in the
    // other order.
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

/// The premise `dmabuf_imported` accepts an unimported buffer on: the
/// `wl_buffer` is valid, and the commit that asks it to become an image is where
/// a device that does not exist yet is answered survivably.
///
/// Refusing the create instead would answer `create_immed` with
/// `INVALID_WL_BUFFER`, which disconnects the client — and `lunette-v1.AC5.5` is
/// precisely that a restart disconnects nobody. So the create has to survive the
/// quiesce and the buffer has to import once a device arrives.
#[test]
fn a_dmabuf_created_during_the_quiesce_imports_once_a_device_arrives() {
    let mut compositor = accepting_dmabuf();
    let mut client = mapped_client(&mut compositor);
    release(&mut compositor);

    // Created while there is no device, so `dmabuf_imported` takes the accept
    // path. Nothing is committed yet, so nothing has asked for an image.
    let created = client.create_dmabuf(&mut compositor, PixelSize::new(640, 480));

    // A disconnected client's next round trip is what would fail here, which is
    // what refusing the create rather than accepting it would have caused.
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

/// A compositor no client has ever committed to still has to answer, because
/// the frame thread waits for the acknowledgement before destroying the device
/// whether or not anything was imported.
#[test]
fn a_release_with_nothing_imported_is_acknowledged() {
    let mut compositor = accepting_dmabuf();

    release(&mut compositor);

    let adopted = ImportLog::default();
    assert_eq!(adopt(&mut compositor, &adopted), (0, 0));
}
