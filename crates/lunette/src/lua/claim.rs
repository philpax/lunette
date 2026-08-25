//! Linux-only: the claim on a composition layer, as Lua holds it.
//!
//! A panel is realised one of two ways. An in-scene quad is resampled by
//! lunette's renderer and then again by the runtime; a composition layer is
//! handed to the runtime at the source's native resolution and composited once,
//! which is the whole of the sharpness difference. Layers are scarce, so a panel
//! asks for one and is told whether it has it.
//!
//! ## Priority ranking
//!
//! `lunette.claimLayer` takes a scalar priority and `claim:setPriority` changes
//! it. [`LayerPool`] sorts by that number, stably, and assigns the top N.
//! Ranking is application knowledge — focus, gaze, distance, a rule putting
//! video above a terminal, hysteresis to prevent grant oscillation — and lunette
//! never invents a ranking value. `docs/rendering.md` records that split.
//!
//! ## Claim resolution timing
//!
//! A claim made inside a callback is registered immediately and granted no earlier
//! than the next frame boundary. A grant applied mid-frame would change a
//! panel's realisation between its `lovr.update` and its `lovr.draw`, which is
//! the class of inconsistency the snapshot model exists to prevent. This is why
//! [`ClaimRegistry::resolve`] runs in the frame loop rather than from Lua.
//!
//! ## Claim lifetime
//!
//! A claim is dead once the pool no longer knows about it, which is what
//! `claim:release()` does and nothing else does. Revocation does not destroy a
//! claim handle: `docs/rendering.md` has the standard library fall back to an
//! in-scene quad on revoke and upgrade back when a layer frees, and a handle
//! that went inert on the way down could never carry the way back up. What
//! revocation takes away is the `Layer` — `claim.granted` goes false and
//! `claim.layer` answers `false` — and the same is true after a session is lost
//! and the pool rebuilt.

use std::{cell::RefCell, collections::HashMap, ffi::c_void, fmt, rc::Rc};

use lunette_compositor::protocol::{PixelSize, WindowId};
use lunette_lovr::raw::{_luax_pushtype, ObjectType_T_Layer};
use mlua::{Lua, Value};

use crate::{
    control::wire::HandleKind,
    layers::{
        ClaimId, ClaimState, LayerBackend, LayerKey, LayerPool, LayerProperties, LayerSize,
        LovrLayer, PoolOutcome, Priority,
    },
    lua::{
        LuaTexture, Session, Window,
        declarations::{NullTexture, Options, handle, record},
        pixel_size,
        values::MaybeLayer,
    },
    texture::FrameGeneration,
};

/// The pool, as the Lua surface and the frame loop reach it.
///
/// A trait so that [`Session`] can hold the pool without carrying the backend in
/// its own type. Threading a second type parameter through every handle —
/// `Window<T, B>`, `Sink<T, B>`, `Process<T, B>` — would cost more to read than
/// the indirection costs to run, which is the reasoning [`crate::events::EventSink`]
/// is boxed under as well.
pub trait ClaimRegistry: fmt::Debug {
    /// Registers a claim on a layer of `key` for `source`, to be ranked at the
    /// next frame boundary.
    fn claim(&self, source: WindowId, key: LayerKey, priority: Priority) -> ClaimId;

    /// Changes a claim's ranking, taking effect at the next frame boundary.
    ///
    /// Reports whether the claim is still known.
    fn set_priority(&self, claim: ClaimId, priority: Priority) -> bool;

    /// Withdraws a claim, returning any layer it held to the free list.
    ///
    /// Reports whether the claim was known.
    fn release(&self, claim: ClaimId) -> bool;

    /// What the pool knows about a claim, or `None` once it knows nothing.
    fn state(&self, claim: ClaimId) -> Option<ClaimState>;

    /// Which window's pixels a claim is for.
    ///
    /// Kept here rather than in the pool: the pool is about layers, and a layer
    /// of a given key serves any source that wants that key.
    fn source(&self, claim: ClaimId) -> Option<WindowId>;

    /// Pushes the `Layer` a claim has been granted, or `false` when it holds
    /// none.
    ///
    /// # Errors
    ///
    /// If the value could not be pushed onto the stack.
    fn push_layer(&self, lua: &Lua, claim: ClaimId) -> mlua::Result<Value>;

    /// Assigns layers to the highest-priority claims that fit the budget.
    ///
    /// Called once per frame, at the boundary, by the frame loop.
    fn resolve(&self, now: FrameGeneration) -> PoolOutcome;

    /// Destroys every layer the pool holds, while the session still exists.
    fn shutdown(&self);
}

/// How a `Layer` is handed to Lua.
///
/// The seam is the same one [`crate::lua::LuaTexture`] is, and for the same
/// reason: it is the only part of a claim that needs an XR session, and
/// everything else about the handle is a projection of what the pool decided.
pub trait LuaLayer: fmt::Debug {
    /// Produces the value Lua holds for this layer.
    ///
    /// # Errors
    ///
    /// If the value could not be pushed onto the stack.
    fn push(&self, lua: &Lua) -> mlua::Result<Value>;
}

impl LuaLayer for LovrLayer {
    /// Pushes LÖVR's own `Layer` userdata, not a wrapper around it.
    ///
    /// Lua receives the object `lovr.headset.newLayer` would have handed it,
    /// with the full `Layer` metatable, so `setPose`, `setDimensions`,
    /// `setViewport`, and the rest are the documented LÖVR methods rather than
    /// a re-export of them.
    fn push(&self, lua: &Lua) -> mlua::Result<Value> {
        let pointer = self.as_ptr().cast::<c_void>();

        // SAFETY: `exec_raw` locks the state and hands the closure the raw
        // pointer under a stack guard, and it runs the closure inside a
        // protected call, so the allocation `_luax_pushtype` performs cannot
        // longjmp past mlua. `_luax_pushtype` retains the object itself
        // (`api/api.c`), so the reference the pool holds is untouched.
        unsafe {
            lua.exec_raw((), |state| {
                _luax_pushtype(state.cast(), ObjectType_T_Layer as i32, pointer);
            })
        }
    }
}

/// The pool, plus the source each claim was made for.
///
/// The interior mutability is a [`RefCell`] and not a lock because the frame
/// thread is the only thread that touches it: the Lua API is available in the
/// main state alone, and [`crate::layers::LovrLayers`] is the frame thread's
/// authority over LÖVR's headset module.
#[derive(Debug)]
pub struct PoolRegistry<B: LayerBackend> {
    pool: RefCell<LayerPool<B>>,
    sources: RefCell<HashMap<ClaimId, WindowId>>,
}

impl<B: LayerBackend> PoolRegistry<B> {
    #[must_use]
    pub fn new(pool: LayerPool<B>) -> Self {
        Self {
            pool: RefCell::new(pool),
            sources: RefCell::new(HashMap::new()),
        }
    }

    /// Runs `body` against the pool itself, for the blit and submit paths.
    ///
    /// A closure rather than a borrow guard, for the reason
    /// [`Session::with_textures`] takes one: the pool is reachable from inside
    /// Lua callbacks, and a guard held across one would panic on the re-entry.
    pub fn with_pool<R>(&self, body: impl FnOnce(&mut LayerPool<B>) -> R) -> R {
        body(&mut self.pool.borrow_mut())
    }

    /// Discards every claim, because the Lua state that made them is gone.
    ///
    /// Called by [`FrameDriver::quiesce`] after the layers have been destroyed,
    /// which is the only moment at which a claim can be certain to be an orphan:
    /// a soft reload keeps the claims deliberately, because the handles Lua
    /// holds survive it.
    ///
    /// [`FrameDriver::quiesce`]: crate::frame::FrameDriver::quiesce
    pub fn forget_claims(&self) {
        self.pool.borrow_mut().forget_claims();
        self.sources.borrow_mut().clear();
    }
}

impl<B> ClaimRegistry for PoolRegistry<B>
where
    B: LayerBackend + fmt::Debug,
    B::Layer: LuaLayer,
{
    fn claim(&self, source: WindowId, key: LayerKey, priority: Priority) -> ClaimId {
        let claim = self.pool.borrow_mut().claim(key, priority);
        self.sources.borrow_mut().insert(claim, source);
        claim
    }

    fn set_priority(&self, claim: ClaimId, priority: Priority) -> bool {
        self.pool.borrow_mut().set_priority(claim, priority)
    }

    fn release(&self, claim: ClaimId) -> bool {
        self.sources.borrow_mut().remove(&claim);
        self.pool.borrow_mut().release_claim(claim)
    }

    fn state(&self, claim: ClaimId) -> Option<ClaimState> {
        self.pool.borrow().state(claim)
    }

    fn source(&self, claim: ClaimId) -> Option<WindowId> {
        self.sources.borrow().get(&claim).copied()
    }

    fn push_layer(&self, lua: &Lua, claim: ClaimId) -> mlua::Result<Value> {
        // The push runs while the pool is borrowed. That is safe here and only
        // here: it pushes a value, and no Lua the caller wrote runs until this
        // returns.
        match self.pool.borrow().granted_layer(claim) {
            Some(layer) => layer.push(lua),
            None => Ok(Value::Boolean(false)),
        }
    }

    fn resolve(&self, now: FrameGeneration) -> PoolOutcome {
        self.pool.borrow_mut().resolve(now)
    }

    fn shutdown(&self) {
        self.pool.borrow_mut().shutdown();
    }
}

/// A claim on a composition layer, as Lua holds it.
///
/// Like every other handle it caches what it last read and refreshes that cache
/// against the pool on each read, because Rust holds no reference into Lua and
/// so cannot walk the handles Lua is keeping at frame start.
#[derive(Debug)]
pub struct Claim<T> {
    id: ClaimId,
    /// The window whose pixels this claim is for. Fixed when the claim is made:
    /// a claim names one source for its whole life, and a panel that changes
    /// source releases and claims again.
    ///
    /// Absent only for a handle built for a claim the pool has already
    /// forgotten, which a handler releasing a claim ahead of the event that
    /// names it can produce.
    source: Option<WindowId>,
    session: Rc<Session<T>>,
    known: RefCell<Known>,
}

impl<T> Claim<T> {
    /// Builds a handle for a claim the pool has just minted, or for one an event
    /// names.
    pub(crate) fn new(session: Rc<Session<T>>, id: ClaimId) -> Self {
        let source = session.claims().source(id);
        let known = session
            .claims()
            .state(id)
            .map_or_else(Known::default, Known::from);
        Self {
            id,
            source,
            session,
            known: RefCell::new(known),
        }
    }

    /// Brings the cache up to date, reporting whether the pool still knows the
    /// claim.
    fn refresh(&self) -> bool {
        let Some(state) = self.session.claims().state(self.id) else {
            return false;
        };
        *self.known.borrow_mut() = Known::from(state);
        true
    }
}

/// The last thing each field of a claim was known to be.
#[derive(Clone, Copy, Debug, Default)]
struct Known {
    granted: bool,
    /// The size of the layer the claim is for, which is the requested size
    /// rounded up to the ladder rather than the requested size itself.
    size: Option<LayerSize>,
    priority: f64,
}

impl From<ClaimState> for Known {
    fn from(state: ClaimState) -> Self {
        Self {
            granted: state.granted,
            size: Some(state.key.size()),
            priority: state.priority.get(),
        }
    }
}

handle! {
    /// A claim for a composition layer carrying a window's pixels.
    Claim<T: LuaTexture> = HandleKind::Claim;

    /// The claim's stable identifier.
    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// Whether this claim has a layer this frame.
    field granted(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().granted)
    }

    /// The LÖVR layer, or false while this claim holds none.
    field layer(lua, this) -> MaybeLayer {
        this.refresh();
        this.session.claims().push_layer(lua, this.id).map(MaybeLayer)
    }

    field priority(_lua, this) -> f64 {
        this.refresh();
        Ok(this.known.borrow().priority)
    }

    /// The allocated layer width, which may exceed the requested width.
    field width(_lua, this) -> Option<u32> { Ok(size(this).map(|size| size.width)) }

    field height(_lua, this) -> Option<u32> { Ok(size(this).map(|size| size.height)) }

    /// The source window, or nil after the claim is forgotten.
    field window(_lua, this) -> Option<Window<T>> {
        Ok(this
            .source
            .map(|source| Window::for_id(Rc::clone(&this.session), source)))
    }

    /// Changes this claim's priority at the next frame boundary.
    method setPriority(_lua, this, priority: f64) -> bool { set_priority(this, priority) }

    /// Releases this claim and returns its layer to the pool.
    method release(_lua, this) -> bool { Ok(release(this)) }
}

/// Creates a layer claim for a window; allocation is resolved at the next frame boundary.
///
/// # Errors
///
/// If an option is unknown, the window is invalid, the size is not positive, or the priority is not numeric.
pub(crate) fn claim_layer<T: LuaTexture>(
    session: &Rc<Session<T>>,
    options: &Options<ClaimLayer>,
) -> mlua::Result<Claim<T>> {
    let options = options.table();

    let source = options
        .get::<Option<mlua::UserDataRef<Window<T>>>>("window")?
        .ok_or_else(|| {
            mlua::Error::runtime(
                "lunette: claimLayer needs a window whose pixels the layer carries",
            )
        })?
        .id();

    let requested = pixel_size(
        options.get::<f64>("width")?,
        options.get::<f64>("height")?,
        "layer size",
    )?;
    let size = LayerSize::quantized(requested).ok_or_else(|| {
        mlua::Error::runtime(format!(
            "lunette: {requested} has no rung on the layer size ladder"
        ))
    })?;

    let priority = options.get::<f64>("priority")?;
    let priority = Priority::new(priority).ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: a claim's priority has to be a number that can be ordered, and nan cannot",
        )
    })?;

    // `LayerProperties::PANEL` rather than anything the caller chooses. Stereo
    // and immutable layers are deliberately not in this build — no source
    // produces stereo content, and a pooled layer is by definition reused, which
    // an immutable one cannot be.
    let key = LayerKey::new(size, LayerProperties::PANEL);
    let id = session.claims().claim(source, key, priority);
    Ok(Claim::new(Rc::clone(session), id))
}

record! {
    /// What `lunette.claimLayer` takes.
    options ClaimLayer as ClaimOptions {
        /// The window whose pixels the layer carries.
        window: Window<NullTexture>,
        width: f64,
        height: f64,
        /// The claim's priority.
        priority: f64,
    }
}

/// Sets a claim's priority for the next frame boundary and returns false if it is dead.
///
/// # Errors
///
/// If the priority is not a number that can be ordered.
fn set_priority<T>(claim: &Claim<T>, priority: f64) -> mlua::Result<bool> {
    // Validated before the liveness check, so a bad priority is reported whether
    // or not the claim happens to still be there.
    let priority = Priority::new(priority).ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: a claim's priority has to be a number that can be ordered, and nan cannot",
        )
    })?;

    Ok(claim.session.claims().set_priority(claim.id, priority))
}

/// Releases a claim and returns false if it is already gone.
fn release<T>(claim: &Claim<T>) -> bool {
    claim.session.claims().release(claim.id)
}

/// The size of the layer a claim is for, or `nil` for a claim the pool has never
/// known.
fn size<T>(claim: &Claim<T>) -> Option<PixelSize> {
    claim.refresh();
    claim.known.borrow().size.map(LayerSize::get)
}
