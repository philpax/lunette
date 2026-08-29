//! The pool: which claim holds a `Layer`, and what happens to the ones nobody
//! holds.

use std::{cmp::Ordering, fmt, mem, num::NonZeroU64};

use tracing::{info, warn};

use crate::{
    layers::{
        backend::{LayerBackend, SessionPresence},
        key::LayerKey,
    },
    scene::SceneRendering,
    texture::FrameGeneration,
};

/// One claim on a layer. The pool creates it, and Lua names it afterwards.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ClaimId(NonZeroU64);

impl ClaimId {
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0.get()
    }
}

impl fmt::Display for ClaimId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "claim {}", self.0)
    }
}

/// Where this claim ranks for service, relative to the others.
///
/// The value comes from Lua and the pool never computes it. Focus, gaze,
/// distance, a rule ranking video above a terminal, and hysteresis to stop
/// grants oscillating are all cases of Lua computing a different value.
#[derive(Clone, Copy, Debug)]
pub struct Priority(f64);

impl Priority {
    /// Rejects a priority that is not a number.
    ///
    /// A NaN would make the ranking's ordering intransitive, and the sort
    /// that consumes it would then produce a different result for the same
    /// set depending on the order of the input. A deterministic assignment
    /// must not do that.
    #[must_use]
    pub fn new(priority: f64) -> Option<Self> {
        (!priority.is_nan()).then_some(Self(priority))
    }

    #[must_use]
    pub const fn get(self) -> f64 {
        self.0
    }
}

impl PartialEq for Priority {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other).is_eq()
    }
}

impl Eq for Priority {}

impl PartialOrd for Priority {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Priority {
    /// Total, because [`Priority::new`] has already refused the one value
    /// `f64`'s own ordering is partial over. This implementation uses
    /// `total_cmp` and not the derived comparison, because the derived
    /// comparison would make `-0.0` and `0.0` equal under `PartialEq` while
    /// `total_cmp` orders them differently. That mismatch breaks `Ord`'s
    /// contract.
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.total_cmp(&other.0)
    }
}

/// How many of the runtime's layer slots lunette will spend.
///
/// The budget is far below what the runtime reports. Monado does not implement
/// `XR_ERROR_LAYER_LIMIT_EXCEEDED`; the specification requires it, and the
/// session and compositor sources contain no check for it. A count past the
/// limit is an out-of-bounds write into a fixed array, not an error. Under
/// `XR_EXTX_overlay` that array is shared: every client session's layers
/// concatenate into one accumulator with no aggregate cap, so lunette can
/// overflow it while individually under its own limit, because it cannot
/// observe what the primary application submits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct LayerBudget {
    slots: u32,
}

impl LayerBudget {
    /// The most slots lunette requests, however generous the runtime is.
    ///
    /// Twelve is the number of layers submitted for sixty frames without
    /// trouble, against a reported limit of 128. The 128 is `XRT_MAX_LAYERS`
    /// in Monado with a real compositor, not a property of the hardware. The
    /// same Monado headless with the null compositor reports a limit of zero
    /// and serves no quad layer. `docs/2026-08-06-milestone-0-findings.md`
    /// records both limits.
    pub const CEILING: u32 = 12;

    /// The fraction of the runtime's limit lunette takes.
    ///
    /// Taking a quarter leaves the primary application three quarters, more
    /// than any ordinary application uses. The quarter is the whole margin
    /// against an overflow nothing else checks for.
    pub const SHARE: u32 = 4;

    #[must_use]
    pub const fn from_runtime_limit(limit: u32) -> Self {
        let share = limit / Self::SHARE;
        Self {
            slots: if share < Self::CEILING {
                share
            } else {
                Self::CEILING
            },
        }
    }

    #[must_use]
    pub const fn slots(self) -> u32 {
        self.slots
    }
}

/// What a frame boundary changed, for the caller to report to Lua.
///
/// The pool produces this; the Lua surface fires `lovr.lunlayergranted` and
/// `lovr.lunlayerrevoked`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PoolOutcome {
    /// Claims whose layer becomes granted at this boundary.
    pub granted: Vec<ClaimId>,
    /// Claims that lose a granted layer at this boundary.
    pub revoked: Vec<ClaimId>,
}

impl PoolOutcome {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.granted.is_empty() && self.revoked.is_empty()
    }
}

/// The pool's record of one claim.
///
/// Read the fields together, not one by one, because a handle refreshing
/// itself needs a consistent answer: a claim revoked between two reads would
/// report granted with the size of a layer it no longer holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClaimState {
    pub key: LayerKey,
    pub priority: Priority,
    /// Whether the claim holds a layer that has been reported granted. False
    /// while a newly created layer awaits its first blit: no grant has been
    /// reported to Lua for that layer, and it is not submittable yet.
    pub granted: bool,
}

/// A pool of `Layer` objects, and the claims requesting them.
///
/// # What is recycled
///
/// Whole `Layer` objects, not their swapchains. `struct Layer` embeds its
/// `Swapchain` by value, `lovrLayerDestroy` calls `xrDestroySwapchain` inline,
/// every swapchain function is `static`, and nothing exposes
/// `quad.subImage.swapchain`, so a swapchain cannot be moved from one layer to
/// another. No move is needed: everything a panel varies (pose, metre
/// dimensions, curve, colour, viewport, origin) has a setter and is not part
/// of `LayerInfo`, so a layer of a given [`LayerKey`] serves any panel with
/// that key, and a layer kept in the pool keeps its swapchain.
#[derive(Debug)]
pub struct LayerPool<B: LayerBackend> {
    backend: B,
    budget: LayerBudget,
    free: Vec<FreeLayer<B::Layer>>,
    claims: Vec<Claim<B::Layer>>,
    next_claim: u64,
    /// The frame the most recent [`LayerPool::resolve`] ran for. A layer
    /// freed between boundaries is counted idle from that frame.
    resolved: FrameGeneration,
    /// The session found by the previous [`LayerPool::resolve`], if any.
    ///
    /// Losing the session is a transition, not a state: the layers are given
    /// up once, at the boundary that observes the loss, and the boundaries
    /// that follow it have nothing left to give up. The field holds an
    /// identity, not a flag, so a session replaced between two boundaries is
    /// also such a transition.
    session: SessionPresence,
}

impl<B: LayerBackend> LayerPool<B> {
    /// The most layers created in one frame boundary.
    ///
    /// One, because `lovrLayerCreate` is synchronous and ends in
    /// `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop
    /// that cannot exit. A claim that cannot be served this frame is not
    /// granted this frame, and the panel renders as an in-scene quad until it
    /// is. Exhaustion causes the same degradation, so the limit needs no
    /// separate mechanism.
    pub const CREATIONS_PER_FRAME: usize = 1;

    /// How long a free layer is kept before being destroyed, in frames.
    ///
    /// Counting frames, not wall-clock, keeps the policy deterministic and
    /// testable. Ten seconds at ninety hertz. A panel demoted and promoted as
    /// the user looks around reuses a layer within that window and allocates
    /// nothing; a layer idle for longer is destroyed along with its swapchain
    /// images.
    pub const IDLE_FRAMES_BEFORE_DESTROY: u64 = 900;

    #[must_use]
    pub fn new(backend: B) -> Self {
        Self {
            // The budget is re-read at every resolve; the value set here is
            // provisional. There is usually no session at construction, so
            // the limit is zero then, and the next resolve corrects it with
            // no other step. The same re-read restores the budget after a
            // session is lost and the pool is rebuilt.
            budget: LayerBudget::from_runtime_limit(backend.layer_limit()),
            session: backend.session(),
            backend,
            free: Vec::new(),
            claims: Vec::new(),
            next_claim: 1,
            resolved: FrameGeneration::INITIAL,
        }
    }

    /// Registers a claim, to be ranked at the next frame boundary.
    ///
    /// Never grants here. A grant landing mid-frame would change a panel's
    /// realisation between its `lovr.update` and its `lovr.draw`. That is the
    /// class of inconsistency the snapshot model prevents.
    pub fn claim(&mut self, key: LayerKey, priority: Priority) -> ClaimId {
        let id = ClaimId(NonZeroU64::new(self.next_claim).unwrap_or(NonZeroU64::MIN));
        self.next_claim = self.next_claim.saturating_add(1);

        self.claims.push(Claim {
            id,
            key,
            priority,
            held: None,
            refusal_reported: false,
        });

        id
    }

    /// Changes a claim's ranking, taking effect at the next frame boundary.
    ///
    /// Reports whether the claim is still registered.
    pub fn set_priority(&mut self, claim: ClaimId, priority: Priority) -> bool {
        let Some(entry) = self.claims.iter_mut().find(|entry| entry.id == claim) else {
            return false;
        };
        entry.priority = priority;
        true
    }

    /// Withdraws a claim, returning any layer it held to the free list.
    ///
    /// Reports whether the claim is registered. No revocation is recorded:
    /// the caller asked for this withdrawal, and reporting the revocation of
    /// a layer the caller has dropped would be redundant.
    pub fn release_claim(&mut self, claim: ClaimId) -> bool {
        let Some(index) = self.claims.iter().position(|entry| entry.id == claim) else {
            return false;
        };

        let entry = self.claims.remove(index);
        if let Some(held) = entry.held {
            self.release_layer(entry.key, held);
        }
        true
    }

    /// Records the first blit issued for a claim's layer.
    ///
    /// Until then the layer's swapchain has no released image, and
    /// `xrEndFrame` answers `XR_ERROR_LAYER_INVALID` for a layer that
    /// references one. `lovrLayerCreate` acquires an image at the end for
    /// this reason, but acquiring is not releasing: release happens inside
    /// `lovrHeadsetSubmit` and in no other call.
    ///
    /// Reports whether the claim holds a layer.
    pub fn note_blit_issued(&mut self, claim: ClaimId) -> bool {
        let Some(held) = self
            .claims
            .iter_mut()
            .find(|entry| entry.id == claim)
            .and_then(|entry| entry.held.as_mut())
        else {
            return false;
        };

        if held.state == HeldState::AwaitingFirstBlit {
            held.state = HeldState::FirstBlitIssued;
        }
        true
    }

    /// Assigns layers to the highest-priority claims that fit the budget.
    ///
    /// Runs once, at a frame boundary. The order is revoke, then serve, then
    /// promote, then sweep: revoking first lets a layer freed by one claim be
    /// reused by another in the same boundary with no allocation.
    ///
    /// This is also where a session the pool's layers no longer belong to is
    /// detected, because this is the call the pool makes at every boundary,
    /// and a layer must be given up before any backend call uses it. See
    /// [`LayerPool::session_lost`].
    pub fn resolve(&mut self, now: FrameGeneration) -> PoolOutcome {
        self.resolved = now;

        let session = self.backend.session();
        match (mem::replace(&mut self.session, session), session) {
            (SessionPresence::Present(_), SessionPresence::Absent) => {
                info!("the xr session is gone; every layer the pool held is given up");
                return self.session_lost();
            }
            (SessionPresence::Present(before), SessionPresence::Present(after))
                if before != after =>
            {
                // A stop and a start inside one Lua callback. Both adjacent
                // boundaries report a session, and the identity differs from
                // the one the pool's layers belong to. The layers are
                // discarded for the same reason a loss discards them, and the
                // new session is served from the boundary after this one. A
                // session appearing after an absence is served from the
                // boundary that reports it.
                info!(%before, %after, "the xr session was replaced; every layer the pool held is given up");
                return self.session_lost();
            }
            // Nothing can be ranked, created, or submitted without a session,
            // so this returns before the budget is read. The limit comes from
            // the system, which outlives the session, and acting on it here
            // would spend a budget against swapchains that no longer exist.
            (SessionPresence::Absent, SessionPresence::Absent) => return PoolOutcome::default(),
            (
                SessionPresence::Absent | SessionPresence::Present(_),
                SessionPresence::Present(_),
            ) => {}
        }

        self.budget = LayerBudget::from_runtime_limit(self.backend.layer_limit());

        let mut outcome = PoolOutcome::default();
        let winners = self.rank();

        for index in 0..self.claims.len() {
            if winners.contains(&index) {
                continue;
            }
            let Some(held) = self.claims[index].held.take() else {
                continue;
            };
            if held.state == HeldState::Granted {
                outcome.revoked.push(self.claims[index].id);
            }
            let key = self.claims[index].key;
            self.release_layer(key, held);
        }

        let mut created = 0;
        for index in winners {
            if self.claims[index].held.is_some() {
                continue;
            }

            let key = self.claims[index].key;
            if let Some(free) = self.take_free(key) {
                self.claims[index].held = Some(free);
                continue;
            }

            // Checked at serve time, because the pool's arithmetic is wrong
            // for such a layer and no other check detects it.
            // `lovrSwapchainAcquire` answers "Static Layers can only be
            // updated once" on the second acquire of an immutable swapchain,
            // so the blit path would stop updating a layer the pool continues
            // to grant and recycle.
            if key.properties().immutable {
                warn!(
                    %key,
                    "the pool does not serve immutable layers, because a pooled layer is by \
                     definition reused and LÖVR refuses the second acquire of an immutable one"
                );
                continue;
            }

            if created >= Self::CREATIONS_PER_FRAME {
                continue;
            }
            created += 1;

            let Some(layer) = self.backend.create(key) else {
                // A runtime that refuses does so on every frame that retries,
                // so reporting each attempt repeats the warning every frame.
                if !self.claims[index].refusal_reported {
                    self.claims[index].refusal_reported = true;
                    warn!(
                        %key,
                        claim = %self.claims[index].id,
                        "the runtime refused a composition layer"
                    );
                }
                continue;
            };
            self.claims[index].held = Some(Held {
                layer,
                state: HeldState::AwaitingFirstBlit,
            });
        }

        for claim in &mut self.claims {
            let Some(held) = claim.held.as_mut() else {
                continue;
            };
            if held.state == HeldState::FirstBlitIssued {
                held.state = HeldState::Granted;
                outcome.granted.push(claim.id);
            }
        }

        self.sweep(now);
        outcome
    }

    /// Discards every layer the pool holds, because the session that owned
    /// their swapchains is gone.
    ///
    /// Called by [`LayerPool::resolve`] at the first frame boundary where the
    /// session is [`SessionPresence::Absent`], or a different session than
    /// the pool records. This is a teardown lunette observes and does not
    /// perform: a restart is the other case, and it runs
    /// [`LayerPool::shutdown`] while the session still exists.
    ///
    /// `lovrHeadsetStop` releases every layer and zeroes the layer count
    /// before `xrDestroySession`, so nothing the pool holds references
    /// anything afterwards, granted or free. The state is discarded, not
    /// reconciled: no layer and no key survives a session.
    ///
    /// The claims are retained empty and re-evaluated against the new session
    /// at the first boundary after it comes up. Every claim holding a granted
    /// layer is reported revoked here, so Lua falls back to in-scene quads by
    /// the path exhaustion already defines, and never holds a `Layer` that
    /// references a destroyed swapchain.
    fn session_lost(&mut self) -> PoolOutcome {
        let mut outcome = PoolOutcome::default();

        for index in 0..self.claims.len() {
            self.claims[index].refusal_reported = false;
            let Some(held) = self.claims[index].held.take() else {
                continue;
            };
            if held.state == HeldState::Granted {
                outcome.revoked.push(self.claims[index].id);
            }
            self.backend.abandon(held.layer);
        }

        for entry in std::mem::take(&mut self.free) {
            self.backend.abandon(entry.layer);
        }

        // Without this, the budget stays the old session's until the next
        // resolve re-reads it. A caller in between would read a budget that
        // still counts the layers the pool discarded.
        self.budget = LayerBudget::from_runtime_limit(0);

        outcome
    }

    /// Destroys every layer the pool holds, while the session still exists.
    ///
    /// The counterpart to [`LayerPool::session_lost`], for a teardown lunette
    /// performs and does not observe.
    pub fn shutdown(&mut self) {
        for claim in &mut self.claims {
            if let Some(held) = claim.held.take() {
                self.backend.destroy(held.layer);
            }
        }
        for entry in std::mem::take(&mut self.free) {
            self.backend.destroy(entry.layer);
        }
    }

    /// Discards every claim, because the Lua state that made them is gone.
    ///
    /// A restart's counterpart to [`LayerPool::shutdown`], and run immediately
    /// after it. `shutdown` gives up the layers while the XR session that owns
    /// their swapchains still exists; this gives up the claims, which are
    /// identifiers held by handles in a Lua state that is about to be closed.
    /// Kept, they would occupy the next session's budget for panels that no
    /// longer exist, and nothing would release them, because no handle in the
    /// new state holds their identifiers.
    ///
    /// A claim still holding a layer is returned to the free list, not
    /// dropped, so a caller that reaches here without having destroyed the
    /// layers first leaks nothing. In the restart path none remain: the
    /// shutdown that precedes this destroys them all.
    pub fn forget_claims(&mut self) {
        for claim in std::mem::take(&mut self.claims) {
            if let Some(held) = claim.held {
                self.release_layer(claim.key, held);
            }
        }
    }

    /// The layer a claim holds, whether or not it has been reported granted.
    ///
    /// The blit path uses this and not [`LayerPool::submitted`], because a
    /// layer awaiting its first blit is the layer that needs blitting.
    #[must_use]
    pub fn layer(&self, claim: ClaimId) -> Option<&B::Layer> {
        self.claims
            .iter()
            .find(|entry| entry.id == claim)
            .and_then(|entry| entry.held.as_ref())
            .map(|held| &held.layer)
    }

    /// The pool's record of a claim, or `None` if it holds no record of it.
    /// A released claim and a claim from a Lua state that has been reloaded
    /// away both produce `None`.
    #[must_use]
    pub fn state(&self, claim: ClaimId) -> Option<ClaimState> {
        let entry = self.claims.iter().find(|entry| entry.id == claim)?;
        Some(ClaimState {
            key: entry.key,
            priority: entry.priority,
            granted: entry
                .held
                .as_ref()
                .is_some_and(|held| held.state == HeldState::Granted),
        })
    }

    /// The layer a claim has been reported granted. Lua may be handed this
    /// layer and no other.
    ///
    /// [`LayerPool::layer`] answers with a layer awaiting its first blit too,
    /// because that is the layer the blit path looks for. Offering that layer
    /// to Lua hands out a `Layer` whose swapchain has never released an
    /// image, before `lovr.lunlayergranted` reports that the claim holds
    /// anything.
    #[must_use]
    pub fn granted_layer(&self, claim: ClaimId) -> Option<&B::Layer> {
        let held = self
            .claims
            .iter()
            .find(|entry| entry.id == claim)?
            .held
            .as_ref()?;
        (held.state == HeldState::Granted).then_some(&held.layer)
    }

    /// Every claim holding a layer, in registration order.
    pub fn held(&self) -> impl Iterator<Item = (ClaimId, &B::Layer)> {
        self.claims
            .iter()
            .filter_map(|entry| Some((entry.id, &entry.held.as_ref()?.layer)))
    }

    /// The layers to hand `lovrHeadsetSetLayers`, in registration order.
    ///
    /// A layer awaiting its first blit is absent, because submitting one whose
    /// swapchain has never released an image is `XR_ERROR_LAYER_INVALID`.
    pub fn submitted(&self) -> impl Iterator<Item = &B::Layer> {
        self.claims.iter().filter_map(|entry| {
            let held = entry.held.as_ref()?;
            (held.state == HeldState::Granted).then_some(&held.layer)
        })
    }

    /// Hands the runtime every grantable layer, copied into this frame or not.
    ///
    /// Runs once a frame, after the blit. Skipping a copy does not mean
    /// skipping the submit: the runtime re-composites an unchanged layer from
    /// the image it last released, at no cost, while leaving the layer out of
    /// the list makes its panel disappear.
    ///
    /// `scene` is set with the list, not separately, because
    /// `lovrHeadsetSetLayers` carries `scene` and no other call does, and a
    /// second call would be a second last-call-wins list.
    ///
    /// Reports whether the runtime accepted the list.
    pub fn submit(&mut self, scene: SceneRendering) -> bool {
        let layers: Vec<&B::Layer> = self
            .claims
            .iter()
            .filter_map(|entry| {
                let held = entry.held.as_ref()?;
                (held.state == HeldState::Granted).then_some(&held.layer)
            })
            .collect();
        self.backend.submit(&layers, scene)
    }

    /// What the layers the pool holds cost against the budget, counting a
    /// stereo layer as two.
    ///
    /// A layer awaiting its first blit is counted although it is not yet
    /// submitted: its slot is reserved, and not counting it would let the
    /// pool grant past the budget for a frame.
    #[must_use]
    pub fn held_slots(&self) -> u32 {
        self.claims
            .iter()
            .filter(|entry| entry.held.is_some())
            .map(|entry| entry.key.slots())
            .sum()
    }

    #[must_use]
    pub const fn budget(&self) -> LayerBudget {
        self.budget
    }

    /// How many layers are pooled and unclaimed.
    #[must_use]
    pub fn free_layers(&self) -> usize {
        self.free.len()
    }

    /// The claims that fit the budget, highest priority first, as indices into
    /// `self.claims`.
    ///
    /// A claim that does not fit ends the walk; the walk does not skip it.
    /// Filling the remaining slot with a lower-priority claim would let a
    /// one-slot claim overtake a two-slot one indefinitely. That is a
    /// starvation bug.
    fn rank(&self) -> Vec<usize> {
        let mut order: Vec<usize> = (0..self.claims.len()).collect();
        // Stable, so equal priorities keep registration order and grants do
        // not churn between frames.
        order.sort_by(|left, right| {
            self.claims[*right]
                .priority
                .cmp(&self.claims[*left].priority)
        });

        let mut spent: u32 = 0;
        let mut winners = Vec::new();
        for index in order {
            let slots = self.claims[index].key.slots();
            if spent.saturating_add(slots) > self.budget.slots() {
                break;
            }
            spent = spent.saturating_add(slots);
            winners.push(index);
        }
        winners
    }

    /// Takes a matching layer off the free list, most recently freed first.
    ///
    /// The layer comes back as [`HeldState::AwaitingFirstBlit`]; the pool
    /// discards its prior progress. The swapchain still holds the previous
    /// claim's pixels. A claim on a window that has committed nothing, or
    /// whose client has died, has no blit to overwrite them, so granting on
    /// reuse would submit one window's content inside another window's panel.
    /// The cost is one frame of grant latency on a reuse, and no allocation.
    fn take_free(&mut self, key: LayerKey) -> Option<Held<B::Layer>> {
        let index = self.free.iter().rposition(|entry| entry.key == key)?;
        let entry = self.free.swap_remove(index);
        Some(Held {
            layer: entry.layer,
            state: HeldState::AwaitingFirstBlit,
        })
    }

    /// Returns a layer to the free list, and does not destroy it.
    ///
    /// This is the recycling, and it is the whole reason a revoke is cheap.
    /// The pool keeps its own reference to every layer here, granted or free,
    /// and that reference is load-bearing: `lovrHeadsetSetLayers` releases
    /// the list it holds before retaining the new one, so a layer with no
    /// reference besides `state.layers` is destroyed during a call that
    /// revokes and re-grants it, and destruction calls `xrDestroySwapchain`
    /// inline.
    fn release_layer(&mut self, key: LayerKey, held: Held<B::Layer>) {
        self.free.push(FreeLayer {
            key,
            layer: held.layer,
            idle_since: self.resolved,
        });
    }

    /// Destroys the free layers nothing has used for long enough.
    ///
    /// The sole call to [`LayerBackend::destroy`] in the frame loop; it runs
    /// at the end of a resolve. A layer freed here is destroyed no earlier
    /// than [`LayerPool::IDLE_FRAMES_BEFORE_DESTROY`] boundaries after the
    /// last submit that named it.
    fn sweep(&mut self, now: FrameGeneration) {
        let mut kept = Vec::with_capacity(self.free.len());
        for entry in std::mem::take(&mut self.free) {
            let idle = now.get().saturating_sub(entry.idle_since.get());
            if idle >= Self::IDLE_FRAMES_BEFORE_DESTROY {
                self.backend.destroy(entry.layer);
            } else {
                kept.push(entry);
            }
        }
        self.free = kept;
    }
}

/// A claim, and the layer it holds if it holds one.
#[derive(Debug)]
struct Claim<L> {
    id: ClaimId,
    key: LayerKey,
    priority: Priority,
    held: Option<Held<L>>,
    /// Whether this claim's refusal has been reported. A runtime that refuses
    /// is described once, not on every frame for the rest of the session.
    /// Cleared when a session goes away, so the next session's refusal is
    /// reported too.
    refusal_reported: bool,
}

/// A layer a claim holds.
#[derive(Debug)]
struct Held<L> {
    layer: L,
    state: HeldState,
}

/// A layer nobody holds.
///
/// The layer's prior progress is not carried. The swapchain holds the
/// previous claim's pixels, so the next claim to take it starts at
/// [`HeldState::AwaitingFirstBlit`] and issues its own copy before anything
/// is submitted; see [`LayerPool::take_free`].
#[derive(Debug)]
struct FreeLayer<L> {
    key: LayerKey,
    layer: L,
    idle_since: FrameGeneration,
}

/// How far along a held layer is towards being submittable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HeldState {
    /// Created and never written. Submitting it is `XR_ERROR_LAYER_INVALID`,
    /// and the claim is not reported granted.
    AwaitingFirstBlit,
    /// Written, and promoted at the next boundary. The promotion happens at
    /// the boundary, not in the blit, so every grant reported to Lua takes
    /// effect with every other mutation.
    FirstBlitIssued,
    /// Reported to Lua and included in the submitted list.
    Granted,
}
