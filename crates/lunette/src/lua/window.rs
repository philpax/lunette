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

use lunette_compositor::protocol::{PixelSize, SinkId, SurfaceId, WindowId, WindowSnapshot};
use mlua::{UserData, UserDataFields, UserDataMethods, Value};

use crate::{
    lua::{LuaTexture, Session, sink::Sink},
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
}

impl From<&WindowSnapshot> for Known {
    fn from(window: &WindowSnapshot) -> Self {
        Self {
            surface: Some(window.surface),
            sink: Some(window.sink),
            title: window.title.clone(),
            app_id: window.app_id.clone(),
            size: window.size,
        }
    }
}

impl<T: LuaTexture> UserData for Window<T> {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        // Stable for the window's whole life, so it is the identifier a Lua
        // table of per-window state is keyed by, and what `lunctl` serialises
        // a handle as.
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
            Ok(sink.map(|sink| Sink::new(Rc::clone(&window.session), sink)))
        });
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("getTexture", |lua, window, ()| get_texture(lua, window));
    }
}

/// `window:getTexture()`: the texture holding this frame's pixels.
///
/// Valid for this frame only. Textures rotate as the client cycles its buffers,
/// so the returned value names something that may not exist next frame; call it
/// again rather than caching it, or take a copy with `surface:stabilize()`.
///
/// `false` rather than an error in two cases, both of which are ordinary: the
/// client is gone, and the client has not committed anything yet.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, window: &Window<T>) -> mlua::Result<Value> {
    if !window.refresh() {
        return Ok(Value::Boolean(false));
    }

    let Some(surface) = window.known.borrow().surface else {
        return Ok(Value::Boolean(false));
    };

    let generation = window.session.generation();
    let reference = TextureRef::new(surface, generation);

    window.session.with_textures(|textures| {
        match textures.lookup(reference, generation) {
            // The push runs while the ledger is borrowed. That is safe here and
            // only here: it pushes a value, and no Lua the caller wrote runs
            // until this returns.
            Ok(texture) => texture.push(lua),
            Err(TextureUnavailable::Dead | TextureUnavailable::Unknown) => {
                Ok(Value::Boolean(false))
            }
            // Unreachable through this path, because the reference was built
            // from the generation it is about to be checked against. Stated
            // rather than assumed, so that a future caller that holds a
            // reference across a frame is told what it did.
            Err(stale @ TextureUnavailable::Stale { .. }) => {
                Err(mlua::Error::runtime(format!("lunette: {stale}")))
            }
        }
    })
}
