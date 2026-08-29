//! Which ledger change each compositor event produces, which monitors the
//! sweep for stopped mirrors releases, and the order in which the device
//! teardown releases what it holds.
//!
//! Every case is a pure mapping, a ledger operation, or a recorded call
//! sequence. None needs a graphics device: the texture is a counter and the
//! teardown target is a list.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use lunette_capture::monitor::{ConnectorKind, ConnectorName, MonitorKey};
use lunette_compositor::{
    protocol::{Event, ImportedBuffer, PixelSize, SurfaceId, WindowId},
    surface::{PixelBuffer, ShmFormat},
};
use pretty_assertions::assert_eq;

use super::{
    LedgerChange, ledger_change, stopped_monitors,
    teardown::{DeviceTeardown, Disposal, tear_down_device},
};
use crate::{
    import::formats::Alpha,
    texture::{FrameGeneration, TextureDescription, TextureLedger, TextureRef, TextureUnavailable},
};

/// A texture that is a counter, so the ledger's bookkeeping runs without a
/// graphics device.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Counted(u64);

impl crate::texture::CopyableTexture for Counted {
    fn allocate_copy(&self) -> Option<Self> {
        Some(Self(self.0 + 1000))
    }

    fn copy_to(&self, _destination: &Self) -> bool {
        true
    }
}

fn surface(raw: u64) -> SurfaceId {
    SurfaceId::new(raw).expect("non-zero")
}

fn description() -> TextureDescription {
    TextureDescription {
        size: PixelSize::new(4, 4),
        alpha: Alpha::Present,
    }
}

fn window_id(raw: u64) -> WindowId {
    WindowId::new(raw).expect("non-zero")
}

fn monitor(index: u32) -> MonitorKey {
    MonitorKey::Connector(ConnectorName::new(ConnectorKind::DisplayPort, index))
}

#[test]
fn a_surface_going_away_takes_its_texture_out_of_the_ledger() {
    // The regression: every `wl_surface` creates an identifier and can hold
    // a texture, but the compositor reports closures for toplevels. A popup
    // or cursor surface is never reported closed, so a texture it holds
    // would name an image the compositor has already retired.
    assert_eq!(
        ledger_change(
            &Event::SurfaceGone {
                surface: surface(1)
            },
            |_| unreachable!("a surface event names its surface directly")
        ),
        LedgerChange::Forget(surface(1))
    );
}

#[test]
fn forgetting_a_surface_hands_back_both_of_its_textures_and_stops_naming_them() {
    let mut ledger = TextureLedger::<Counted>::new();
    ledger.install(surface(1), Counted(1), description());
    ledger
        .stabilize(
            TextureRef::new(surface(1), FrameGeneration::INITIAL),
            FrameGeneration::INITIAL,
        )
        .expect("a live surface can be stabilised");

    let released = ledger.forget(surface(1));

    assert_eq!(released.imported, Some(Counted(1)));
    assert_eq!(released.stable, Some(Counted(1001)));
    assert_eq!(
        ledger.textures().count(),
        0,
        "a texture the frame no longer holds must not be named in a barrier"
    );
    assert_eq!(
        ledger.lookup(
            TextureRef::new(surface(1), FrameGeneration::INITIAL),
            FrameGeneration::INITIAL
        ),
        Err(TextureUnavailable::Unknown)
    );
}

#[test]
fn a_window_closing_marks_its_surface_dead_rather_than_forgetting_it() {
    assert_eq!(
        ledger_change(
            &Event::WindowClosed {
                window: window_id(3)
            },
            |window| (window == window_id(3)).then(|| surface(9))
        ),
        LedgerChange::MarkDead(surface(9))
    );
}

#[test]
fn a_window_the_snapshot_does_not_describe_changes_nothing() {
    assert_eq!(
        ledger_change(
            &Event::WindowClosed {
                window: window_id(3)
            },
            |_| None
        ),
        LedgerChange::Nothing
    );
}

#[test]
fn an_imported_buffer_installs_against_the_surface_it_arrived_for() {
    let buffer = ImportedBuffer::Pixels(
        PixelBuffer::new(
            PixelSize::new(1, 1),
            ShmFormat::Argb8888,
            vec![0, 0, 0, 255],
        )
        .expect("one pixel"),
    );
    let event = Event::BufferImported {
        surface: surface(2),
        buffer,
    };

    let Event::BufferImported { buffer, .. } = &event else {
        unreachable!("the event was just built as an import")
    };
    assert_eq!(
        ledger_change(&event, |_| unreachable!(
            "a buffer names its surface directly"
        )),
        LedgerChange::Install {
            surface: surface(2),
            buffer,
        }
    );
}

#[test]
fn the_reports_that_touch_no_texture_change_nothing() {
    for event in [
        Event::WindowOpened {
            window: window_id(1),
        },
        Event::TitleChanged {
            window: window_id(1),
            title: "htop".to_owned(),
        },
        Event::SurfaceDamaged {
            surface: surface(1),
        },
    ] {
        assert_eq!(
            ledger_change(&event, |_| None),
            LedgerChange::Nothing,
            "{event:?} has nothing to do with what the frame may sample"
        );
    }
}

#[test]
fn every_live_texture_is_offered_a_barrier() {
    let mut ledger = TextureLedger::<Counted>::new();
    ledger.install(surface(1), Counted(1), description());
    ledger.install(surface(2), Counted(2), description());

    let mut seen: Vec<u64> = ledger.textures().map(|texture| texture.0).collect();
    seen.sort_unstable();

    assert_eq!(seen, vec![1, 2]);
}

#[test]
fn a_dead_surfaces_texture_is_not_offered_a_barrier() {
    let mut ledger = TextureLedger::<Counted>::new();
    ledger.install(surface(1), Counted(1), description());
    let released = ledger.mark_dead(surface(1));

    assert_eq!(released.imported, Some(Counted(1)));
    assert_eq!(
        ledger.textures().count(),
        0,
        "a texture already handed back must not be named in a barrier"
    );
}

#[test]
fn a_stabilised_copy_is_offered_a_barrier_alongside_its_source() {
    let mut ledger = TextureLedger::<Counted>::new();
    ledger.install(surface(1), Counted(1), description());
    ledger
        .stabilize(
            TextureRef::new(surface(1), FrameGeneration::INITIAL),
            FrameGeneration::INITIAL,
        )
        .expect("a live surface can be stabilised");

    assert_eq!(ledger.textures().count(), 2);
}

#[test]
fn a_monitor_that_retains_buffers_but_holds_no_texture_is_still_swept() {
    // The regression: the sweep reads the texture ledger, and a monitor whose
    // frames import as images but whose textures the device refuses is never
    // in it. Every frame retains a buffer, the dismissal releases nothing,
    // and the dmabuf descriptors and their imported memory stay for the rest
    // of the process.
    assert_eq!(
        stopped_monitors(vec![], vec![monitor(1)], |_| false),
        vec![monitor(1)],
    );
}

#[test]
fn a_monitor_holding_a_texture_with_nothing_retained_is_swept() {
    assert_eq!(
        stopped_monitors(vec![monitor(1)], vec![], |_| false),
        vec![monitor(1)],
    );
}

#[test]
fn a_monitor_that_is_still_mirroring_keeps_what_it_holds() {
    // Neither the texture nor the retained buffers are released while frames
    // are still arriving, and a paused mirror is still mirroring.
    assert_eq!(
        stopped_monitors(vec![monitor(1)], vec![monitor(1)], |_| true),
        Vec::new(),
    );
}

#[test]
fn a_monitor_named_by_both_is_released_once() {
    // `forget_monitor_texture` is idempotent, but a repeat would log a second
    // release for buffers already released.
    assert_eq!(
        stopped_monitors(vec![monitor(1)], vec![monitor(1)], |_| false),
        vec![monitor(1)],
    );
}

#[test]
fn a_sweep_over_nothing_releases_nothing() {
    assert_eq!(
        stopped_monitors(vec![], vec![], |_| unreachable!(
            "no monitor is named, so none is asked about"
        )),
        Vec::new()
    );
}

#[test]
fn only_the_monitors_that_stopped_are_released() {
    let live = monitor(2);
    let stopped = stopped_monitors(vec![monitor(1)], vec![monitor(2), monitor(3)], |asked| {
        asked == &live
    });

    assert_eq!(stopped, vec![monitor(1), monitor(3)]);
}

#[test]
fn teardown_hands_back_every_texture_once() {
    let mut ledger = TextureLedger::<Counted>::new();
    ledger.install(surface(1), Counted(1), description());
    ledger.install(surface(2), Counted(2), description());

    let mut taken: Vec<u64> = ledger
        .take_all()
        .into_iter()
        .map(|texture| texture.0)
        .collect();
    taken.sort_unstable();

    assert_eq!(taken, vec![1, 2]);
    assert!(
        ledger.take_all().is_empty(),
        "a second teardown has nothing left to release"
    );
    assert_eq!(
        ledger.lookup(
            TextureRef::new(surface(1), FrameGeneration::INITIAL),
            FrameGeneration::INITIAL
        ),
        Err(TextureUnavailable::Unknown)
    );
}

/// One documented step of the device teardown, so the tests can compare the
/// ordered steps as values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    DestroyLayers,
    DrainGpu,
    ForgetClaims,
    ForgetBlits,
    ReleaseTextures,
    GiveUpImages(Disposal),
}

/// A teardown target that records each step it runs, in order.
///
/// The production target is `FrameDriver`, whose steps each need an XR
/// session, a graphics device, or both. The order in which the steps run is
/// the property under test, and that property belongs to `tear_down_device`.
/// The pool, the ledger, and the arena each have their own cases.
#[derive(Debug, Default)]
struct Recorder(Vec<Step>);

impl DeviceTeardown for Recorder {
    fn drain_gpu(&mut self) {
        self.0.push(Step::DrainGpu);
    }

    fn destroy_layers(&mut self) {
        self.0.push(Step::DestroyLayers);
    }

    fn forget_claims(&mut self) {
        self.0.push(Step::ForgetClaims);
    }

    fn forget_blits(&mut self) {
        self.0.push(Step::ForgetBlits);
    }

    fn release_textures(&mut self) {
        self.0.push(Step::ReleaseTextures);
    }

    fn give_up_images(&mut self, disposal: Disposal) {
        self.0.push(Step::GiveUpImages(disposal));
    }
}

fn torn_down(disposal: Disposal) -> Vec<Step> {
    let mut recorder = Recorder::default();
    tear_down_device(&mut recorder, disposal);
    recorder.0
}

/// The ordering `crate::restart` documents. A reordering produces a
/// use-after-free on the GPU, and nothing reports it. A layer is destroyed by
/// `xrDestroySwapchain` and so goes while the XR session is active. Releasing
/// a texture retires LÖVR's image view, and the image it names is not given
/// up before the view retires.
#[test]
fn the_device_teardown_destroys_layers_then_releases_textures_then_gives_up_the_images() {
    assert_eq!(
        torn_down(Disposal::Abandon),
        vec![
            Step::DrainGpu,
            Step::DestroyLayers,
            Step::ForgetClaims,
            Step::ForgetBlits,
            Step::ReleaseTextures,
            Step::GiveUpImages(Disposal::Abandon),
        ]
    );
}

/// The restart the compositor does not acknowledge, and the session ending,
/// run the same teardown. The regression: the failed-quiesce path skips the
/// claims, and the next session's layer budget remains reserved by panels
/// from a closed Lua state.
#[test]
fn a_teardown_that_stops_the_compositor_gives_up_everything_the_restart_does() {
    let abandoning = torn_down(Disposal::Abandon);
    let stopping = torn_down(Disposal::StopCompositor);

    assert_eq!(
        stopping,
        vec![
            Step::DrainGpu,
            Step::DestroyLayers,
            Step::ForgetClaims,
            Step::ForgetBlits,
            Step::ReleaseTextures,
            Step::GiveUpImages(Disposal::StopCompositor),
        ]
    );
    assert_eq!(
        stopping[..stopping.len() - 1],
        abandoning[..abandoning.len() - 1],
        "the two teardowns differ in what becomes of the images and in nothing else"
    );
}
