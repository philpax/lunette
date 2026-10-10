//! Assigns pooled `Layer` objects to claims and recycles the unclaimed ones.

use std::{cmp::Ordering, fmt, mem, num::NonZeroU64};

use tracing::{info, warn};

use crate::{
    layers::{
        backend::{LayerBackend, SessionPresence},
        key::LayerSize,
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
/// The value comes from Lua; the pool never computes it.
#[derive(Clone, Copy, Debug)]
pub struct Priority(f64);

impl Priority {
    /// Rejects a priority that is not a number.
    ///
    /// A NaN makes the ordering intransitive, so the ranking would depend on
    /// input order.
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
    /// Total, because [`Priority::new`] refuses NaN. `PartialEq` delegates
    /// here so `-0.0` and `0.0` compare consistently with `Ord`.
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.total_cmp(&other.0)
    }
}

/// How many of the runtime's layer slots lunette will spend.
///
/// The budget is far below the reported limit because Monado does not check
/// it, and under `XR_EXTX_overlay` all sessions share one fixed array that
/// lunette cannot observe. Overflowing it is an out-of-bounds write.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct LayerBudget {
    slots: u32,
}

impl LayerBudget {
    /// The most slots lunette requests, however generous the runtime is.
    ///
    /// Twelve layers were submitted without trouble against Monado's reported
    /// limit of 128; `docs/dev/2026-08-06-milestone-0-findings.md` records it.
    pub const CEILING: u32 = 12;

    /// The fraction of the runtime's limit lunette takes.
    ///
    /// A quarter leaves the primary application the rest, and is the only
    /// margin against an unchecked overflow.
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

/// The pool's record of one claim.
///
/// The fields are read together so a handle never mixes state from before
/// and after a revocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClaimState {
    pub size: LayerSize,
    /// Whether the claim holds a layer that has been reported granted. False
    /// while a new layer awaits its first blit.
    pub granted: bool,
}

/// A pool of `Layer` objects, and the claims requesting them.
///
/// Whole layers are recycled. Everything a panel varies has a setter outside
/// `LayerInfo`, so a layer of a given [`LayerSize`] serves any panel with that
/// size.
#[derive(Debug)]
pub struct LayerPool<B: LayerBackend> {
    backend: B,
    free: Vec<FreeLayer<B::Layer>>,
    claims: Vec<Claim<B::Layer>>,
    next_claim: u64,
    /// The frame the most recent [`LayerPool::resolve`] ran for. A layer
    /// freed between boundaries is counted idle from that frame.
    resolved: FrameGeneration,
    /// The session found by the previous [`LayerPool::resolve`], if any.
    ///
    /// It holds an identity, not a flag, so a session replaced between two
    /// boundaries is detected as a loss.
    session: SessionPresence,
}

impl<B: LayerBackend> LayerPool<B> {
    /// The most layers created in one frame boundary.
    ///
    /// One, because `lovrLayerCreate` blocks in `xrWaitSwapchainImage` with
    /// no timeout. An unserved claim renders as an in-scene quad meanwhile.
    pub const CREATIONS_PER_FRAME: usize = 1;

    /// How long a free layer is kept before being destroyed, in frames.
    ///
    /// Frames keep the policy deterministic. This is ten seconds at ninety
    /// hertz, long enough for a demoted panel to reuse its layer.
    pub const IDLE_FRAMES_BEFORE_DESTROY: u64 = 900;

    #[must_use]
    pub fn new(backend: B) -> Self {
        Self {
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
    /// Never grants here, so a panel's realisation cannot change between its
    /// `lovr.update` and its `lovr.draw`.
    pub fn claim(&mut self, size: LayerSize, priority: Priority) -> ClaimId {
        let id = ClaimId(NonZeroU64::new(self.next_claim).unwrap_or(NonZeroU64::MIN));
        self.next_claim = self.next_claim.saturating_add(1);

        self.claims.push(Claim {
            id,
            size,
            priority,
            held: None,
            refusal_reported: false,
        });

        id
    }

    /// Withdraws a claim, returning any layer it held to the free list.
    ///
    /// Reports whether the claim is registered. No revocation is recorded,
    /// because the caller asked for the withdrawal.
    pub fn release_claim(&mut self, claim: ClaimId) -> bool {
        let Some(index) = self.claims.iter().position(|entry| entry.id == claim) else {
            return false;
        };

        let entry = self.claims.remove(index);
        if let Some(held) = entry.held {
            self.release_layer(entry.size, held);
        }
        true
    }

    /// Records the first blit issued for a claim's layer.
    ///
    /// Until then the swapchain has no released image, and `xrEndFrame`
    /// answers `XR_ERROR_LAYER_INVALID` for the layer.
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
    /// Runs once, at a frame boundary. Revoking before serving lets a freed
    /// layer be reused in the same boundary with no allocation.
    ///
    /// It also detects a lost session before any backend call uses a stale
    /// layer. See [`LayerPool::session_lost`].
    pub fn resolve(&mut self, now: FrameGeneration) {
        self.resolved = now;

        let session = self.backend.session();
        match (mem::replace(&mut self.session, session), session) {
            (SessionPresence::Present(_), SessionPresence::Absent) => {
                info!("the xr session is gone; every layer the pool held is given up");
                self.session_lost();
                return;
            }
            (SessionPresence::Present(before), SessionPresence::Present(after))
                if before != after =>
            {
                // A stop and a start inside one Lua callback. The new session
                // is served from the next boundary.
                info!(%before, %after, "the xr session was replaced; every layer the pool held is given up");
                self.session_lost();
                return;
            }
            // Returns before the budget is read, because the system's limit
            // outlives the session and would budget for absent swapchains.
            (SessionPresence::Absent, SessionPresence::Absent) => return,
            (
                SessionPresence::Absent | SessionPresence::Present(_),
                SessionPresence::Present(_),
            ) => {}
        }

        let winners = self.rank(LayerBudget::from_runtime_limit(self.backend.layer_limit()));

        for index in 0..self.claims.len() {
            if winners.contains(&index) {
                continue;
            }
            let Some(held) = self.claims[index].held.take() else {
                continue;
            };
            let size = self.claims[index].size;
            self.release_layer(size, held);
        }

        let mut created = 0;
        for index in winners {
            if self.claims[index].held.is_some() {
                continue;
            }

            let size = self.claims[index].size;
            if let Some(free) = self.take_free(size) {
                self.claims[index].held = Some(free);
                continue;
            }

            if created >= Self::CREATIONS_PER_FRAME {
                continue;
            }
            created += 1;

            let Some(layer) = self.backend.create(size) else {
                // A refusing runtime refuses on every retry, so warn once.
                if !self.claims[index].refusal_reported {
                    self.claims[index].refusal_reported = true;
                    warn!(
                        %size,
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
            }
        }

        self.sweep(now);
    }

    /// Discards every layer the pool holds, because the session that owned
    /// their swapchains is gone.
    ///
    /// No layer survives a session. Claims are kept empty for the next
    /// session, so Lua reads them as not granted and falls back to in-scene
    /// quads.
    fn session_lost(&mut self) {
        for claim in &mut self.claims {
            claim.refusal_reported = false;
            if let Some(held) = claim.held.take() {
                self.backend.destroy(held.layer);
            }
        }

        for entry in std::mem::take(&mut self.free) {
            self.backend.destroy(entry.layer);
        }
    }

    /// Destroys every layer the pool holds, while the session still exists.
    ///
    /// The counterpart to [`LayerPool::session_lost`], for a teardown lunette
    /// performs.
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
    /// Runs after [`LayerPool::shutdown`] on a restart. Kept claims would
    /// occupy the budget with no handle left to release them.
    ///
    /// A claim still holding a layer returns it to the free list, so nothing
    /// leaks.
    pub fn forget_claims(&mut self) {
        for claim in std::mem::take(&mut self.claims) {
            if let Some(held) = claim.held {
                self.release_layer(claim.size, held);
            }
        }
    }

    /// The layer a claim holds, whether or not it has been reported granted.
    ///
    /// The blit path uses this, because a layer awaiting its first blit is
    /// the one that needs blitting.
    #[must_use]
    pub fn layer(&self, claim: ClaimId) -> Option<&B::Layer> {
        self.claims
            .iter()
            .find(|entry| entry.id == claim)
            .and_then(|entry| entry.held.as_ref())
            .map(|held| &held.layer)
    }

    /// The pool's record of a claim, or `None` for a released or reloaded
    /// claim.
    #[must_use]
    pub fn state(&self, claim: ClaimId) -> Option<ClaimState> {
        let entry = self.claims.iter().find(|entry| entry.id == claim)?;
        Some(ClaimState {
            size: entry.size,
            granted: entry
                .held
                .as_ref()
                .is_some_and(|held| held.state == HeldState::Granted),
        })
    }

    /// The layer a claim has been reported granted. Lua may be handed this
    /// layer and no other, because one awaiting its first blit has never
    /// released an image.
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

    /// Hands the runtime every granted layer, copied into this frame or not,
    /// in registration order.
    ///
    /// Runs once a frame, after the blit. An unchanged layer is still
    /// submitted, because leaving it out makes its panel disappear.
    ///
    /// `scene` travels with the list because only `lovrHeadsetSetLayers`
    /// carries it.
    ///
    /// A layer awaiting its first blit is absent, because submitting it is
    /// `XR_ERROR_LAYER_INVALID`.
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

    /// The claims that fit the budget, highest priority first, as indices into
    /// `self.claims`. Every claim spends one slot.
    fn rank(&self, budget: LayerBudget) -> Vec<usize> {
        let mut order: Vec<usize> = (0..self.claims.len()).collect();
        // Stable, so equal priorities keep registration order and grants do
        // not churn between frames.
        order.sort_by(|left, right| {
            self.claims[*right]
                .priority
                .cmp(&self.claims[*left].priority)
        });

        order.truncate(usize::try_from(budget.slots()).unwrap_or(usize::MAX));
        order
    }

    /// Takes a matching layer off the free list, most recently freed first.
    ///
    /// The layer comes back as [`HeldState::AwaitingFirstBlit`], because the
    /// swapchain still holds the previous claim's pixels.
    fn take_free(&mut self, size: LayerSize) -> Option<Held<B::Layer>> {
        let index = self.free.iter().rposition(|entry| entry.size == size)?;
        let entry = self.free.swap_remove(index);
        Some(Held {
            layer: entry.layer,
            state: HeldState::AwaitingFirstBlit,
        })
    }

    /// Returns a layer to the free list, and does not destroy it.
    ///
    /// The pool's own reference is load-bearing: `lovrHeadsetSetLayers`
    /// releases its old list before retaining the new one, which would
    /// otherwise destroy a re-granted layer.
    fn release_layer(&mut self, size: LayerSize, held: Held<B::Layer>) {
        self.free.push(FreeLayer {
            size,
            layer: held.layer,
            idle_since: self.resolved,
        });
    }

    /// Destroys the free layers nothing has used for long enough.
    ///
    /// The sole call to [`LayerBackend::destroy`] in the frame loop.
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
    size: LayerSize,
    priority: Priority,
    held: Option<Held<L>>,
    /// Whether this claim's refusal has been reported. Cleared when a session
    /// goes away.
    refusal_reported: bool,
}

/// A layer a claim holds.
#[derive(Debug)]
struct Held<L> {
    layer: L,
    state: HeldState,
}

/// A layer nobody holds. See [`LayerPool::take_free`].
#[derive(Debug)]
struct FreeLayer<L> {
    size: LayerSize,
    layer: L,
    idle_since: FrameGeneration,
}

/// How far along a held layer is towards being submittable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HeldState {
    /// Created and never written. Submitting it is `XR_ERROR_LAYER_INVALID`,
    /// and the claim is not reported granted.
    AwaitingFirstBlit,
    /// Written, and promoted at the next boundary so grants take effect with
    /// every other mutation.
    FirstBlitIssued,
    /// Reported to Lua and included in the submitted list.
    Granted,
}
