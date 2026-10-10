//! Linux-only: decides whether a window's pixels are copied into its
//! composition layer's swapchain this frame.
//!
//! A copy happens when the texture ledger's install counter differs from the
//! one last copied. Damage rectangles are not consulted, because a client can
//! attach a new buffer without posting damage.

use std::collections::HashMap;

use lunette_compositor::protocol::SurfaceId;
use tracing::warn;

use crate::{
    layers::{ClaimId, backend::LayerBackend, pool::LayerPool},
    texture::{SurfaceCommit, TextureLedger},
};

/// The seam between the blit decision and LÖVR, so tests run with no XR runtime
/// and no device.
pub trait LayerBlitter {
    /// A layer the pool holds.
    type Layer;
    /// A texture, either a surface's or a layer's.
    type Texture;

    /// Acquires the layer's swapchain image for this frame.
    ///
    /// Each submit releases the swapchain, so a call in a later frame may
    /// answer with a different image, and the image is used only in the frame
    /// that acquired it. `None` when the runtime refused.
    fn acquire(&mut self, layer: &Self::Layer) -> Option<Self::Texture>;

    /// Whether the device can copy `source` into `destination`.
    ///
    /// The formats usually differ, so `lovrTextureCopy` falls back to
    /// `lovrTextureBlit`, which needs `GPU_FEATURE_BLIT` on both formats.
    fn can_copy(&self, source: &Self::Texture, destination: &Self::Texture) -> bool;

    /// Records the copy, reporting whether LÖVR accepted it.
    fn copy(&mut self, source: &Self::Texture, destination: &Self::Texture) -> bool;
}

/// What the blit path did about one claim.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Blitted {
    /// The source has been replaced since the last copy, and the copy was
    /// recorded.
    Copied,
    /// The source has not changed since the last copy, so nothing is acquired
    /// or copied.
    Unchanged,
    /// The claim's source has no texture: it has never committed a buffer, or
    /// its client is gone.
    NoSource,
    /// The layer's swapchain image could not be acquired for this frame.
    NotAcquired,
    /// The device cannot copy this source into a layer. The claim never
    /// becomes grantable, and the panel renders as an in-scene quad.
    Unsupported,
    /// LÖVR refused the copy it was asked to record.
    Refused,
}

impl Blitted {
    /// Whether a copy was recorded. A newly created layer becomes grantable
    /// after a copy is recorded into it.
    #[must_use]
    pub const fn copied(self) -> bool {
        matches!(self, Self::Copied)
    }

    /// Whether the outcome is worth a line every frame it happens.
    ///
    /// False for [`Blitted::Unsupported`], which recurs every frame for the
    /// rest of the session. [`BlitLedger`] reports that outcome once per claim.
    #[must_use]
    pub const fn worth_reporting_every_frame(self) -> bool {
        matches!(self, Self::NotAcquired | Self::Refused)
    }
}

/// What the blit path decided about one claim, before anything was recorded.
///
/// Deciding needs no device, so it stays separate from recording the copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Decision {
    /// Copy the source, and record this commit as the last-copied source.
    Copy(SurfaceCommit),
    /// Leave the layer as it is, for this reason.
    Skip(Blitted),
}

/// Whether a claim's layer takes the copy this frame.
///
/// `last` is the commit last copied into the layer, and `source` is the commit
/// the surface holds now. A claim nothing has been copied into is always
/// copied.
fn decide(last: Option<SurfaceCommit>, source: Option<SurfaceCommit>) -> Decision {
    let Some(current) = source else {
        return Decision::Skip(Blitted::NoSource);
    };

    if last == Some(current) {
        Decision::Skip(Blitted::Unchanged)
    } else {
        Decision::Copy(current)
    }
}

/// What each claim has had copied into its layer.
///
/// It holds no swapchain image: each copy acquires the layer's image for the
/// frame it runs in.
#[derive(Debug, Default)]
pub struct BlitLedger {
    copied: HashMap<ClaimId, SurfaceCommit>,
    /// Claims whose source the device cannot copy into a layer, so the refusal
    /// is reported once per claim.
    reported: Vec<ClaimId>,
}

impl BlitLedger {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Copies into every layer the pool holds whose source has changed.
    ///
    /// Layers that are not yet grantable are included, because `xrEndFrame`
    /// rejects a layer whose swapchain has never released an image. `source`
    /// maps a claim onto its surface, since neither the pool nor this ledger
    /// holds that mapping.
    pub fn run<B, S, T>(
        &mut self,
        pool: &mut LayerPool<B>,
        blitter: &mut S,
        textures: &TextureLedger<T>,
        source: impl Fn(ClaimId) -> Option<SurfaceId>,
    ) -> Vec<(ClaimId, Blitted)>
    where
        B: LayerBackend,
        S: LayerBlitter<Layer = B::Layer, Texture = T>,
    {
        let claims: Vec<ClaimId> = pool.held().map(|(claim, _)| claim).collect();
        self.forget_absent(&claims);

        let mut report = Vec::with_capacity(claims.len());
        for claim in claims {
            let commit = source(claim)
                .and_then(|surface| textures.source(surface))
                .map(|(_, commit)| commit);

            let outcome = match decide(self.copied.get(&claim).copied(), commit) {
                Decision::Skip(outcome) => outcome,
                Decision::Copy(commit) => {
                    let outcome = self.copy(pool, blitter, textures, &source, claim);
                    if outcome.copied() {
                        self.copied.insert(claim, commit);
                        pool.note_blit_issued(claim);
                    }
                    outcome
                }
            };

            report.push((claim, outcome));
        }

        report
    }

    /// Forgets every claim not in `held`.
    ///
    /// A claim that lost its layer must not keep its counter, because its next
    /// layer holds a previous holder's pixels.
    fn forget_absent(&mut self, held: &[ClaimId]) {
        self.copied.retain(|claim, _| held.contains(claim));
        self.reported.retain(|claim| held.contains(claim));
    }

    /// Records one claim's copy.
    fn copy<B, S, T>(
        &mut self,
        pool: &LayerPool<B>,
        blitter: &mut S,
        textures: &TextureLedger<T>,
        source: &impl Fn(ClaimId) -> Option<SurfaceId>,
        claim: ClaimId,
    ) -> Blitted
    where
        B: LayerBackend,
        S: LayerBlitter<Layer = B::Layer, Texture = T>,
    {
        let Some((pixels, _)) = source(claim).and_then(|surface| textures.source(surface)) else {
            return Blitted::NoSource;
        };
        let Some(layer) = pool.layer(claim) else {
            return Blitted::NoSource;
        };

        let Some(destination) = blitter.acquire(layer) else {
            return Blitted::NotAcquired;
        };

        let outcome = if !blitter.can_copy(pixels, &destination) {
            Blitted::Unsupported
        } else if blitter.copy(pixels, &destination) {
            Blitted::Copied
        } else {
            Blitted::Refused
        };

        if outcome == Blitted::Unsupported && !self.reported.contains(&claim) {
            self.reported.push(claim);
            warn!(
                %claim,
                "this device cannot copy the window's pixels into a composition layer, so the \
                 panel renders as an in-scene quad"
            );
        }

        outcome
    }
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]
mod tests {
    use std::{
        cell::{Cell, RefCell},
        rc::Rc,
    };

    use lunette_compositor::protocol::PixelSize;
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::{
        import::formats::Alpha,
        layers::{LayerBudget, LayerSize, Priority, SessionId, SessionPresence},
        scene::SceneRendering,
        texture::{CopyableTexture, FrameGeneration, TextureDescription},
    };

    /// A texture that is a number, so the decision can be exercised without a
    /// graphics device.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    struct Counted(u64);

    impl CopyableTexture for Counted {
        fn allocate_copy(&self) -> Option<Self> {
            Some(Self(self.0 + 1000))
        }

        fn copy_to(&self, _destination: &Self) -> bool {
            true
        }
    }

    /// A layer that is a number.
    #[derive(Debug)]
    struct FakeLayer(u64);

    /// A pool backend that allocates numbered layers and stores each submitted
    /// list.
    #[derive(Debug)]
    struct FakeLayers {
        next: u64,
        /// What the runtime reports as the layer limit. The pool spends a
        /// fraction of it.
        limit: u32,
        /// Shared with the harness, because an accessor through the pool would
        /// be production code only tests call.
        submitted: Rc<RefCell<Vec<Vec<u64>>>>,
    }

    impl LayerBackend for FakeLayers {
        type Layer = FakeLayer;

        fn layer_limit(&self) -> u32 {
            self.limit
        }

        /// A pool with no session holds nothing to blit into.
        fn session(&self) -> SessionPresence {
            SessionPresence::Present(SessionId::new(1).expect("one is not zero"))
        }

        fn create(&mut self, _size: LayerSize) -> Option<Self::Layer> {
            self.next += 1;
            Some(FakeLayer(self.next))
        }

        fn submit(&mut self, layers: &[&Self::Layer], _scene: SceneRendering) -> bool {
            self.submitted
                .borrow_mut()
                .push(layers.iter().map(|layer| layer.0).collect());
            true
        }

        fn destroy(&mut self, _layer: Self::Layer) {}
    }

    /// A blitter that records each acquire and each copy it performs.
    #[derive(Debug)]
    struct FakeBlitter {
        acquires: Cell<u64>,
        copies: RefCell<Vec<(u64, u64)>>,
        /// Which swapchain image the next acquire returns. The harness bumps
        /// it each frame, because a real swapchain rotates.
        image: Cell<u64>,
        supported: Cell<bool>,
        acquirable: Cell<bool>,
    }

    impl Default for FakeBlitter {
        fn default() -> Self {
            Self {
                acquires: Cell::new(0),
                copies: RefCell::new(Vec::new()),
                image: Cell::new(1_000_000),
                supported: Cell::new(true),
                acquirable: Cell::new(true),
            }
        }
    }

    impl LayerBlitter for FakeBlitter {
        type Layer = FakeLayer;
        type Texture = Counted;

        fn acquire(&mut self, _layer: &Self::Layer) -> Option<Self::Texture> {
            if !self.acquirable.get() {
                return None;
            }
            self.acquires.set(self.acquires.get() + 1);
            Some(Counted(self.image.get()))
        }

        fn can_copy(&self, _source: &Self::Texture, _destination: &Self::Texture) -> bool {
            self.supported.get()
        }

        fn copy(&mut self, source: &Self::Texture, destination: &Self::Texture) -> bool {
            self.copies.borrow_mut().push((source.0, destination.0));
            true
        }
    }

    /// A runtime limit generous enough that nothing here contends for slots.
    const GENEROUS: u32 = 128;

    /// A pool, a texture ledger, and a blit ledger, stepped one frame at a
    /// time.
    struct Harness {
        pool: LayerPool<FakeLayers>,
        blitter: FakeBlitter,
        textures: TextureLedger<Counted>,
        ledger: BlitLedger,
        submitted: Rc<RefCell<Vec<Vec<u64>>>>,
        sources: Vec<(ClaimId, SurfaceId)>,
        frame: FrameGeneration,
        next_texture: u64,
    }

    impl Harness {
        fn new() -> Self {
            Self::with_limit(GENEROUS)
        }

        /// `limit` is what the runtime reports, which is four times what the
        /// pool will spend.
        fn with_limit(limit: u32) -> Self {
            let submitted = Rc::new(RefCell::new(Vec::new()));
            Self {
                pool: LayerPool::new(FakeLayers {
                    next: 0,
                    limit,
                    submitted: Rc::clone(&submitted),
                }),
                blitter: FakeBlitter::default(),
                textures: TextureLedger::new(),
                ledger: BlitLedger::new(),
                submitted,
                sources: Vec::new(),
                frame: FrameGeneration::INITIAL,
                next_texture: 0,
            }
        }

        fn claim(&mut self, surface: SurfaceId) -> ClaimId {
            self.claim_at(surface, 1.0)
        }

        fn claim_at(&mut self, surface: SurfaceId, priority: f64) -> ClaimId {
            let size =
                LayerSize::quantized(PixelSize::new(512, 512)).expect("a positive size has a rung");
            let claim = self.pool.claim(
                size,
                Priority::new(priority).expect("a number is a priority"),
            );
            self.sources.push((claim, surface));
            claim
        }

        /// A client commits a buffer, which installs a new texture.
        fn commit(&mut self, surface: SurfaceId) {
            self.next_texture += 1;
            self.textures.install(
                surface,
                Counted(self.next_texture),
                TextureDescription {
                    size: PixelSize::new(512, 512),
                    alpha: Alpha::Present,
                },
            );
        }

        /// One frame: resolve, blit, submit.
        fn frame(&mut self) -> Vec<(ClaimId, Blitted)> {
            self.frame = self.frame.next();
            self.pool.resolve(self.frame);

            self.blitter.image.set(self.blitter.image.get() + 1);

            let sources = self.sources.clone();
            let report =
                self.ledger
                    .run(&mut self.pool, &mut self.blitter, &self.textures, |claim| {
                        sources
                            .iter()
                            .find(|(known, _)| *known == claim)
                            .map(|(_, surface)| *surface)
                    });

            // The pool's own tests cover the submit flag.
            self.pool.submit(SceneRendering::Drawn);
            report
        }

        /// Whether Lua reads the claim as granted.
        fn granted(&self, claim: ClaimId) -> bool {
            self.pool.state(claim).is_some_and(|state| state.granted)
        }

        fn copies(&self) -> usize {
            self.blitter.copies.borrow().len()
        }

        /// The most recent list given to the runtime.
        fn last_submitted(&self) -> Vec<u64> {
            self.submitted.borrow().last().cloned().unwrap_or_default()
        }
    }

    fn surface(raw: u64) -> SurfaceId {
        SurfaceId::new(raw).expect("non-zero")
    }

    #[test]
    fn a_source_that_has_not_changed_is_not_copied_again() {
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));

        assert_eq!(harness.frame(), vec![(claim, Blitted::Copied)]);
        assert_eq!(harness.copies(), 1);

        for _ in 0..5 {
            assert_eq!(harness.frame(), vec![(claim, Blitted::Unchanged)]);
        }
        assert_eq!(harness.copies(), 1);
    }

    #[test]
    fn a_source_that_committed_again_is_copied_again() {
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();

        harness.commit(surface(1));

        assert_eq!(harness.frame(), vec![(claim, Blitted::Copied)]);
        assert_eq!(harness.copies(), 2);
    }

    #[test]
    fn a_claim_whose_source_has_no_texture_is_left_alone() {
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));

        assert_eq!(harness.frame(), vec![(claim, Blitted::NoSource)]);
        assert_eq!(harness.copies(), 0);
    }

    #[test]
    fn a_layer_is_not_submitted_until_something_has_been_copied_into_it() {
        // `xrEndFrame` answers `XR_ERROR_LAYER_INVALID` for a layer whose
        // swapchain has never released an image.
        let mut harness = Harness::new();
        harness.claim(surface(1));

        harness.frame();
        assert_eq!(harness.last_submitted(), Vec::<u64>::new());

        harness.commit(surface(1));
        harness.frame();
        assert_eq!(
            harness.last_submitted(),
            Vec::<u64>::new(),
            "the copy makes the layer grantable at the next boundary, not this one"
        );

        harness.frame();
        assert_eq!(harness.last_submitted(), vec![1]);
    }

    #[test]
    fn a_recycled_layer_is_not_submitted_until_the_new_claim_has_been_copied_into_it() {
        // The recycled layer still holds the first claim's window, so
        // submitting it would show one window's pixels in another window's
        // panel.
        let mut harness = Harness::with_limit(LayerBudget::SHARE);
        let first = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();
        harness.frame();
        assert_eq!(
            harness.last_submitted(),
            vec![1],
            "the first claim is on it"
        );

        let second = harness.claim_at(surface(2), 2.0);

        assert_eq!(harness.frame(), vec![(second, Blitted::NoSource)]);
        assert_eq!(
            harness.last_submitted(),
            Vec::<u64>::new(),
            "the recycled layer still holds the first claim's window"
        );
        assert!(harness.pool.layer(second).is_some());
        assert!(harness.pool.layer(first).is_none());

        harness.commit(surface(2));
        assert_eq!(harness.frame(), vec![(second, Blitted::Copied)]);
        harness.frame();
        assert_eq!(harness.last_submitted(), vec![1]);
    }

    #[test]
    fn a_stale_claim_asks_the_device_for_nothing_at_all() {
        // `lovrLayerGetTexture` calls `lovrSwapchainAcquire`, which waits on
        // the runtime, so a skip that still acquired would pay most of its
        // cost.
        let mut harness = Harness::new();
        harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();

        for _ in 0..10 {
            harness.frame();
        }

        assert_eq!(harness.blitter.acquires.get(), 1);
        assert_eq!(harness.copies(), 1);
    }

    #[test]
    fn a_run_of_frames_copies_once_per_commit_and_submits_on_every_one() {
        // A copy happens exactly when the source committed, and the submitted
        // list does not depend on whether the frame copied.
        const COMMITTING: [bool; 16] = [
            true, false, false, true, true, false, false, false, true, false, true, true, false,
            false, false, false,
        ];

        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        let mut copies = 0;

        for (frame, committing) in (1..).zip(COMMITTING) {
            if committing {
                harness.commit(surface(1));
                copies += 1;
            }

            let report = harness.frame();

            assert_eq!(report, vec![(claim, expected(committing, frame))]);
            assert_eq!(harness.copies(), copies, "frame {frame}");
            assert_eq!(
                harness.blitter.acquires.get(),
                copies as u64,
                "a frame that copied nothing acquired nothing either, at frame {frame}"
            );
            // The first copy lands in frame 1 and the grant follows it, so
            // every later frame submits the layer.
            let submitted = if frame >= 2 { vec![1] } else { Vec::new() };
            assert_eq!(harness.last_submitted(), submitted, "frame {frame}");
        }
    }

    /// What the schedule above expects of one frame.
    ///
    /// Only the first frame can report something other than a copy or a skip.
    fn expected(committing: bool, frame: u32) -> Blitted {
        match (committing, frame) {
            (true, _) => Blitted::Copied,
            (false, 1) => Blitted::NoSource,
            (false, _) => Blitted::Unchanged,
        }
    }

    #[test]
    fn a_device_that_cannot_blit_leaves_the_panel_on_an_in_scene_quad() {
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.blitter.supported.set(false);

        for _ in 0..3 {
            assert_eq!(harness.frame(), vec![(claim, Blitted::Unsupported)]);
        }

        assert_eq!(harness.copies(), 0);
        assert_eq!(
            harness.last_submitted(),
            Vec::<u64>::new(),
            "a layer nothing could be copied into is never grantable"
        );
    }

    #[test]
    fn a_layer_whose_image_cannot_be_acquired_is_reported_rather_than_copied_into() {
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.blitter.acquirable.set(false);

        assert_eq!(harness.frame(), vec![(claim, Blitted::NotAcquired)]);
        assert_eq!(harness.copies(), 0);
    }

    #[test]
    fn each_frame_copies_into_the_image_that_frame_acquired() {
        // The swapchain rotates, so an image cached from an earlier frame
        // names one the runtime has already composited from and returned.
        let mut harness = Harness::new();
        harness.claim(surface(1));

        harness.commit(surface(1));
        harness.frame();
        harness.commit(surface(1));
        harness.frame();

        let copies = harness.blitter.copies.borrow().clone();
        assert_eq!(copies.len(), 2);
        assert_ne!(
            copies[0].1, copies[1].1,
            "the second copy went into the image the first frame acquired"
        );
        assert_eq!(harness.blitter.acquires.get(), 2);
    }

    #[test]
    fn a_claim_that_regains_a_layer_is_copied_into_it_again() {
        // The layer it regains comes off the free list, and that layer's
        // swapchain holds whatever its previous holder put there. Its own
        // source has not changed, so a remembered copy would leave it
        // showing those pixels and never granted.
        let mut harness = Harness::with_limit(LayerBudget::SHARE);
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();
        harness.frame();
        assert!(harness.granted(claim));

        let rival = harness.claim_at(surface(2), 2.0);
        harness.frame();
        assert!(harness.pool.layer(claim).is_none(), "the rival outbid it");

        assert!(harness.pool.release_claim(rival));
        assert_eq!(harness.frame(), vec![(claim, Blitted::Copied)]);
        harness.frame();
        assert!(harness.granted(claim));
    }

    #[test]
    fn a_surface_forgotten_and_committed_again_is_copied_rather_than_skipped() {
        // The copied counter is keyed by claim, so forgetting the claim drops
        // it. A per-surface counter could read a new texture as unchanged.
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();

        harness.textures.forget(surface(1));
        harness.commit(surface(1));

        assert_eq!(harness.frame(), vec![(claim, Blitted::Copied)]);
    }

    #[test]
    fn a_dead_clients_layer_is_left_holding_what_it_last_had() {
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();

        harness.textures.mark_dead(surface(1));

        assert_eq!(harness.frame(), vec![(claim, Blitted::NoSource)]);
        assert_eq!(harness.copies(), 1);
    }

    #[test]
    fn the_decision_is_a_function_of_two_counters() {
        let first = SurfaceCommit::INITIAL.next();
        let second = first.next();

        assert_eq!(decide(None, None), Decision::Skip(Blitted::NoSource));
        assert_eq!(decide(Some(first), None), Decision::Skip(Blitted::NoSource));
        assert_eq!(decide(None, Some(first)), Decision::Copy(first));
        assert_eq!(
            decide(Some(first), Some(first)),
            Decision::Skip(Blitted::Unchanged)
        );
        assert_eq!(decide(Some(first), Some(second)), Decision::Copy(second));
    }
}
