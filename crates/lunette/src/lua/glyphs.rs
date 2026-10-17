//! Linux-only: `lunette.glyphAtlas`, the UI toolkit's distance field glyph atlas from `lunette-ui`.
//!
//! Every layout tree in a Lua state shapes with one set of fonts, and the atlas draws glyphs from
//! those fonts by the face handles that `LayoutTree:textLayout` reports. Fields are generated with
//! msdfgen, which LÖVR builds. Pages cross the boundary as RGBA8 strings that the host uploads to
//! LÖVR textures when their revision changes.
//!
//! msdfgen takes several milliseconds per glyph, longer than a frame's budget for a panel full of
//! new text, so fields are generated on worker threads. Outlines are read on the Lua thread,
//! because the fonts belong to it, and `update` places finished fields in the atlas once a frame.

use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    panic::{self, AssertUnwindSafe},
    rc::Rc,
    sync::{
        Arc,
        mpsc::{self, Receiver, SyncSender, TrySendError},
    },
    thread::{self, JoinHandle},
};

use lunette_lovr::msdf::{self, Edge, Projection};
use lunette_ui::{
    glyphs::{
        Atlas, AtlasConfig, FieldError, FieldGenerator, FieldRequest, Job, Outline, Placement,
        Prepared, Segment,
    },
    layout::SharedFonts,
    text::FaceHandle,
};
use mlua::{IntoLua, Lua, LuaString, UserData, UserDataFields, UserDataMethods, Value};
use parking_lot::Mutex;

use crate::lua::{
    declarations::{
        AliasSpec, Aliased, Described, HandleSpec, Surface, Type, Typed, add_fields, handle,
    },
    layout::shared_fonts,
};

/// Jobs waiting for a worker. A full queue leaves a glyph to be asked for again on a later frame.
const QUEUED_JOBS: usize = 64;
/// Finished fields waiting for `update`. A full queue holds the workers until the next frame.
const FINISHED_JOBS: usize = 64;
/// The most worker threads. The compositor, LÖVR, and the runtime have threads of their own.
const MOST_WORKERS: usize = 3;

/// The atlas every panel in this Lua state draws glyphs from, kept in the state's app data.
#[derive(Clone)]
struct SharedAtlas(Rc<RefCell<State>>);

/// The atlas and the glyphs on their way into it.
struct State {
    atlas: Atlas,
    workers: Workers,
    /// Glyphs whose fields a worker is generating.
    pending: HashSet<(FaceHandle, u16)>,
    /// Glyphs that could not be placed, kept until `glyph` reports them.
    failures: HashMap<(FaceHandle, u16), String>,
}

/// The Lua state's glyph atlas, created on first use.
pub fn glyph_atlas(lua: &Lua) -> GlyphAtlas {
    let state = match lua.app_data_ref::<SharedAtlas>() {
        Some(shared) => shared.0.clone(),
        None => {
            let created = Rc::new(RefCell::new(State {
                atlas: Atlas::new(AtlasConfig::default()),
                workers: Workers::start(worker_count(), || Box::new(Msdf)),
                pending: HashSet::new(),
                failures: HashMap::new(),
            }));
            lua.set_app_data(SharedAtlas(created.clone()));
            created
        }
    };
    GlyphAtlas {
        atlas: state,
        fonts: shared_fonts(lua),
    }
}

fn worker_count() -> usize {
    thread::available_parallelism()
        .map_or(1, |count| count.get() / 2)
        .clamp(1, MOST_WORKERS)
}

/// A view of the shared glyph atlas.
pub struct GlyphAtlas {
    atlas: Rc<RefCell<State>>,
    fonts: SharedFonts,
}

impl PartialEq for GlyphAtlas {
    fn eq(&self, other: &Self) -> bool {
        Rc::ptr_eq(&self.atlas, &other.atlas)
    }
}

impl Typed for GlyphAtlas {
    fn luau() -> Type {
        Type::Named("GlyphAtlas")
    }
}

impl UserData for GlyphAtlas {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        add_fields(fields);
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        crate::lua::declarations::add_methods(methods);
    }
}

impl Described for GlyphAtlas {
    const HANDLE: HandleSpec = HandleSpec {
        name: "GlyphAtlas",
        doc: "The distance field glyph atlas that every panel in this Lua state draws shaped glyphs from. Pages are square, numbered from 1, and hold RGBA8 multi-channel distance fields to sample with linear filtering and no colour-space conversion. Fields are generated on worker threads, and `update` places the finished ones, so a glyph is drawable some frames after it is first asked for. The atlas holds a fixed number of pages; when they are full it clears the page that has gone longest undrawn, if no frame has touched it for a while, and a glyph with no room otherwise is a failure. The atlas is not a handle: it never goes dead.",
    };
    const KIND: Option<crate::control::wire::HandleKind> = None;

    fn describe(surface: &mut impl Surface<Self>) {
        handle!(@items surface,
            /// The width and height of each page in pixels.
            field pageSize(_lua, this) -> u32 { Ok(config(this)?.page_size) }
            /// Pixels per em at which glyphs are generated.
            field emPixels(_lua, this) -> u32 { Ok(config(this)?.em_pixels) }
            /// The distance field's range in pixels, for the shader's edge width.
            field range(_lua, this) -> u32 { Ok(config(this)?.range_pixels) }
            /// The number of pages.
            field pages(_lua, this) -> usize { Ok(borrow(this)?.atlas.pages().len()) }
            /// The number of glyphs whose fields are being generated.
            field pending(_lua, this) -> usize { Ok(borrow(this)?.pending.len()) }
            /// Advances whenever a full atlas clears a page that has gone undrawn, after which every placement answered before must be asked for again.
            field epoch(_lua, this) -> u64 { Ok(borrow(this)?.atlas.epoch()) }
            /// The placement of a glyph from a layout glyph's face and id. A glyph not yet in the atlas starts generating and answers nil and true, and is asked for again on a later frame. Answers nil for a glyph with no outline, such as a space, and nil with a message, once, for a glyph that could not be generated, which a later call tries again.
            method glyph(_lua, this, face: u32, id: u32) -> (Option<GlyphPlacement>, Option<String>, bool) {
                let id = u16::try_from(id).map_err(|_| mlua::Error::runtime(format!("glyph atlas: {id} is not a glyph id")))?;
                glyph(this, face, id)
            }
            /// Starts a frame and places the fields the workers have finished. The host calls it once a frame, before it asks for glyphs.
            method update(_lua, this) -> () {
                update(this)
            }
            /// Records that this frame draws a page, so a full atlas does not clear it.
            method touch(_lua, this, page: usize) -> () {
                let Some(index) = page.checked_sub(1).and_then(|index| u32::try_from(index).ok()) else {
                    return Ok(());
                };
                borrow_mut(this)?.atlas.touch(index);
                Ok(())
            }
            /// A page's revision, which advances whenever a glyph is written to it, or nil for a page that does not exist.
            method revision(_lua, this, page: usize) -> Option<u64> {
                Ok(page_of(this, page)?.map(|page| page.revision))
            }
            /// A page's pixels as tightly packed RGBA8 rows, top row first, which `lovr.data.newBlob` wraps for `lovr.data.newImage`, or nil for a page that does not exist.
            method pixels(lua, this, page: usize) -> Option<LuaString> {
                let state = borrow(this)?;
                let found = page.checked_sub(1).and_then(|index| state.atlas.pages().get(index));
                found.map(|page| lua.create_string(&page.pixels)).transpose()
            }
        );
    }
}

fn borrow(this: &GlyphAtlas) -> mlua::Result<std::cell::Ref<'_, State>> {
    this.atlas.try_borrow().map_err(|_| {
        mlua::Error::runtime("glyph atlas: the atlas is in use by a glyph being generated")
    })
}

fn config(this: &GlyphAtlas) -> mlua::Result<AtlasConfig> {
    Ok(borrow(this)?.atlas.config())
}

fn page_of(this: &GlyphAtlas, page: usize) -> mlua::Result<Option<lunette_ui::glyphs::Page>> {
    let state = borrow(this)?;
    Ok(page
        .checked_sub(1)
        .and_then(|index| state.atlas.pages().get(index))
        .cloned())
}

fn glyph(
    this: &GlyphAtlas,
    face: u32,
    id: u16,
) -> mlua::Result<(Option<GlyphPlacement>, Option<String>, bool)> {
    let fonts = this.fonts.try_borrow().map_err(|_| {
        mlua::Error::runtime(
            "glyph atlas: the fonts are in use by a layout computation in progress",
        )
    })?;
    let mut state = borrow_mut(this)?;
    let state = &mut *state;
    let key = (FaceHandle::new(face), id);
    if let Some(failure) = state.failures.remove(&key) {
        return Ok((None, Some(failure), false));
    }
    if state.pending.contains(&key) {
        return Ok((None, None, true));
    }
    let prepared = state.atlas.prepare(key.0, id, || fonts.outline(key.0, id));
    let job = match prepared {
        Ok(Prepared::Known(placement)) => return Ok((placement.map(GlyphPlacement), None, false)),
        Ok(Prepared::Job(job)) => job,
        Err(error) => return Ok((None, Some(error.to_string()), false)),
    };
    match state.workers.submit(job) {
        Submitted::Queued => {
            state.pending.insert(key);
            Ok((None, None, true))
        }
        Submitted::Busy => Ok((None, None, true)),
        // With no worker running, the glyph is generated here, as it would be without workers.
        Submitted::Unavailable(job) => {
            let field = job.generate(&mut Msdf);
            match state.atlas.complete(&job, field) {
                Ok(placement) => Ok((placement.map(GlyphPlacement), None, false)),
                Err(error) => Ok((None, Some(error.to_string()), false)),
            }
        }
    }
}

fn update(this: &GlyphAtlas) -> mlua::Result<()> {
    let mut state = borrow_mut(this)?;
    let state = &mut *state;
    state.atlas.advance();
    for (job, field) in state.workers.finished() {
        let key = job.key();
        state.pending.remove(&key);
        if let Err(error) = state.atlas.complete(&job, field) {
            state.failures.insert(key, error.to_string());
        }
    }
    Ok(())
}

fn borrow_mut(this: &GlyphAtlas) -> mlua::Result<std::cell::RefMut<'_, State>> {
    this.atlas.try_borrow_mut().map_err(|_| {
        mlua::Error::runtime("glyph atlas: the atlas is in use by a glyph being generated")
    })
}

/// A field a worker has generated, or its failure.
type Finished = (Job, Result<Vec<f32>, FieldError>);

/// Threads that generate fields. Dropping the pool stops the threads after their current jobs.
struct Workers {
    jobs: Option<SyncSender<Job>>,
    finished: Option<Receiver<Finished>>,
    threads: Vec<JoinHandle<()>>,
}

/// What became of a submitted job.
enum Submitted {
    Queued,
    /// The queue is full; the glyph is asked for again later.
    Busy,
    /// No worker is running.
    Unavailable(Job),
}

impl Workers {
    /// Starts up to `count` workers, each with its own generator. A thread that cannot be spawned
    /// is left out, and with none the pool answers every job as unavailable.
    fn start(count: usize, generator: fn() -> Box<dyn FieldGenerator + Send>) -> Self {
        let (jobs, queue) = mpsc::sync_channel::<Job>(QUEUED_JOBS);
        let (done, finished) = mpsc::sync_channel::<Finished>(FINISHED_JOBS);
        let queue = Arc::new(Mutex::new(queue));
        let mut threads = Vec::new();
        for index in 0..count {
            let queue = queue.clone();
            let done = done.clone();
            let spawned = thread::Builder::new()
                .name(format!("lunette-glyphs-{index}"))
                .spawn(move || work(&queue, &done, generator()));
            match spawned {
                Ok(handle) => threads.push(handle),
                Err(error) => {
                    tracing::warn!("glyph atlas: a worker thread could not start: {error}");
                }
            }
        }
        Self {
            jobs: (!threads.is_empty()).then_some(jobs),
            finished: Some(finished),
            threads,
        }
    }

    fn submit(&self, job: Job) -> Submitted {
        let Some(jobs) = &self.jobs else {
            return Submitted::Unavailable(job);
        };
        match jobs.try_send(job) {
            Ok(()) => Submitted::Queued,
            Err(TrySendError::Full(_)) => Submitted::Busy,
            Err(TrySendError::Disconnected(job)) => Submitted::Unavailable(job),
        }
    }

    fn finished(&self) -> Vec<Finished> {
        self.finished
            .as_ref()
            .map(|finished| finished.try_iter().collect())
            .unwrap_or_default()
    }
}

impl Drop for Workers {
    fn drop(&mut self) {
        // Closing both channels ends every worker: an idle one sees the job queue close, and a
        // busy one fails to send its field.
        self.jobs = None;
        self.finished = None;
        for handle in self.threads.drain(..) {
            if handle.join().is_err() {
                tracing::warn!("glyph atlas: a worker thread panicked");
            }
        }
    }
}

fn work(
    queue: &Mutex<Receiver<Job>>,
    done: &SyncSender<Finished>,
    mut generator: Box<dyn FieldGenerator + Send>,
) {
    loop {
        let Ok(job) = queue.lock().recv() else {
            return;
        };
        // A panic is reported as the glyph's failure, so the glyph does not stay pending.
        let field = panic::catch_unwind(AssertUnwindSafe(|| job.generate(generator.as_mut())))
            .unwrap_or_else(|_| Err(FieldError("the generator panicked".to_owned())));
        if done.send((job, field)).is_err() {
            return;
        }
    }
}

/// Generates fields with msdfgen.
struct Msdf;

impl FieldGenerator for Msdf {
    fn generate(
        &mut self,
        outline: &Outline,
        request: &FieldRequest,
    ) -> Result<Vec<f32>, FieldError> {
        let contours: Vec<Vec<Edge>> = outline
            .contours
            .iter()
            .map(|contour| contour.iter().map(edge).collect())
            .collect();
        msdf::generate(
            &contours,
            &Projection {
                width: request.width,
                height: request.height,
                range: request.range,
                scale: request.scale,
                translate: request.translate,
            },
        )
        .map_err(|error| FieldError(error.to_string()))
    }
}

fn edge(segment: &Segment) -> Edge {
    match *segment {
        Segment::Line(a, b) => Edge::Linear(a, b),
        Segment::Quadratic(a, b, c) => Edge::Quadratic(a, b, c),
        Segment::Cubic(a, b, c, d) => Edge::Cubic(a, b, c, d),
    }
}

/// Where a glyph is in the atlas, as Lua sees it.
pub struct GlyphPlacement(Placement);

impl IntoLua for GlyphPlacement {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let placement = self.0;
        let table = lua.create_table()?;
        table.set("page", placement.page + 1)?;
        table.set("u0", placement.uv[0])?;
        table.set("v0", placement.uv[1])?;
        table.set("u1", placement.uv[2])?;
        table.set("v1", placement.uv[3])?;
        table.set("left", placement.quad[0])?;
        table.set("top", placement.quad[1])?;
        table.set("width", placement.quad[2])?;
        table.set("height", placement.quad[3])?;
        Ok(Value::Table(table))
    }
}

impl Typed for GlyphPlacement {
    fn luau() -> Type {
        Type::Named("GlyphPlacement")
    }
}

impl Aliased for GlyphPlacement {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "Where a glyph is in the atlas: its page, its texture rectangle from (u0, v0) at the top left to (u1, v1), and its quad in ems from the glyph's origin on the baseline, with its top edge above the baseline.",
        name: <GlyphPlacement as Typed>::luau,
        definition: |_| {
            Type::Record(
                [
                    "page", "u0", "v0", "u1", "v1", "left", "top", "width", "height",
                ]
                .into_iter()
                .map(|name| lunette_luau::Parameter {
                    name,
                    ty: Type::NUMBER,
                })
                .collect(),
            )
        },
    };
}
