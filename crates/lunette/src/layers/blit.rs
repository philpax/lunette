//! Linux-only: what is copied into a composition layer, and what is not.
//!
//! A granted claim holds a `Layer` whose swapchain the runtime composites from.
//! Getting a window's pixels into that swapchain is one copy, and this module is
//! the decision about whether to make it.
//!
//! # The predicate
//!
//! A surface's texture is replaced when its client commits a new buffer, and
//! nothing else changes what a copy would produce. So the question is whether
//! the texture behind a claim is the one that was last copied, which
//! [`SurfaceCommit`] answers exactly: the texture ledger stamps every install,
//! the ledger here records what it last copied, and a copy happens when the two
//! differ.
//!
//! Damage rectangles are deliberately not consulted. smithay tracks them, but
//! `DamageSnapshot::add` increments its counter only when a commit posted a
//! rectangle that was not empty — so a client attaching a new buffer and posting
//! no damage leaves the counter where it was while the pixels under it changed.
//! Counting installs has no such hole. The copy is whole-surface either way:
//! `lovrTextureCopy` takes a rectangle, but a partial copy would leave the rest
//! of the swapchain image holding an older frame, because the swapchain rotates
//! and the image acquired this frame is not the one written last frame.
//!
//! # What a stale claim costs
//!
//! Nothing. A claim whose source has not committed since its last copy — which
//! `docs/rendering.md` calls a stale claim — reaches [`Decision::Skip`] before
//! anything touches the device: no `lovrLayerGetTexture`, so no
//! `lovrSwapchainAcquire` and no `xrWaitSwapchainImage`, and no copy recorded
//! into LÖVR's stream. That is the whole of the saving, and it is why the
//! decision is taken from two counters rather than from anything the layer
//! itself has to be asked for.
//!
//! # What is not skipped
//!
//! The submit. Every grantable layer goes to the runtime every frame, copied
//! into or not: `xrEndFrame` re-composites from the image the swapchain last
//! released, which costs nothing, whereas leaving a layer out of the list makes
//! its panel disappear rather than hold still.
//! [`LayerPool::submit`](crate::layers::LayerPool::submit) is what does that, and
//! it runs whatever this module decided.

use std::{collections::HashMap, fmt};

use lunette_compositor::protocol::SurfaceId;
use tracing::{debug, warn};

use crate::{
    layers::{ClaimId, backend::LayerBackend, pool::LayerPool},
    texture::{FrameGeneration, SurfaceCommit, TextureLedger},
};

/// The seam between the blit decision and LÖVR.
///
/// The decision is arithmetic over two counters; acquiring a layer's swapchain
/// image and recording a copy into it are not, and are the whole of what is
/// behind this trait. The production implementation is
/// [`crate::layers::LovrBlits`]; the tests answer with a counter, and so run with
/// no XR runtime and no device.
pub trait LayerBlitter {
    /// A layer the pool holds.
    type Layer;
    /// A texture, either a surface's or a layer's.
    type Texture;

    /// Acquires the layer's swapchain image for this frame.
    ///
    /// `lovrLayerGetTexture` calls `lovrSwapchainAcquire`, and the release at
    /// the end of every submit sets the swapchain's index back to `~0`, so a
    /// call in a later frame genuinely re-acquires and may answer with a
    /// different image. That is why the caller wraps the result in a
    /// [`LayerTexture`], which carries the frame it was obtained in.
    ///
    /// `None` when the runtime refused. An immutable layer asked for a second
    /// image is one such case, and the reason the pool never creates one.
    fn acquire(&mut self, layer: &Self::Layer) -> Option<Self::Texture>;

    /// Whether the device can copy `source` into `destination`.
    ///
    /// Their formats ordinarily differ: a layer's swapchain image is
    /// `FORMAT_RGBA8` with sRGB, and a window arriving as `Argb8888` or
    /// `Xrgb8888` imports as `FORMAT_BGRA8` without. `lovrTextureCopy` degrades
    /// to `lovrTextureBlit` in that case, which needs `GPU_FEATURE_BLIT` on both
    /// formats.
    fn can_copy(&self, source: &Self::Texture, destination: &Self::Texture) -> bool;

    /// Records the copy, reporting whether LÖVR accepted it.
    fn copy(&mut self, source: &Self::Texture, destination: &Self::Texture) -> bool;
}

/// A layer's swapchain image, as acquired in one frame.
///
/// The same hazard `window:getTexture()` carries, and the same treatment. A
/// swapchain hands out a different image each time it is acquired, and it is
/// re-acquired on the first ask of every frame — so a handle kept from an
/// earlier frame names an image the runtime has since composited from and handed
/// back. Copying into it produces content from the wrong frame, intermittently,
/// which is among the hardest things to diagnose from a headset. The generation
/// travels with the handle and is checked at every use rather than being
/// documented and hoped for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LayerTexture<T> {
    texture: T,
    generation: FrameGeneration,
}

impl<T> LayerTexture<T> {
    #[must_use]
    pub const fn new(texture: T, generation: FrameGeneration) -> Self {
        Self {
            texture,
            generation,
        }
    }

    /// The image, if this is still the frame it was acquired in.
    ///
    /// # Errors
    ///
    /// See [`StaleLayerTexture`].
    pub fn get(&self, current: FrameGeneration) -> Result<&T, StaleLayerTexture> {
        if self.generation == current {
            Ok(&self.texture)
        } else {
            Err(StaleLayerTexture {
                obtained: self.generation,
                current,
            })
        }
    }

    #[must_use]
    pub const fn generation(&self) -> FrameGeneration {
        self.generation
    }
}

/// A layer's swapchain image, used in a frame after the one that acquired it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StaleLayerTexture {
    pub obtained: FrameGeneration,
    pub current: FrameGeneration,
}

impl fmt::Display for StaleLayerTexture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self { obtained, current } = self;
        write!(
            f,
            "layer: the swapchain image was acquired in frame {obtained} and this is frame \
             {current}; a layer's swapchain rotates its images as the runtime composites them, so \
             acquire again rather than caching one"
        )
    }
}

impl std::error::Error for StaleLayerTexture {}

/// What the blit path did about one claim.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Blitted {
    /// The source has been replaced since the last copy, and the copy was
    /// recorded.
    Copied,
    /// The source is the one that was last copied. This is the whole of the
    /// damage skipping: no acquire, no copy, and the runtime re-composites the
    /// layer from the image it last released.
    Unchanged,
    /// The claim's source has no texture — it has never committed a buffer, or
    /// its client is gone.
    NoSource,
    /// The layer's swapchain image could not be acquired.
    NotAcquired,
    /// The device cannot copy this source into a layer, so the claim never
    /// becomes grantable and the panel renders as an in-scene quad.
    Unsupported,
    /// LÖVR refused the copy it was asked to record.
    Refused,
}

impl Blitted {
    /// Whether a copy was recorded, which is what makes a newly created layer
    /// grantable.
    #[must_use]
    pub const fn copied(self) -> bool {
        matches!(self, Self::Copied)
    }

    /// Whether this is worth a line every frame it happens.
    ///
    /// True only for the outcomes a later frame can answer differently. A
    /// device that cannot blit answers the same way for the rest of the
    /// session and its claim is never granted, so it is never dropped from the
    /// pool's held list either — reporting [`Blitted::Unsupported`] here would
    /// be ninety identical lines a second for as long as the claim lives.
    /// [`BlitLedger`] reports that one once per claim instead.
    #[must_use]
    pub const fn worth_reporting_every_frame(self) -> bool {
        matches!(self, Self::NotAcquired | Self::Refused)
    }
}

/// What the blit path decided about one claim, before anything was recorded.
///
/// Separate from performing it so that the decision is a pure function of two
/// counters: recording a copy needs a device and deciding does not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Copy, and record this as the source that was copied.
    Copy(SurfaceCommit),
    /// Leave the layer as it is, for this reason.
    Skip(Blitted),
}

/// Whether a claim's layer wants the copy this frame.
///
/// `last` is what the claim last had copied into it and `source` is what its
/// surface holds now. The two absent cases are the ones that are not "the same
/// texture as last time": a claim nothing has been copied into, and a surface
/// with no texture.
#[must_use]
pub fn decide(last: Option<SurfaceCommit>, source: Option<SurfaceCommit>) -> Decision {
    let Some(current) = source else {
        return Decision::Skip(Blitted::NoSource);
    };

    if last == Some(current) {
        Decision::Skip(Blitted::Unchanged)
    } else {
        Decision::Copy(current)
    }
}

/// What each claim has had copied into its layer, and which swapchain image this
/// frame acquired for it.
///
/// The acquired images are cached because acquiring is an FFI call a frame may
/// make more than once. The cache is also what makes [`LayerTexture`]'s
/// generation load-bearing rather than decorative: an entry outlives the frame
/// that put it there, and has to be refused rather than reused.
#[derive(Debug)]
pub struct BlitLedger<T> {
    copied: HashMap<ClaimId, SurfaceCommit>,
    acquired: HashMap<ClaimId, LayerTexture<T>>,
    /// Claims whose source the device cannot copy into a layer, so the refusal
    /// is reported once rather than on every frame for the rest of the session.
    reported: Vec<ClaimId>,
}

impl<T> Default for BlitLedger<T> {
    fn default() -> Self {
        Self {
            copied: HashMap::new(),
            acquired: HashMap::new(),
            reported: Vec::new(),
        }
    }
}

impl<T> BlitLedger<T> {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Copies into every layer the pool holds whose source has changed.
    ///
    /// Every claim holding a layer is considered, not only the grantable ones: a
    /// layer awaiting its first copy is precisely the one that needs it, since
    /// `xrEndFrame` answers `XR_ERROR_LAYER_INVALID` for a layer whose swapchain
    /// has never released an image. A copy is what makes such a layer grantable,
    /// which is why [`LayerPool::note_blit_issued`] is called from here.
    ///
    /// `source` maps a claim onto the surface whose pixels it carries. The pool
    /// does not know that — a layer of a given key serves any source wanting
    /// that key — and neither does this ledger, so it arrives as a function.
    pub fn run<B, S>(
        &mut self,
        pool: &mut LayerPool<B>,
        blitter: &mut S,
        textures: &TextureLedger<T>,
        source: impl Fn(ClaimId) -> Option<SurfaceId>,
        now: FrameGeneration,
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
                    let outcome = self.copy(pool, blitter, textures, &source, claim, now);
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
    /// Both maps are keyed by claim, and a claim that lost its layer must not
    /// keep the counter it last had copied: the layer it holds next comes off
    /// the free list, and that layer's swapchain holds whatever its previous
    /// holder put there.
    pub fn forget_absent(&mut self, held: &[ClaimId]) {
        self.copied.retain(|claim, _| held.contains(claim));
        self.acquired.retain(|claim, _| held.contains(claim));
        self.reported.retain(|claim| held.contains(claim));
    }

    /// Discards everything, because the session that owned the swapchains is
    /// gone.
    pub fn clear(&mut self) {
        self.copied.clear();
        self.acquired.clear();
        self.reported.clear();
    }

    /// What a claim last had copied into its layer.
    #[must_use]
    pub fn copied_commit(&self, claim: ClaimId) -> Option<SurfaceCommit> {
        self.copied.get(&claim).copied()
    }

    /// Records one claim's copy.
    fn copy<B, S>(
        &mut self,
        pool: &LayerPool<B>,
        blitter: &mut S,
        textures: &TextureLedger<T>,
        source: &impl Fn(ClaimId) -> Option<SurfaceId>,
        claim: ClaimId,
        now: FrameGeneration,
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

        if !self.acquire(blitter, claim, layer, now) {
            return Blitted::NotAcquired;
        }

        let outcome = match self.acquired.get(&claim).map(|image| image.get(now)) {
            Some(Ok(destination)) if !blitter.can_copy(pixels, destination) => Blitted::Unsupported,
            Some(Ok(destination)) => {
                if blitter.copy(pixels, destination) {
                    Blitted::Copied
                } else {
                    Blitted::Refused
                }
            }
            _ => Blitted::NotAcquired,
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

    /// Puts this frame's swapchain image for `claim` in the cache, reporting
    /// whether there is one.
    ///
    /// An entry from an earlier frame is discarded rather than reused: the
    /// runtime has composited from that image and handed it back, so a copy into
    /// it lands nowhere the next `xrEndFrame` looks.
    fn acquire<S>(
        &mut self,
        blitter: &mut S,
        claim: ClaimId,
        layer: &S::Layer,
        now: FrameGeneration,
    ) -> bool
    where
        S: LayerBlitter<Texture = T>,
    {
        if let Some(image) = self.acquired.get(&claim) {
            match image.get(now) {
                Ok(_) => return true,
                Err(stale) => debug!(%claim, %stale, "re-acquiring a layer's swapchain image"),
            }
        }

        let Some(texture) = blitter.acquire(layer) else {
            self.acquired.remove(&claim);
            return false;
        };
        self.acquired.insert(claim, LayerTexture::new(texture, now));
        true
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
        layers::{
            LayerBudget, LayerKey, LayerProperties, LayerSize, Priority, SessionId, SessionPresence,
        },
        scene::SceneRendering,
        texture::{CopyableTexture, TextureDescription},
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

    /// A pool backend that hands out numbered layers and records each submitted
    /// list.
    #[derive(Debug)]
    struct FakeLayers {
        next: u64,
        /// What the runtime reports, not what the pool will spend.
        limit: u32,
        /// Shared with the harness, because the pool owns the backend and an
        /// accessor through the pool would be production code only tests call.
        submitted: Rc<RefCell<Vec<Vec<u64>>>>,
    }

    impl LayerBackend for FakeLayers {
        type Layer = FakeLayer;

        fn layer_limit(&self) -> u32 {
            self.limit
        }

        /// The same session throughout. These tests are about the blit, and a
        /// pool with no session holds nothing to blit into.
        fn session(&self) -> SessionPresence {
            SessionPresence::Present(SessionId::new(1).expect("one is not zero"))
        }

        fn create(&mut self, _key: LayerKey) -> Option<Self::Layer> {
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

        fn abandon(&mut self, _layer: Self::Layer) {}
    }

    /// A blitter that counts what it was asked to do.
    #[derive(Debug)]
    struct FakeBlitter {
        acquires: Cell<u64>,
        copies: RefCell<Vec<(u64, u64)>>,
        /// Which swapchain image the next acquire hands out. The harness bumps
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

    /// A pool, a texture ledger, and a blit ledger, driven one frame at a time.
    struct Harness {
        pool: LayerPool<FakeLayers>,
        blitter: FakeBlitter,
        textures: TextureLedger<Counted>,
        ledger: BlitLedger<Counted>,
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
            let key = LayerKey::new(
                LayerSize::quantized(PixelSize::new(512, 512)).expect("a positive size has a rung"),
                LayerProperties::PANEL,
            );
            let claim = self.pool.claim(
                key,
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
            let report = self.ledger.run(
                &mut self.pool,
                &mut self.blitter,
                &self.textures,
                |claim| {
                    sources
                        .iter()
                        .find(|(known, _)| *known == claim)
                        .map(|(_, surface)| *surface)
                },
                self.frame,
            );

            // What the flag carries is the pool's business, and its own tests
            // cover it. Here every frame draws a scene.
            self.pool.submit(SceneRendering::Drawn);
            report
        }

        fn copies(&self) -> usize {
            self.blitter.copies.borrow().len()
        }

        /// The most recent list handed to the runtime.
        fn last_submitted(&self) -> Vec<u64> {
            self.submitted.borrow().last().cloned().unwrap_or_default()
        }
    }

    fn surface(raw: u64) -> SurfaceId {
        SurfaceId::new(raw).expect("non-zero")
    }

    #[test]
    fn a_source_that_has_not_changed_is_not_copied_again() {
        // lunette-v1.AC7.2.
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
        // The layer's swapchain still holds the previous claimant's window.
        // Submitting it for a claim whose own source has committed nothing puts
        // one window's pixels inside another window's panel, for as long as the
        // new source stays sourceless.
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

        // And it is submitted as soon as the new claim has pixels of its own.
        harness.commit(surface(2));
        assert_eq!(harness.frame(), vec![(second, Blitted::Copied)]);
        harness.frame();
        assert_eq!(harness.last_submitted(), vec![1]);
    }

    #[test]
    fn a_frame_that_skips_the_copy_still_submits_the_layer() {
        // Leaving an unchanged layer out of the list makes its panel disappear
        // rather than hold still.
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();
        harness.frame();

        assert_eq!(harness.frame(), vec![(claim, Blitted::Unchanged)]);
        assert_eq!(harness.last_submitted(), vec![1]);
    }

    #[test]
    fn a_stale_claim_asks_the_device_for_nothing_at_all() {
        // The saving is the acquire as much as the copy. `lovrLayerGetTexture`
        // calls `lovrSwapchainAcquire`, which waits on the image the runtime
        // hands back, so a skip that still acquired would pay most of the cost
        // it was meant to avoid.
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
        // The two halves of the rule, over an arbitrary schedule rather than a
        // pair of frames: a copy happens exactly when the source committed, and
        // the submitted list is the same whether the frame copied or not.
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
            // The first copy lands in frame 1 and the grant at the boundary
            // after it, so every frame from the second on submits the layer
            // whether or not it was copied into.
            let submitted = if frame >= 2 { vec![1] } else { Vec::new() };
            assert_eq!(harness.last_submitted(), submitted, "frame {frame}");
        }
    }

    /// What the schedule above expects of one frame.
    ///
    /// The first frame is the only one that can report anything but a copy or a
    /// skip: nothing has committed before it.
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
    fn a_device_that_cannot_blit_is_reported_once_rather_than_on_every_frame() {
        // The claim is never granted, so it is never dropped from the pool's
        // held list, so this outcome recurs for as long as the claim lives. The
        // ledger's own report is the once-per-claim one.
        assert!(!Blitted::Unsupported.worth_reporting_every_frame());
        assert!(!Blitted::NoSource.worth_reporting_every_frame());
        assert!(Blitted::NotAcquired.worth_reporting_every_frame());
        assert!(Blitted::Refused.worth_reporting_every_frame());
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
        // The swapchain rotates, so an image cached from an earlier frame names
        // one the runtime has already composited from and handed back.
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
    fn a_layer_texture_from_an_earlier_frame_is_refused() {
        let obtained = FrameGeneration::INITIAL.next();
        let texture = LayerTexture::new(Counted(7), obtained);

        assert_eq!(texture.get(obtained), Ok(&Counted(7)));
        assert_eq!(
            texture.get(obtained.next()),
            Err(StaleLayerTexture {
                obtained,
                current: obtained.next(),
            })
        );
    }

    #[test]
    fn a_claim_that_lost_its_layer_forgets_what_was_copied_into_it() {
        // The layer it holds next comes off the free list, and that layer's
        // swapchain holds whatever its previous holder put there.
        let mut harness = Harness::new();
        let claim = harness.claim(surface(1));
        harness.commit(surface(1));
        harness.frame();
        assert!(harness.ledger.copied_commit(claim).is_some());

        harness.ledger.forget_absent(&[]);

        assert_eq!(harness.ledger.copied_commit(claim), None);
    }

    #[test]
    fn a_surface_forgotten_and_committed_again_is_copied_rather_than_skipped() {
        // A per-surface counter would restart here, and the repeat would read as
        // "nothing has changed" while the texture underneath is a new one.
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

    #[test]
    fn a_counter_that_jumped_far_ahead_is_copied_like_any_other_change() {
        // smithay's damage bag keeps four commits of history and reports full
        // damage past that. Counting installs has no history to age out, and
        // every copy is whole-surface, so a jump of any size is one copy.
        let mut far = SurfaceCommit::INITIAL;
        for _ in 0..64 {
            far = far.next();
        }

        assert_eq!(
            decide(Some(SurfaceCommit::INITIAL.next()), Some(far)),
            Decision::Copy(far)
        );
    }
}
