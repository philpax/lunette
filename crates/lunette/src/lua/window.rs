//! Linux-only: the window handle Lua holds.
//!
//! A handle names a toplevel by identifier and caches its last known state.
//! Every read refreshes that cache against the frame's snapshot. A dead handle
//! continues to report the last state it knew.
//!
//! Refreshing on read avoids retaining Lua references. Rust does not track which
//! handles Lua keeps, so it cannot refresh them all at frame start; soft reload
//! discards the Lua state without Rust retaining its values.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::protocol::{
    Command, ContentType, FramePacing, FrameRate, PixelSize, SinkId, SurfaceId, ToplevelStates,
    WindowId, WindowSnapshot,
};
use mlua::{LuaString, Value};

use crate::{
    control::wire::HandleKind,
    import::formats::Alpha,
    lua::{
        LuaTexture, Session,
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
    /// Builds a handle from the snapshot entry it was found in.
    pub(crate) fn new(session: Rc<Session<T>>, window: &WindowSnapshot) -> Self {
        Self {
            id: window.window,
            session,
            known: RefCell::new(Known::from(window)),
        }
    }

    /// Builds a handle for a window named by an event.
    ///
    /// The window may already be gone: `lunwindowclosed` is dispatched against
    /// the snapshot that no longer holds it, which is the whole content of the
    /// event. The cache is seeded from the frame before in that case, so the
    /// handler is handed a dead handle that still reports the title and size
    /// the window had.
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
    /// a window as an argument rather than returning one.
    pub(crate) const fn id(&self) -> WindowId {
        self.id
    }

    /// Brings the cache up to date, reporting whether the window still exists.
    ///
    /// A window absent from the snapshot was unmapped or its client has
    /// disconnected. Either way the handle is dead: it keeps answering, with
    /// what it last knew, and every mutation it offers is refused.
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

/// The last thing each field of a window was known to be.
///
/// The surface and the sink are optional for one case: a handle built for a
/// window that no snapshot in reach describes. Everything else has a natural
/// empty value; those two are identifiers, and inventing one would name a
/// surface belonging to somebody else.
#[derive(Clone, Debug, Default)]
struct Known {
    surface: Option<SurfaceId>,
    sink: Option<SinkId>,
    title: Option<String>,
    app_id: Option<String>,
    size: PixelSize,
    content_type: ContentType,
    /// Carried so that a resize can restate them. A configure replaces the
    /// state set wholesale, so sending one without them would take a window out
    /// of maximised or fullscreen as a side effect of changing its size.
    states: ToplevelStates,
}

impl From<&WindowSnapshot> for Known {
    fn from(window: &WindowSnapshot) -> Self {
        Self {
            surface: Some(window.surface),
            sink: Some(window.sink),
            title: window.title.clone(),
            app_id: window.app_id.clone(),
            size: window.size,
            content_type: window.content_type,
            states: window.states.clone(),
        }
    }
}

handle! {
    /// A mapped toplevel; dead handles retain their last-known state and reject mutations.
    Window<T: LuaTexture> = HandleKind::Window;

    /// The window's stable identifier, including across soft reloads.
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

    /// The width in pixels of the last buffer committed by the client.
    field width(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().size.width)
    }

    field height(_lua, this) -> u32 {
        this.refresh();
        Ok(this.known.borrow().size.height)
    }

    /// Whether the texture's fourth component is padding rather than alpha.
    field opaque(_lua, this) -> bool { Ok(is_opaque(this)) }

    /// The content type reported by the client, as a hint.
    field contentType(_lua, this) -> ContentTypeName {
        this.refresh();
        let content_type = this.known.borrow().content_type;
        Ok(ContentTypeName(content_type))
    }

    /// The sink receiving input for this window, or nil if it has never appeared.
    field sink(_lua, this) -> Option<Sink<T>> {
        this.refresh();
        let sink = this.known.borrow().sink;
        Ok(sink.map(|sink| Sink::window(Rc::clone(&this.session), sink)))
    }

    /// This frame's pixels, or false if the client is gone or has no committed buffer.
    method getTexture(lua, this: Textured) -> MaybeTexture { get_texture(lua, this) }

    /// A persistent texture updated when the surface is damaged.
    method stabilize(lua, this) -> MaybeTexture { stabilize(lua, this) }

    /// Requests that the client close the window.
    method close(_lua, this) -> bool { Ok(close(this)) }

    /// Requests a new client size in pixels.
    method resize(_lua, this, width: f64, height: f64) -> bool { resize(this, width, height) }

    /// Sets the client's frame-rate ceiling in hertz; nil removes the limit.
    method setFrameRate(_lua, this, hertz: Option<f64>) -> bool { set_frame_rate(this, hertz) }

    /// Stores a scalar value for this window across soft reloads; nil removes it.
    method setProperty(_lua, this, key: LuaString, value: PropertyArgument) -> bool {
        set_property(this, &key, &value.0)
    }

    /// The value stored under a key, or nil.
    method getProperty(lua, this, key: LuaString) -> StoredProperty {
        get_property(lua, this, &key)
    }

    /// The keys stored for this window.
    method properties(lua, this) -> PropertyMap { properties(lua, this) }
}

/// Returns this frame's client texture, or false if unavailable. The texture is
/// valid only for this frame.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = texture_ref(window) else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.lookup(reference, generation)))
}

/// Returns a texture whose identity survives buffer rotation, or false if no
/// client texture exists.
fn stabilize<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = texture_ref(window) else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.stabilize(reference, generation)))
}

/// Requests that the client close the window; returns false if it is already gone.
fn close<T>(window: &Window<T>) -> bool {
    if !window.refresh() {
        return false;
    }

    window
        .session
        .queue(Command::CloseWindow { window: window.id });
    true
}

/// Requests a new positive whole-pixel client size; the client may apply a different size asynchronously.
///
/// # Errors
///
/// If either dimension is not a positive whole number.
fn resize<T>(window: &Window<T>, width: f64, height: f64) -> mlua::Result<bool> {
    // Validated before the liveness check, so a bad size is reported whether or
    // not the window happens to still be there.
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
/// The rate is a ceiling and the floor is approximately 1 Hz, not zero: a
/// client answered no frame callbacks at all stops pumping its event loop and
/// stops answering input with it, so a rate below the floor is paced at the
/// floor instead. `docs/rendering.md` records why, and this is the mechanism —
/// which window deserves which rate is policy, and belongs in `mullion`.
///
/// `false` on a dead handle, like every other mutation here.
///
/// # Errors
///
/// If the rate is not a finite positive number.
fn set_frame_rate<T>(window: &Window<T>, hertz: Option<f64>) -> mlua::Result<bool> {
    // Validated before the liveness check, for the reason `resize` validates
    // first: a defect in the caller is worth reporting whether or not the
    // window happened to still be there.
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
/// The store lives in Rust rather than in Lua, so it survives the Lua state
/// being discarded and re-run. That is what it is for: a pose the user placed by
/// hand, or a size they dragged, is not derivable from any rule, so a reload
/// that lost it would scramble a hand-arranged workspace.
///
/// The value is a number, a string, a boolean, or nil to remove the key.
/// Anything else raises with the key named, because a table would hold Lua
/// values and so would not survive the reload this exists to survive. A caller
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
    // window happened to still be there.
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
/// An absent key is nil rather than an error: a configuration asking for a pose
/// it has not placed yet is the ordinary first case.
///
/// Readable on a dead handle, unlike the mutations, and for the same reason a
/// dead handle still reports its title — a `lunwindowclosed` handler tidying up
/// after a panel is exactly who wants to read what the panel stored.
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
/// Present so that what survived a reload can be discovered rather than guessed
/// at. A configuration that stores under a key it computed — a tag name, a
/// monitor identity — cannot enumerate its own keys after the state holding them
/// has gone, so without this the store would only be readable by a configuration
/// that hardcoded every key it ever writes.
///
/// A fresh table each call, holding a copy. Nothing here hands Lua a reference
/// into the store.
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
    // Not `to_string_lossy`: a key is what a later lookup is spelled with, and
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
/// Read from the ledger rather than from the snapshot, because it is a property
/// of the buffer the client committed and not of the toplevel. False once the
/// surface is gone, which is the same answer `window:getTexture()` gives then
/// and for the same reason: there is nothing left to draw, so there is nothing
/// to force alpha on.
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
/// `None` when the client is gone, and when nothing has ever been committed for
/// the window — the two cases Lua is answered `false` for.
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
/// handle cached across a frame, and the second is the device saying no, and
/// silence would leave either undiagnosed.
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
        // is built from the generation it is about to be checked against.
        // Stated rather than assumed, so that a future caller holding one across
        // a frame is told what it did.
        Err(raised @ (TextureUnavailable::Stale { .. } | TextureUnavailable::CopyFailed)) => {
            Err(mlua::Error::runtime(format!("lunette: {raised}")))
        }
    }
}
