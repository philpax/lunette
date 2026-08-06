//! What the pool decides, exercised with no XR runtime and no device.
//!
//! Everything below runs against [`FakeLayers`], which counts creations and
//! destructions and hands out an integer where LÖVR would hand out a `Layer`.
//! The decisions are the thing under test; the calls they turn into are the
//! seam's business.

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
        ClaimId, LayerBackend, LayerBudget, LayerKey, LayerPool, LayerProperties, LayerSize,
        PoolOutcome, Priority,
    },
    texture::FrameGeneration,
};

/// What the fake backend was asked to do, readable while the pool still owns
/// the backend itself.
#[derive(Debug, Default)]
struct Calls {
    created: Vec<LayerKey>,
    destroyed: Vec<u64>,
}

/// A layer that is a number.
#[derive(Debug, PartialEq, Eq)]
struct FakeLayer(u64);

#[derive(Debug)]
struct FakeLayers {
    limit: u32,
    /// Whether creation is refused, standing in for a runtime that will not
    /// allocate another swapchain. Shared rather than owned, because the pool
    /// owns the backend and a test that could reach into it through the pool
    /// would be an accessor in production code that only tests call.
    refusing: Rc<Cell<bool>>,
    next: u64,
    calls: Rc<RefCell<Calls>>,
}

impl LayerBackend for FakeLayers {
    type Layer = FakeLayer;

    fn layer_limit(&self) -> u32 {
        self.limit
    }

    fn create(&mut self, key: LayerKey) -> Option<Self::Layer> {
        if self.refusing.get() {
            return None;
        }
        self.calls.borrow_mut().created.push(key);
        self.next += 1;
        Some(FakeLayer(self.next))
    }

    fn destroy(&mut self, layer: Self::Layer) {
        self.calls.borrow_mut().destroyed.push(layer.0);
    }
}

/// A pool and a frame counter to drive it with.
struct Harness {
    pool: LayerPool<FakeLayers>,
    calls: Rc<RefCell<Calls>>,
    refusing: Rc<Cell<bool>>,
    frame: FrameGeneration,
}

impl Harness {
    /// `limit` is what the runtime reports, not what the pool will spend.
    fn new(limit: u32) -> Self {
        let calls = Rc::new(RefCell::new(Calls::default()));
        let refusing = Rc::new(Cell::new(false));
        let backend = FakeLayers {
            limit,
            refusing: Rc::clone(&refusing),
            next: 0,
            calls: Rc::clone(&calls),
        };

        Self {
            pool: LayerPool::new(backend),
            calls,
            refusing,
            frame: FrameGeneration::INITIAL,
        }
    }

    fn resolve(&mut self) -> PoolOutcome {
        self.frame = self.frame.next();
        self.pool.resolve(self.frame)
    }

    /// Runs boundaries until every held layer has been reported granted, which
    /// is what a frame with a blit path in it does.
    fn settle(&mut self) -> PoolOutcome {
        let mut outcome = self.resolve();
        for _ in 0..4 {
            let held: Vec<ClaimId> = self.pool.held().map(|(claim, _)| claim).collect();
            for claim in held {
                self.pool.note_blit_issued(claim);
            }

            let next = self.resolve();
            outcome.granted.extend(next.granted);
            outcome.revoked.extend(next.revoked);
        }
        outcome
    }

    fn created(&self) -> usize {
        self.calls.borrow().created.len()
    }

    fn destroyed(&self) -> usize {
        self.calls.borrow().destroyed.len()
    }
}

fn key(width: u32, height: u32) -> LayerKey {
    LayerKey::new(
        LayerSize::quantized(PixelSize::new(width, height)).expect("a positive size has a rung"),
        LayerProperties::PANEL,
    )
}

fn stereo_key(width: u32, height: u32) -> LayerKey {
    LayerKey::new(
        LayerSize::quantized(PixelSize::new(width, height)).expect("a positive size has a rung"),
        LayerProperties {
            stereo: true,
            ..LayerProperties::PANEL
        },
    )
}

fn priority(value: f64) -> Priority {
    Priority::new(value).expect("a number is a priority")
}

/// A runtime limit generous enough that the ceiling is what binds.
const GENEROUS: u32 = 128;

#[test]
fn a_new_layer_is_not_submitted_until_its_first_blit_has_been_issued() {
    // `xrEndFrame` answers `XR_ERROR_LAYER_INVALID` for a layer whose swapchain
    // has never released an image, and release happens only inside
    // `lovrHeadsetSubmit`.
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));

    let first = harness.resolve();

    assert_eq!(harness.created(), 1);
    assert!(harness.pool.layer(claim).is_some(), "the layer exists");
    assert_eq!(harness.pool.submitted().count(), 0);
    assert_eq!(first.granted, Vec::new());

    assert!(harness.pool.note_blit_issued(claim));
    let second = harness.resolve();

    assert_eq!(second.granted, vec![claim]);
    assert_eq!(harness.pool.submitted().count(), 1);
}

#[test]
fn a_revoked_layer_is_reused_by_the_next_claim_of_the_same_key_with_no_allocation() {
    // lunette-v1.AC2.4. One slot, so the second claim can only be served by the
    // first claim's layer.
    let mut harness = Harness::new(LayerBudget::SHARE);
    assert_eq!(harness.pool.budget().slots(), 1);

    let first = harness.pool.claim(key(1920, 1080), priority(1.0));
    harness.settle();
    assert_eq!(harness.created(), 1);

    let second = harness.pool.claim(key(1920, 1080), priority(2.0));
    let outcome = harness.resolve();

    assert_eq!(outcome.revoked, vec![first]);
    assert_eq!(
        outcome.granted,
        vec![second],
        "a recycled layer has already been blitted, so it is grantable at once"
    );
    assert_eq!(
        harness.created(),
        1,
        "the second claim allocated where it should have recycled"
    );
    assert_eq!(harness.destroyed(), 0);
}

#[test]
fn two_sizes_the_ladder_rounds_together_share_one_layer() {
    // The ladder is what makes a drag resize hit the free list rather than
    // allocating on every frame of the drag.
    let mut harness = Harness::new(LayerBudget::SHARE);

    harness.pool.claim(key(1000, 1000), priority(1.0));
    harness.settle();

    harness.pool.claim(key(1001, 1000), priority(2.0));
    harness.resolve();

    assert_eq!(harness.created(), 1);
}

#[test]
fn a_claim_of_a_different_key_allocates_rather_than_taking_the_free_layer() {
    let mut harness = Harness::new(LayerBudget::SHARE);

    let first = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    let second = harness.pool.claim(key(2048, 2048), priority(2.0));
    let outcome = harness.resolve();

    assert_eq!(outcome.revoked, vec![first]);
    assert_eq!(harness.created(), 2);
    assert_eq!(
        harness.pool.free_layers(),
        1,
        "the first claim's layer is kept for a later claim of its own size"
    );
    assert!(harness.pool.layer(second).is_some());
}

#[test]
fn at_most_one_layer_is_created_a_frame() {
    // `lovrLayerCreate` ends in `xrWaitSwapchainImage` with
    // `XR_INFINITE_DURATION` inside a retry loop with no escape, so more than
    // one of these in a frame is more than one chance to stall it for ever.
    let mut harness = Harness::new(GENEROUS);
    for size in [512, 1024, 2048] {
        harness.pool.claim(key(size, size), priority(1.0));
    }

    for expected in 1..=3 {
        harness.resolve();
        assert_eq!(harness.created(), expected);
    }
}

#[test]
fn the_pool_never_holds_more_than_the_budget_however_many_claims_there_are() {
    let mut harness = Harness::new(4096);
    assert_eq!(harness.pool.budget().slots(), LayerBudget::CEILING);

    for index in 0..40 {
        harness
            .pool
            .claim(key(512, 512), priority(f64::from(index)));
    }
    for _ in 0..80 {
        harness.resolve();
    }

    assert_eq!(harness.pool.held_slots(), LayerBudget::CEILING);
}

#[test]
fn a_stereo_claim_spends_two_slots_of_the_budget() {
    // `lovrHeadsetSetLayers` inserts the right-eye copy as its own entry and
    // checks the doubled total, so the pool has to count the same way.
    let mut harness = Harness::new(2 * LayerBudget::SHARE);
    assert_eq!(harness.pool.budget().slots(), 2);

    harness.pool.claim(stereo_key(512, 512), priority(2.0));
    harness.pool.claim(stereo_key(512, 512), priority(1.0));
    for _ in 0..4 {
        harness.resolve();
    }

    assert_eq!(harness.pool.held_slots(), 2);
    assert_eq!(harness.created(), 1, "two stereo layers do not fit in two");
}

#[test]
fn a_claim_that_does_not_fit_stops_the_ranking_rather_than_being_stepped_over() {
    // Letting a one-slot claim take the slot a two-slot claim above it could
    // not use starves the two-slot claim for as long as the smaller one lives.
    let mut harness = Harness::new(2 * LayerBudget::SHARE);

    let mono = harness.pool.claim(key(512, 512), priority(5.0));
    let stereo = harness.pool.claim(stereo_key(512, 512), priority(4.0));
    let lower = harness.pool.claim(key(512, 512), priority(1.0));
    for _ in 0..4 {
        harness.resolve();
    }

    assert!(harness.pool.layer(mono).is_some());
    assert!(harness.pool.layer(stereo).is_none());
    assert!(
        harness.pool.layer(lower).is_none(),
        "the claim below the one that did not fit must not overtake it"
    );
}

#[test]
fn claims_are_served_highest_priority_first() {
    let mut harness = Harness::new(LayerBudget::SHARE);

    let low = harness.pool.claim(key(512, 512), priority(1.0));
    let high = harness.pool.claim(key(512, 512), priority(9.0));
    harness.resolve();

    assert!(harness.pool.layer(high).is_some());
    assert!(harness.pool.layer(low).is_none());
}

#[test]
fn equal_priorities_do_not_reorder_between_frames() {
    // An unstable sort here would revoke and re-grant every frame, which reads
    // to a user as panels flickering between sharp and soft.
    let mut harness = Harness::new(LayerBudget::SHARE);

    let first = harness.pool.claim(key(512, 512), priority(1.0));
    harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    for _ in 0..10 {
        let outcome = harness.resolve();
        assert_eq!(outcome, PoolOutcome::default(), "a grant churned");
    }
    assert!(harness.pool.layer(first).is_some());
}

#[test]
fn raising_a_priority_moves_the_grant_at_the_next_boundary() {
    let mut harness = Harness::new(LayerBudget::SHARE);

    let held = harness.pool.claim(key(512, 512), priority(5.0));
    let wanting = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    assert!(harness.pool.set_priority(wanting, priority(9.0)));
    let outcome = harness.resolve();

    assert_eq!(outcome.revoked, vec![held]);
    assert_eq!(outcome.granted, vec![wanting]);
}

#[test]
fn a_priority_that_is_not_a_number_is_refused() {
    assert_eq!(Priority::new(f64::NAN), None);
    assert!(Priority::new(f64::NEG_INFINITY).is_some());
}

#[test]
fn a_free_layer_is_destroyed_only_once_it_has_been_idle_long_enough() {
    let mut harness = Harness::new(LayerBudget::SHARE);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();
    assert!(harness.pool.release_claim(claim));
    assert_eq!(harness.pool.free_layers(), 1);

    for _ in 1..LayerPool::<FakeLayers>::IDLE_FRAMES_BEFORE_DESTROY {
        harness.resolve();
        assert_eq!(harness.destroyed(), 0, "swept before the threshold");
    }

    harness.resolve();

    assert_eq!(harness.destroyed(), 1);
    assert_eq!(harness.pool.free_layers(), 0);
}

#[test]
fn withdrawing_a_claim_frees_its_layer_and_reports_no_revocation() {
    let mut harness = Harness::new(LayerBudget::SHARE);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    assert!(harness.pool.release_claim(claim));
    let outcome = harness.resolve();

    assert_eq!(
        outcome,
        PoolOutcome::default(),
        "the caller asked for this; telling it what it already knows is noise"
    );
    assert_eq!(harness.pool.free_layers(), 1);
    assert!(!harness.pool.release_claim(claim), "the claim is gone");
}

#[test]
fn a_claim_revoked_before_it_was_ever_granted_reports_nothing() {
    // Lua was never told it held a layer, so it has nothing to be told it has
    // lost.
    let mut harness = Harness::new(LayerBudget::SHARE);
    let first = harness.pool.claim(key(512, 512), priority(1.0));
    harness.resolve();
    assert!(harness.pool.layer(first).is_some());

    harness.pool.claim(key(512, 512), priority(9.0));
    let outcome = harness.resolve();

    assert_eq!(outcome.revoked, Vec::new());
}

#[test]
fn nothing_is_granted_before_the_runtime_reports_a_limit() {
    // Which is the state before a session exists, and the state after one is
    // lost.
    let mut harness = Harness::new(0);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    assert_eq!(harness.pool.budget().slots(), 0);
    assert!(harness.pool.layer(claim).is_none());
    assert_eq!(harness.created(), 0);
}

#[test]
fn the_budget_stays_below_the_runtime_limit_it_is_derived_from() {
    // Monado does not implement `XR_ERROR_LAYER_LIMIT_EXCEEDED` and writes past
    // the end of a fixed array instead, and under `XR_EXTX_overlay` that array
    // is shared with an application whose layer count lunette cannot see.
    for limit in [0, 1, 4, 16, 32, 64, 128, 1024] {
        let budget = LayerBudget::from_runtime_limit(limit);

        assert!(
            budget.slots() <= limit / LayerBudget::SHARE,
            "a budget of {} claims more than its share of {limit}",
            budget.slots()
        );
        assert!(budget.slots() <= LayerBudget::CEILING);
    }
}

#[test]
fn a_runtime_refusing_to_allocate_leaves_the_claim_ungranted_and_retries() {
    let mut harness = Harness::new(GENEROUS);
    harness.refusing.set(true);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));

    harness.resolve();
    assert!(harness.pool.layer(claim).is_none());

    harness.refusing.set(false);
    harness.resolve();

    assert!(harness.pool.layer(claim).is_some());
}

#[test]
fn shutdown_destroys_every_layer_the_pool_holds() {
    let mut harness = Harness::new(GENEROUS);
    harness.pool.claim(key(512, 512), priority(2.0));
    let released = harness.pool.claim(key(1024, 1024), priority(1.0));
    harness.settle();
    harness.pool.release_claim(released);
    assert_eq!(harness.created(), 2);

    harness.pool.shutdown();

    assert_eq!(harness.destroyed(), 2);
    assert_eq!(harness.pool.free_layers(), 0);
    assert_eq!(harness.pool.held_slots(), 0);
}
