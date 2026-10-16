//! Linux-only: `lunette.glyphAtlas`, the UI toolkit's distance field glyph atlas from `lunette-ui`.
//!
//! Every layout tree in a Lua state shapes with one set of fonts, and the atlas draws glyphs from
//! those fonts by the face handles that `LayoutTree:textLayout` reports. Fields are generated with
//! msdfgen, which LÖVR builds. Pages cross the boundary as RGBA8 strings that the host uploads to
//! LÖVR textures when their revision changes.

use std::{cell::RefCell, rc::Rc};

use lunette_lovr::msdf::{self, Edge, Projection};
use lunette_ui::{
    glyphs::{
        Atlas, AtlasConfig, FieldError, FieldGenerator, FieldRequest, Outline, Placement, Segment,
    },
    layout::SharedFonts,
    text::FaceHandle,
};
use mlua::{IntoLua, Lua, LuaString, UserData, UserDataFields, UserDataMethods, Value};

use crate::lua::{
    declarations::{
        AliasSpec, Aliased, Described, HandleSpec, Surface, Type, Typed, add_fields, handle,
    },
    layout::shared_fonts,
};

/// The atlas every panel in this Lua state draws glyphs from, kept in the state's app data.
#[derive(Clone)]
struct SharedAtlas(Rc<RefCell<Atlas>>);

/// The Lua state's glyph atlas, created on first use.
pub fn glyph_atlas(lua: &Lua) -> GlyphAtlas {
    let atlas = match lua.app_data_ref::<SharedAtlas>() {
        Some(shared) => shared.0.clone(),
        None => {
            let created = Rc::new(RefCell::new(Atlas::new(AtlasConfig::default())));
            lua.set_app_data(SharedAtlas(created.clone()));
            created
        }
    };
    GlyphAtlas {
        atlas,
        fonts: shared_fonts(lua),
    }
}

/// A view of the shared glyph atlas.
pub struct GlyphAtlas {
    atlas: Rc<RefCell<Atlas>>,
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
        doc: "The distance field glyph atlas that every panel in this Lua state draws shaped glyphs from. Pages are square, numbered from 1, and hold RGBA8 multi-channel distance fields to sample with linear filtering and no colour-space conversion. The atlas is not a handle: it never goes dead.",
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
            field pages(_lua, this) -> usize { Ok(borrow(this)?.pages().len()) }
            /// The placement of a glyph from a layout glyph's face and id, generating it on first use. Answers nil for a glyph with no outline, such as a space, and nil with a message for a glyph that could not be generated, which is tried again on the next call.
            method glyph(_lua, this, face: u32, id: u32) -> (Option<GlyphPlacement>, Option<String>) {
                let id = u16::try_from(id).map_err(|_| mlua::Error::runtime(format!("glyph atlas: {id} is not a glyph id")))?;
                glyph(this, face, id)
            }
            /// A page's revision, which advances whenever a glyph is written to it, or nil for a page that does not exist.
            method revision(_lua, this, page: usize) -> Option<u64> {
                Ok(page_of(this, page)?.map(|page| page.revision))
            }
            /// A page's pixels as tightly packed RGBA8 rows, top row first, which `lovr.data.newBlob` wraps for `lovr.data.newImage`, or nil for a page that does not exist.
            method pixels(lua, this, page: usize) -> Option<LuaString> {
                let atlas = borrow(this)?;
                let found = page.checked_sub(1).and_then(|index| atlas.pages().get(index));
                found.map(|page| lua.create_string(&page.pixels)).transpose()
            }
        );
    }
}

fn borrow(this: &GlyphAtlas) -> mlua::Result<std::cell::Ref<'_, Atlas>> {
    this.atlas.try_borrow().map_err(|_| {
        mlua::Error::runtime("glyph atlas: the atlas is in use by a glyph being generated")
    })
}

fn config(this: &GlyphAtlas) -> mlua::Result<AtlasConfig> {
    Ok(borrow(this)?.config())
}

fn page_of(this: &GlyphAtlas, page: usize) -> mlua::Result<Option<lunette_ui::glyphs::Page>> {
    let atlas = borrow(this)?;
    Ok(page
        .checked_sub(1)
        .and_then(|index| atlas.pages().get(index))
        .cloned())
}

fn glyph(
    this: &GlyphAtlas,
    face: u32,
    id: u16,
) -> mlua::Result<(Option<GlyphPlacement>, Option<String>)> {
    let fonts = this.fonts.try_borrow().map_err(|_| {
        mlua::Error::runtime(
            "glyph atlas: the fonts are in use by a layout computation in progress",
        )
    })?;
    let mut atlas = this.atlas.try_borrow_mut().map_err(|_| {
        mlua::Error::runtime("glyph atlas: the atlas is in use by a glyph being generated")
    })?;
    let handle = FaceHandle::new(face);
    match atlas.glyph(handle, id, || fonts.outline(handle, id), &mut Msdf) {
        Ok(placement) => Ok((placement.map(GlyphPlacement), None)),
        Err(error) => Ok((None, Some(error.to_string()))),
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
