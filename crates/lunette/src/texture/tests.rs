//! The ledger's bookkeeping, exercised without a graphics device.
//!
//! A texture here is an integer or a counter, which is what the generic on
//! [`TextureLedger`] is for. The rotation, the frame check, the dead-handle
//! rule, the retirement schedule, and the stabilising copy are all production
//! code paths; only the texture itself is a stand-in.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

use pretty_assertions::assert_eq;

use super::*;

/// Stands in for a LÖVR texture. The ledger never dereferences what it
/// holds, which is the property that makes this substitution honest.
type FakeTexture = u32;

fn surface(raw: u64) -> SurfaceId {
    SurfaceId::new(raw).expect("non-zero")
}

fn image(raw: u64) -> ImageHandle {
    ImageHandle::new(raw).expect("non-zero")
}

fn frame(raw: u64) -> FrameGeneration {
    let mut generation = FrameGeneration::INITIAL;
    for _ in 0..raw {
        generation = generation.next();
    }
    generation
}

fn description(width: u32, height: u32) -> TextureDescription {
    TextureDescription {
        size: PixelSize::new(width, height),
        alpha: Alpha::Present,
    }
}

fn ledger() -> TextureLedger<FakeTexture> {
    TextureLedger::new()
}

/// An imported texture handed back with no stabilised copy alongside it, which
/// is what every change to a surface nobody has stabilised produces.
fn released(imported: Option<FakeTexture>) -> Released<FakeTexture> {
    Released {
        imported,
        stable: None,
    }
}

#[test]
fn a_frame_generation_increases_and_never_wraps() {
    assert_eq!(FrameGeneration::INITIAL.get(), 0);
    assert_eq!(FrameGeneration::INITIAL.next().get(), 1);

    let last = FrameGeneration(u64::MAX);
    assert_eq!(
        last.next(),
        last,
        "wrapping would make an ancient handle compare equal to a current one"
    );
}

#[test]
fn a_handle_from_this_frame_resolves() {
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(64, 32));

    let reference = TextureRef::new(surface(1), frame(3));
    assert_eq!(ledger.lookup(reference, frame(3)), Ok(&7));
}

#[test]
fn a_handle_from_an_earlier_frame_is_refused() {
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(64, 32));

    let reference = TextureRef::new(surface(1), frame(3));
    assert_eq!(
        ledger.lookup(reference, frame(4)),
        Err(TextureUnavailable::Stale {
            obtained: frame(3),
            current: frame(4),
        }),
        "the texture rotates as the client cycles buffers, so a cached handle is not merely \
         stale bookkeeping"
    );
}

#[test]
fn a_handle_from_a_later_frame_is_refused_too() {
    // Not reachable through the public API, but the check is an equality
    // rather than an ordering, and stating that keeps it one.
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(64, 32));

    assert!(
        ledger
            .lookup(TextureRef::new(surface(1), frame(9)), frame(4))
            .is_err()
    );
}

#[test]
fn a_handle_to_an_unknown_surface_resolves_to_nothing() {
    assert_eq!(
        ledger().lookup(TextureRef::new(surface(1), frame(1)), frame(1)),
        Err(TextureUnavailable::Unknown)
    );
}

#[test]
fn installing_a_texture_returns_the_one_it_replaces() {
    let mut ledger = ledger();

    assert_eq!(
        ledger.install(surface(1), 1, description(64, 32)),
        released(None)
    );
    assert_eq!(
        ledger.install(surface(1), 2, description(64, 32)),
        released(Some(1)),
        "the previous texture is handed back so its reference can be dropped"
    );
    assert_eq!(
        ledger.lookup(TextureRef::new(surface(1), frame(0)), frame(0)),
        Ok(&2)
    );
}

#[test]
fn surfaces_do_not_replace_each_others_textures() {
    let mut ledger = ledger();
    assert_eq!(
        ledger.install(surface(1), 1, description(64, 32)),
        released(None)
    );
    assert_eq!(
        ledger.install(surface(2), 2, description(64, 32)),
        released(None)
    );

    assert_eq!(
        ledger.lookup(TextureRef::new(surface(1), frame(0)), frame(0)),
        Ok(&1)
    );
    assert_eq!(
        ledger.lookup(TextureRef::new(surface(2), frame(0)), frame(0)),
        Ok(&2)
    );
}

#[test]
fn a_dead_surface_keeps_its_last_known_description() {
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(1280, 720));

    assert_eq!(ledger.mark_dead(surface(1)), released(Some(7)));
    assert!(ledger.is_dead(surface(1)));
    assert_eq!(
        ledger.describe(surface(1)),
        Some(description(1280, 720)),
        "a handle whose client has exited reads its last-known values rather than nothing"
    );
}

#[test]
fn a_dead_surface_reports_death_rather_than_staleness() {
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(64, 32));
    ledger.mark_dead(surface(1));

    assert_eq!(
        ledger.lookup(TextureRef::new(surface(1), frame(1)), frame(9)),
        Err(TextureUnavailable::Dead),
        "a handle to an exited client is both dead and stale, and death is the answer that \
         does not raise"
    );
}

#[test]
fn marking_a_surface_dead_twice_yields_the_texture_once() {
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(64, 32));

    assert_eq!(ledger.mark_dead(surface(1)), released(Some(7)));
    assert_eq!(
        ledger.mark_dead(surface(1)),
        released(None),
        "a second call must not hand out a reference that has already been dropped"
    );
}

#[test]
fn marking_an_unknown_surface_dead_does_nothing() {
    let mut ledger = ledger();
    assert_eq!(ledger.mark_dead(surface(4)), released(None));
    assert!(!ledger.is_dead(surface(4)));
    assert_eq!(ledger.describe(surface(4)), None);
}

#[test]
fn forgetting_a_surface_removes_it_entirely() {
    let mut ledger = ledger();
    ledger.install(surface(1), 7, description(64, 32));

    assert_eq!(ledger.forget(surface(1)), released(Some(7)));
    assert_eq!(ledger.describe(surface(1)), None);
    assert_eq!(ledger.forget(surface(1)), released(None));
}

#[test]
fn a_retired_image_is_not_destroyed_in_the_frame_it_was_retired() {
    let mut ledger = ledger();
    ledger.retire_image(image(1), frame(5));

    assert_eq!(
        ledger.collect_due_images(frame(5)),
        Vec::new(),
        "LÖVR retires the view at the end of this tick, so the image is still named by a \
         recorded command buffer"
    );
}

#[test]
fn a_retired_image_is_destroyed_once_its_deferral_has_elapsed() {
    let mut ledger = ledger();
    ledger.retire_image(image(1), frame(5));

    assert_eq!(ledger.collect_due_images(frame(6)), Vec::new());
    assert_eq!(ledger.collect_due_images(frame(7)), vec![image(1)]);
    assert_eq!(
        ledger.collect_due_images(frame(8)),
        Vec::new(),
        "an image is collected exactly once, or it is freed twice"
    );
}

#[test]
fn images_retired_in_different_frames_come_due_in_order() {
    let mut ledger = ledger();
    ledger.retire_image(image(1), frame(1));
    ledger.retire_image(image(2), frame(3));

    assert_eq!(ledger.collect_due_images(frame(3)), vec![image(1)]);
    assert_eq!(ledger.collect_due_images(frame(4)), Vec::new());
    assert_eq!(ledger.collect_due_images(frame(5)), vec![image(2)]);
}

#[test]
fn several_images_retired_in_one_frame_come_due_together() {
    let mut ledger = ledger();
    ledger.retire_image(image(1), frame(2));
    ledger.retire_image(image(2), frame(2));

    let mut due = ledger.collect_due_images(frame(4));
    due.sort_unstable();
    assert_eq!(due, vec![image(1), image(2)]);
}

#[test]
fn a_barrier_policy_defaults_to_what_the_specification_describes() {
    let policy = BarrierPolicy::default();
    assert_eq!(policy.source_family, QueueFamilyMode::Foreign);
    assert_eq!(policy.old_layout, ForeignLayout::General);
    assert_eq!(policy.source_family.index(), vk::QUEUE_FAMILY_FOREIGN_EXT);
    assert_eq!(policy.old_layout.layout(), vk::ImageLayout::GENERAL);
}

#[test]
fn the_other_value_of_each_setting_is_reachable_without_a_rebuild() {
    let policy = BarrierPolicy::from_settings(Some("ignored"), Some("undefined"));

    assert_eq!(policy.source_family, QueueFamilyMode::Ignored);
    assert_eq!(policy.source_family.index(), vk::QUEUE_FAMILY_IGNORED);
    assert_eq!(policy.old_layout, ForeignLayout::Undefined);
    assert_eq!(policy.old_layout.layout(), vk::ImageLayout::UNDEFINED);
}

#[test]
fn a_release_hands_the_image_back_in_a_layout_a_barrier_may_name() {
    // The regression: the release passed the policy's own layout as the
    // barrier's `newLayout`, so `LUNETTE_IMPORT_LAYOUT=undefined` recorded
    // `VK_IMAGE_LAYOUT_UNDEFINED` as a destination, which
    // VUID-VkImageMemoryBarrier2-newLayout-01198 forbids.
    assert_ne!(BarrierPolicy::RELEASE_LAYOUT, vk::ImageLayout::UNDEFINED);
    assert_eq!(BarrierPolicy::RELEASE_LAYOUT, vk::ImageLayout::GENERAL);

    for layout in [ForeignLayout::General, ForeignLayout::Undefined] {
        let policy = BarrierPolicy {
            source_family: QueueFamilyMode::Foreign,
            old_layout: layout,
        };
        assert_eq!(
            policy.acquire_layout(),
            layout.layout(),
            "the acquire is where the switch is measurable, and `UNDEFINED` is legal there"
        );
    }
}

#[test]
fn an_unrecognised_setting_falls_back_rather_than_stopping_the_session() {
    assert_eq!(
        BarrierPolicy::from_settings(Some("FOREIGN"), Some("")),
        BarrierPolicy::default(),
        "a diagnostic switch is not worth failing a session over, and the parse is exact"
    );
    assert_eq!(QueueFamilyMode::parse("neither"), None);
    assert_eq!(ForeignLayout::parse("optimal"), None);
}

#[test]
fn an_unset_setting_is_the_default() {
    assert_eq!(
        BarrierPolicy::from_settings(None, None),
        BarrierPolicy::default()
    );
}

#[test]
fn an_imported_x_format_is_described_as_opaque() {
    let buffer = ImportedBuffer::Image(ImportedImage {
        image: image(1),
        size: PixelSize::new(8, 4),
        format: smithay::backend::allocator::Fourcc::Xrgb8888,
        modifier: smithay::backend::allocator::Modifier::Linear,
    });

    assert_eq!(
        describe(&buffer),
        TextureDescription {
            size: PixelSize::new(8, 4),
            alpha: Alpha::Opaque,
        }
    );
}

#[test]
fn an_imported_a_format_is_described_as_carrying_alpha() {
    let buffer = ImportedBuffer::Image(ImportedImage {
        image: image(1),
        size: PixelSize::new(8, 4),
        format: smithay::backend::allocator::Fourcc::Argb8888,
        modifier: smithay::backend::allocator::Modifier::Linear,
    });

    assert_eq!(describe(&buffer).alpha, Alpha::Present);
}

#[test]
fn an_uploaded_buffer_always_carries_alpha_because_the_repack_forced_it() {
    for format in [ShmFormat::Argb8888, ShmFormat::Xrgb8888] {
        let pixels =
            PixelBuffer::new(PixelSize::new(1, 1), format, vec![1, 2, 3, 255]).expect("one pixel");

        assert_eq!(
            describe(&ImportedBuffer::Pixels(pixels)),
            TextureDescription {
                size: PixelSize::new(1, 1),
                alpha: Alpha::Present,
            }
        );
    }
}

#[test]
fn every_shm_format_is_uploaded_as_bgra() {
    for format in [ShmFormat::Argb8888, ShmFormat::Xrgb8888] {
        assert_eq!(shm_texture_format(format), TextureFormat_FORMAT_BGRA8);
    }
}

#[test]
fn the_texture_declaration_matches_what_the_import_creates() {
    let info = texture_info(PixelSize::new(2, 2), TextureFormat_FORMAT_BGRA8, 42, true);

    assert_eq!(info.usage, TEXTURE_SAMPLE | TEXTURE_TRANSFER);
    assert!(info.foreign);
    assert_eq!(info.handle, 42);
    assert_eq!(info.layers, 1);
    assert_eq!(info.mipmaps, 1);
    assert_eq!(info.samples, 1);
    assert!(!info.srgb);
    assert!(!info.xr);
    assert_eq!(info.imageCount, 0);
    assert!(info.images.is_null());
}

#[test]
fn a_texture_lovr_allocates_is_not_declared_foreign() {
    let info = texture_info(PixelSize::new(2, 2), TextureFormat_FORMAT_BGRA8, 0, false);
    assert!(
        !info.foreign,
        "the flag suppresses the initial transition, which a texture LÖVR is about to fill \
         genuinely wants"
    );
    assert_eq!(info.handle, 0);
}

/// Stands in for a texture that can be copied into.
///
/// Identity is the number, and it is the property the stabilising copy exists
/// to provide, so equality is the number alone. Every texture descended from
/// one source shares a log of the copies made between them, which is how a test
/// sees a copy that the ledger performed on its own.
#[derive(Clone, Debug)]
struct CountingTexture {
    id: u32,
    shared: Rc<Shared>,
}

#[derive(Debug, Default)]
struct Shared {
    /// The last identifier handed out by [`CopyableTexture::allocate_copy`].
    allocated: Cell<u32>,
    /// Every copy made, as the source and the destination it was written into.
    copies: RefCell<Vec<(u32, u32)>>,
    /// Whether the device refuses to allocate or to copy.
    refuse: Cell<bool>,
}

impl CountingTexture {
    fn new(id: u32) -> Self {
        Self {
            id,
            shared: Rc::new(Shared {
                allocated: Cell::new(1000),
                ..Shared::default()
            }),
        }
    }

    /// Another source recorded in the same log, standing in for the next buffer
    /// a client commits.
    fn rotated(&self, id: u32) -> Self {
        Self {
            id,
            shared: Rc::clone(&self.shared),
        }
    }

    fn copies(&self) -> Vec<(u32, u32)> {
        self.shared.copies.borrow().clone()
    }

    fn refuse(&self) {
        self.shared.refuse.set(true);
    }
}

impl PartialEq for CountingTexture {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for CountingTexture {}

impl CopyableTexture for CountingTexture {
    fn allocate_copy(&self) -> Option<Self> {
        if self.shared.refuse.get() {
            return None;
        }

        let id = self.shared.allocated.get() + 1;
        self.shared.allocated.set(id);
        Some(self.rotated(id))
    }

    fn copy_to(&self, destination: &Self) -> bool {
        if self.shared.refuse.get() {
            return false;
        }

        self.shared
            .copies
            .borrow_mut()
            .push((self.id, destination.id));
        true
    }
}

/// A ledger holding one stabilised surface, with the source that fills it.
fn stabilized() -> (TextureLedger<CountingTexture>, CountingTexture, u32) {
    let mut ledger = TextureLedger::new();
    let source = CountingTexture::new(1);
    ledger.install(surface(1), source.clone(), description(64, 32));

    let stable = ledger
        .stabilize(TextureRef::new(surface(1), frame(1)), frame(1))
        .expect("the first stabilise allocates")
        .id;

    (ledger, source, stable)
}

#[test]
fn stabilizing_allocates_a_texture_and_fills_it_from_the_client_buffer() {
    let (_, source, stable) = stabilized();

    assert_ne!(stable, source.id, "the copy is lunette's, not the client's");
    assert_eq!(
        source.copies(),
        vec![(source.id, stable)],
        "the first call returns something current rather than something empty"
    );
}

#[test]
fn stabilizing_twice_returns_the_same_texture_rather_than_allocating_again() {
    let (mut ledger, source, stable) = stabilized();

    let again = ledger
        .stabilize(TextureRef::new(surface(1), frame(1)), frame(1))
        .expect("the surface is still there")
        .id;

    assert_eq!(again, stable);
    assert_eq!(
        source.copies().len(),
        1,
        "an undamaged surface costs nothing, which is what makes an idle window free"
    );
}

#[test]
fn a_stabilised_texture_keeps_its_identity_as_the_client_cycles_its_buffers() {
    let (mut ledger, source, stable) = stabilized();

    for rotation in 2..=4 {
        let next = source.rotated(rotation);
        assert_eq!(
            ledger.install(surface(1), next, description(64, 32)),
            Released {
                imported: Some(source.rotated(rotation - 1)),
                stable: None,
            },
            "surviving the rotation is the whole reason to have asked for a copy"
        );
        ledger.refresh_stable();
    }

    let after = ledger
        .stabilize(TextureRef::new(surface(1), frame(1)), frame(1))
        .expect("the surface is still there")
        .id;

    assert_eq!(after, stable);
    assert_eq!(
        source.copies(),
        vec![(1, stable), (2, stable), (3, stable), (4, stable)],
        "every buffer the client committed was copied into the one stable texture"
    );
}

#[test]
fn refreshing_twice_without_damage_copies_once() {
    let (mut ledger, source, _) = stabilized();
    ledger.install(surface(1), source.rotated(2), description(64, 32));

    ledger.refresh_stable();
    ledger.refresh_stable();

    assert_eq!(
        source.copies().len(),
        2,
        "one for the stabilise, one for the damage"
    );
}

#[test]
fn a_surface_nobody_stabilised_is_not_copied() {
    let mut ledger = TextureLedger::new();
    let source = CountingTexture::new(1);
    ledger.install(surface(1), source.clone(), description(64, 32));

    ledger.refresh_stable();

    assert!(
        source.copies().is_empty(),
        "the zero-copy default is what the copy is opted out of"
    );
}

#[test]
fn a_resize_releases_the_copy_because_a_texture_cannot_follow_one() {
    let (mut ledger, source, stable) = stabilized();

    assert_eq!(
        ledger.install(surface(1), source.rotated(2), description(128, 64)),
        Released {
            imported: Some(source.rotated(1)),
            stable: Some(source.rotated(stable)),
        },
        "a LÖVR texture's dimensions are fixed at creation, so the copy cannot be kept"
    );

    let after = ledger
        .stabilize(TextureRef::new(surface(1), frame(1)), frame(1))
        .expect("a copy of the new shape is allocated")
        .id;
    assert_ne!(after, stable);
}

#[test]
fn a_dead_surface_hands_back_its_copy_and_refuses_to_stabilise_again() {
    let (mut ledger, source, stable) = stabilized();

    assert_eq!(
        ledger.mark_dead(surface(1)),
        Released {
            imported: Some(source.rotated(1)),
            stable: Some(source.rotated(stable)),
        },
        "every method of a dead handle answers false before it could reach the copy, so keeping \
         it would only leak it"
    );
    assert_eq!(
        ledger.stabilize(TextureRef::new(surface(1), frame(1)), frame(1)),
        Err(TextureUnavailable::Dead)
    );

    ledger.refresh_stable();
    assert_eq!(source.copies().len(), 1, "a dead surface is not redrawn");
}

#[test]
fn forgetting_a_surface_hands_back_its_copy_too() {
    let (mut ledger, source, stable) = stabilized();

    assert_eq!(
        ledger.forget(surface(1)),
        Released {
            imported: Some(source.rotated(1)),
            stable: Some(source.rotated(stable)),
        }
    );
}

#[test]
fn stabilizing_through_a_handle_from_another_frame_is_refused() {
    let (mut ledger, _, _) = stabilized();

    assert_eq!(
        ledger.stabilize(TextureRef::new(surface(1), frame(1)), frame(2)),
        Err(TextureUnavailable::Stale {
            obtained: frame(1),
            current: frame(2),
        })
    );
}

#[test]
fn stabilizing_a_surface_that_has_committed_nothing_resolves_to_nothing() {
    let mut ledger: TextureLedger<CountingTexture> = TextureLedger::new();

    assert_eq!(
        ledger.stabilize(TextureRef::new(surface(1), frame(1)), frame(1)),
        Err(TextureUnavailable::Unknown)
    );
}

#[test]
fn a_device_that_refuses_the_copy_is_reported_rather_than_left_stale() {
    let mut ledger = TextureLedger::new();
    let source = CountingTexture::new(1);
    ledger.install(surface(1), source.clone(), description(64, 32));
    source.refuse();

    assert_eq!(
        ledger.stabilize(TextureRef::new(surface(1), frame(1)), frame(1)),
        Err(TextureUnavailable::CopyFailed),
        "a refused allocation is the device saying no, not a race with a client"
    );
}

#[test]
fn a_copy_that_is_refused_leaves_the_surface_damaged_so_the_next_frame_retries() {
    let (mut ledger, source, stable) = stabilized();
    ledger.install(surface(1), source.rotated(2), description(64, 32));
    source.refuse();

    ledger.refresh_stable();
    assert_eq!(source.copies(), vec![(1, stable)]);

    // The device recovers; the surface is still damaged, so the copy is made.
    source.shared.refuse.set(false);
    ledger.refresh_stable();
    assert_eq!(source.copies(), vec![(1, stable), (2, stable)]);
}
