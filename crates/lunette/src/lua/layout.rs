//! `lunette.newLayoutTree`: the UI toolkit's layout and text mechanism, from `lunette-ui`.
//!
//! A tree is a plain userdata, not a handle: Lua creates it, it has no compositor counterpart,
//! and it needs no snapshot or dead-handle semantics. Changes arrive as one batch per commit and
//! layouts come back as one flat array, because every value crossing the boundary allocates.

mod parse;

use std::{cell::RefCell, rc::Rc};

use lunette_luau::Parameter;
use lunette_ui::{
    layout::{
        Available, Input, NodeId, ScriptContext, ScriptError, Scripts, SharedFonts, Size,
        Transform, Tree,
    },
    text::Fonts,
};
use mlua::{
    FromLua, Function, IntoLua, Lua, Table, UserData, UserDataFields, UserDataMethods, Value,
};

use crate::lua::declarations::{
    AliasSpec, Aliased, Described, HandleSpec, Surface, Type, Typed, add_fields, handle,
};

/// The fonts every tree in this Lua state shapes with, kept in the state's app data.
#[derive(Clone)]
pub struct LayoutFonts(pub SharedFonts);

/// Creates a tree, building the font database on first use if the host has not supplied one.
pub fn new_layout_tree(lua: &Lua) -> mlua::Result<LayoutTree> {
    Ok(LayoutTree(RefCell::new(Tree::new(shared_fonts(lua)))))
}

/// Adds the faces in a font file to the fonts every tree in this Lua state shapes with.
pub fn load_layout_font(lua: &Lua, data: &mlua::LuaString) -> mlua::Result<usize> {
    let fonts = shared_fonts(lua);
    let mut fonts = fonts.try_borrow_mut().map_err(|_| {
        mlua::Error::runtime(
            "layout: loadLayoutFont: the fonts are in use by a computation in progress",
        )
    })?;
    Ok(fonts.add(data.as_bytes().to_vec()))
}

pub(crate) fn shared_fonts(lua: &Lua) -> SharedFonts {
    if let Some(fonts) = lua.app_data_ref::<LayoutFonts>() {
        return fonts.0.clone();
    }
    let fonts = Rc::new(RefCell::new(Fonts::with_system(std::iter::empty())));
    lua.set_app_data(LayoutFonts(fonts.clone()));
    fonts
}

/// A UI layout tree.
pub struct LayoutTree(RefCell<Tree>);

impl PartialEq for LayoutTree {
    fn eq(&self, other: &Self) -> bool {
        std::ptr::eq(self, other)
    }
}

impl Typed for LayoutTree {
    fn luau() -> Type {
        Type::Named("LayoutTree")
    }
}

impl UserData for LayoutTree {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        add_fields(fields);
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        crate::lua::declarations::add_methods(methods);
    }
}

impl Described for LayoutTree {
    const HANDLE: HandleSpec = HandleSpec {
        name: "LayoutTree",
        doc: "A UI layout tree, laid out in metres. The host assigns node ids. A tree is not a handle: it lives until it is collected, and it never goes dead.",
    };
    const KIND: Option<crate::control::wire::HandleKind> = None;

    fn describe(surface: &mut impl Surface<Self>) {
        handle!(@items surface,
            /// The number of nodes.
            field size(_lua, this) -> usize { Ok(borrow(this)?.len()) }
            /// Applies one commit's changes in order. The batch is checked first, so a rejected batch changes nothing.
            method apply(_lua, this, changes: LayoutChanges) -> () {
                let mut tree = borrow_mut(this)?;
                tree.apply(changes.0).map_err(|error| mlua::Error::runtime(error.to_string()))
            }
            /// Lays out the tree under `root` in the space offered, unbounded along an axis given as nil. Answers the nodes whose placement changed, as consecutive id, u, v, width, height, rotation, and scale values, and the callbacks that failed.
            method compute(lua, this, root: NodeId, width: Option<f32>, height: Option<f32>, scripts: LayoutScripts) -> (Vec<f64>, Vec<LayoutFailure>) {
                compute(lua, this, root, width, height, &scripts)
            }
            /// The shaped lines of a text node at its laid-out width, or nil for a node that is not text.
            method textLayout(_lua, this, id: NodeId) -> Option<Vec<LayoutLine>> {
                let mut tree = borrow_mut(this)?;
                Ok(tree.text_lines(id).map(|lines| lines.into_iter().map(LayoutLine).collect()))
            }
        );
    }
}

fn borrow(tree: &LayoutTree) -> mlua::Result<std::cell::Ref<'_, Tree>> {
    tree.0.try_borrow().map_err(|_| {
        mlua::Error::runtime(
            "layout: the tree is computing, so it cannot be read until its computation returns",
        )
    })
}

fn borrow_mut(tree: &LayoutTree) -> mlua::Result<std::cell::RefMut<'_, Tree>> {
    tree.0.try_borrow_mut().map_err(|_| {
        mlua::Error::runtime(
            "layout: the tree is computing; a layout callback reaches the tree only through its context",
        )
    })
}

fn compute(
    lua: &Lua,
    this: &LayoutTree,
    root: NodeId,
    width: Option<f32>,
    height: Option<f32>,
    scripts: &LayoutScripts,
) -> mlua::Result<(Vec<f64>, Vec<LayoutFailure>)> {
    for (axis, value) in [("width", width), ("height", height)] {
        if let Some(value) = value
            && !(value.is_finite() && value >= 0.0)
        {
            return Err(mlua::Error::runtime(format!(
                "layout: compute: the {axis} {value} is not a finite length"
            )));
        }
    }
    let mut tree = borrow_mut(this)?;
    let bridge = LuaScripts {
        lua,
        measure: scripts.measure.clone(),
        layout: scripts.layout.clone(),
    };
    let outcome = tree
        .compute(root, width, height, &bridge)
        .map_err(|error| mlua::Error::runtime(error.to_string()))?;
    let mut flat = Vec::with_capacity(outcome.changed.len() * 7);
    for placement in outcome.changed {
        flat.extend([
            f64::from(placement.id),
            f64::from(placement.u),
            f64::from(placement.v),
            f64::from(placement.width),
            f64::from(placement.height),
            f64::from(placement.transform.rotation),
            f64::from(placement.transform.scale),
        ]);
    }
    let failures = outcome
        .failures
        .into_iter()
        .map(|failure| LayoutFailure {
            id: failure.id,
            message: failure.error.0,
        })
        .collect();
    Ok((flat, failures))
}

/// The host's measure and layout callbacks, called through Lua.
struct LuaScripts<'a> {
    lua: &'a Lua,
    measure: Option<Function>,
    layout: Option<Function>,
}

impl Scripts for LuaScripts<'_> {
    fn measure(&self, node: NodeId, input: &Input) -> Result<Size, ScriptError> {
        let measure = self.measure.as_ref().ok_or_else(|| {
            ScriptError(format!(
                "node {node} is measured, and no measure callback was given"
            ))
        })?;
        let input = input_table(self.lua, input).map_err(script_error)?;
        let (width, height): (f32, f32) = measure.call((node, input)).map_err(script_error)?;
        Ok(Size { width, height })
    }

    fn layout(
        &self,
        node: NodeId,
        input: &Input,
        context: &mut dyn ScriptContext,
    ) -> Result<Size, ScriptError> {
        let layout = self.layout.as_ref().ok_or_else(|| {
            ScriptError(format!(
                "node {node} is scripted, and no layout callback was given"
            ))
        })?;
        let input = input_table(self.lua, input).map_err(script_error)?;
        let context = RefCell::new(context);
        let result = self.lua.scope(|scope| {
            let table = self.lua.create_table()?;
            table.set(
                "children",
                scope.create_function(|_, ()| {
                    let context = context.try_borrow().map_err(|_| busy())?;
                    Ok(context.children())
                })?,
            )?;
            table.set(
                "measure",
                scope.create_function(|_, (child, width, height): (NodeId, Value, Value)| {
                    let available = (available(width)?, available(height)?);
                    let mut context = context.try_borrow_mut().map_err(|_| busy())?;
                    let size = context
                        .measure(child, available)
                        .map_err(|error| mlua::Error::runtime(error.0))?;
                    Ok((size.width, size.height))
                })?,
            )?;
            table.set(
                "place",
                scope.create_function(
                    |_, (child, u, v, options): (NodeId, f32, f32, Option<Table>)| {
                        let (size, transform) = placement_options(options.as_ref())?;
                        let mut context = context.try_borrow_mut().map_err(|_| busy())?;
                        context
                            .place(child, u, v, size, transform)
                            .map_err(|error| mlua::Error::runtime(error.0))
                    },
                )?,
            )?;
            layout.call::<(f32, f32)>((node, input, table))
        });
        let (width, height) = result.map_err(script_error)?;
        Ok(Size { width, height })
    }
}

fn busy() -> mlua::Error {
    mlua::Error::runtime("layout: the layout context is already in use by this callback")
}

fn script_error(error: mlua::Error) -> ScriptError {
    ScriptError(error.to_string())
}

fn input_table(lua: &Lua, input: &Input) -> mlua::Result<Table> {
    let table = lua.create_table()?;
    table.set("knownWidth", input.known.0)?;
    table.set("knownHeight", input.known.1)?;
    table.set("availableWidth", available_value(lua, input.available.0)?)?;
    table.set("availableHeight", available_value(lua, input.available.1)?)?;
    table.set("perform", input.perform)?;
    Ok(table)
}

fn available_value(lua: &Lua, space: Available) -> mlua::Result<Value> {
    match space {
        Available::Definite(length) => length.into_lua(lua),
        Available::MinContent => "min-content".into_lua(lua),
        Available::MaxContent => "max-content".into_lua(lua),
    }
}

fn available(value: Value) -> mlua::Result<Available> {
    match value {
        Value::Nil => Ok(Available::MaxContent),
        Value::Integer(length) => {
            #[expect(
                clippy::cast_precision_loss,
                reason = "A length in metres is far below 2^24."
            )]
            let length = length as f32;
            Ok(Available::Definite(length))
        }
        Value::Number(length) => {
            #[expect(clippy::cast_possible_truncation, reason = "Layout runs in f32.")]
            let length = length as f32;
            Ok(Available::Definite(length))
        }
        Value::String(name) if name.as_bytes() == b"min-content" => Ok(Available::MinContent),
        Value::String(name) if name.as_bytes() == b"max-content" => Ok(Available::MaxContent),
        other => Err(mlua::Error::runtime(format!(
            "layout: an available size is a length, 'min-content', or 'max-content', not {}",
            other.type_name()
        ))),
    }
}

fn placement_options(options: Option<&Table>) -> mlua::Result<(Option<Size>, Transform)> {
    let Some(options) = options else {
        return Ok((None, Transform::default()));
    };
    parse::reject_unknown(
        options,
        "layout: place",
        &["width", "height", "rotation", "scale"],
    )?;
    let width: Option<f32> = options.get("width")?;
    let height: Option<f32> = options.get("height")?;
    let size = match (width, height) {
        (Some(width), Some(height)) => Some(Size { width, height }),
        (None, None) => None,
        _ => {
            return Err(mlua::Error::runtime(
                "layout: place: a size gives both width and height, or neither",
            ));
        }
    };
    let transform = Transform {
        rotation: options.get::<Option<f32>>("rotation")?.unwrap_or(0.0),
        scale: options.get::<Option<f32>>("scale")?.unwrap_or(1.0),
    };
    Ok((size, transform))
}

/// One commit's changes, parsed from Lua.
pub struct LayoutChanges(Vec<lunette_ui::layout::Change>);

impl FromLua for LayoutChanges {
    fn from_lua(value: Value, _lua: &Lua) -> mlua::Result<Self> {
        let Value::Table(table) = value else {
            return Err(mlua::Error::runtime(
                "layout: apply takes an array of changes",
            ));
        };
        parse::changes(&table).map(Self)
    }
}

impl Typed for LayoutChanges {
    fn luau() -> Type {
        Type::Named("LayoutChange").readonly_array()
    }
}

/// The host's callbacks for one computation.
#[derive(Default)]
pub struct LayoutScripts {
    measure: Option<Function>,
    layout: Option<Function>,
}

impl FromLua for LayoutScripts {
    fn from_lua(value: Value, _lua: &Lua) -> mlua::Result<Self> {
        match value {
            Value::Nil => Ok(Self::default()),
            Value::Table(table) => {
                parse::reject_unknown(&table, "layout: compute", &["measure", "layout"])?;
                Ok(Self {
                    measure: table.get("measure")?,
                    layout: table.get("layout")?,
                })
            }
            other => Err(mlua::Error::runtime(format!(
                "layout: compute takes a table of callbacks, not {}",
                other.type_name()
            ))),
        }
    }
}

impl Typed for LayoutScripts {
    fn luau() -> Type {
        Type::Named("LayoutScripts").optional()
    }
}

/// A callback that failed during a computation.
pub struct LayoutFailure {
    id: NodeId,
    message: String,
}

impl IntoLua for LayoutFailure {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let table = lua.create_table()?;
        table.set("id", self.id)?;
        table.set("message", self.message)?;
        Ok(Value::Table(table))
    }
}

impl Typed for LayoutFailure {
    fn luau() -> Type {
        Type::Named("LayoutFailure")
    }
}

/// One shaped line of a text node.
pub struct LayoutLine(lunette_ui::text::Line);

impl IntoLua for LayoutLine {
    fn into_lua(self, lua: &Lua) -> mlua::Result<Value> {
        let line = self.0;
        let table = lua.create_table()?;
        table.set("top", line.top)?;
        table.set("height", line.height)?;
        table.set("width", line.width)?;
        table.set("baseline", line.baseline)?;
        let glyphs = lua.create_table_with_capacity(line.glyphs.len(), 0)?;
        for (index, glyph) in line.glyphs.into_iter().enumerate() {
            let entry = lua.create_table()?;
            entry.set("face", glyph.handle.get())?;
            entry.set("id", glyph.id)?;
            entry.set("x", glyph.x)?;
            entry.set("xOffset", glyph.offset_x)?;
            entry.set("yOffset", glyph.offset_y)?;
            entry.set("advance", glyph.advance)?;
            entry.set("size", glyph.size)?;
            entry.set("byteStart", glyph.start + 1)?;
            entry.set("byteEnd", glyph.end)?;
            glyphs.raw_set(index + 1, entry)?;
        }
        table.set("glyphs", glyphs)?;
        Ok(Value::Table(table))
    }
}

impl Typed for LayoutLine {
    fn luau() -> Type {
        Type::Named("LayoutLine")
    }
}

fn record(fields: &[(&'static str, Type)]) -> Type {
    Type::Record(
        fields
            .iter()
            .map(|(name, ty)| Parameter {
                name,
                ty: ty.clone(),
            })
            .collect(),
    )
}

fn function(parameters: &[(&'static str, Type)], returns: Type) -> Type {
    Type::Function {
        receiver: None,
        parameters: parameters
            .iter()
            .map(|(name, ty)| Parameter {
                name,
                ty: ty.clone(),
            })
            .collect(),
        returns: Box::new(returns),
    }
}

fn number() -> Type {
    Type::NUMBER
}

fn optional_number() -> Type {
    Type::NUMBER.optional()
}

/// A length in metres, a percentage such as `'50%'`, or `'auto'`.
fn length() -> Type {
    Type::Union(vec![Type::NUMBER, Type::STRING]).optional()
}

/// The aliases the layout surface declares, in the order they are rendered.
pub fn aliases() -> Vec<AliasSpec> {
    vec![
        LayoutEdgesAlias::ALIAS,
        LayoutStyleAlias::ALIAS,
        LayoutTextStyleAlias::ALIAS,
        LayoutLeafAlias::ALIAS,
        LayoutChangeAlias::ALIAS,
        LayoutAvailableAlias::ALIAS,
        LayoutInputAlias::ALIAS,
        LayoutContextAlias::ALIAS,
        LayoutScriptsAlias::ALIAS,
        LayoutFailureAlias::ALIAS,
        LayoutGlyphAlias::ALIAS,
        LayoutLineAlias::ALIAS,
    ]
}

macro_rules! alias {
    ($rust:ident, $name:literal, $doc:literal, $definition:expr) => {
        struct $rust;

        impl Typed for $rust {
            fn luau() -> Type {
                Type::Named($name)
            }
        }

        impl Aliased for $rust {
            const ALIAS: AliasSpec = AliasSpec {
                doc: $doc,
                name: <$rust as Typed>::luau,
                definition: |_| $definition,
            };
        }
    };
}

alias!(
    LayoutEdgesAlias,
    "LayoutEdges",
    "One length for every edge, or a length for each of the top, right, bottom, and left edges.",
    Type::Union(vec![
        Type::NUMBER,
        Type::STRING,
        record(&[
            ("top", length()),
            ("right", length()),
            ("bottom", length()),
            ("left", length())
        ]),
    ])
);

alias!(
    LayoutStyleAlias,
    "LayoutStyle",
    "A node's layout style. Lengths are metres, percentages such as '50%', or 'auto'. Edges take one length or a table of top, right, bottom, and left.",
    record(&[
        ("display", Type::literals(parse::DISPLAYS).optional()),
        ("direction", Type::literals(parse::DIRECTIONS).optional()),
        (
            "flexDirection",
            Type::literals(parse::FLEX_DIRECTIONS).optional()
        ),
        ("wrap", Type::literals(parse::WRAPS).optional()),
        ("grow", optional_number()),
        ("shrink", optional_number()),
        ("basis", length()),
        ("alignItems", Type::literals(parse::ALIGN_ITEMS).optional()),
        ("alignSelf", Type::literals(parse::ALIGN_ITEMS).optional()),
        (
            "justifyItems",
            Type::literals(parse::ALIGN_ITEMS).optional()
        ),
        ("justifySelf", Type::literals(parse::ALIGN_ITEMS).optional()),
        (
            "alignContent",
            Type::literals(parse::ALIGN_CONTENT).optional()
        ),
        (
            "justifyContent",
            Type::literals(parse::ALIGN_CONTENT).optional()
        ),
        ("gap", optional_number()),
        ("rowGap", optional_number()),
        ("columnGap", optional_number()),
        ("padding", Type::Named("LayoutEdges").optional()),
        ("margin", Type::Named("LayoutEdges").optional()),
        ("border", Type::Named("LayoutEdges").optional()),
        ("width", length()),
        ("height", length()),
        ("minWidth", length()),
        ("minHeight", length()),
        ("maxWidth", length()),
        ("maxHeight", length()),
        ("aspectRatio", optional_number()),
        ("position", Type::literals(parse::POSITIONS).optional()),
        ("top", length()),
        ("right", length()),
        ("bottom", length()),
        ("left", length()),
        ("overflow", Type::literals(parse::OVERFLOWS).optional()),
        (
            "gridTemplateColumns",
            Type::Union(vec![Type::NUMBER, Type::STRING])
                .readonly_array()
                .optional()
        ),
        (
            "gridTemplateRows",
            Type::Union(vec![Type::NUMBER, Type::STRING])
                .readonly_array()
                .optional()
        ),
        (
            "gridColumn",
            record(&[("start", optional_number()), ("span", optional_number())]).optional()
        ),
        (
            "gridRow",
            record(&[("start", optional_number()), ("span", optional_number())]).optional()
        ),
    ])
);

alias!(
    LayoutTextStyleAlias,
    "LayoutTextStyle",
    "How a text node is shaped. Sizes are metres; the line height and the letter spacing, which is added after each glyph, are multiples of the size.",
    record(&[
        ("family", Type::STRING.optional()),
        ("size", optional_number()),
        ("lineHeight", optional_number()),
        ("weight", optional_number()),
        ("letterSpacing", optional_number()),
        (
            "align",
            Type::literals(&["start", "center", "end"]).optional()
        ),
        (
            "wrap",
            Type::literals(&["none", "word", "word-or-glyph"]).optional()
        ),
        ("maxLines", optional_number()),
    ])
);

alias!(
    LayoutLeafAlias,
    "LayoutLeaf",
    "How a leaf sizes itself without a callback.",
    Type::Union(vec![
        record(&[
            ("kind", Type::Literal("fixed")),
            ("width", number()),
            ("height", number())
        ]),
        record(&[
            ("kind", Type::Literal("aspect")),
            ("ratio", number()),
            ("width", number())
        ]),
        record(&[("kind", Type::Literal("fill"))]),
    ])
);

alias!(
    LayoutChangeAlias,
    "LayoutChange",
    "One change in a commit.",
    Type::Union(vec![
        record(&[
            ("op", Type::Literal("create")),
            ("id", number()),
            (
                "kind",
                Type::literals(&["box", "text", "leaf", "measured", "scripted"])
            ),
            ("style", Type::Named("LayoutStyle").optional()),
            ("text", Type::STRING.optional()),
            ("textStyle", Type::Named("LayoutTextStyle").optional()),
            ("leaf", Type::Named("LayoutLeaf").optional()),
        ]),
        record(&[
            ("op", Type::Literal("style")),
            ("id", number()),
            ("style", Type::Named("LayoutStyle"))
        ]),
        record(&[
            ("op", Type::Literal("children")),
            ("id", number()),
            ("children", number().readonly_array())
        ]),
        record(&[
            ("op", Type::Literal("text")),
            ("id", number()),
            ("text", Type::STRING),
            ("textStyle", Type::Named("LayoutTextStyle").optional()),
        ]),
        record(&[("op", Type::Literal("remove")), ("id", number())]),
    ])
);

alias!(
    LayoutAvailableAlias,
    "LayoutAvailable",
    "The space offered along one axis: a length in metres, or a sizing mode.",
    Type::Union(vec![
        Type::NUMBER,
        Type::Literal("min-content"),
        Type::Literal("max-content")
    ])
);

alias!(
    LayoutInputAlias,
    "LayoutInput",
    "What a measure or layout callback is asked. `perform` is true in the final pass, the only one in which a layout places its children.",
    record(&[
        ("knownWidth", optional_number()),
        ("knownHeight", optional_number()),
        ("availableWidth", Type::Named("LayoutAvailable")),
        ("availableHeight", Type::Named("LayoutAvailable")),
        ("perform", Type::BOOLEAN),
    ])
);

alias!(
    LayoutContextAlias,
    "LayoutContext",
    "What a layout callback does with its container's children. It is valid only during the call.",
    record(&[
        ("children", function(&[], number().array())),
        (
            "measure",
            function(
                &[
                    ("child", number()),
                    ("width", Type::Named("LayoutAvailable").optional()),
                    ("height", Type::Named("LayoutAvailable").optional())
                ],
                Type::Tuple(vec![number(), number()]),
            ),
        ),
        (
            "place",
            function(
                &[
                    ("child", number()),
                    ("u", number()),
                    ("v", number()),
                    (
                        "options",
                        record(&[
                            ("width", optional_number()),
                            ("height", optional_number()),
                            ("rotation", optional_number()),
                            ("scale", optional_number()),
                        ])
                        .optional(),
                    ),
                ],
                Type::Tuple(Vec::new()),
            ),
        ),
    ])
);

alias!(
    LayoutScriptsAlias,
    "LayoutScripts",
    "The host's callbacks for measured leaves and scripted containers. Both answer a width and a height in metres. They cannot yield, and they read only their arguments.",
    record(&[
        (
            "measure",
            function(
                &[("id", number()), ("input", Type::Named("LayoutInput"))],
                Type::Tuple(vec![number(), number()])
            )
            .optional(),
        ),
        (
            "layout",
            function(
                &[
                    ("id", number()),
                    ("input", Type::Named("LayoutInput")),
                    ("context", Type::Named("LayoutContext"))
                ],
                Type::Tuple(vec![number(), number()]),
            )
            .optional(),
        ),
    ])
);

alias!(
    LayoutFailureAlias,
    "LayoutFailure",
    "A callback that failed. Its node keeps its previous size.",
    record(&[("id", number()), ("message", Type::STRING)])
);

alias!(
    LayoutGlyphAlias,
    "LayoutGlyph",
    "One positioned glyph, in metres from the text node's left edge, with the inclusive byte range of the text it draws. The face is a handle that the glyph atlas takes. The offsets place the glyph relative to its origin, y down, as shaping positions a combining mark.",
    record(&[
        ("face", number()),
        ("id", number()),
        ("x", number()),
        ("xOffset", number()),
        ("yOffset", number()),
        ("advance", number()),
        ("size", number()),
        ("byteStart", number()),
        ("byteEnd", number()),
    ])
);

alias!(
    LayoutLineAlias,
    "LayoutLine",
    "One shaped line, in metres from the text node's top-left corner.",
    record(&[
        ("top", number()),
        ("height", number()),
        ("width", number()),
        ("baseline", number()),
        ("glyphs", Type::Named("LayoutGlyph").readonly_array()),
    ])
);
