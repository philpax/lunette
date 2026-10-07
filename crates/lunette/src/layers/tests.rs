//! What the pool decides, exercised with no XR runtime and no device.
//!
//! Everything below runs against [`FakeLayers`], which counts creations and
//! destructions and hands out an integer where LÖVR would hand out a `Layer`.
//! The pool's decisions are under test. The calls the decisions produce are
//! the seam's output.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    cell::{Cell, RefCell},
    io::{self, Write},
    rc::Rc,
    sync::{Arc, Once},
};

use lunette_compositor::protocol::PixelSize;
use parking_lot::Mutex;
use pretty_assertions::assert_eq;
use tracing_subscriber::{filter::LevelFilter, fmt::MakeWriter};

use crate::{
    layers::{
        ClaimId, LayerBackend, LayerBudget, LayerKey, LayerPool, LayerProperties, LayerSize,
        PoolOutcome, Priority, SessionId, SessionPresence,
    },
    scene::SceneRendering,
    texture::FrameGeneration,
};

/// The calls the fake backend received, readable while the pool still owns
/// the backend.
#[derive(Debug, Default)]
struct Calls {
    created: Vec<LayerKey>,
    destroyed: Vec<u64>,
    abandoned: Vec<u64>,
    /// One entry per submit, holding the layers the submit named and whether
    /// lunette's own projection layer is part of it.
    submitted: Vec<(Vec<u64>, SceneRendering)>,
}

/// A layer that is a number.
#[derive(Debug, PartialEq, Eq)]
struct FakeLayer(u64);

#[derive(Debug)]
struct FakeLayers {
    /// Shared with the harness for the same reason `refusing` is, and mutable
    /// because a runtime may report a different one to the session that
    /// replaces a lost one.
    limit: Rc<Cell<u32>>,
    /// Which session exists, which the harness takes away, gives back, and
    /// replaces.
    ///
    /// Separate from `limit` because LÖVR's two answers are separate: the
    /// limit is read off the system and survives the session, so a session
    /// going away is not a limit going to zero. The field holds an identity
    /// because a session replaced between two boundaries is a session the
    /// pool's layers no longer belong to, and a presence flag carries no
    /// such distinction.
    session: Rc<Cell<SessionPresence>>,
    /// Whether creation is refused, standing in for a runtime that will not
    /// allocate another swapchain. Shared with the harness: the pool owns the
    /// backend, and a test reaching the flag through the pool would need an
    /// accessor in production code that only tests call.
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

    fn create(&mut self, key: LayerKey) -> Option<Self::Layer> {
        if self.refusing.get() {
            return None;
        }
        self.calls.borrow_mut().created.push(key);
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

    fn abandon(&mut self, layer: Self::Layer) {
        self.calls.borrow_mut().abandoned.push(layer.0);
    }
}

/// A pool and the frame counter that advances it.
struct Harness {
    pool: LayerPool<FakeLayers>,
    calls: Rc<RefCell<Calls>>,
    refusing: Rc<Cell<bool>>,
    limit: Rc<Cell<u32>>,
    session: Rc<Cell<SessionPresence>>,
    /// The generation the next session carries, so a session the harness
    /// gives back is never the session it took away.
    next_session: u32,
    frame: FrameGeneration,
}

impl Harness {
    /// The runtime's layer limit. The pool derives its budget from it and
    /// may spend less.
    fn new(limit: u32) -> Self {
        // Every log line the pool emits comes from a harness, so installing
        // the subscriber here puts it in place before any thread can reach a
        // callsite and have its interest decided against no subscriber.
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

    fn resolve(&mut self) -> PoolOutcome {
        self.frame = self.frame.next();
        self.pool.resolve(self.frame)
    }

    /// Runs boundaries until every held layer has been reported granted. A
    /// frame with a blit path in it does this.
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

    fn abandoned(&self) -> Vec<u64> {
        self.calls.borrow().abandoned.clone()
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

    /// The session goes away, taking every swapchain with it. The pool
    /// observes the loss at the next boundary.
    ///
    /// The limit is left unchanged, because LÖVR reads it off the system and
    /// `lovr.headset.stop()` does not touch it. A harness that zeroed it as
    /// well would produce a zero budget even for a pool that never noticed
    /// the session.
    fn lose_session(&mut self) -> PoolOutcome {
        self.session.set(SessionPresence::Absent);
        self.resolve()
    }

    /// A session comes back. A rebuilt session produces this state.
    ///
    /// It is never the session that went away: `lovr.headset.start()`
    /// creates one, and LÖVR's generation counter never returns a number a
    /// previous session had.
    fn regain_session(&mut self) {
        self.session
            .set(SessionPresence::Present(session_id(self.next_session)));
        self.next_session += 1;
    }

    /// `lovr.headset.stop()` and `lovr.headset.start()` inside one Lua
    /// callback: the pool never sees the moment there was no session. It sees
    /// that the session at this boundary is not the one at the last.
    fn replace_session(&mut self) -> PoolOutcome {
        self.regain_session();
        self.resolve()
    }
}

/// Collects what the code under test logs, so a test can assert how often
/// something is reported and what is decided.
#[derive(Clone, Debug, Default)]
struct Warnings(Arc<Mutex<Vec<u8>>>);

impl Warnings {
    /// How many lines mention `needle`.
    fn mentioning(&self, needle: &str) -> usize {
        String::from_utf8_lossy(&self.0.lock())
            .lines()
            .filter(|line| line.contains(needle))
            .count()
    }

    /// Runs `body` with everything the calling thread logs collected into the
    /// returned `Warnings`.
    fn capture(body: impl FnOnce()) -> Self {
        install_collecting_subscriber();
        let warnings = Self::default();
        let _collecting = Collecting::start(warnings.clone());
        body();
        warnings
    }
}

/// Installs the one subscriber the whole test binary logs through.
///
/// The subscriber is process-wide because `tracing` caches a callsite's
/// `Interest` globally, computing it once from whatever subscriber the thread
/// that first reached the callsite happened to have. A per-thread subscriber
/// installed with `with_default` loses a race it cannot detect: a test
/// that reaches the same `warn!` without one caches `Interest::never` for
/// that callsite, and every later capture of it collects nothing. One global
/// subscriber settles the interest once, for every thread, whatever order the
/// tests run in.
fn install_collecting_subscriber() {
    static INSTALLED: Once = Once::new();

    INSTALLED.call_once(|| {
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(LevelFilter::TRACE)
            .with_writer(ThreadCollector)
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("no other subscriber is installed in the test binary");
    });
}

thread_local! {
    /// What the running thread collects into, if it is collecting.
    static COLLECTING: RefCell<Option<Warnings>> = const { RefCell::new(None) };
}

/// Directs each event to whatever the thread that emitted it collects into.
/// Concurrent tests capture their own output and nothing else's.
struct ThreadCollector;

impl<'a> MakeWriter<'a> for ThreadCollector {
    type Writer = ThreadWriter;

    fn make_writer(&'a self) -> Self::Writer {
        ThreadWriter(COLLECTING.with_borrow(Clone::clone))
    }
}

/// Writes to the collector the emitting thread has, and discards the line
/// when it has none. The discard covers every test that asserts on decisions
/// and not on logs.
struct ThreadWriter(Option<Warnings>);

impl Write for ThreadWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if let Some(warnings) = self.0.as_ref() {
            warnings.0.lock().extend_from_slice(buf);
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Collects into `warnings` until dropped, restoring the collector it
/// replaced, including when the body panics.
struct Collecting(Option<Warnings>);

impl Collecting {
    fn start(warnings: Warnings) -> Self {
        Self(COLLECTING.with_borrow_mut(|slot| slot.replace(warnings)))
    }
}

impl Drop for Collecting {
    fn drop(&mut self) {
        COLLECTING.with_borrow_mut(|slot| *slot = self.0.take());
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

fn session_id(generation: u32) -> SessionId {
    SessionId::new(generation).expect("a session's generation is never zero")
}

/// A runtime limit high enough that the pool's own ceiling constrains the
/// budget.
const GENEROUS: u32 = 128;

#[test]
fn a_new_layer_is_not_submitted_until_its_first_blit_has_been_issued() {
    // `xrEndFrame` returns `XR_ERROR_LAYER_INVALID` for a layer whose swapchain
    // has never released an image. Release happens inside `lovrHeadsetSubmit`
    // and nowhere else.
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
    // One slot, so the second claim reuses the first claim's layer.
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
        Vec::new(),
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
    let next = harness.resolve();

    assert_eq!(next.granted, vec![second]);
    assert_eq!(harness.created(), 1, "the grant allocated nothing either");
}

#[test]
fn two_sizes_the_ladder_rounds_together_share_one_layer() {
    // The ladder rounds the sizes of a drag resize to the same rung, so the
    // drag reuses the layer, with no allocation per frame.
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
    // `lovrLayerCreate` waits for a swapchain image with an infinite timeout,
    // so the pool limits each frame to one potentially blocking creation.
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
    // A one-slot claim taking the slot a two-slot claim above it could not use
    // leaves the two-slot claim ungranted for as long as the smaller one holds
    // a layer.
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
    // An unstable sort here would revoke and re-grant every frame. The user
    // would see panels flickering between sharp and soft.
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
fn raising_a_priority_moves_the_layer_at_the_next_boundary() {
    let mut harness = Harness::new(LayerBudget::SHARE);

    let held = harness.pool.claim(key(512, 512), priority(5.0));
    let wanting = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    assert!(harness.pool.set_priority(wanting, priority(9.0)));
    let outcome = harness.resolve();

    assert_eq!(outcome.revoked, vec![held]);
    assert_eq!(
        outcome.granted,
        Vec::new(),
        "the layer that moved carries the other claim's pixels until this one is copied in"
    );

    assert!(harness.pool.note_blit_issued(wanting));

    assert_eq!(harness.resolve().granted, vec![wanting]);
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
    // Lua holds no granted layer: the first claim never reached a grant, so
    // the pool has nothing to revoke.
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
    // This is the state before a session exists and the state after one is
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
    // Monado does not implement `XR_ERROR_LAYER_LIMIT_EXCEEDED` and writes
    // past the end of a fixed array instead. Under `XR_EXTX_overlay` that
    // array is shared with an application whose layer count lunette cannot
    // see.
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
fn a_runtime_refusing_to_allocate_is_reported_once_per_claim_rather_than_every_frame() {
    // A runtime that refuses refuses every frame. A warning per attempt is
    // thousands of identical lines per second, and nothing else is readable.
    const REFUSAL: &str = "the runtime refused a composition layer";

    let warnings = Warnings::capture(|| {
        let mut harness = Harness::new(GENEROUS);
        harness.refusing.set(true);
        harness.pool.claim(key(512, 512), priority(1.0));

        for _ in 0..8 {
            harness.resolve();
        }

        assert_eq!(harness.created(), 0);
    });

    assert_eq!(warnings.mentioning(REFUSAL), 1);
}

#[test]
fn a_new_session_reports_a_refusal_the_old_one_had_already_reported() {
    // The refusal belongs to the runtime the claim was refused by. A session
    // that came up since is a different answer to the same question. Silence
    // would hide a runtime that started refusing.
    const REFUSAL: &str = "the runtime refused a composition layer";

    let warnings = Warnings::capture(|| {
        let mut harness = Harness::new(GENEROUS);
        harness.refusing.set(true);
        harness.pool.claim(key(512, 512), priority(1.0));
        harness.resolve();
        harness.resolve();

        harness.lose_session();
        harness.regain_session();
        harness.resolve();
        harness.resolve();
    });

    assert_eq!(warnings.mentioning(REFUSAL), 2);
}

/// The pool observes the loss itself, at the boundary it already runs.
/// Nothing outside the pool is notified of a session going away, so a pool
/// that waited to be told would keep handing out `Layer` handles naming
/// destroyed swapchains.
///
/// The limit is left unchanged, because LÖVR reads it off the system and
/// the system survives `lovr.headset.stop()`. A pool that inferred loss from
/// a zero limit would see nothing here.
#[test]
fn a_session_that_goes_away_is_observed_at_the_next_boundary() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();
    assert!(harness.pool.layer(claim).is_some());

    harness.session.set(SessionPresence::Absent);
    let outcome = harness.resolve();

    assert_eq!(outcome.revoked, vec![claim]);
    assert_eq!(harness.abandoned().len(), 1);
    assert_eq!(harness.limit.get(), GENEROUS, "the limit is not the signal");
}

/// A session that is stopped and started again inside one Lua callback never
/// looks absent from a frame boundary, and every swapchain the pool held is
/// destroyed as part of the stop. `lovr.headset.stop()` and
/// `lovr.headset.start()` are both bound, and reconfiguring the session is
/// the most ordinary reason to call the pair. A presence flag cannot see this
/// case; the session identity exists for it.
#[test]
fn a_session_replaced_between_two_boundaries_is_given_up_like_a_lost_one() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();
    let stale = harness
        .pool
        .layer(claim)
        .expect("the claim holds a layer")
        .0;

    let outcome = harness.replace_session();

    assert_eq!(outcome.revoked, vec![claim]);
    assert_eq!(
        harness.abandoned(),
        vec![stale],
        "the pool relinquishes the retired layer through the session-loss path"
    );
    assert_eq!(harness.destroyed(), 0);
    assert!(harness.pool.layer(claim).is_none());
    assert_eq!(harness.pool.budget().slots(), 0);
}

/// The claim survives the replacement holding nothing, and is served against
/// the new session from a pool with nothing of the old one left in it.
#[test]
fn the_session_that_replaced_one_is_served_from_an_empty_pool() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();
    let stale = harness
        .pool
        .layer(claim)
        .expect("the claim holds a layer")
        .0;
    harness.replace_session();

    let outcome = harness.settle();

    assert_eq!(outcome.granted, vec![claim]);
    let live = harness.pool.layer(claim).expect("the claim holds a layer");
    assert_ne!(
        live.0, stale,
        "a layer created against the destroyed session was handed back out"
    );
    assert_eq!(harness.created(), 2);
}

/// The same session across two boundaries is not a replacement. A pool that
/// compared anything but the identity would give up every layer every frame,
/// and no panel would ever stay granted.
#[test]
fn a_session_that_stays_the_same_gives_up_nothing() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    for _ in 0..3 {
        let outcome = harness.resolve();
        assert_eq!(outcome.revoked, Vec::new());
    }

    assert!(harness.pool.layer(claim).is_some());
    assert_eq!(harness.abandoned(), Vec::<u64>::new());
}

/// The layers are given up once. A boundary that reported the same revocation
/// every frame would have Lua tearing down a panel it had already torn down.
#[test]
fn a_session_that_stays_away_is_reported_once() {
    let mut harness = Harness::new(GENEROUS);
    harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    harness.lose_session();
    let again = harness.resolve();

    assert_eq!(again.revoked, Vec::new());
    assert_eq!(again.granted, Vec::new());
    assert_eq!(
        harness.abandoned().len(),
        1,
        "the second boundary has nothing left to give up"
    );
}

#[test]
fn session_loss_gives_up_every_layer_and_revokes_every_grant() {
    let mut harness = Harness::new(GENEROUS);
    let granted = harness.pool.claim(key(512, 512), priority(2.0));
    let freed = harness.pool.claim(key(1024, 1024), priority(1.0));
    harness.settle();
    harness.pool.release_claim(freed);
    assert_eq!(harness.created(), 2);
    assert_eq!(harness.pool.free_layers(), 1);

    let outcome = harness.lose_session();

    assert_eq!(outcome.revoked, vec![granted]);
    assert_eq!(
        harness.abandoned().len(),
        2,
        "the free list is as invalid as the granted layer"
    );
    assert_eq!(harness.pool.free_layers(), 0);
    assert!(harness.pool.layer(granted).is_none());
    assert_eq!(harness.pool.budget().slots(), 0);
}

/// A restart invalidates a claim without Lua releasing it. The handles that
/// name the layers are destroyed with the state being closed, and the state
/// that replaces them carries none of their identifiers.
#[test]
fn a_restart_leaves_the_pool_with_no_claims_and_no_layers() {
    let mut harness = Harness::new(GENEROUS);
    let held = harness.pool.claim(key(512, 512), priority(2.0));
    let freed = harness.pool.claim(key(1024, 1024), priority(1.0));
    harness.settle();
    harness.pool.release_claim(freed);
    assert!(harness.pool.state(held).is_some());

    // What `FrameDriver::quiesce` does, in its order: the layers go while the
    // XR session still exists, and then the claims go with the Lua state.
    harness.pool.shutdown();
    harness.pool.forget_claims();

    assert_eq!(
        harness.destroyed(),
        2,
        "a restart destroys the layers rather than abandoning them, because the session that owns \
         their swapchains is still alive when it runs"
    );
    assert_eq!(harness.abandoned(), Vec::<u64>::new());
    assert_eq!(harness.pool.free_layers(), 0);
    assert_eq!(
        harness.pool.state(held),
        None,
        "a claim from the discarded Lua state must not contend for the next session's budget"
    );
}

/// The next session claims from scratch and gets served from an empty pool.
/// Nothing from the last session is left behind.
#[test]
fn the_session_after_a_restart_claims_from_an_empty_pool() {
    let mut harness = Harness::new(GENEROUS);
    harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();
    harness.pool.shutdown();
    harness.pool.forget_claims();

    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    let outcome = harness.settle();

    assert_eq!(outcome.granted, vec![claim]);
    assert_eq!(
        harness.created(),
        2,
        "the layer the previous session held was destroyed, so this one is new"
    );
}

/// The step order matters, and a claim forgotten while it still holds a layer
/// keeps the layer. The layer stays in the pool.
#[test]
fn forgetting_a_claim_that_still_holds_a_layer_returns_it_to_the_free_list() {
    let mut harness = Harness::new(GENEROUS);
    harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    harness.pool.forget_claims();

    assert_eq!(harness.pool.free_layers(), 1);
    assert_eq!(harness.destroyed(), 0);
}

#[test]
fn a_layer_is_never_destroyed_once_its_session_is_gone() {
    // `lovrLayerDestroy` calls `xrDestroySwapchain` inline, and after
    // `xrDestroySession` the handle it would pass is already invalid.
    let mut harness = Harness::new(GENEROUS);
    harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();

    harness.lose_session();

    assert_eq!(harness.destroyed(), 0);
}

#[test]
fn the_first_boundary_after_recovery_grants_a_new_layer_rather_than_a_stale_one() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
    harness.settle();
    let before = harness.lose_session();
    assert_eq!(before.revoked, vec![claim]);

    // Nothing is granted while there is no session to grant against.
    harness.resolve();
    assert!(harness.pool.layer(claim).is_none());
    assert_eq!(harness.created(), 1);

    harness.regain_session();
    let after = harness.settle();

    assert_eq!(after.granted, vec![claim]);
    assert_eq!(
        harness.created(),
        2,
        "the claim was served from the pool it had before the session went away"
    );
    let live = harness.pool.layer(claim).expect("the claim holds a layer");
    assert!(
        !harness.abandoned().contains(&live.0),
        "a handle given up with the old session was handed back out"
    );
}

#[test]
fn an_immutable_key_is_never_created() {
    // LÖVR raises "Static Layers can only be updated once" on the second
    // acquire of one, and a pooled layer is reused. The blit path would then
    // stop updating a layer the pool goes on granting.
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(
        LayerKey::new(
            LayerSize::quantized(PixelSize::new(512, 512)).expect("a positive size has a rung"),
            LayerProperties {
                immutable: true,
                ..LayerProperties::PANEL
            },
        ),
        priority(1.0),
    );

    harness.settle();

    assert_eq!(harness.created(), 0);
    assert!(harness.pool.layer(claim).is_none());
}

#[test]
fn the_submitted_list_holds_every_granted_layer_and_nothing_else() {
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));

    harness.resolve();
    harness.pool.submit(SceneRendering::Drawn);
    assert_eq!(
        harness.last_submitted(),
        Vec::<u64>::new(),
        "a layer whose swapchain has never released an image is XR_ERROR_LAYER_INVALID"
    );

    harness.pool.note_blit_issued(claim);
    harness.resolve();
    harness.pool.submit(SceneRendering::Drawn);

    assert_eq!(harness.last_submitted(), vec![1]);
}

#[test]
fn the_submit_carries_whether_lunette_drew_a_scene_of_its_own() {
    // `lovrHeadsetSetLayers` is the call that carries it. The flag travels
    // with the list and is not set separately.
    let mut harness = Harness::new(GENEROUS);
    let claim = harness.pool.claim(key(512, 512), priority(1.0));
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
