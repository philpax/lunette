//! Linux-only: implements window handles for Lua.
//!
//! Handles refresh their cached values from each frame snapshot. When a window closes, a handle
//! retains the last snapshot values and refuses mutations. Rust stores no Lua references, so Lua
//! state reloads do not leave stale handles in native code.

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

    /// Builds a handle for an event-named window, including a closed window.
    ///
    /// Closed-window handles use the previous snapshot to preserve last-known title and size.
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

/// Cached values for a window. Resource identifiers are absent when no available snapshot describes
/// the window.
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

    /// Stable across frames and soft reloads. Per-window properties use this identifier.
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

    /// Whether the fourth pixel component is padding. Clients using an X-variant format do not
    /// provide alpha; consumers must treat the component as opaque. Returns false until a texture
    /// exists.
    field opaque(_lua, this) -> bool { Ok(is_opaque(this)) }

    /// The content type reported by `wp_content_type_v1`. The protocol value is a hint; clients may
    /// report `none` while playing video.
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

    /// The output assigned to the window. Returns `nil` if no snapshot has described the window or
    /// its output.
    field output(_lua, this) -> Option<Output<T>> { Ok(output(this)) }

    /// A counter that changes when the client commits a buffer. Returns zero before the first
    /// commit or after the window closes.
    field commit(_lua, this) -> u64 { Ok(commit(this)) }

    /// This frame's pixels, or `false` when the client is gone or has committed no buffer. The
    /// texture may change when the client cycles buffers, so callers must not cache it across
    /// frames.
    method getTexture(lua, this: Textured) -> MaybeTexture { get_texture(lua, this) }

    /// Returns a persistent texture copy, updated whenever the surface is damaged.
    method stabilize(lua, this) -> MaybeTexture { stabilize(lua, this) }

    /// Requests that the client close the window. The client controls whether it unmaps.
    method close(_lua, this) -> bool { Ok(close(this)) }

    /// Requests a pixel size. The client may commit a different size.
    method resize(_lua, this, width: f64, height: f64) -> bool { resize(this, width, height) }

    /// Sets the client's frame-rate ceiling in hertz. `nil` restores unthrottled pacing.
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

/// Returns the output assigned to the window in the current snapshot.
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

/// Returns the texture ledger's buffer commit counter for this window.
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

/// Returns the current buffer texture, or `false` when the window is gone or has no committed
/// buffer.
///
/// The texture is valid for the current frame only. Use `window:stabilize()` to retain a copy
/// across frames.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = texture_ref(window) else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.lookup(reference, generation)))
}

/// Returns a persistent copy of the window texture, updated when the surface is damaged.
///
/// The copy preserves texture identity across buffer rotations but not window resizes, because LÖVR
/// texture dimensions are fixed at creation. Copying a damaged surface costs bandwidth; undamaged
/// surfaces are not copied. Returns `false` when the window is gone or has no committed buffer.
fn stabilize<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = texture_ref(window) else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.stabilize(reference, generation)))
}

/// Requests that the client close the window.
///
/// The request does not terminate the client. The window remains until it unmaps, which
/// `lovr.lunwindowclosed` reports. Returns `false` if the window is already gone.
fn close<T>(window: &Window<T>) -> bool {
    if !window.refresh() {
        return false;
    }

    window
        .session
        .queue(Command::CloseWindow { window: window.id });
    true
}

/// Requests a new toplevel size in pixels.
///
/// The client controls when and what size it commits. `window.width` and `window.height` change
/// only after a buffer commit.
///
/// # Errors
///
/// Returns an error unless both dimensions are positive whole pixel counts.
fn resize<T>(window: &Window<T>, width: f64, height: f64) -> mlua::Result<bool> {
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

/// Sets a ceiling on the client's frame callback rate.
///
/// The rate has an approximate 1 Hz floor because a client with no frame callbacks stops processing
/// input. `nil` restores unthrottled pacing. Returns `false` when the window is gone.
///
/// # Errors
///
/// Returns an error unless the rate is finite and positive.
fn set_frame_rate<T>(window: &Window<T>, hertz: Option<f64>) -> mlua::Result<bool> {
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

/// Stores a window property that survives Lua state reloads.
///
/// Values may be numbers, strings, or booleans. `nil` removes the key. Tables are rejected because
/// they retain Lua values that cannot survive reloads. Callers can encode structured data as
/// strings.
/// Returns `false` for a dead handle.
///
/// # Errors
///
/// Returns an error for an empty or non-UTF-8 key, an unsupported value, or a non-finite number.
fn set_property<T>(window: &Window<T>, key: &LuaString, value: &Value) -> mlua::Result<bool> {
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

/// Returns the stored value, or `nil` when the key is absent.
///
/// Properties remain readable on dead handles so `lunwindowclosed` handlers can inspect them.
///
/// # Errors
///
/// Returns an error for an empty or non-UTF-8 key.
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

/// Returns a fresh table containing copies of all stored properties for this window.
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
    // Preserve key bytes exactly; lossy conversion could merge distinct keys.
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

/// Returns the alpha interpretation recorded for the current buffer.
///
/// Opacity belongs to the committed buffer, not the window snapshot. Returns `false` when no buffer
/// is available.
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
