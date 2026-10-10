//! Linux-only: implements drag handles for Lua.
//!
//! A drag is what a client started from a press of a seat's pointer, and
//! `seat.drag` returns one while it lasts. Its icon is a surface, so the icon's
//! texture comes from the ledger as a window's does, and is valid for the
//! current frame only unless stabilized. The handle names one drag: when the
//! drag drops or is cancelled the handle is dead, and the seat's next drag is
//! another handle.

use std::{cell::RefCell, rc::Rc};

use lunette_compositor::protocol::{DragIcon, DragId, DragSnapshot, SeatId};
use mlua::Value;

use crate::{
    control::wire::HandleKind,
    import::formats::Alpha,
    lua::{LuaTexture, Session, declarations::handle, values::MaybeTexture, window::answer},
    texture::TextureRef,
};

/// A drag in progress, as Lua holds it.
#[derive(Debug)]
pub struct Drag<T> {
    id: DragId,
    seat: SeatId,
    session: Rc<Session<T>>,
    /// The icon the snapshot last reported, kept so a dead handle answers
    /// with its last values.
    icon: RefCell<Option<DragIcon>>,
}

/// Two handles are equal when they name the same drag.
impl<T> PartialEq for Drag<T> {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl<T> Drag<T> {
    pub(crate) fn new(session: Rc<Session<T>>, seat: SeatId, drag: &DragSnapshot) -> Self {
        Self {
            id: drag.drag,
            seat,
            session,
            icon: RefCell::new(drag.icon.clone()),
        }
    }

    /// Brings the cached icon up to date, reporting whether the drag is
    /// still under way.
    fn refresh(&self) -> bool {
        let snapshot = self.session.snapshot();
        let Some(drag) = snapshot
            .seats
            .iter()
            .find(|seat| seat.seat == self.seat)
            .and_then(|seat| seat.drag.as_ref())
            .filter(|drag| drag.drag == self.id)
        else {
            return false;
        };
        self.icon.replace(drag.icon.clone());
        true
    }

    /// Reads the cached icon after refreshing it.
    fn icon<R>(&self, read: impl FnOnce(&DragIcon) -> R) -> Option<R> {
        self.refresh();
        self.icon.borrow().as_ref().map(read)
    }

    /// Names this frame's icon texture, or `None` when the drag has ended or
    /// has no icon with content.
    fn texture_ref(&self) -> Option<TextureRef> {
        if !self.refresh() {
            return None;
        }
        let surface = self.icon.borrow().as_ref()?.surface;
        Some(TextureRef::new(surface, self.session.generation()))
    }
}

handle! {
    /// A drag a client started from a press of a seat's pointer, carrying the
    /// icon that follows the pointer. The handle is dead once the drag drops or
    /// is cancelled, and answers with its last values.
    Drag<T: LuaTexture> = HandleKind::Drag;

    /// Distinguishes this drag from the seat's earlier and later ones.
    field id(_lua, this) -> u64 { Ok(this.id.get()) }

    field dead(_lua, this) -> bool { Ok(!this.refresh()) }

    /// The icon's width in surface coordinates, or zero when the drag has no
    /// icon with content.
    field width(_lua, this) -> u32 { Ok(this.icon(|icon| icon.size.width).unwrap_or(0)) }

    /// The icon's height in surface coordinates, or zero when the drag has no
    /// icon with content.
    field height(_lua, this) -> u32 { Ok(this.icon(|icon| icon.size.height).unwrap_or(0)) }

    /// How far right of the pointer the icon's left edge sits, in surface
    /// coordinates. Negative places it left of the pointer.
    field x(_lua, this) -> i32 { Ok(this.icon(|icon| icon.offset.x).unwrap_or(0)) }

    /// How far below the pointer the icon's top edge sits, in surface
    /// coordinates. Negative places it above the pointer.
    field y(_lua, this) -> i32 { Ok(this.icon(|icon| icon.offset.y).unwrap_or(0)) }

    /// Whether the fourth pixel component of the icon is padding, so a
    /// consumer treats it as opaque. False until a texture exists.
    field opaque(_lua, this) -> bool { Ok(is_opaque(this)) }

    /// This frame's icon pixels, or `false` when the drag has ended or has no
    /// icon with content. The texture rotates with the client's buffers, so do
    /// not cache it across frames.
    method getTexture(lua, this) -> MaybeTexture { get_texture(lua, this) }

    /// The part of the icon's texture the icon shows, as `x, y, width, height`
    /// fractions of the texture's size.
    method getSourceCrop(_lua, this) -> (f64, f64, f64, f64) { Ok(source_crop(this)) }

    /// Returns a persistent copy of the icon's texture, updated whenever the
    /// icon is damaged.
    method stabilize(lua, this) -> MaybeTexture { stabilize(lua, this) }
}

/// Returns this frame's icon texture, or `false` when there is none to name.
fn get_texture<T: LuaTexture>(lua: &mlua::Lua, drag: &Drag<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = drag.texture_ref() else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };
    let generation = drag.session.generation();
    drag.session
        .with_textures(|textures| answer(lua, textures.lookup(reference, generation)))
}

/// Returns a persistent copy of the icon texture, which keeps its identity
/// while the client's buffers rotate.
fn stabilize<T: LuaTexture>(lua: &mlua::Lua, drag: &Drag<T>) -> mlua::Result<MaybeTexture> {
    let Some(reference) = drag.texture_ref() else {
        return Ok(MaybeTexture(Value::Boolean(false)));
    };
    let generation = drag.session.generation();
    drag.session
        .with_textures(|textures| answer(lua, textures.stabilize(reference, generation)))
}

/// The icon's source crop as a rectangle, the whole texture without an icon.
fn source_crop<T>(drag: &Drag<T>) -> (f64, f64, f64, f64) {
    drag.icon(|icon| {
        let crop = icon.source_crop;
        (
            crop.left(),
            crop.top(),
            crop.right() - crop.left(),
            crop.bottom() - crop.top(),
        )
    })
    .unwrap_or((0.0, 0.0, 1.0, 1.0))
}

/// Whether the icon's current buffer has no alpha channel.
fn is_opaque<T>(drag: &Drag<T>) -> bool {
    let Some(surface) = drag.icon(|icon| icon.surface) else {
        return false;
    };
    drag.session.with_textures(|textures| {
        textures
            .describe(surface)
            .is_some_and(|description| description.alpha == Alpha::Opaque)
    })
}
