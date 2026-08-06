//! `lunette.claimLayer`, the `Claim` handle, and where a grant lands.
//!
//! The registry under test is the production one over [`FakeLayers`], so the
//! ranking, the budget, and the free list are the pool's real decisions rather
//! than a rehearsal of them. What the fake stands in for is the `Layer` itself,
//! which Lua receives as a number.

use std::rc::Rc;

use lunette_compositor::protocol::PixelSize;
use mlua::{Lua, Value};
use pretty_assertions::assert_eq;

use crate::{
    layers::{ClaimId, LayerBackend, LayerBudget, LayerKey},
    lua::{
        LuaLayer, PoolRegistry,
        tests::{TestSession, error, layered_session, lua, run, window},
    },
};

/// A `Layer` that is a number, which is enough to tell one from another and
/// from `false`.
#[derive(Debug)]
pub(crate) struct FakeLayer(i64);

impl LuaLayer for FakeLayer {
    fn push(&self, _: &Lua) -> mlua::Result<Value> {
        Ok(Value::Integer(self.0))
    }
}

/// Hands out layers numbered from one, so that a second allocation is visible
/// from Lua as a different number.
#[derive(Debug)]
pub(crate) struct FakeLayers {
    /// What the runtime reports, which is not what the pool will spend:
    /// [`LayerBudget::from_runtime_limit`] takes a quarter of it.
    limit: u32,
    created: i64,
}

impl FakeLayers {
    pub(crate) const fn new(limit: u32) -> Self {
        Self { limit, created: 0 }
    }
}

impl LayerBackend for FakeLayers {
    type Layer = FakeLayer;

    fn layer_limit(&self) -> u32 {
        self.limit
    }

    fn create(&mut self, _key: LayerKey) -> Option<Self::Layer> {
        self.created += 1;
        Some(FakeLayer(self.created))
    }

    /// Nothing here reads the submitted list; what these tests are about is
    /// what Lua is told, and the pool's own tests cover the list itself.
    fn submit(&mut self, _layers: &[&Self::Layer]) -> bool {
        true
    }

    fn destroy(&mut self, _layer: Self::Layer) {}

    fn abandon(&mut self, _layer: Self::Layer) {}
}

/// The runtime limit that leaves the pool exactly one slot to spend.
///
/// [`LayerBudget::SHARE`] is the divisor, so four is the smallest limit that
/// yields a budget at all.
pub(crate) const ONE_SLOT: u32 = LayerBudget::SHARE;

/// The runtime limit that leaves the pool two slots.
pub(crate) const TWO_SLOTS: u32 = 2 * LayerBudget::SHARE;

/// Runs frame boundaries until nothing more can be granted.
///
/// A newly created layer is not grantable until its first blit has been issued,
/// because `xrEndFrame` answers `XR_ERROR_LAYER_INVALID` for a layer whose
/// swapchain has never released an image. This stands in for the blit path,
/// which is what calls `note_blit_issued` in a running session.
pub(crate) fn settle(session: &TestSession, registry: &Rc<PoolRegistry<FakeLayers>>) {
    for _ in 0..4 {
        session.resolve_layers();
        registry.with_pool(|pool| {
            let held: Vec<ClaimId> = pool.held().map(|(claim, _)| claim).collect();
            for claim in held {
                pool.note_blit_issued(claim);
            }
        });
    }
    session.resolve_layers();
}

/// A session, a Lua state, and a claim on a layer for each window named.
fn claimed(
    limit: u32,
    priorities: &[(u64, f64)],
) -> (TestSession, Rc<PoolRegistry<FakeLayers>>, Lua) {
    let windows = priorities
        .iter()
        .map(|(id, _)| window(*id, "htop", "foot", PixelSize::new(1280, 720)))
        .collect();
    let (session, _, registry) = layered_session(windows, limit);
    let lua = lua(&session);

    run::<()>(&lua, "claims = {}");
    for (id, priority) in priorities {
        run::<()>(
            &lua,
            &format!(
                "claims[{id}] = lunette.claimLayer{{
                     window = lunette.windows()[{id}],
                     width = 1280, height = 720, priority = {priority},
                 }}"
            ),
        );
    }

    (session, registry, lua)
}

#[test]
fn a_fresh_claim_holds_nothing_until_a_boundary_has_passed() {
    let (session, registry, lua) = claimed(TWO_SLOTS, &[(1, 1.0)]);

    let (granted, layer): (bool, Value) = run(&lua, "return claims[1].granted, claims[1].layer");
    assert!(
        !granted,
        "a grant landing inside the call would change a panel's realisation mid-frame"
    );
    assert_eq!(layer, Value::Boolean(false));

    settle(&session, &registry);

    assert!(
        run::<bool>(&lua, "return claims[1].granted"),
        "the claim fits the budget, so the next boundary has to serve it"
    );
}

#[test]
fn a_granted_claim_hands_lua_the_layer_itself() {
    let (session, registry, lua) = claimed(TWO_SLOTS, &[(1, 1.0)]);
    settle(&session, &registry);

    assert_eq!(
        run::<Value>(&lua, "return claims[1].layer"),
        Value::Integer(1),
        "the claim exposes the pool's own Layer, not a wrapper around it"
    );
}

#[test]
fn the_pool_serves_the_highest_priorities_it_can_afford() {
    let (session, registry, lua) = claimed(TWO_SLOTS, &[(1, 1.0), (2, 5.0), (3, 3.0)]);
    settle(&session, &registry);

    let (first, second, third): (bool, bool, bool) = run(
        &lua,
        "return claims[1].granted, claims[2].granted, claims[3].granted",
    );

    assert_eq!(
        (first, second, third),
        (false, true, true),
        "two slots go to the two highest numbers Lua supplied"
    );
}

#[test]
fn raising_a_claim_above_a_granted_one_takes_the_layer_from_it() {
    let (session, registry, lua) = claimed(ONE_SLOT, &[(1, 5.0), (2, 1.0)]);
    settle(&session, &registry);
    assert!(run::<bool>(&lua, "return claims[1].granted"));

    run::<()>(&lua, "claims[2]:setPriority(9)");
    settle(&session, &registry);

    let (first, second): (bool, bool) = run(&lua, "return claims[1].granted, claims[2].granted");
    assert_eq!(
        (first, second),
        (false, true),
        "exhaustion revokes the lowest-priority claim in favour of a higher one"
    );
}

#[test]
fn a_revoked_claim_stays_alive_and_can_be_granted_again() {
    let (session, registry, lua) = claimed(ONE_SLOT, &[(1, 5.0), (2, 1.0)]);
    settle(&session, &registry);

    run::<()>(&lua, "claims[2]:setPriority(9)");
    settle(&session, &registry);
    assert!(
        !run::<bool>(&lua, "return claims[1].dead"),
        "revocation takes the layer, not the claim; a handle that died could never upgrade back"
    );

    run::<()>(&lua, "claims[2]:setPriority(0)");
    settle(&session, &registry);

    assert!(
        run::<bool>(&lua, "return claims[1].granted"),
        "the highest-priority ungranted claim takes a layer as soon as one frees"
    );
}

#[test]
fn releasing_a_claim_kills_the_handle_and_frees_its_layer() {
    let (session, registry, lua) = claimed(ONE_SLOT, &[(1, 5.0), (2, 1.0)]);
    settle(&session, &registry);

    assert!(run::<bool>(&lua, "return claims[1]:release()"));
    settle(&session, &registry);

    let (dead, granted, layer, again): (bool, bool, Value, bool) = run(
        &lua,
        "return claims[1].dead, claims[1].granted, claims[1].layer, claims[1]:release()",
    );

    assert!(dead);
    assert!(!granted, "a dead handle reports holding nothing");
    assert_eq!(layer, Value::Boolean(false));
    assert!(!again, "every method of a dead handle answers false");
    assert!(
        run::<bool>(&lua, "return claims[2].granted"),
        "the released claim's layer is the one the survivor takes"
    );
}

#[test]
fn a_dead_claim_reports_the_last_thing_it_knew() {
    let (session, registry, lua) = claimed(TWO_SLOTS, &[(1, 5.0)]);
    settle(&session, &registry);

    run::<()>(&lua, "claims[1]:release()");

    let (id, priority, width, dead): (u64, f64, u32, bool) = run(
        &lua,
        "return claims[1].id, claims[1].priority, claims[1].width, claims[1].dead",
    );

    assert!(dead);
    assert_eq!(priority, 5.0);
    assert_eq!(width, 1280, "the size the claim was made at, not nothing");
    assert!(id > 0);
}

#[test]
fn setting_a_priority_on_a_dead_claim_answers_false_rather_than_raising() {
    let (_session, _registry, lua) = claimed(TWO_SLOTS, &[(1, 1.0)]);
    run::<()>(&lua, "claims[1]:release()");

    assert!(!run::<bool>(&lua, "return claims[1]:setPriority(3)"));
}

#[test]
fn a_claim_reports_the_layers_size_rather_than_the_size_asked_for() {
    let (session, _, registry) = layered_session(
        vec![window(1, "htop", "foot", PixelSize::new(1000, 1000))],
        TWO_SLOTS,
    );
    let lua = lua(&session);
    run::<()>(
        &lua,
        "claim = lunette.claimLayer{
             window = lunette.windows()[1], width = 1001, height = 1000, priority = 1,
         }",
    );
    settle(&session, &registry);

    let (width, height): (u32, u32) = run(&lua, "return claim.width, claim.height");
    assert!(
        width >= 1001 && height >= 1000,
        "a requested size is rounded up to the ladder, and a caller setting a viewport needs the \
         rung rather than the request"
    );
}

#[test]
fn a_claim_names_the_window_it_was_made_for() {
    let (session, _, _) = layered_session(
        vec![window(7, "htop", "foot", PixelSize::new(640, 480))],
        TWO_SLOTS,
    );
    let lua = lua(&session);
    run::<()>(
        &lua,
        "claim = lunette.claimLayer{
             window = lunette.windows()[1], width = 640, height = 480, priority = 1,
         }",
    );

    assert_eq!(run::<u64>(&lua, "return claim.window.id"), 7);
}

#[test]
fn a_claim_with_no_window_is_refused() {
    let (session, _, _) = layered_session(Vec::new(), TWO_SLOTS);
    let lua = lua(&session);

    let message = error(
        &lua,
        "lunette.claimLayer{ width = 640, height = 480, priority = 1 }",
    );
    assert!(
        message.contains("needs a window"),
        "unhelpful message: {message}"
    );
}

#[test]
fn a_claim_at_an_impossible_size_is_refused() {
    let (session, _, _) = layered_session(
        vec![window(1, "htop", "foot", PixelSize::new(640, 480))],
        TWO_SLOTS,
    );
    let lua = lua(&session);

    let message = error(
        &lua,
        "lunette.claimLayer{
             window = lunette.windows()[1], width = 640.5, height = 480, priority = 1,
         }",
    );
    assert!(
        message.contains("layer size"),
        "unhelpful message: {message}"
    );
}

#[test]
fn a_priority_that_cannot_be_ordered_is_refused() {
    let (session, _, _) = layered_session(
        vec![window(1, "htop", "foot", PixelSize::new(640, 480))],
        TWO_SLOTS,
    );
    let lua = lua(&session);

    // A NaN would make the ranking intransitive, so the same set of claims
    // could be assigned differently depending on the order it happened to be
    // in — which is the one thing a deterministic assignment must not do.
    let message = error(
        &lua,
        "lunette.claimLayer{
             window = lunette.windows()[1], width = 640, height = 480, priority = 0/0,
         }",
    );
    assert!(message.contains("ordered"), "unhelpful message: {message}");
}

#[test]
fn an_option_the_call_does_not_take_is_refused() {
    let (session, _, _) = layered_session(
        vec![window(1, "htop", "foot", PixelSize::new(640, 480))],
        TWO_SLOTS,
    );
    let lua = lua(&session);

    let message = error(
        &lua,
        "lunette.claimLayer{
             window = lunette.windows()[1], width = 640, height = 480, priority = 1,
             stereo = true,
         }",
    );
    assert!(message.contains("stereo"), "unhelpful message: {message}");
}

#[test]
fn a_regranted_claim_reuses_the_layer_rather_than_allocating() {
    let (session, registry, lua) = claimed(ONE_SLOT, &[(1, 5.0), (2, 1.0)]);
    settle(&session, &registry);

    run::<()>(&lua, "claims[2]:setPriority(9)");
    settle(&session, &registry);
    run::<()>(&lua, "claims[2]:setPriority(0)");
    settle(&session, &registry);

    assert_eq!(
        registry.with_pool(|pool| pool.free_layers()),
        0,
        "one slot means one layer, handed between the two claims"
    );
    assert_eq!(
        run::<Value>(&lua, "return claims[1].layer"),
        Value::Integer(1),
        "the claim that came back holds the layer that was created first, not a second one"
    );
}

/// The claim is on a `FakeTexture` session, so this asserts the pool's own
/// arithmetic rather than the Lua surface's.
#[test]
fn the_pool_never_holds_more_layers_than_the_budget() {
    let (session, registry, _) = claimed(ONE_SLOT, &[(1, 3.0), (2, 2.0), (3, 1.0)]);
    settle(&session, &registry);

    let (held, budget) = registry.with_pool(|pool| (pool.held_slots(), pool.budget().slots()));
    assert_eq!(budget, 1);
    assert!(
        held <= budget,
        "{held} layers held against a budget of {budget}"
    );
}
