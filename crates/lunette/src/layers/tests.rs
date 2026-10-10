//! Tests of the layer pool's decisions, run against [`FakeLayers`] with no XR
//! runtime and no device.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

use lunette_compositor::protocol::PixelSize;
use pretty_assertions::assert_eq;

use crate::{
    layers::{
        ClaimId, LayerBackend, LayerBudget, LayerPool, LayerSize, Priority, SessionId,
        SessionPresence,
    },
    log_capture::{Logs, install_collecting_subscriber},
    scene::SceneRendering,
    texture::FrameGeneration,
};

/// The calls the fake backend received, readable while the pool still owns
/// the backend.
#[derive(Debug, Default)]
struct Calls {
    created: Vec<LayerSize>,
    destroyed: Vec<u64>,
    /// One entry per submit: the layers it named and whether lunette's own
    /// projection layer is part of it.
    submitted: Vec<(Vec<u64>, SceneRendering)>,
}

/// A layer that is a number.
#[derive(Debug, PartialEq, Eq)]
struct FakeLayer(u64);

#[derive(Debug)]
struct FakeLayers {
    /// Shared with the harness, and mutable because a replacement session may
    /// report a different limit.
    limit: Rc<Cell<u32>>,
    /// Which session exists, which the harness takes away, gives back, and
    /// replaces.
    ///
    /// Separate from `limit` because the limit survives the session. An
    /// identity, not a presence flag, so a session replaced between two
    /// boundaries is distinguishable.
    session: Rc<Cell<SessionPresence>>,
    /// Whether creation is refused, standing in for a runtime that will not
    /// allocate another swapchain. Shared with the harness so production code
    /// needs no test-only accessor.
    refusing: Rc<Cell<bool>>,
    next: u64,
    calls: Rc<RefCell<Calls>>,
}

impl LayerBackend for FakeLayers {
    type Layer = FakeLayer;

    fn layer_limit(&self) -> u32 {
        self.limit.get()
    }

    fn session(&self) -> SessionPresence {
        self.session.get()
    }

    fn create(&mut self, size: LayerSize) -> Option<Self::Layer> {
        if self.refusing.get() {
            return None;
        }
        self.calls.borrow_mut().created.push(size);
        self.next += 1;
        Some(FakeLayer(self.next))
    }

    fn submit(&mut self, layers: &[&Self::Layer], scene: SceneRendering) -> bool {
        let named = layers.iter().map(|layer| layer.0).collect();
        self.calls.borrow_mut().submitted.push((named, scene));
        true
    }

    fn destroy(&mut self, layer: Self::Layer) {
        self.calls.borrow_mut().destroyed.push(layer.0);
    }
}

/// A pool and the frame counter that advances it.
struct Harness {
    pool: LayerPool<FakeLayers>,
    calls: Rc<RefCell<Calls>>,
    refusing: Rc<Cell<bool>>,
    limit: Rc<Cell<u32>>,
    session: Rc<Cell<SessionPresence>>,
    /// The generation the next session carries, so a returned session is never
    /// the one taken away.
    next_session: u32,
    frame: FrameGeneration,
}

impl Harness {
    /// The runtime's layer limit, from which the pool derives its budget.
    fn new(limit: u32) -> Self {
        // Installing the subscriber here puts it in place before any thread
        // reaches a callsite.
        install_collecting_subscriber();

        let calls = Rc::new(RefCell::new(Calls::default()));
        let refusing = Rc::new(Cell::new(false));
        let limit = Rc::new(Cell::new(limit));
        let session = Rc::new(Cell::new(SessionPresence::Present(session_id(1))));
        let backend = FakeLayers {
            limit: Rc::clone(&limit),
            session: Rc::clone(&session),
            refusing: Rc::clone(&refusing),
            next: 0,
            calls: Rc::clone(&calls),
        };

        Self {
            pool: LayerPool::new(backend),
            calls,
            refusing,
            limit,
            session,
            next_session: 2,
            frame: FrameGeneration::INITIAL,
        }
    }

    fn resolve(&mut self) {
        self.frame = self.frame.next();
        self.pool.resolve(self.frame);
    }

    /// Runs boundaries until every held layer has been reported granted, as a
    /// frame with a blit path does.
    fn settle(&mut self) {
        self.resolve();
        for _ in 0..4 {
            let held: Vec<ClaimId> = self.pool.held().map(|(claim, _)| claim).collect();
            for claim in held {
                self.pool.note_blit_issued(claim);
            }
            self.resolve();
        }
    }

    /// Whether Lua reads the claim as granted.
    fn granted(&self, claim: ClaimId) -> bool {
        self.pool.state(claim).is_some_and(|state| state.granted)
    }

    fn created(&self) -> usize {
        self.calls.borrow().created.len()
    }

    fn destroyed(&self) -> usize {
        self.calls.borrow().destroyed.len()
    }

    fn destroyed_layers(&self) -> Vec<u64> {
        self.calls.borrow().destroyed.clone()
    }

    /// How many layers claims hold.
    fn held(&self) -> usize {
        self.pool.held().count()
    }

    /// How many layers are pooled and unclaimed: every layer created and not
    /// destroyed that no claim holds.
    fn free_layers(&self) -> usize {
        self.created() - self.destroyed() - self.held()
    }

    /// The layers the most recent submit named.
    fn last_submitted(&self) -> Vec<u64> {
        self.calls
            .borrow()
            .submitted
            .last()
            .map(|(named, _)| named.clone())
            .unwrap_or_default()
    }

    /// Whether the most recent submit carried lunette's own projection layer.
    fn last_scene(&self) -> Option<SceneRendering> {
        self.calls
            .borrow()
            .submitted
            .last()
            .map(|(_, scene)| *scene)
    }

    /// The session goes away, taking every swapchain with it.
    ///
    /// The limit is left unchanged, because LÖVR reads it off the system and
    /// `lovr.headset.stop()` does not touch it.
    fn lose_session(&mut self) {
        self.session.set(SessionPresence::Absent);
        self.resolve();
    }

    /// A session comes back, never the one that went away, because LÖVR's
    /// generation counter does not repeat.
    fn regain_session(&mut self) {
        self.session
            .set(SessionPresence::Present(session_id(self.next_session)));
        self.next_session += 1;
    }

    /// `lovr.headset.stop()` and `lovr.headset.start()` inside one Lua
    /// callback, so the pool never sees a boundary with no session.
    fn replace_session(&mut self) {
        self.regain_session();
        self.resolve();
    }
}

fn size(width: u32, height: u32) -> LayerSize {
    LayerSize::quantized(PixelSize::new(width, height)).expect("a positive size has a rung")
}

fn priority(value: f64) -> Priority {
    Priority::new(value).expect("a number is a priority")
}

fn session_id(generation: u32) -> SessionId {
    SessionId::new(generation).expect("a session's generation is never zero")
}

/// A runtime limit high enough that the pool's own ceiling constrains the
/// budget.
const GENEROUS: u32 = 128;

/// A runtime limit that leaves the pool one slot.
const ONE_SLOT: u32 = LayerBudget::SHARE;

#[test]
fn a_new_layer_is_not_submitted_until_its_first_blit_has_been_issued() {
    // `xrEndFrame` rejects a layer whose swapchain has never released an image,
    // and only `lovrHeadsetSubmit` releases one.
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));

    harness.resolve();
    harness.pool.submit(SceneRendering::Drawn);

    assert_eq!(harness.created(), 1);
    assert!(harness.pool.layer(claim).is_some(), "the layer exists");
    assert!(!harness.granted(claim));
    assert_eq!(
        harness.last_submitted(),
        Vec::<u64>::new(),
        "a layer whose swapchain has never released an image is XR_ERROR_LAYER_INVALID"
    );

    assert!(harness.pool.note_blit_issued(claim));
    harness.resolve();
    harness.pool.submit(SceneRendering::Drawn);

    assert!(harness.granted(claim));
    assert_eq!(harness.last_submitted(), vec![1]);
}

#[test]
fn a_revoked_layer_is_reused_by_the_next_claim_of_the_same_size_with_no_allocation() {
    let mut harness = Harness::new(ONE_SLOT);

    let first = harness.pool.claim(size(1920, 1080), priority(1.0));
    harness.settle();
    assert_eq!(harness.created(), 1);

    let second = harness.pool.claim(size(1920, 1080), priority(2.0));
    harness.resolve();

    assert!(!harness.granted(first));
    assert!(harness.pool.layer(first).is_none());
    assert!(
        !harness.granted(second),
        "the recycled layer holds the first claim's pixels until the second claim's own copy is \
         issued"
    );
    assert_eq!(
        harness.created(),
        1,
        "the second claim allocated where it should have recycled"
    );
    assert_eq!(harness.destroyed(), 0);

    assert!(harness.pool.note_blit_issued(second));
    harness.resolve();

    assert!(harness.granted(second));
    assert_eq!(harness.created(), 1, "the grant allocated nothing either");
}

#[test]
fn a_claim_of_a_different_size_allocates_rather_than_taking_the_free_layer() {
    let mut harness = Harness::new(ONE_SLOT);

    let first = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();

    let second = harness.pool.claim(size(2048, 2048), priority(2.0));
    harness.resolve();

    assert!(harness.pool.layer(first).is_none());
    assert_eq!(harness.created(), 2);
    assert_eq!(
        harness.free_layers(),
        1,
        "the first claim's layer is kept for a later claim of its own size"
    );
    assert!(harness.pool.layer(second).is_some());
}

#[test]
fn at_most_one_layer_is_created_a_frame() {
    // `lovrLayerCreate` waits for a swapchain image with an infinite timeout,
    // so the pool limits each frame to one potentially blocking creation.
    let mut harness = Harness::new(GENEROUS);
    for side in [512, 1024, 2048] {
        harness.pool.claim(size(side, side), priority(1.0));
    }

    for expected in 1..=3 {
        harness.resolve();
        assert_eq!(harness.created(), expected);
    }
}

#[test]
fn the_pool_never_holds_more_than_the_budget_however_many_claims_there_are() {
    let mut harness = Harness::new(4096);

    for index in 0..40 {
        harness
            .pool
            .claim(size(512, 512), priority(f64::from(index)));
    }
    for _ in 0..80 {
        harness.resolve();
    }

    assert_eq!(
        harness.held(),
        usize::try_from(LayerBudget::CEILING).expect("the ceiling is small")
    );
}

#[test]
fn claims_are_served_highest_priority_first() {
    let mut harness = Harness::new(ONE_SLOT);

    let low = harness.pool.claim(size(512, 512), priority(1.0));
    let high = harness.pool.claim(size(512, 512), priority(9.0));
    harness.resolve();

    assert!(harness.pool.layer(high).is_some());
    assert!(harness.pool.layer(low).is_none());
}

#[test]
fn equal_priorities_do_not_reorder_between_frames() {
    // An unstable sort here would revoke and re-grant every frame, flickering
    // panels between sharp and soft.
    let mut harness = Harness::new(ONE_SLOT);

    let first = harness.pool.claim(size(512, 512), priority(1.0));
    let second = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();

    for _ in 0..10 {
        harness.resolve();
        assert!(harness.granted(first), "a grant churned");
        assert!(harness.pool.layer(second).is_none(), "a grant churned");
    }
}

#[test]
fn a_priority_that_is_not_a_number_is_refused() {
    assert_eq!(Priority::new(f64::NAN), None);
    assert!(Priority::new(f64::NEG_INFINITY).is_some());
}

#[test]
fn a_free_layer_is_destroyed_only_once_it_has_been_idle_long_enough() {
    let mut harness = Harness::new(ONE_SLOT);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();
    assert!(harness.pool.release_claim(claim));
    assert_eq!(harness.free_layers(), 1);

    for _ in 1..LayerPool::<FakeLayers>::IDLE_FRAMES_BEFORE_DESTROY {
        harness.resolve();
        assert_eq!(harness.destroyed(), 0, "swept before the threshold");
    }

    harness.resolve();

    assert_eq!(harness.destroyed(), 1);
    assert_eq!(harness.free_layers(), 0);
}

#[test]
fn withdrawing_a_claim_frees_its_layer() {
    let mut harness = Harness::new(ONE_SLOT);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();

    assert!(harness.pool.release_claim(claim));
    harness.resolve();

    assert_eq!(harness.free_layers(), 1);
    assert_eq!(harness.pool.state(claim), None);
    assert!(!harness.pool.release_claim(claim), "the claim is gone");
}

#[test]
fn nothing_is_granted_before_the_runtime_reports_a_limit() {
    // The state before a session exists and after one is lost.
    let mut harness = Harness::new(0);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();

    assert!(harness.pool.layer(claim).is_none());
    assert_eq!(harness.created(), 0);
}

#[test]
fn the_budget_stays_below_the_runtime_limit_it_is_derived_from() {
    // Monado does not implement `XR_ERROR_LAYER_LIMIT_EXCEEDED` and writes past
    // a fixed array shared, under `XR_EXTX_overlay`, with an application whose
    // layer count lunette cannot see.
    for limit in [0, 1, 4, 16, 32, 64, 128, 1024] {
        let budget = LayerBudget::from_runtime_limit(limit);

        assert!(
            budget.slots() <= limit / LayerBudget::SHARE,
            "a budget of {} claims more than its share of {limit}",
            budget.slots()
        );
        assert!(budget.slots() <= LayerBudget::CEILING);
    }
    assert_eq!(LayerBudget::from_runtime_limit(ONE_SLOT).slots(), 1);
}

#[test]
fn a_runtime_refusing_to_allocate_leaves_the_claim_ungranted_and_retries() {
    let mut harness = Harness::new(GENEROUS);
    harness.refusing.set(true);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));

    harness.resolve();
    assert!(harness.pool.layer(claim).is_none());

    harness.refusing.set(false);
    harness.resolve();

    assert!(harness.pool.layer(claim).is_some());
}

#[test]
fn a_runtime_refusing_to_allocate_is_reported_once_per_claim_rather_than_every_frame() {
    // A runtime that refuses refuses every frame, so a warning per attempt
    // would flood the log.
    const REFUSAL: &str = "the runtime refused a composition layer";

    let warnings = Logs::capture(|| {
        let mut harness = Harness::new(GENEROUS);
        harness.refusing.set(true);
        harness.pool.claim(size(512, 512), priority(1.0));

        for _ in 0..8 {
            harness.resolve();
        }

        assert_eq!(harness.created(), 0);
    });

    assert_eq!(warnings.mentioning(REFUSAL), 1);
}

/// Nothing outside the pool is notified of a session going away, so the pool
/// observes the loss itself at its boundary. The limit is left unchanged
/// because the system survives `lovr.headset.stop()`, so no grant is made
/// until a session returns.
#[test]
fn session_loss_gives_up_every_layer_and_revokes_every_grant() {
    let mut harness = Harness::new(GENEROUS);
    let granted = harness.pool.claim(size(512, 512), priority(2.0));
    let freed = harness.pool.claim(size(1024, 1024), priority(1.0));
    harness.settle();
    harness.pool.release_claim(freed);
    assert_eq!(harness.created(), 2);
    assert_eq!(harness.free_layers(), 1);

    harness.lose_session();

    assert!(!harness.granted(granted));
    assert!(harness.pool.layer(granted).is_none());
    assert_eq!(
        harness.destroyed(),
        2,
        "the free list is as invalid as the granted layer"
    );
    assert_eq!(harness.free_layers(), 0);

    harness.settle();

    assert_eq!(harness.limit.get(), GENEROUS, "the limit is not the signal");
    assert!(harness.pool.layer(granted).is_none());
    assert_eq!(harness.created(), 2, "nothing is created without a session");
    assert_eq!(
        harness.destroyed(),
        2,
        "a later boundary has nothing left to give up"
    );
}

/// A stop and start inside one Lua callback never looks absent from a boundary,
/// and the stop destroys every swapchain. The session identity exists for this
/// case.
#[test]
fn a_session_replaced_between_two_boundaries_is_given_up_like_a_lost_one() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();
    let stale = harness
        .pool
        .layer(claim)
        .expect("the claim holds a layer")
        .0;

    harness.replace_session();

    assert!(!harness.granted(claim));
    assert_eq!(harness.destroyed_layers(), vec![stale]);
    assert!(harness.pool.layer(claim).is_none());
}

/// A pool that compared anything but the identity would give up every layer
/// every frame.
#[test]
fn a_session_that_stays_the_same_gives_up_nothing() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();

    for _ in 0..3 {
        harness.resolve();
        assert!(harness.granted(claim));
    }

    assert_eq!(harness.destroyed(), 0);
}

/// The claim survives a lost or replaced session holding nothing, and the
/// next session serves it from a pool with nothing of the old one in it.
#[test]
fn the_first_boundary_after_recovery_grants_a_new_layer_rather_than_a_stale_one() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();
    harness.lose_session();

    // Nothing is granted while there is no session to grant against.
    harness.resolve();
    assert!(harness.pool.layer(claim).is_none());
    assert_eq!(harness.created(), 1);

    harness.regain_session();
    harness.settle();

    assert!(harness.granted(claim));
    assert_eq!(
        harness.created(),
        2,
        "the claim was served from the pool it had before the session went away"
    );

    harness.replace_session();
    harness.settle();

    assert!(harness.granted(claim));
    assert_eq!(harness.created(), 3);
    let live = harness.pool.layer(claim).expect("the claim holds a layer");
    assert!(
        !harness.destroyed_layers().contains(&live.0),
        "a handle given up with the old session was handed back out"
    );
}

/// A restart invalidates a claim without Lua releasing it.
#[test]
fn a_restart_destroys_every_layer_and_leaves_the_next_state_an_empty_pool() {
    let mut harness = Harness::new(GENEROUS);
    let held = harness.pool.claim(size(512, 512), priority(2.0));
    let freed = harness.pool.claim(size(1024, 1024), priority(1.0));
    harness.settle();
    harness.pool.release_claim(freed);
    assert!(harness.pool.state(held).is_some());

    // This is `FrameDriver::quiesce`'s order: the layers go while the XR
    // session still exists, then the claims go with the Lua state.
    harness.pool.shutdown();
    harness.pool.forget_claims();

    assert_eq!(harness.destroyed(), 2);
    assert_eq!(harness.free_layers(), 0);
    assert_eq!(
        harness.pool.state(held),
        None,
        "a claim from the discarded Lua state must not contend for the next session's budget"
    );

    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.settle();

    assert!(harness.granted(claim));
    assert_eq!(
        harness.created(),
        3,
        "the layers the previous state held were destroyed, so this one is new"
    );
}

#[test]
fn the_submit_carries_whether_lunette_drew_a_scene_of_its_own() {
    // The flag travels with the list in `lovrHeadsetSetLayers` and is not set
    // separately.
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(size(512, 512), priority(1.0));
    harness.resolve();
    harness.pool.note_blit_issued(claim);
    harness.resolve();

    harness.pool.submit(SceneRendering::Drawn);
    assert_eq!(harness.last_scene(), Some(SceneRendering::Drawn));

    harness.pool.submit(SceneRendering::Skipped);
    assert_eq!(harness.last_scene(), Some(SceneRendering::Skipped));
    assert_eq!(
        harness.last_submitted(),
        vec![1],
        "skipping the projection layer leaves the quad layers where they were"
    );
}
