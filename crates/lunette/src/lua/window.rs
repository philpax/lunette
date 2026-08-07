//! Linux-only: the window handle Lua holds.
//!
//! A handle names a toplevel by identifier and caches what the last snapshot
//! said about it. Every read refreshes that cache against the frame's snapshot
//! first, so a handle picked up three frames ago reports this frame's title —
//! and once the window is gone it reports the last title it had, rather than
//! nothing.
//!
//! Refreshing on read, rather than at frame start, is what the prohibition on
//! holding Lua references costs and buys. Rust does not know which handles Lua
//! is keeping, so it cannot walk them at frame start; in exchange, a soft
//! reload can throw the whole Lua state away without leaving Rust holding
//! anything.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::protocol::{
    Command, PixelSize, SinkId, SurfaceId, ToplevelStates, WindowId, WindowSnapshot,
};
use mlua::{UserData, UserDataFields, UserDataMethods, Value};

use crate::{
    control::{serialise::HANDLE_METAFIELD, wire::HandleKind},
    import::formats::Alpha,
    lua::{LuaTexture, Session, pixel_size, sink::Sink},
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

    /// Builds a handle for a window named by an event rather than found in a
    /// list.
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
    /// A window absent from the snapshot has unmapped or its client has
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
            states: window.states.clone(),
        }
    }
}

impl<T: LuaTexture> UserData for Window<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        // How `lunctl` recognises a handle. A metafield rather than a field,
        // so it is invisible to `pairs` and to ordinary indexing; the
        // serialiser reads it off the metatable and refuses any other
        // userdata, which is how a LÖVR `Texture` comes to be reported rather
        // than stringified.
        fields.add_meta_field(HANDLE_METAFIELD, HandleKind::Window.as_str());

        // Stable for the window's whole life, so it is the identifier a Lua
        // table of per-window state is keyed by, and what `lunctl` serialises
        // a handle as. A soft reload does not restart the compositor thread and
        // so does not change it, which is what lets a configuration re-associate
        // with its windows — and their properties — after one.
        fields.add_field_method_get("id", |_, window| Ok(window.id.get()));

        fields.add_field_method_get("dead", |_, window| Ok(!window.refresh()));

        fields.add_field_method_get("title", |_, window| {
            window.refresh();
            Ok(window.known.borrow().title.clone())
        });

        fields.add_field_method_get("appId", |_, window| {
            window.refresh();
            Ok(window.known.borrow().app_id.clone())
        });

        // Pixels, and the size the client last committed rather than the size
        // last asked of it. A panel converts a ray hit into a pixel coordinate
        // with these, so they are part of the public surface and are recorded
        // in `docs/lua-api.md`.
        fields.add_field_method_get("width", |_, window| {
            window.refresh();
            Ok(window.known.borrow().size.width)
        });

        fields.add_field_method_get("height", |_, window| {
            window.refresh();
            Ok(window.known.borrow().size.height)
        });

        // Whether the fourth component of this window's pixels is padding
        // rather than alpha, which a client negotiating an X-variant fourcc —
        // `XR24` is the commonest opaque format there is — leaves at whatever
        // it happened to write, usually zero. A caller drawing such a texture
        // forces alpha to one instead of sampling it; `docs/rendering.md`
        // records how, and `etc/xdg/lunette/main.lua` does it.
        //
        // False for a window with no texture yet, which is the answer that
        // makes an unanswerable question harmless: there is nothing to draw.
        fields.add_field_method_get("opaque", |_, window| Ok(is_opaque(window)));

        // Where input for this window goes. A fresh handle each read: it holds
        // an identifier and an `Rc`, so there is nothing to gain by caching one
        // and a stale cache to lose.
        //
        // Nil only for a handle that has never seen its window in a snapshot,
        // which a `lunwindowclosed` handler can produce by holding on to the
        // payload for a frame too long. A dead window still names its sink.
        fields.add_field_method_get("sink", |_, window| {
            window.refresh();
            let sink = window.known.borrow().sink;
            Ok(sink.map(|sink| Sink::window(Rc::clone(&window.session), sink)))
        });
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("getTexture", |lua, window, ()| get_texture(lua, window));
        methods.add_method("stabilize", |lua, window, ()| stabilize(lua, window));
        methods.add_method("close", |_, window, ()| Ok(close(window)));
        methods.add_method("resize", |_, window, (width, height): (f64, f64)| {
            resize(window, width, height)
        });
        methods.add_method(
            "setProperty",
            |_, window, (key, value): (mlua::LuaString, Value)| set_property(window, &key, &value),
        );
        methods.add_method("getProperty", |lua, window, key: mlua::LuaString| {
            get_property(lua, window, &key)
        });
        methods.add_method("properties", |lua, window, ()| properties(lua, window));
    }
}

/// `window:getTexture()`: the texture holding this frame's pixels.
///
/// Valid for this frame only. Textures rotate as the client cycles its buffers,
/// so the returned value names something that may not exist next frame; call it
/// again rather than caching it, or take a copy with `window:stabilize()`.
///
/// `false` rather than an error in two cases, both of which are ordinary: the
/// client is gone, and the client has not committed anything yet.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<Value> {
    let Some(reference) = texture_ref(window) else {
        return Ok(Value::Boolean(false));
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
/// This allocates a lunette-owned texture instead and copies the client's
/// buffer into it on every frame the surface is damaged, so the same texture
/// comes back every time.
///
/// That copy is the price, and it is not small: a full surface per damaged
/// frame, around 3 GB/s for a 4K mirror at 90 Hz. It is why sampling directly
/// is the default. Reach for this when a persistent texture is genuinely
/// wanted — a multi-pass shader chain, a screenshot, a mesh with cached
/// bindings, or freezing a window that stopped painting — and not otherwise. An
/// idle window costs nothing, because an undamaged surface is not copied.
///
/// A second call returns the same texture rather than allocating another. The
/// identity survives the client cycling its buffers, which is the whole point;
/// it does not survive the client resizing, because a LÖVR texture's dimensions
/// are fixed when it is created.
///
/// `false` in the same two ordinary cases as `window:getTexture()`: the client
/// is gone, and the client has not committed anything yet.
fn stabilize<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<Value> {
    let Some(reference) = texture_ref(window) else {
        return Ok(Value::Boolean(false));
    };

    let generation = window.session.generation();
    window
        .session
        .with_textures(|textures| answer(lua, textures.stabilize(reference, generation)))
}

/// `window:close()`: asks the client to close the window.
///
/// A request, and not a kill. The client decides what to do with it: a text
/// editor with unsaved work puts up a prompt, and a client is free to ignore it
/// entirely. The window disappears when the client unmaps it, which is reported
/// as `lovr.lunwindowclosed` — watch for that rather than assuming this did it.
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
/// A request as well. The client resizes at its own pace and the new size is
/// visible in `window.width` and `window.height` once it has committed a buffer
/// at it, which is some frames later and may be a different size entirely: a
/// client is free to honour its own minimum, or to round to a character cell.
/// Nothing here waits for that.
///
/// The dimensions are pixels and both have to be positive whole numbers; a
/// value that is not is a defect in the caller's maths and raises.
///
/// # Errors
///
/// If the size is not a pair of positive pixel counts.
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
fn set_property<T>(window: &Window<T>, key: &mlua::LuaString, value: &Value) -> mlua::Result<bool> {
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
    key: &mlua::LuaString,
) -> mlua::Result<Value> {
    let key = property_key(key)?;
    window.session.with_properties(|properties| {
        properties
            .get(window.id, key.as_str())
            .map_or(Ok(Value::Nil), |value| push_property(lua, value))
    })
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
fn properties<T>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<mlua::Table> {
    let table = lua.create_table()?;
    window.session.with_properties(|properties| {
        for (key, value) in properties.of(window.id) {
            table.set(key.as_str(), push_property(lua, value)?)?;
        }
        Ok(table)
    })
}

/// Reads the name a property call was made against.
fn property_key(key: &mlua::LuaString) -> mlua::Result<PropertyKey> {
    // Not `to_string_lossy`: a key is what a later lookup is spelled with, and
    // replacing an unrepresentable byte would silently merge two distinct keys
    // into one.
    PropertyKey::new(&*key.to_str()?).map_err(raised)
}

/// Reads a string property, refusing bytes that are not text.
fn text(value: &mlua::LuaString, key: &PropertyKey) -> mlua::Result<String> {
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
) -> mlua::Result<Value> {
    match answered {
        // The push runs while the ledger is borrowed. That is safe here and
        // only here: it pushes a value, and no Lua the caller wrote runs until
        // this returns.
        Ok(texture) => texture.push(lua),
        Err(TextureUnavailable::Dead | TextureUnavailable::Unknown) => Ok(Value::Boolean(false)),
        // Staleness is unreachable through either caller, because the reference
        // is built from the generation it is about to be checked against.
        // Stated rather than assumed, so that a future caller holding one across
        // a frame is told what it did.
        Err(raised @ (TextureUnavailable::Stale { .. } | TextureUnavailable::CopyFailed)) => {
            Err(mlua::Error::runtime(format!("lunette: {raised}")))
        }
    }
}
