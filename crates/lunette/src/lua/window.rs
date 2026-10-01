//! Linux-only: the window handle Lua holds.
//!
//! A handle names a toplevel by identifier and caches what the last snapshot
//! reported about it. Every read refreshes that cache against the frame's
//! snapshot first, so a handle from three frames ago reports this frame's
//! title; once the window is gone it reports the title from the last snapshot
//! that named it.
//!
//! The cache refreshes on read. The prohibition on holding Lua references
//! forces this: Rust cannot walk the handles Lua is keeping, so a walk at
//! frame start is impossible. A soft reload discards the whole Lua state
//! without leaving Rust holding anything.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::protocol::{
    Command, ContentType, FramePacing, FrameRate, OutputId, PixelSize, SinkId, SurfaceId,
    ToplevelStates, WindowId, WindowSnapshot,
};
use mlua::{LuaString, Value};

use crate::{
    control::wire::HandleKind,
    import::formats::Alpha,
    lua::{
        LuaTexture, Output, Session,
        declarations::{Textured, handle},
        pixel_size,
        sink::Sink,
        values::{ContentTypeName, MaybeTexture, PropertyArgument, PropertyMap, StoredProperty},
    },
    properties::{PropertyError, PropertyKey, PropertyValue},
    texture::{TextureRef, TextureUnavailable},
};

/// A mapped toplevel, as Lua holds it.
#[derive(Debug)]
pub struct Window<T> {
    id: WindowId,
    session: Rc<Session<T>>,
    known: RefCell<Known>,
}

impl<T> Window<T> {
    /// Builds a handle from a snapshot entry.
    pub(crate) fn new(session: Rc<Session<T>>, window: &WindowSnapshot) -> Self {
        Self {
            id: window.window,
            session,
            known: RefCell::new(Known::from(window)),
        }
    }

    /// Builds a handle for a window named by an event.
    ///
    /// The window may already be gone. `lunwindowclosed` is dispatched against
    /// the snapshot that no longer holds it, and that absence is the whole
    /// content of the event. The cache is seeded from the frame before in that
    /// case, so the handler is handed a dead handle that still reports the
    /// title and size from before the window disappeared.
    pub(crate) fn for_id(session: Rc<Session<T>>, id: WindowId) -> Self {
        let known = session
            .window(id)
            .as_ref()
            .map_or_else(Known::default, Known::from);
        Self {
            id,
            session,
            known: RefCell::new(known),
        }
    }

    /// Which toplevel this handle names, for the parts of the module that take
    /// a window as an argument.
    pub(crate) const fn id(&self) -> WindowId {
        self.id
    }

    /// Brings the cache up to date, reporting whether the window still exists.
    ///
    /// A window absent from the snapshot has unmapped or its client has
    /// disconnected. In either case the handle is dead: it keeps answering from
    /// the cached values, and every mutation it offers is refused.
    fn refresh(&self) -> bool {
        let snapshot = self.session.snapshot();
        let Some(window) = snapshot
            .windows
            .iter()
            .find(|window| window.window == self.id)
        else {
            return false;
        };

        *self.known.borrow_mut() = Known::from(window);
        true
    }
}

/// The latest cached value of each window field.
///
/// The surface, the sink, and the output are optional for one case: a handle
/// built for a window that no snapshot in reach describes. Everything else has
/// a natural empty value; those three are identifiers, and inventing one would
/// name something belonging to a different window.
#[derive(Clone, Debug, Default)]
struct Known {
    surface: Option<SurfaceId>,
    sink: Option<SinkId>,
    output: Option<OutputId>,
    title: Option<String>,
    app_id: Option<String>,
    size: PixelSize,
    content_type: ContentType,
    /// Carried so a resize can restate them. A configure replaces the whole
    /// state set, so sending one without them takes a window out of maximised
    /// or fullscreen as a side effect of changing its size.
    states: ToplevelStates,
}

impl From<&WindowSnapshot> for Known {
    fn from(window: &WindowSnapshot) -> Self {
        Self {
            surface: Some(window.surface),
            sink: Some(window.sink),
            output: Some(window.output),
            title: window.title.clone(),
            app_id: window.app_id.clone(),
            size: window.size,
            content_type: window.content_type,
            states: window.states.clone(),
        }
    }
}

handle! {
    /// A mapped toplevel. A handle keeps answering once its window has gone,
    /// with the values it cached, and every mutation it offers is refused.
    Window<T: LuaTexture> = HandleKind::Window;

    /// Stable for the window's whole life and across a soft reload, so a table
    /// of per-window state keys by it.
    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    field title(_lua, this) -> Option<String> {
        this.refresh();
        Ok(this.known.borrow().title.clone())
    }

    field appId(_lua, this) -> Option<String> {
        this.refresh();
        Ok(this.known.borrow().app_id.clone())
    }

    /// Pixels, and the size the client last committed, not the size last asked
    /// of it.
    field width(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().size.width)
    }

    field height(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().size.height)
    }

    /// Whether the fourth component of this window's pixels is padding, not
    /// alpha. A client negotiating an X-variant fourcc leaves that component at
    /// a value it wrote, and a caller drawing such a texture forces alpha to
    /// one and does not sample it. False for a window with no texture yet,
    /// because there is nothing to draw.
    field opaque(_lua, this) -> bool { Ok(is_opaque(this)) }

    /// What the client says it draws, as `wp_content_type_v1` reports it. The
    /// report is a hint: adoption is thin, and a client playing video may
    /// report 'none'.
    field contentType(_lua, this) -> ContentTypeName {
        this.refresh();
        let content_type = this.known.borrow().content_type;
        Ok(ContentTypeName(content_type))
    }

    /// Where input for this window goes. Nil only for a handle that has never
    /// seen its window in a snapshot; a dead window still names its sink.
    field sink(_lua, this) -> Option<Sink<T>> {
        this.refresh();
        let sink = this.known.borrow().sink;
        Ok(sink.map(|sink| Sink::window(Rc::clone(&this.session), sink)))
    }

    /// The output the window's client is shown, whose scale and refresh rate
    /// the client lays out against. Nil for a handle that has never seen its
    /// window in a snapshot, and while the output is not in the snapshot.
    field output(_lua, this) -> Option<Output<T>> { Ok(output(this)) }

    /// Which buffer this window's pixels came from: a number that changes
    /// whenever the client commits a new buffer, and zero while it has
    /// committed none or is gone. Comparing it across frames tells whether the
    /// client drew in between.
    field commit(_lua, this) -> u64 { Ok(commit(this)) }

    /// This frame's pixels. False while the client is gone or has committed
    /// nothing. Textures rotate as the client cycles its buffers, so the
    /// texture does not carry across frames.
    method getTexture(lua, this: Textured) -> MaybeTexture { get_texture(lua, this) }

    /// A texture whose identity outlives the frame, at the cost of copying the
    /// surface on every frame it is damaged.
    method stabilize(lua, this) -> MaybeTexture { stabilize(lua, this) }

    /// Asks the client to close the window. The request is not a kill: the
    /// client decides what to do with it.
    method close(_lua, this) -> bool { Ok(close(this)) }

    /// Configures the toplevel to a size in pixels. The client resizes at its
    /// own pace and may settle on a different size.
    method resize(_lua, this, width: f64, height: f64) -> bool { resize(this, width, height) }

    /// A ceiling on how often this window's client is let draw, in hertz. Nil
    /// returns it to unthrottled.
    method setFrameRate(_lua, this, hertz: Option<f64>) -> bool { set_frame_rate(this, hertz) }

    /// Keeps a value for this window across a soft reload. Nil removes the
    /// key.
    method setProperty(_lua, this, key: LuaString, value: PropertyArgument) -> bool {
        set_property(this, &key, &value.0)
    }

    /// What was kept under a key, or nil. Readable on a dead handle; the
    /// mutations are not.
    method getProperty(lua, this, key: LuaString) -> StoredProperty {
        get_property(lua, this, &key)
    }

    /// Every key this window is carrying, so what survived a reload can be
    /// discovered.
    method properties(lua, this) -> PropertyMap { properties(lua, this) }
}

/// `window.output`: the output the window's client is shown.
///
/// Read from the snapshot's assignment rather than from what the client was
/// spawned with, because destroying an output moves its clients to the one
/// every session starts with. A handle for an output the snapshot does not
/// hold would report a mode nothing is showing, so the field is nil then.
fn output<T>(window: &Window<T>) -> Option<Output<T>> {
    window.refresh();
    let id = window.known.borrow().output?;
    let snapshot = window.session.snapshot();
    snapshot
        .outputs
        .iter()
        .find(|output| output.output == id)
        .map(|output| Output::new(Rc::clone(&window.session), output))
}

/// `window.commit`: which buffer the window's texture was made from.
///
/// The ledger's commit counter is shared by every surface and never restarts,
/// so a value is never repeated for a different buffer, and a caller that
/// compares two readings learns whether a new buffer arrived between them.
/// This is the observed commit rate frame pacing reads, which is what tells a
/// video player that sets no content-type hint from an idle window.
fn commit<T>(window: &Window<T>) -> u64 {
    if !window.refresh() {
        return 0;
    }
    let Some(surface) = window.known.borrow().surface else {
        return 0;
    };
    window.session.with_textures(|textures| {
        textures
            .source(surface)
            .map_or(0, |(_, commit)| commit.get())
    })
}

/// `window:getTexture()`: the texture holding this frame's pixels.
///
/// Valid for this frame only. Textures rotate as the client cycles its buffers,
/// so the returned value names a texture that may not exist next frame; call
/// the method again, or take a copy with `window:stabilize()`.
///
/// `false`, and not an error, in two cases, both ordinary: the client is gone,
/// and the client has not committed anything yet.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = texture_ref(window) else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.lookup(reference, generation)))
}

/// `window:stabilize()`: a texture whose identity outlives the frame.
///
/// The default is zero-copy, so `window:getTexture()` hands out whichever
/// buffer the client most recently committed and the texture behind it rotates.
/// This allocates a lunette-owned texture, copies the client's buffer into it
/// on every frame the surface is damaged, and returns the same texture every
/// time.
///
/// The copy is the cost, and it is not small: a full surface per damaged
/// frame, around 3 GB/s for a 4K mirror at 90 Hz. Sampling directly is the
/// default. Use it only when a persistent texture is wanted: a multi-pass
/// shader chain, a screenshot, a mesh with cached bindings, or freezing a
/// window that stopped painting. An idle window costs nothing, because an
/// undamaged surface is not copied.
///
/// A second call returns the same texture, and no further allocation happens.
/// The identity survives the client cycling its buffers; it does not survive
/// the client resizing, because a LÖVR texture's dimensions are fixed when it
/// is created.
///
/// `false` in the same two ordinary cases as `window:getTexture()`: the client
/// is gone, and the client has not committed anything yet.
fn stabilize<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = texture_ref(window) else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.stabilize(reference, generation)))
}

/// `window:close()`: asks the client to close the window.
///
/// The request is not a kill. The client decides what to do with it: a text
/// editor with unsaved work puts up a prompt, and a client may ignore it.
/// The window disappears when the client unmaps it, and
/// `lovr.lunwindowclosed` reports that unmapping. The close call does not
/// report it, so a caller waits for the event.
///
/// `false` when the client is already gone, without raising.
fn close<T>(window: &Window<T>) -> bool {
    if !window.refresh() {
        return false;
    }

    window
        .session
        .queue(Command::CloseWindow { window: window.id });
    true
}

/// `window:resize(width, height)`: configures the toplevel to a new size.
///
/// The call is a request: the client resizes at its own pace, and the new size
/// is visible in `window.width` and `window.height` once the client has
/// committed a buffer at that size. That happens some frames later, and the
/// size may then be a different one, because a client may honour its own
/// minimum or round to a character cell. Nothing here waits for that.
///
/// The dimensions are pixels, and both have to be positive whole numbers; a
/// value that is not is a defect in the caller's maths and raises.
///
/// # Errors
///
/// If the size is not a pair of positive pixel counts.
fn resize<T>(window: &Window<T>, width: f64, height: f64) -> mlua::Result<bool> {
    // Validated before the liveness check, so a bad size is reported whether
    // or not the window is still there.
    let size = pixel_size(width, height, "window size")?;
    if !window.refresh() {
        return Ok(false);
    }

    window.session.queue(Command::ConfigureWindow {
        window: window.id,
        size: Some(size),
        states: window.known.borrow().states.clone(),
    });
    Ok(true)
}

/// `window:setFrameRate(hz)`: how often this window's client is let draw.
///
/// A Wayland client draws only after the compositor answers its frame callback,
/// so this is what a panel outside the view costs. `nil` returns the window to
/// unthrottled, which is where every window starts.
///
/// The rate is a ceiling, and the floor is approximately 1 Hz, not zero: a
/// client answered no frame callbacks at all stops pumping its event loop and
/// stops answering input with it, so a rate below the floor is paced at the
/// floor. `docs/dev/rendering.md` records why. Assigning a rate to a window is
/// policy, which the `@lunette-plugins/pacing` provider and the
/// `desktop/pacing` consumer hold.
///
/// `false` on a dead handle, like every other mutation here.
///
/// # Errors
///
/// If the rate is not a finite positive number.
fn set_frame_rate<T>(window: &Window<T>, hertz: Option<f64>) -> mlua::Result<bool> {
    // Validated before the liveness check, for the reason `resize` validates
    // first: a defect in the caller is worth reporting whether or not the
    // window is still there.
    let pacing = match hertz {
        None => FramePacing::Unthrottled,
        Some(hertz) => FramePacing::Limited(FrameRate::new(hertz).ok_or_else(|| {
            mlua::Error::runtime(format!(
                "lunette: {hertz} is not a frame rate; a rate is a finite number of hertz above \
                 zero, and nil is how a window is returned to unthrottled"
            ))
        })?),
    };

    if !window.refresh() {
        return Ok(false);
    }

    let Some(surface) = window.known.borrow().surface else {
        return Ok(false);
    };

    window
        .session
        .queue(Command::SetFramePacing { surface, pacing });
    Ok(true)
}

/// `window:setProperty(key, value)`: keeps a value for this window across a
/// reload.
///
/// The store lives in Rust, not in Lua, so it survives the Lua state being
/// discarded and re-run. That is its purpose: a pose the user placed by hand,
/// or a size they dragged, is not derivable from any rule, so a reload that
/// lost it would scramble a hand-arranged workspace.
///
/// The value is a number, a string, a boolean, or nil to remove the key.
/// Anything else raises with the key named, because a table would hold Lua
/// values and would not survive the reload this exists to survive. A caller
/// wanting structure encodes it into a string itself.
///
/// `false` on a dead handle, like every other mutation here: the entries of a
/// window that has gone are dropped, so there would be nothing to store into.
///
/// # Errors
///
/// If the key is empty or is not UTF-8, or the value is of a kind a property
/// cannot hold.
fn set_property<T>(window: &Window<T>, key: &LuaString, value: &Value) -> mlua::Result<bool> {
    // Validated before the liveness check, for the reason `resize` validates
    // first: a defect in the caller is worth reporting whether or not the
    // window is still there.
    let key = property_key(key)?;
    let stored = match value {
        Value::Nil => None,
        Value::Boolean(held) => Some(PropertyValue::Boolean(*held)),
        Value::Integer(held) => Some(PropertyValue::number(&key, *held as f64).map_err(raised)?),
        Value::Number(held) => Some(PropertyValue::number(&key, *held).map_err(raised)?),
        Value::String(held) => Some(PropertyValue::Text(text(held, &key)?)),
        other => {
            return Err(raised(PropertyError::Unsupported {
                key,
                kind: other.type_name(),
            }));
        }
    };

    if !window.refresh() {
        return Ok(false);
    }

    window.session.with_properties(|properties| match stored {
        Some(value) => properties.set(window.id, key, value),
        None => {
            properties.clear(window.id, key.as_str());
        }
    });
    Ok(true)
}

/// `window:getProperty(key)`: what was kept under `key`, or nil.
///
/// An absent key is nil, not an error: a configuration asking for a pose it
/// has not placed yet is the ordinary first case.
///
/// Readable on a dead handle; the mutations are not. The reason is the same
/// one that lets a dead handle still report its title: a `lunwindowclosed`
/// handler tidying up after a panel is the caller that reads what the
/// panel stored.
///
/// # Errors
///
/// If the key is empty or is not UTF-8.
fn get_property<T>(
    lua: &mlua::Lua,
    window: &Window<T>,
    key: &LuaString,
) -> mlua::Result<StoredProperty> {
    let key = property_key(key)?;
    window
        .session
        .with_properties(|properties| {
            properties
                .get(window.id, key.as_str())
                .map_or(Ok(Value::Nil), |value| push_property(lua, value))
        })
        .map(StoredProperty)
}

/// `window:properties()`: every key this window is carrying, as a table.
///
/// Present so what survived a reload can be discovered, not guessed at. A
/// configuration that stores under a key it computed, such as a tag name or a
/// monitor identity, cannot enumerate its own keys after the state holding
/// them has gone; without this, the store would be readable only by a
/// configuration that hardcoded every key it ever writes.
///
/// The table is fresh on each call and holds a copy. Nothing here hands Lua a
/// reference into the store.
fn properties<T>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<PropertyMap> {
    let table = lua.create_table()?;
    window.session.with_properties(|properties| {
        for (key, value) in properties.of(window.id) {
            table.set(key.as_str(), push_property(lua, value)?)?;
        }
        Ok(PropertyMap(table))
    })
}

/// Reads the name a property call was made against.
fn property_key(key: &LuaString) -> mlua::Result<PropertyKey> {
    // Not `to_string_lossy`: a later lookup matches the key byte for byte, and
    // replacing an unrepresentable byte would silently merge two distinct keys
    // into one.
    PropertyKey::new(&*key.to_str()?).map_err(raised)
}

/// Reads a string property, refusing bytes that are not text.
fn text(value: &LuaString, key: &PropertyKey) -> mlua::Result<String> {
    value.to_str().map(|text| text.to_owned()).map_err(|_| {
        raised(PropertyError::Unsupported {
            key: key.clone(),
            kind: "string of bytes that are not UTF-8",
        })
    })
}

/// Hands a stored value back to Lua.
fn push_property(lua: &mlua::Lua, value: &PropertyValue) -> mlua::Result<Value> {
    Ok(match value {
        PropertyValue::Boolean(held) => Value::Boolean(*held),
        PropertyValue::Number(held) => Value::Number(*held),
        PropertyValue::Text(held) => Value::String(lua.create_string(held)?),
    })
}

/// Turns a rejected property into the error Lua sees.
fn raised(error: PropertyError) -> mlua::Error {
    mlua::Error::runtime(format!("lunette: {error}"))
}

/// `window.opaque`: whether the texture's fourth component is padding.
///
/// Read from the ledger, not from the snapshot, because it is a property of
/// the buffer the client committed and not of the toplevel. False once the
/// surface is gone, which is the same answer `window:getTexture()` gives then,
/// for the same reason: there is nothing left to draw, so there is nothing to
/// force alpha on.
fn is_opaque<T>(window: &Window<T>) -> bool {
    window.refresh();
    let Some(surface) = window.known.borrow().surface else {
        return false;
    };

    window.session.with_textures(|textures| {
        textures
            .describe(surface)
            .is_some_and(|description| description.alpha == Alpha::Opaque)
    })
}

/// Names this frame's texture for the window, if it has one to name.
///
/// `None` when the client is gone, and when nothing has ever been committed
/// for the window: the two cases Lua is answered `false` for.
fn texture_ref<T>(window: &Window<T>) -> Option<TextureRef> {
    if !window.refresh() {
        return None;
    }

    let surface = window.known.borrow().surface?;
    Some(TextureRef::new(surface, window.session.generation()))
}

/// Turns what the ledger answered into what Lua receives.
///
/// The split is the dead-handle rule. A client exiting between the raycast and
/// the draw is a race, and answering `false` is what keeps it from taking the
/// frame down. A stale handle and a refused copy are not races: the first is a
/// handle cached across a frame, and the second is a copy the device rejected.
/// Each raises, so a caller sees the failure named.
fn answer<T: LuaTexture>(
    lua: &mlua::Lua,
    answered: Result<&T, TextureUnavailable>,
) -> mlua::Result<MaybeTexture> {
    match answered {
        // The push runs while the ledger is borrowed. That is safe here and
        // only here: it pushes a value, and no Lua the caller wrote runs until
        // this returns.
        Ok(texture) => texture.push(lua).map(MaybeTexture),
        Err(TextureUnavailable::Dead | TextureUnavailable::Unknown) => {
            Ok(MaybeTexture(Value::Boolean(false)))
        }
        // Staleness is unreachable through either caller, because the reference
        // is built from the generation it is about to be checked against. The
        // branch still raises, so a future caller holding a reference across a
        // frame sees which failure occurred.
        Err(raised @ (TextureUnavailable::Stale { .. } | TextureUnavailable::CopyFailed)) => {
            Err(mlua::Error::runtime(format!("lunette: {raised}")))
        }
    }
}
