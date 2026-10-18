//! Parses layout changes and styles from Lua tables.
//!
//! Every name is checked: an unknown field, an unknown keyword, or a value of the wrong type is
//! an error that names the field, so a misspelt style does not silently lay out as the default.

use lunette_ui::{
    layout::{Change, ContentSpec, Descriptor, NodeId, Style},
    text::{Alignment, TextStyle, Wrapping},
};
use mlua::{Table, Value};
use taffy::{
    geometry::{Line, Point, Rect, Size},
    style::{
        AlignContent, AlignItems, Dimension, Direction, Display, FlexDirection, FlexWrap,
        GridPlacement, GridTemplateComponent, LengthPercentage, LengthPercentageAuto, Overflow,
        Position, TrackSizingFunction,
    },
    style_helpers::{
        TaffyGridLine, TaffyGridSpan, auto, fr, length, max_content, min_content, percent,
    },
};

pub const DISPLAYS: &[(&str, Display)] = &[
    ("flex", Display::Flex),
    ("grid", Display::Grid),
    ("block", Display::Block),
    ("none", Display::None),
];
pub const DIRECTIONS: &[(&str, Direction)] = &[("ltr", Direction::Ltr), ("rtl", Direction::Rtl)];
pub const FLEX_DIRECTIONS: &[(&str, FlexDirection)] = &[
    ("row", FlexDirection::Row),
    ("column", FlexDirection::Column),
    ("row-reverse", FlexDirection::RowReverse),
    ("column-reverse", FlexDirection::ColumnReverse),
];
pub const WRAPS: &[(&str, FlexWrap)] = &[
    ("nowrap", FlexWrap::NoWrap),
    ("wrap", FlexWrap::Wrap),
    ("wrap-reverse", FlexWrap::WrapReverse),
];
pub const ALIGN_ITEMS: &[(&str, AlignItems)] = &[
    ("start", AlignItems::START),
    ("end", AlignItems::END),
    ("center", AlignItems::CENTER),
    ("stretch", AlignItems::STRETCH),
    ("baseline", AlignItems::BASELINE),
    ("flex-start", AlignItems::FLEX_START),
    ("flex-end", AlignItems::FLEX_END),
];
pub const ALIGN_CONTENT: &[(&str, AlignContent)] = &[
    ("start", AlignContent::START),
    ("end", AlignContent::END),
    ("center", AlignContent::CENTER),
    ("stretch", AlignContent::STRETCH),
    ("space-between", AlignContent::SPACE_BETWEEN),
    ("space-around", AlignContent::SPACE_AROUND),
    ("space-evenly", AlignContent::SPACE_EVENLY),
    ("flex-start", AlignContent::FLEX_START),
    ("flex-end", AlignContent::FLEX_END),
];
pub const POSITIONS: &[(&str, Position)] = &[
    ("relative", Position::Relative),
    ("absolute", Position::Absolute),
];
pub const OVERFLOWS: &[(&str, Overflow)] = &[
    ("visible", Overflow::Visible),
    ("clip", Overflow::Clip),
    ("scroll", Overflow::Scroll),
];

const STYLE_FIELDS: &[&str] = &[
    "display",
    "direction",
    "flexDirection",
    "wrap",
    "grow",
    "shrink",
    "basis",
    "alignItems",
    "alignSelf",
    "justifyItems",
    "justifySelf",
    "alignContent",
    "justifyContent",
    "gap",
    "rowGap",
    "columnGap",
    "padding",
    "margin",
    "border",
    "width",
    "height",
    "minWidth",
    "minHeight",
    "maxWidth",
    "maxHeight",
    "aspectRatio",
    "position",
    "top",
    "right",
    "bottom",
    "left",
    "overflow",
    "gridTemplateColumns",
    "gridTemplateRows",
    "gridColumn",
    "gridRow",
];

/// Refuses a key that `known` does not list.
pub fn reject_unknown(table: &Table, context: &str, known: &[&str]) -> mlua::Result<()> {
    for pair in table.pairs::<Value, Value>() {
        let (key, _) = pair?;
        let name = match &key {
            Value::String(name) => name.to_string_lossy(),
            other => {
                return Err(mlua::Error::runtime(format!(
                    "{context}: a {} key is not an option; this takes {}",
                    other.type_name(),
                    known.join(", ")
                )));
            }
        };
        if !known.contains(&name.as_str()) {
            return Err(mlua::Error::runtime(format!(
                "{context}: '{name}' is not an option; this takes {}",
                known.join(", ")
            )));
        }
    }
    Ok(())
}

fn error(context: &str, message: impl std::fmt::Display) -> mlua::Error {
    mlua::Error::runtime(format!("{context}: {message}"))
}

/// One commit's changes, from an array of change tables.
pub fn changes(table: &Table) -> mlua::Result<Vec<Change>> {
    let count = table.raw_len();
    let mut changes = Vec::with_capacity(count);
    for index in 1..=count {
        let context = format!("layout: apply: change {index}");
        let change: Table = table
            .raw_get::<Option<Table>>(index)?
            .ok_or_else(|| error(&context, "is not a table"))?;
        changes.push(change_from(&change, &context)?);
    }
    Ok(changes)
}

fn change_from(table: &Table, context: &str) -> mlua::Result<Change> {
    let op: String = table
        .get::<Option<String>>("op")?
        .ok_or_else(|| error(context, "has no op"))?;
    let id = || -> mlua::Result<NodeId> {
        table
            .get::<Option<NodeId>>("id")?
            .ok_or_else(|| error(context, "has no id"))
    };
    match op.as_str() {
        "create" => {
            reject_unknown(
                table,
                context,
                &["op", "id", "kind", "style", "text", "textStyle", "leaf"],
            )?;
            let kind: String = table
                .get::<Option<String>>("kind")?
                .ok_or_else(|| error(context, "has no kind"))?;
            let content = match kind.as_str() {
                "box" => ContentSpec::Box,
                "text" => ContentSpec::Text {
                    text: table.get::<Option<String>>("text")?.unwrap_or_default(),
                    style: text_style(table.get::<Option<Table>>("textStyle")?.as_ref(), context)?,
                },
                "leaf" => ContentSpec::Leaf(leaf(
                    &table
                        .get::<Option<Table>>("leaf")?
                        .ok_or_else(|| error(context, "creates a leaf with no leaf descriptor"))?,
                    context,
                )?),
                "measured" => ContentSpec::Measured,
                "scripted" => ContentSpec::Scripted,
                other => {
                    return Err(error(
                        context,
                        format!(
                            "'{other}' is not a kind; a kind is box, text, leaf, measured, or scripted"
                        ),
                    ));
                }
            };
            Ok(Change::Create {
                id: id()?,
                content,
                style: Box::new(style(
                    table.get::<Option<Table>>("style")?.as_ref(),
                    context,
                )?),
            })
        }
        "style" => {
            reject_unknown(table, context, &["op", "id", "style"])?;
            Ok(Change::SetStyle {
                id: id()?,
                style: Box::new(style(
                    table.get::<Option<Table>>("style")?.as_ref(),
                    context,
                )?),
            })
        }
        "children" => {
            reject_unknown(table, context, &["op", "id", "children"])?;
            let children: Vec<NodeId> = table
                .get::<Option<Vec<NodeId>>>("children")?
                .ok_or_else(|| error(context, "sets children with no children array"))?;
            Ok(Change::SetChildren {
                id: id()?,
                children,
            })
        }
        "text" => {
            reject_unknown(table, context, &["op", "id", "text", "textStyle"])?;
            Ok(Change::SetText {
                id: id()?,
                text: table
                    .get::<Option<String>>("text")?
                    .ok_or_else(|| error(context, "sets text with no text"))?,
                style: text_style(table.get::<Option<Table>>("textStyle")?.as_ref(), context)?,
            })
        }
        "remove" => {
            reject_unknown(table, context, &["op", "id"])?;
            Ok(Change::Remove { id: id()? })
        }
        other => Err(error(
            context,
            format!("'{other}' is not an op; an op is create, style, children, text, or remove"),
        )),
    }
}

fn leaf(table: &Table, context: &str) -> mlua::Result<Descriptor> {
    let kind: String = table
        .get::<Option<String>>("kind")?
        .ok_or_else(|| error(context, "has a leaf with no kind"))?;
    match kind.as_str() {
        "fixed" => {
            reject_unknown(table, context, &["kind", "width", "height"])?;
            Ok(Descriptor::Fixed {
                width: table.get("width")?,
                height: table.get("height")?,
            })
        }
        "aspect" => {
            reject_unknown(table, context, &["kind", "ratio", "width"])?;
            Ok(Descriptor::Aspect {
                ratio: table.get("ratio")?,
                preferred_width: table.get("width")?,
            })
        }
        "fill" => {
            reject_unknown(table, context, &["kind"])?;
            Ok(Descriptor::Fill)
        }
        other => Err(error(
            context,
            format!("'{other}' is not a leaf kind; it is fixed, aspect, or fill"),
        )),
    }
}

fn text_style(table: Option<&Table>, context: &str) -> mlua::Result<TextStyle> {
    let mut style = TextStyle::default();
    let Some(table) = table else {
        return Ok(style);
    };
    reject_unknown(
        table,
        context,
        &[
            "family",
            "size",
            "lineHeight",
            "weight",
            "letterSpacing",
            "align",
            "wrap",
            "maxLines",
        ],
    )?;
    if let Some(family) = table.get::<Option<String>>("family")? {
        style.family = Some(family);
    }
    if let Some(size) = table.get::<Option<f32>>("size")? {
        style.size = size;
    }
    if let Some(height) = table.get::<Option<f32>>("lineHeight")? {
        style.line_height = height;
    }
    if let Some(weight) = table.get::<Option<u16>>("weight")? {
        style.weight = weight;
    }
    if let Some(spacing) = table.get::<Option<f32>>("letterSpacing")? {
        style.letter_spacing = spacing;
    }
    if let Some(align) = table.get::<Option<String>>("align")? {
        style.alignment = match align.as_str() {
            "start" => Alignment::Start,
            "center" => Alignment::Center,
            "end" => Alignment::End,
            other => {
                return Err(error(
                    context,
                    format!("'{other}' is not an alignment; it is start, center, or end"),
                ));
            }
        };
    }
    if let Some(wrap) = table.get::<Option<String>>("wrap")? {
        style.wrapping = match wrap.as_str() {
            "none" => Wrapping::None,
            "word" => Wrapping::Word,
            "word-or-glyph" => Wrapping::WordOrGlyph,
            other => {
                return Err(error(
                    context,
                    format!("'{other}' is not a wrap; it is none, word, or word-or-glyph"),
                ));
            }
        };
    }
    style.max_lines = table.get::<Option<usize>>("maxLines")?;
    Ok(style)
}

fn keyword<T: Copy>(
    table: &Table,
    field: &str,
    context: &str,
    options: &[(&str, T)],
) -> mlua::Result<Option<T>> {
    let Some(name) = table.get::<Option<String>>(field)? else {
        return Ok(None);
    };
    options
        .iter()
        .find_map(|(candidate, value)| (*candidate == name).then_some(Some(*value)))
        .ok_or_else(|| {
            let names: Vec<_> = options.iter().map(|(name, _)| *name).collect();
            error(
                context,
                format!("{field}: '{name}' is not one of {}", names.join(", ")),
            )
        })
}

/// A length in metres, `'N%'`, or `'auto'`.
enum Length {
    Metres(f32),
    Percent(f32),
    Auto,
}

fn length_value(value: Value, field: &str, context: &str) -> mlua::Result<Option<Length>> {
    match value {
        Value::Nil => Ok(None),
        Value::Integer(metres) => {
            #[expect(
                clippy::cast_precision_loss,
                reason = "A length in metres is far below 2^24."
            )]
            let metres = metres as f32;
            Ok(Some(Length::Metres(metres)))
        }
        Value::Number(metres) if metres.is_finite() => {
            #[expect(clippy::cast_possible_truncation, reason = "Layout runs in f32.")]
            let metres = metres as f32;
            Ok(Some(Length::Metres(metres)))
        }
        Value::String(text) => {
            let text = text.to_string_lossy();
            if text == "auto" {
                return Ok(Some(Length::Auto));
            }
            text.strip_suffix('%')
                .and_then(|number| number.trim().parse::<f32>().ok())
                .filter(|number| number.is_finite())
                .map(|number| Some(Length::Percent(number / 100.0)))
                .ok_or_else(|| {
                    error(
                        context,
                        format!("{field}: '{text}' is not a length, a percentage, or 'auto'"),
                    )
                })
        }
        other => Err(error(
            context,
            format!(
                "{field}: a length is a number of metres, not {}",
                other.type_name()
            ),
        )),
    }
}

fn dimension(table: &Table, field: &str, context: &str) -> mlua::Result<Option<Dimension>> {
    Ok(
        length_value(table.get(field)?, field, context)?.map(|length| match length {
            Length::Metres(metres) => Dimension::length(metres),
            Length::Percent(fraction) => Dimension::percent(fraction),
            Length::Auto => Dimension::auto(),
        }),
    )
}

fn length_auto(
    value: Value,
    field: &str,
    context: &str,
) -> mlua::Result<Option<LengthPercentageAuto>> {
    Ok(
        length_value(value, field, context)?.map(|length| match length {
            Length::Metres(metres) => LengthPercentageAuto::length(metres),
            Length::Percent(fraction) => LengthPercentageAuto::percent(fraction),
            Length::Auto => LengthPercentageAuto::auto(),
        }),
    )
}

fn length_fixed(
    value: Value,
    field: &str,
    context: &str,
) -> mlua::Result<Option<LengthPercentage>> {
    match length_value(value, field, context)? {
        None => Ok(None),
        Some(Length::Metres(metres)) => Ok(Some(LengthPercentage::length(metres))),
        Some(Length::Percent(fraction)) => Ok(Some(LengthPercentage::percent(fraction))),
        Some(Length::Auto) => Err(error(
            context,
            format!("{field}: 'auto' is not allowed here"),
        )),
    }
}

/// A single length for every edge, or a table of edges. An edge the table leaves out is `zero`.
fn edges<T: Copy>(
    table: &Table,
    field: &str,
    context: &str,
    zero: T,
    parse: impl Fn(Value, &str, &str) -> mlua::Result<Option<T>>,
) -> mlua::Result<Option<Rect<T>>> {
    match table.get::<Value>(field)? {
        Value::Nil => Ok(None),
        Value::Table(sides) => {
            reject_unknown(&sides, context, &["top", "right", "bottom", "left"])?;
            let side = |name: &str| -> mlua::Result<T> {
                Ok(parse(sides.get(name)?, field, context)?.unwrap_or(zero))
            };
            Ok(Some(Rect {
                top: side("top")?,
                right: side("right")?,
                bottom: side("bottom")?,
                left: side("left")?,
            }))
        }
        value => Ok(parse(value, field, context)?.map(|all| Rect {
            top: all,
            right: all,
            bottom: all,
            left: all,
        })),
    }
}

fn number(table: &Table, field: &str, context: &str) -> mlua::Result<Option<f32>> {
    match table.get::<Option<f32>>(field)? {
        Some(value) if !value.is_finite() => {
            Err(error(context, format!("{field}: {value} is not finite")))
        }
        other => Ok(other),
    }
}

fn track(value: Value, context: &str) -> mlua::Result<TrackSizingFunction> {
    match value {
        Value::Integer(_) | Value::Number(_) => match length_value(value, "a grid track", context)?
        {
            Some(Length::Metres(metres)) => Ok(length(metres)),
            _ => Err(error(context, "a grid track is not a finite length")),
        },
        Value::String(text) => {
            let text = text.to_string_lossy();
            match text.as_str() {
                "auto" => Ok(auto()),
                "min-content" => Ok(min_content()),
                "max-content" => Ok(max_content()),
                _ => {
                    if let Some(flex) = text
                        .strip_suffix("fr")
                        .and_then(|number| number.trim().parse::<f32>().ok())
                    {
                        Ok(fr(flex))
                    } else if let Some(fraction) = text
                        .strip_suffix('%')
                        .and_then(|number| number.trim().parse::<f32>().ok())
                    {
                        Ok(percent(fraction / 100.0))
                    } else {
                        Err(error(
                            context,
                            format!(
                                "'{text}' is not a grid track; a track is a length, 'Nfr', 'N%', 'auto', 'min-content', or 'max-content'"
                            ),
                        ))
                    }
                }
            }
        }
        other => Err(error(
            context,
            format!("a grid track is not {}", other.type_name()),
        )),
    }
}

fn tracks(
    table: &Table,
    field: &str,
    context: &str,
) -> mlua::Result<Option<Vec<GridTemplateComponent<String>>>> {
    let Some(list) = table.get::<Option<Table>>(field)? else {
        return Ok(None);
    };
    let mut out = Vec::new();
    for index in 1..=list.raw_len() {
        out.push(GridTemplateComponent::Single(track(
            list.raw_get(index)?,
            context,
        )?));
    }
    Ok(Some(out))
}

fn placement(
    table: &Table,
    field: &str,
    context: &str,
) -> mlua::Result<Option<Line<GridPlacement<String>>>> {
    let Some(place) = table.get::<Option<Table>>(field)? else {
        return Ok(None);
    };
    reject_unknown(&place, context, &["start", "span"])?;
    let start = place
        .get::<Option<i16>>("start")?
        .map_or(GridPlacement::Auto, GridPlacement::from_line_index);
    let end = place
        .get::<Option<u16>>("span")?
        .map_or(GridPlacement::Auto, GridPlacement::from_span);
    Ok(Some(Line { start, end }))
}

/// A layout style, from a style table. A missing table is the default style.
pub fn style(table: Option<&Table>, context: &str) -> mlua::Result<Style> {
    let mut style = Style::default();
    let Some(table) = table else {
        return Ok(style);
    };
    reject_unknown(table, context, STYLE_FIELDS)?;
    if let Some(display) = keyword(table, "display", context, DISPLAYS)? {
        style.display = display;
    }
    if let Some(direction) = keyword(table, "direction", context, DIRECTIONS)? {
        style.direction = direction;
    }
    if let Some(flex_direction) = keyword(table, "flexDirection", context, FLEX_DIRECTIONS)? {
        style.flex_direction = flex_direction;
    }
    if let Some(wrap) = keyword(table, "wrap", context, WRAPS)? {
        style.flex_wrap = wrap;
    }
    if let Some(grow) = number(table, "grow", context)? {
        style.flex_grow = grow;
    }
    if let Some(shrink) = number(table, "shrink", context)? {
        style.flex_shrink = shrink;
    }
    if let Some(basis) = dimension(table, "basis", context)? {
        style.flex_basis = basis;
    }
    if let Some(value) = keyword(table, "alignItems", context, ALIGN_ITEMS)? {
        style.align_items = value;
    }
    if let Some(value) = keyword(table, "justifyItems", context, ALIGN_ITEMS)? {
        style.justify_items = value;
    }
    style.align_self = keyword(table, "alignSelf", context, ALIGN_ITEMS)?;
    style.justify_self = keyword(table, "justifySelf", context, ALIGN_ITEMS)?;
    if let Some(value) = keyword(table, "alignContent", context, ALIGN_CONTENT)? {
        style.align_content = value;
    }
    if let Some(value) = keyword(table, "justifyContent", context, ALIGN_CONTENT)? {
        style.justify_content = value;
    }
    if let Some(gap) = number(table, "gap", context)? {
        style.gap = Size {
            width: LengthPercentage::length(gap),
            height: LengthPercentage::length(gap),
        };
    }
    if let Some(gap) = number(table, "rowGap", context)? {
        style.gap.height = LengthPercentage::length(gap);
    }
    if let Some(gap) = number(table, "columnGap", context)? {
        style.gap.width = LengthPercentage::length(gap);
    }
    if let Some(padding) = edges(
        table,
        "padding",
        context,
        LengthPercentage::length(0.0),
        length_fixed,
    )? {
        style.padding = padding;
    }
    if let Some(border) = edges(
        table,
        "border",
        context,
        LengthPercentage::length(0.0),
        length_fixed,
    )? {
        style.border = border;
    }
    if let Some(margin) = edges(
        table,
        "margin",
        context,
        LengthPercentageAuto::length(0.0),
        length_auto,
    )? {
        style.margin = margin;
    }
    if let Some(width) = dimension(table, "width", context)? {
        style.size.width = width;
    }
    if let Some(height) = dimension(table, "height", context)? {
        style.size.height = height;
    }
    for (field, slot) in [
        ("minWidth", &mut style.min_size.width),
        ("minHeight", &mut style.min_size.height),
        ("maxWidth", &mut style.max_size.width),
        ("maxHeight", &mut style.max_size.height),
    ] {
        if let Some(value) = length_auto(table.get(field)?, field, context)? {
            *slot = value;
        }
    }
    style.aspect_ratio = number(table, "aspectRatio", context)?;
    if let Some(position) = keyword(table, "position", context, POSITIONS)? {
        style.position = position;
    }
    for (field, slot) in [
        ("top", &mut style.inset.top),
        ("right", &mut style.inset.right),
        ("bottom", &mut style.inset.bottom),
        ("left", &mut style.inset.left),
    ] {
        if let Some(value) = length_auto(table.get(field)?, field, context)? {
            *slot = value;
        }
    }
    if let Some(overflow) = keyword(table, "overflow", context, OVERFLOWS)? {
        style.overflow = Point {
            x: overflow,
            y: overflow,
        };
    }
    if let Some(columns) = tracks(table, "gridTemplateColumns", context)? {
        style.grid_template_columns = columns;
    }
    if let Some(rows) = tracks(table, "gridTemplateRows", context)? {
        style.grid_template_rows = rows;
    }
    if let Some(column) = placement(table, "gridColumn", context)? {
        style.grid_column = column;
    }
    if let Some(row) = placement(table, "gridRow", context)? {
        style.grid_row = row;
    }
    Ok(style)
}

#[cfg(test)]
mod tests {
    use std::fmt::Debug;

    use mlua::Lua;

    use super::*;

    #[test]
    fn style_keywords_use_their_paired_native_values() -> mlua::Result<()> {
        let lua = Lua::new();
        check_keywords(&lua, "display", DISPLAYS, |style| style.display)?;
        check_keywords(&lua, "direction", DIRECTIONS, |style| style.direction)?;
        check_keywords(&lua, "flexDirection", FLEX_DIRECTIONS, |style| {
            style.flex_direction
        })?;
        check_keywords(&lua, "wrap", WRAPS, |style| style.flex_wrap)?;
        check_keywords(&lua, "alignItems", ALIGN_ITEMS, |style| style.align_items)?;
        check_keywords(&lua, "justifyItems", ALIGN_ITEMS, |style| {
            style.justify_items
        })?;
        check_keywords(&lua, "alignContent", ALIGN_CONTENT, |style| {
            style.align_content
        })?;
        check_keywords(&lua, "justifyContent", ALIGN_CONTENT, |style| {
            style.justify_content
        })?;
        check_keywords(&lua, "position", POSITIONS, |style| style.position)?;
        check_keywords(&lua, "overflow", OVERFLOWS, |style| style.overflow.x)?;
        check_keywords(&lua, "overflow", OVERFLOWS, |style| style.overflow.y)?;
        let table = lua.create_table()?;
        for (name, value) in ALIGN_ITEMS {
            table.set("alignSelf", *name)?;
            table.set("justifySelf", *name)?;
            let style = style(Some(&table), "layout test")?;
            assert_eq!(style.align_self, Some(*value));
            assert_eq!(style.justify_self, Some(*value));
        }
        Ok(())
    }

    #[test]
    fn omitted_style_keywords_keep_taffy_defaults() -> mlua::Result<()> {
        let lua = Lua::new();
        assert_eq!(style(None, "layout test")?, Style::default());
        assert_eq!(
            style(Some(&lua.create_table()?), "layout test")?,
            Style::default()
        );
        Ok(())
    }

    fn check_keywords<T: Copy + Debug + PartialEq>(
        lua: &Lua,
        field: &str,
        options: &[(&str, T)],
        read: impl Fn(&Style) -> T,
    ) -> mlua::Result<()> {
        let table = lua.create_table()?;
        for (name, value) in options {
            table.set(field, *name)?;
            let style = style(Some(&table), "layout test")?;
            assert_eq!(read(&style), *value, "{field}: {name}");
        }
        Ok(())
    }
}
