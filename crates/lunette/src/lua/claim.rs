//! Linux-only: the claim on a composition layer, as Lua holds it.
//!
//! A panel is realised one of two ways. An in-scene quad is resampled by
//! lunette's renderer and then again by the runtime; a composition layer is
//! handed to the runtime at the source's native resolution and composited once.
//! That is the whole of the sharpness difference. Layers are scarce, so a
//! panel requests one and the claim records whether the request is granted.
//!
//! # The priority division
//!
//! `lunette.claimLayer` takes a scalar priority and `claim:setPriority` changes
//! it. [`LayerPool`] sorts by that number, stably, and assigns the top N.
//! The caller supplies the ranking: focus, gaze, distance, a rule putting
//! video above a terminal, hysteresis to stop grant oscillation. lunette adds
//! no ranking of its own. `docs/rendering.md` records that split.
//!
//! # Grant timing
//!
//! A claim made inside a callback is registered at once and granted no earlier
//! than the next frame boundary. A grant that arrives mid-frame would change a
//! panel's realisation between its `lovr.update` and its `lovr.draw`, the
//! class of inconsistency the snapshot model prevents. The frame loop calls
//! [`ClaimRegistry::resolve`]; Lua does not.
//!
//! # Claim death
//!
//! A claim is dead once the pool no longer holds it. `claim:release()` is the
//! sole operation that does this. Revocation does not end it.
//! `docs/rendering.md` records that the standard library falls back to an
//! in-scene quad on revoke and upgrades back when a layer returns to the
//! pool. A handle that becomes inert at revocation cannot carry that later
//! upgrade. Revocation removes the `Layer`: `claim.granted` is false and
//! `claim.layer` is `false`, and the same holds after a session is lost and
//! the pool rebuilt.

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
/// A trait, because [`Session`] holds the pool without carrying the backend in
/// its own type. A second type parameter on every handle (`Window<T, B>`,
/// `Sink<T, B>`, `Process<T, B>`) costs more to read than the indirection
/// costs to run. [`crate::events::EventSink`] is boxed under that same
/// reasoning.
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

    /// What the pool holds about a claim, or `None` once it holds nothing.
    fn state(&self, claim: ClaimId) -> Option<ClaimState>;

    /// Which window's pixels a claim is for.
    ///
    /// Kept here and not in the pool: the pool is about layers, and a layer of
    /// a given key serves any source that requests that key.
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
/// reason. Pushing a layer needs an XR session. Everything else about the
/// handle reflects the pool's state.
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
    /// Lua receives the object `lovr.headset.newLayer` returns, with the full
    /// `Layer` metatable, so `setPose`, `setDimensions`, `setViewport`, and the
    /// rest work as the documented LÖVR methods.
    fn push(&self, lua: &Lua) -> mlua::Result<Value> {
        let pointer = self.as_ptr().cast::<c_void>();

        // SAFETY: `exec_raw` locks the state and hands the closure the raw
        // pointer under a stack guard, and it runs the closure inside a
        // protected call, so the allocation `_luax_pushtype` performs cannot
        // longjmp past mlua. `_luax_pushtype` retains the object itself, so the
        // reference the pool holds is untouched.
        unsafe {
            lua.exec_raw((), |state| {
                _luax_pushtype(state.cast(), ObjectType_T_Layer as i32, pointer);
            })
        }
    }
}

/// The pool, plus each claim's source window.
///
/// The interior mutability is a [`RefCell`] and not a lock because the frame
/// thread is the sole thread that touches it: the Lua API is available in the
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
    /// A closure, for the same reason [`Session::with_textures`] takes one: the
    /// pool is reachable from inside Lua callbacks, and a guard held across one
    /// would panic on the re-entry.
    pub fn with_pool<R>(&self, body: impl FnOnce(&mut LayerPool<B>) -> R) -> R {
        body(&mut self.pool.borrow_mut())
    }

    /// Discards every claim, because the Lua state that made them is gone.
    ///
    /// Called by [`FrameDriver::quiesce`] after the layers have been destroyed.
    /// At no other moment is a claim certain to be an orphan. A soft reload
    /// keeps the claims, because the handles Lua holds survive it.
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
/// cannot walk the handles Lua is keeping at frame start.
#[derive(Debug)]
pub struct Claim<T> {
    id: ClaimId,
    /// The window whose pixels this claim is for. Fixed when the claim is made:
    /// a claim names one source for its whole life, and a panel that changes
    /// source releases the claim and makes a new one.
    ///
    /// Absent when the pool no longer holds the claim.
    /// A handler that releases a claim earlier than the event naming the claim
    /// can produce such a handle.
    source: Option<WindowId>,
    session: Rc<Session<T>>,
    known: RefCell<Known>,
}

impl<T> Claim<T> {
    /// Builds a handle for a claim the pool has just created, or for one an event
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

    /// Brings the cache up to date, reporting whether the pool still holds the
    /// claim.
    fn refresh(&self) -> bool {
        let Some(state) = self.session.claims().state(self.id) else {
            return false;
        };
        *self.known.borrow_mut() = Known::from(state);
        true
    }
}

/// The last read value of each claim field.
#[derive(Clone, Copy, Debug, Default)]
struct Known {
    granted: bool,
    /// The size of the layer the claim is for. This is the requested size
    /// rounded up to the ladder, not the requested size itself.
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
    /// A claim on a composition layer for a window's pixels. Layers are scarce, so a panel requests one and the claim records whether the request is granted. An in-scene quad is the fallback. `lunette.claimLayer` mints the claim; an event names one that already exists.
    Claim<T: LuaTexture> = HandleKind::Claim;

    /// Fixed for the claim's whole life, so it is the key a table of per-claim state uses.
    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// Whether the panel draws itself on the layer this frame, or as an in-scene quad. Read every frame: a claim is revoked when a higher-priority one arrives at capacity, and re-granted when a layer returns to the pool.
    field granted(_lua, this) -> bool {
        this.refresh();
        Ok(this.known.borrow().granted)
    }

    /// The LÖVR layer, with the full `Layer` metatable, or `false` while the claim holds none. Never cached across frames: what it names goes away on revoke.
    field layer(lua, this) -> MaybeLayer {
        this.refresh();
        this.session.claims().push_layer(lua, this.id).map(MaybeLayer)
    }

    field priority(_lua, this) -> f64 {
        this.refresh();
        Ok(this.known.borrow().priority)
    }

    /// The size of the layer a claim is for. The requested size is rounded up to
    /// the ladder, so the layer is at least as large as the request and usually
    /// larger. A caller setting the layer's viewport needs the number it
    /// actually has.
    field width(_lua, this) -> Option<u32> { Ok(size(this).map(|size| size.width)) }

    field height(_lua, this) -> Option<u32> { Ok(size(this).map(|size| size.height)) }

    /// The source, as a fresh handle each read. Absent when the pool no longer
    /// holds the claim.
    field window(_lua, this) -> Option<Window<T>> {
        Ok(this
            .source
            .map(|source| Window::for_id(Rc::clone(&this.session), source)))
    }

    /// Changes where this claim ranks against the others, taking effect at the next frame boundary. Raising a claim above a granted one displaces it.
    method setPriority(_lua, this, priority: f64) -> bool { set_priority(this, priority) }

    /// Withdraws the claim and returns the layer to the pool. The handle is dead
    /// afterwards, and no revocation event fires. `false` when the claim is
    /// already gone.
    method release(_lua, this) -> bool { Ok(release(this)) }
}

/// `lunette.claimLayer{ window = …, width = …, height = …, priority = … }`.
///
/// The handle comes back before ranking, so it describes a
/// claim that holds nothing: `granted` is false and `layer` is `false` until a
/// frame boundary has assigned the pool's layers, and it may stay that way
/// indefinitely if higher-priority claims keep the pool full. Both paths have to
/// be live in the caller: an in-scene quad is the fallback.
///
/// # Errors
///
/// If the table carries an option this call does not take, if `window` is not a
/// window handle, if the size is not a pair of positive pixel counts, or if the
/// priority is not a number.
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

    // The key is `LayerProperties::PANEL`. The caller does not choose it.
    // Stereo and immutable layers are not in this build. No source produces
    // stereo content, and a pooled layer is reused, so it cannot be immutable.
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
        /// Where this claim ranks against the others. Ranking is the caller's: lunette sorts by the number and adds no ranking of its own.
        priority: f64,
    }
}

/// `claim:setPriority(n)`: changes where this claim ranks against the others.
///
/// Takes effect at the next frame boundary, with every other grant and
/// revocation. Raising a claim above a granted one displaces it, and the
/// displaced claim receives `lovr.lunlayerrevoked`.
///
/// `false` on a dead handle, without raising. A priority that is not a number
/// raises: that is a defect in the caller's maths, and a claim silently
/// keeping its old ranking would be diagnosed as a fault in the pool.
///
/// # Errors
///
/// If the priority is not a number that can be ordered.
fn set_priority<T>(claim: &Claim<T>, priority: f64) -> mlua::Result<bool> {
    // Validated before the liveness check, so a bad priority is reported
    // whether or not the claim is still there.
    let priority = Priority::new(priority).ok_or_else(|| {
        mlua::Error::runtime(
            "lunette: a claim's priority has to be a number that can be ordered, and nan cannot",
        )
    })?;

    Ok(claim.session.claims().set_priority(claim.id, priority))
}

/// `claim:release()`: withdraws the claim, returning any layer to the pool.
///
/// The handle is dead afterwards, and no `lovr.lunlayerrevoked` fires: the
/// caller released the claim itself, and an event would restate the call.
///
/// Releasing is explicit. A collected handle does not release. The event
/// payloads carry a second handle to the same claim, and a handle that releases
/// on drop would withdraw a live claim as soon as the garbage collector reaches
/// the copy a handler has finished with.
///
/// `false` when the claim is already gone, without raising.
fn release<T>(claim: &Claim<T>) -> bool {
    claim.session.claims().release(claim.id)
}

/// The size of the layer a claim is for, or `nil` for a claim the pool has never
/// held.
fn size<T>(claim: &Claim<T>) -> Option<PixelSize> {
    claim.refresh();
    claim.known.borrow().size.map(LayerSize::get)
}
