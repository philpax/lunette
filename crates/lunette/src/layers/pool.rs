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

/// One claim on a layer, minted by the pool and named by Lua afterwards.
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

/// How badly Lua wants this claim served, relative to the others.
///
/// The number is Lua's and the pool never invents it. Focus, gaze, distance, a
/// rule ranking video above a terminal, and hysteresis to stop grants flapping
/// are all cases of Lua computing a different one.
#[derive(Clone, Copy, Debug)]
pub struct Priority(f64);

impl Priority {
    /// Rejects a priority that is not a number.
    ///
    /// A NaN would make the ranking's ordering intransitive, and the sort it
    /// feeds would then produce a different result for the same set depending
    /// on the order it happened to be in — which is the one thing a
    /// deterministic assignment must not do.
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
    /// `f64`'s own ordering is partial over. `total_cmp` rather than the
    /// derived comparison so that `-0.0` and `0.0` do not compare equal under
    /// `PartialEq` while ordering differently, which would break `Ord`'s
    /// contract.
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.total_cmp(&other.0)
    }
}

/// How many of the runtime's layer slots lunette will spend.
///
/// Deliberately far below what the runtime reports. Monado does not implement
/// `XR_ERROR_LAYER_LIMIT_EXCEEDED` at all — the specification requires it and a
/// grep across the session and compositor sources finds no check — so a count
/// past the limit is an out-of-bounds write into a fixed array rather than an
/// error. And under `XR_EXTX_overlay` that array is shared: every client
/// session's layers are concatenated into one accumulator with no aggregate
/// cap, so lunette can overflow it while individually under its own limit,
/// because it cannot see what the primary application is submitting.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct LayerBudget {
    slots: u32,
}

impl LayerBudget {
    /// The most slots lunette asks for however generous the runtime is.
    ///
    /// Twelve is what milestone 0 submitted for sixty frames without trouble,
    /// against a reported limit of 128. That was Monado carrying a real
    /// compositor, where 128 is `XRT_MAX_LAYERS` rather than anything about the
    /// hardware. The number is not universal: the same Monado headless with the
    /// null compositor reports a limit of zero and serves no quad layer at all.
    /// `docs/milestone-0-findings.md` records both.
    pub const CEILING: u32 = 12;

    /// The fraction of the runtime's limit lunette is willing to be.
    ///
    /// A quarter leaves the primary application three, which is more than any
    /// ordinary one uses, and it is the whole of the margin against an overflow
    /// nothing else checks for.
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
/// The pool decides; firing `lovr.lunlayergranted` and `lovr.lunlayerrevoked`
/// is the Lua surface's business.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PoolOutcome {
    /// Claims that now hold a layer and did not before.
    pub granted: Vec<ClaimId>,
    /// Claims that held a layer, had been reported granted, and no longer hold
    /// one.
    pub revoked: Vec<ClaimId>,
}

impl PoolOutcome {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.granted.is_empty() && self.revoked.is_empty()
    }
}

/// What the pool knows about one claim.
///
/// Read together rather than field by field, because a handle refreshing itself
/// wants a consistent answer: a claim revoked between two reads would otherwise
/// report granted with the size of a layer it no longer holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClaimState {
    pub key: LayerKey,
    pub priority: Priority,
    /// Whether the claim holds a layer that has been reported granted. False
    /// while a newly created layer awaits its first blit: nothing has told Lua
    /// about that one, and it is not submittable yet.
    pub granted: bool,
}

/// A pool of `Layer` objects and the claims contending for them.
///
/// # What is recycled
///
/// Whole `Layer` objects, not their swapchains. `struct Layer` embeds its
/// `Swapchain` by value, `lovrLayerDestroy` calls `xrDestroySwapchain` inline,
/// every swapchain function is `static`, and nothing exposes
/// `quad.subImage.swapchain` — so a swapchain cannot be moved from one layer to
/// another. It does not need to be: everything a panel varies (pose, metre
/// dimensions, curve, colour, viewport, origin) has a setter and lives outside
/// `LayerInfo`, so a layer of a given [`LayerKey`] serves any panel wanting that
/// key, and keeping the layer alive keeps its swapchain alive.
#[derive(Debug)]
pub struct LayerPool<B: LayerBackend> {
    backend: B,
    budget: LayerBudget,
    free: Vec<FreeLayer<B::Layer>>,
    claims: Vec<Claim<B::Layer>>,
    next_claim: u64,
    /// The frame the most recent [`LayerPool::resolve`] ran for, which is what
    /// a layer freed between boundaries is counted idle from.
    resolved: FrameGeneration,
    /// Which session the previous [`LayerPool::resolve`] found, if it found
    /// one.
    ///
    /// Losing one is a transition rather than a state: the layers are given up
    /// once, at the boundary that observes the loss, and the boundaries that
    /// follow it have nothing left to give up. Held as an identity rather than
    /// a flag so that a session replaced between two boundaries is such a
    /// transition too.
    session: SessionPresence,
}

impl<B: LayerBackend> LayerPool<B> {
    /// The most layers created in one frame boundary.
    ///
    /// One, because `lovrLayerCreate` is synchronous and ends in
    /// `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop
    /// that has no escape. A claim that cannot be served this frame is not
    /// granted this frame, and the panel renders as an in-scene quad until it
    /// is — which is the degradation path exhaustion already takes, so this
    /// needs no separate mechanism.
    pub const CREATIONS_PER_FRAME: usize = 1;

    /// How long a free layer is kept before being destroyed, in frames.
    ///
    /// Frames rather than wall-clock so the policy is deterministic and
    /// testable. Ten seconds at ninety hertz: long enough that a panel demoted
    /// and promoted as the user looks around never pays for an allocation, and
    /// short enough that a layer nothing has wanted for that long is not worth
    /// its swapchain images.
    pub const IDLE_FRAMES_BEFORE_DESTROY: u64 = 900;

    #[must_use]
    pub fn new(backend: B) -> Self {
        Self {
            // Re-read at every resolve rather than only here. There is usually
            // no session at construction, so the limit is zero, and it becomes
            // real without anything having to notice — which is also how the
            // pool comes back after a session is lost and rebuilt.
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
    /// Never granted here. A grant landing mid-frame would change a panel's
    /// realisation between its `lovr.update` and its `lovr.draw`, which is the
    /// class of inconsistency the snapshot model exists to prevent.
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
    /// Reports whether the claim is still known.
    pub fn set_priority(&mut self, claim: ClaimId, priority: Priority) -> bool {
        let Some(entry) = self.claims.iter_mut().find(|entry| entry.id == claim) else {
            return false;
        };
        entry.priority = priority;
        true
    }

    /// Withdraws a claim, returning any layer it held to the free list.
    ///
    /// Reports whether the claim was known. No revocation is recorded: the
    /// caller asked for this, and telling Lua that what it just dropped has
    /// been taken away would be noise.
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

    /// Records that a claim's layer has had its first blit issued.
    ///
    /// Until this happens the layer's swapchain has no released image, and
    /// `xrEndFrame` answers `XR_ERROR_LAYER_INVALID` for a layer that
    /// references one. `lovrLayerCreate` acquires an image at the end for
    /// exactly this reason, but acquiring is not releasing, and release happens
    /// only inside `lovrHeadsetSubmit`.
    ///
    /// Reports whether the claim holds a layer at all.
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
    /// promote, then sweep: revoking first is what lets a layer freed by one
    /// claim be reused by another in the same boundary with no allocation.
    ///
    /// This is also where a session the pool's layers no longer belong to is
    /// observed, because it is the one call the pool makes at every boundary
    /// and the layers must be given up before anything asks the backend to do
    /// something with one. See [`LayerPool::session_lost`].
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
                // A stop and a start inside one Lua callback. Both boundaries
                // around it see a session, and only the identity says it is not
                // the one the pool's layers belong to. Given up here for the
                // same reason a loss gives them up, and the new session is
                // served from the boundary after this one — which is what an
                // absence the pool comes back from already does.
                info!(%before, %after, "the xr session was replaced; every layer the pool held is given up");
                return self.session_lost();
            }
            // Nothing can be ranked, created, or submitted without a session,
            // so this returns before the budget is read: the limit is answered
            // off the system, which outlives the session, and acting on it here
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

            // Checked here rather than assumed, because the whole of the
            // pool's arithmetic is wrong for such a layer and nothing else
            // would notice. `lovrSwapchainAcquire` answers "Static Layers can
            // only be updated once" on the second acquire of an immutable
            // swapchain, so the blit path would silently stop updating a layer
            // the pool went on granting and recycling.
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
                // A runtime that refuses refuses on every frame that retries,
                // so reporting each attempt buries every other line.
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
    /// Called by [`LayerPool::resolve`], at the first frame boundary that finds
    /// the session [`SessionPresence::Absent`] or finds a different one in its
    /// place. This is a teardown lunette observes rather than one it performs:
    /// a restart is the other case, and it runs [`LayerPool::shutdown`] while
    /// the session still exists.
    ///
    /// `lovrHeadsetStop` releases every layer and zeroes the layer count before
    /// `xrDestroySession`, so nothing the pool holds names anything afterwards,
    /// granted or free. The state is discarded rather than reconciled: no
    /// layer, and no key, survives a session.
    ///
    /// The claims themselves survive holding nothing, and are re-evaluated
    /// against the new session at the first boundary after it comes up. Every
    /// claim that had been reported granted is reported revoked here, so Lua
    /// falls back to in-scene quads by the path exhaustion already defines and
    /// never holds a `Layer` that names a destroyed swapchain.
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

        // Not cosmetic: the budget is otherwise the old session's until the
        // next resolve re-reads it, and anything asking in between would be
        // told the pool can hold layers it has just given up.
        self.budget = LayerBudget::from_runtime_limit(0);

        outcome
    }

    /// Destroys every layer the pool holds, while the session still exists.
    ///
    /// The orderly counterpart to [`LayerPool::session_lost`], for a teardown
    /// lunette is performing rather than observing.
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
    /// Kept, they would contend for the next session's budget on behalf of
    /// panels that no longer exist, and never be released — nothing in the new
    /// state knows their identifiers.
    ///
    /// A claim still holding a layer is returned to the free list rather than
    /// dropped, so a caller that reaches here without having destroyed the
    /// layers first leaks nothing. In the restart path there are none: the
    /// shutdown that precedes this took them all.
    pub fn forget_claims(&mut self) {
        for claim in std::mem::take(&mut self.claims) {
            if let Some(held) = claim.held {
                self.release_layer(claim.key, held);
            }
        }
    }

    /// The layer a claim holds, whether or not it has been reported granted.
    ///
    /// The blit path wants this rather than [`LayerPool::submitted`]: a layer
    /// awaiting its first blit is precisely the one that needs blitting.
    #[must_use]
    pub fn layer(&self, claim: ClaimId) -> Option<&B::Layer> {
        self.claims
            .iter()
            .find(|entry| entry.id == claim)
            .and_then(|entry| entry.held.as_ref())
            .map(|held| &held.layer)
    }

    /// What the pool knows about a claim, or `None` if it knows nothing about
    /// it — which is what a released claim, and a claim from a Lua state that
    /// has been reloaded away, both look like.
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

    /// The layer a claim has been reported granted, which is the only one Lua
    /// may be handed.
    ///
    /// [`LayerPool::layer`] answers with a layer awaiting its first blit too,
    /// because that is precisely the layer the blit path is looking for.
    /// Offering that one to Lua would hand out a `Layer` whose swapchain has
    /// never released an image, before `lovr.lunlayergranted` has said the
    /// claim holds anything.
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

    /// Every claim holding a layer, in the order the claims were made.
    pub fn held(&self) -> impl Iterator<Item = (ClaimId, &B::Layer)> {
        self.claims
            .iter()
            .filter_map(|entry| Some((entry.id, &entry.held.as_ref()?.layer)))
    }

    /// The layers to hand `lovrHeadsetSetLayers`, in the order the claims were
    /// made.
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
    /// the image it last released, which costs it nothing, while leaving the
    /// layer out of the list makes its panel disappear.
    ///
    /// `scene` travels with the list rather than being set separately, because
    /// `lovrHeadsetSetLayers` is the only call that carries it and a second
    /// call would be a second last-call-wins list.
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
    /// submitted: its slot is spoken for, and not counting it would let the
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
    /// A claim that does not fit stops the walk rather than being stepped over.
    /// Filling the remaining slot with a lower-priority claim would let a
    /// one-slot claim jump a two-slot one indefinitely, which is a starvation
    /// bug dressed as an optimisation.
    fn rank(&self) -> Vec<usize> {
        let mut order: Vec<usize> = (0..self.claims.len()).collect();
        // Stable, so equal priorities keep the order the claims were made in
        // and grants do not churn between frames.
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
    /// The layer comes back as [`HeldState::AwaitingFirstBlit`] however far
    /// along it was when it was freed. Its swapchain still holds the pixels the
    /// previous claim put there, and a claim on a window that has committed
    /// nothing — or whose client has just died — has no blit to overwrite them
    /// with, so granting on reuse would submit one window's content inside
    /// another window's panel. The cost is one frame of grant latency on a
    /// reuse, and no allocation, which is what the recycling is for.
    fn take_free(&mut self, key: LayerKey) -> Option<Held<B::Layer>> {
        let index = self.free.iter().rposition(|entry| entry.key == key)?;
        let entry = self.free.swap_remove(index);
        Some(Held {
            layer: entry.layer,
            state: HeldState::AwaitingFirstBlit,
        })
    }

    /// Returns a layer to the free list rather than destroying it.
    ///
    /// This is the recycling, and it is the whole reason a revoke is cheap. The
    /// pool keeps its own reference to every layer here, granted or free, and
    /// that reference is load-bearing rather than redundant:
    /// `lovrHeadsetSetLayers` releases the list it holds before retaining the
    /// new one, so a layer reachable only through `state.layers` is destroyed
    /// during a call that revokes and re-grants it — and destruction calls
    /// `xrDestroySwapchain` inline.
    fn release_layer(&mut self, key: LayerKey, held: Held<B::Layer>) {
        self.free.push(FreeLayer {
            key,
            layer: held.layer,
            idle_since: self.resolved,
        });
    }

    /// Destroys the free layers nothing has wanted for long enough.
    ///
    /// The only place [`LayerBackend::destroy`] is called during a session, and
    /// it runs at the end of a resolve so that a layer freed here is destroyed
    /// no earlier than [`LayerPool::IDLE_FRAMES_BEFORE_DESTROY`] boundaries
    /// after the last submit that named it.
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
    /// Whether this claim's refusal has been reported, so a runtime that
    /// refuses is described once rather than on every frame for the rest of
    /// the session. Cleared when a session goes away, because the next one
    /// answers the question afresh.
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
/// How far along it was when it was freed is deliberately not carried. The
/// layer's swapchain holds the previous claim's pixels, so the next claim to
/// take it starts at [`HeldState::AwaitingFirstBlit`] and has to have its own
/// copy issued before anything is submitted; see [`LayerPool::take_free`].
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
    /// and Lua has not been told the claim was granted.
    AwaitingFirstBlit,
    /// Written, and promoted at the next boundary. The promotion waits for a
    /// boundary rather than happening in the blit so that every grant Lua
    /// hears about lands where every other mutation does.
    FirstBlitIssued,
    /// Reported to Lua and included in the submitted list.
    Granted,
}
