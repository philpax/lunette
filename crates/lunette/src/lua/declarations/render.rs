//! Rendering `lua/lunette/init.luau`.
//!
//! The output is already StyLua-formatted, because `stylua --check lua` is one
//! of the standing checks.

use std::fmt::Write as _;

use lunette_luau::Type;

use crate::{
    events::{payload_records, subscription_functions},
    lua::{
        Claim, ErrorEvent, Monitor, Output, Process, ReportError, Seat, Sink, Spawn, Window,
        claim::ClaimLayer,
        declarations::{
            AliasSpec, Aliased, Handle, NullTexture, Property, PropertyType, Record, Recorded,
            Textured, collect,
        },
        keys::KeyName,
        module_functions,
        output::{NewOutput, SetMode},
        seat::{NewSeat, Stroke},
        values::PointerButtonName,
    },
    plugin::declarations::{API_TYPE_NAME, render_types},
};

/// Renders the whole file.
#[must_use]
pub fn render() -> String {
    let mut out = String::from(HEADER);
    let items = surface();

    let handles: Vec<&Handle> = items
        .iter()
        .filter_map(|item| match item {
            Item::Handle(handle) => Some(handle),
            Item::Record(_) => None,
        })
        .collect();

    for alias in [Textured::ALIAS, PointerButtonName::ALIAS, KeyName::ALIAS] {
        render_alias(&mut out, &alias, &handles);
    }

    for item in &items {
        match item {
            Item::Handle(handle) => render_handle(&mut out, handle),
            Item::Record(record) => render_record(&mut out, record),
        }
    }

    let mut plugin_types = String::new();
    render_types(&mut plugin_types);
    render_plugin_types(&mut out, &plugin_types);
    render_module(&mut out);
    out.push('\n');
    out.push_str(FOOTER);

    out
}

/// Keeps the plugin declarations in the generated file StyLua-compatible.
fn render_plugin_types(out: &mut String, plugin_types: &str) {
    for line in plugin_types.lines() {
        if line.starts_with("  read define: ") && line.len() > STYLUA_COLUMNS {
            render_wrapped_function(out, line);
        } else {
            let _ = writeln!(out, "{line}");
        }
    }
}

/// Wraps a long function type at its outer argument boundaries.
fn render_wrapped_function(out: &mut String, line: &str) {
    let Some(signature) = line.strip_prefix("  read define: ") else {
        let _ = writeln!(out, "{line}");
        return;
    };
    let Some((arguments, return_type)) = split_function_type(signature) else {
        let _ = writeln!(out, "{line}");
        return;
    };

    out.push_str("  read define: (\n");
    for (index, argument) in arguments.iter().enumerate() {
        let comma = if index + 1 == arguments.len() {
            ""
        } else {
            ","
        };
        let _ = writeln!(out, "    {argument}{comma}");
    }
    let _ = writeln!(out, "  ){return_type}");
}

/// Splits a function signature at commas outside nested parameter lists.
fn split_function_type(signature: &str) -> Option<(Vec<&str>, &str)> {
    let mut depth = 0usize;
    let mut argument_start = 1;
    let mut arguments = Vec::new();

    for (index, character) in signature.char_indices() {
        match character {
            '(' => depth += 1,
            ')' if depth == 1 => {
                let argument = signature[argument_start..index].trim();
                if !argument.is_empty() {
                    arguments.push(argument);
                }
                return Some((arguments, &signature[index + 1..]));
            }
            ')' => depth = depth.checked_sub(1)?,
            ',' if depth == 1 => {
                arguments.push(signature[argument_start..index].trim());
                argument_start = index + 1;
            }
            _ => {}
        }
    }

    None
}

/// One declaration in the generated file.
enum Item {
    Handle(Handle),
    Record(Record),
}

/// Everything below the aliases, in the order the file states it: each handle
/// appears next to the option table its constructor takes.
fn surface() -> Vec<Item> {
    let mut items = vec![
        Item::Handle(collect::<Sink<NullTexture>>()),
        Item::Handle(collect::<Window<NullTexture>>()),
        Item::Handle(collect::<Monitor<NullTexture>>()),
        Item::Handle(collect::<Process<NullTexture>>()),
        Item::Record(Stroke::RECORD),
        Item::Record(NewSeat::RECORD),
        Item::Handle(collect::<Seat<NullTexture>>()),
        Item::Record(SetMode::RECORD),
        Item::Record(NewOutput::RECORD),
        Item::Handle(collect::<Output<NullTexture>>()),
        Item::Record(Spawn::RECORD),
        Item::Record(ClaimLayer::RECORD),
        Item::Handle(collect::<Claim<NullTexture>>()),
        Item::Record(ErrorEvent::RECORD),
        Item::Record(ReportError::RECORD),
    ];
    // The tables the `lovr.lun*` callbacks are called with are exported from
    // the module; the callbacks do not declare them, because a definitions
    // file declares globals and cannot name a module's types. The handles a
    // payload carries are `Window` and `Claim`, which the definitions file
    // alone declares. `docs/dev/lua-api.md` records what that means for a
    // configuration.
    items.extend(payload_records().into_iter().map(Item::Record));
    items
}

const HEADER: &str = "\
-- The `lunette` module as the type checker sees it.
--
-- Generated by `cargo run -p lunette-generate-definitions` from the Rust
-- registration surface. A change belongs beside the registration, in
-- `crates/lunette/src/lua/`, not here.
--
-- At runtime the module is the table the host registers in `package.preload`,
-- so nothing below is executed. It exists because Luau resolves a require to a
-- file on disk, and a definitions file can only declare globals.
";

const FOOTER: &str = "return (nil :: any) :: Lunette\n";

/// Where a comment wraps, at the width the prose in the tree already uses.
const COLUMNS: usize = 80;
const STYLUA_COLUMNS: usize = 120;

/// Renders one `export type`, named by the type the Rust side declares itself
/// as.
fn render_alias(out: &mut String, alias: &AliasSpec, handles: &[&Handle]) {
    out.push('\n');
    render_doc(out, alias.doc, "");
    let name = (alias.name)();
    let definition = (alias.definition)(handles);
    let line = format!("export type {name} = {definition}");
    match &definition {
        // StyLua breaks a union too wide for one line before each member.
        Type::Union(members) if line.len() > STYLUA_COLUMNS => {
            let _ = writeln!(out, "export type {name} =");
            for (index, member) in members.iter().enumerate() {
                let separator = if index == 0 { "" } else { "| " };
                let _ = writeln!(out, "  {separator}{member}");
            }
        }
        _ => {
            let _ = writeln!(out, "{line}");
        }
    }
}

fn render_handle(out: &mut String, handle: &Handle) {
    let name = handle.spec.name;
    let discriminated = !handle.spec.variants.is_empty();

    out.push('\n');
    render_doc(out, handle.spec.doc, "");
    if discriminated {
        let _ = writeln!(out, "type {name}Fields = {{");
    } else {
        let _ = writeln!(out, "export type {name} = {{");
    }

    for field in &handle.fields {
        if let PropertyType::Same(ty) = &field.ty {
            render_doc(out, field.doc, "  ");
            let _ = writeln!(out, "  read {}: {ty},", field.name);
        }
    }
    for method in &handle.methods {
        render_doc(out, method.doc, "  ");
        let _ = writeln!(out, "  read {}: {},", method.name, method.ty);
    }
    out.push_str("}\n");

    for (arm, variant) in handle.spec.variants.iter().enumerate() {
        let fields: Vec<String> = handle
            .fields
            .iter()
            .filter_map(|field| arm_type(field, arm))
            .collect();
        let _ = writeln!(out, "\ntype {variant} = {{ {} }}", fields.join(", "));
    }

    if discriminated {
        let arms = handle.spec.variants.join(" | ");
        let _ = writeln!(out, "\nexport type {name} = {name}Fields & ({arms})");
    }
}

/// The type one arm assigns to a field whose arms disagree.
fn arm_type(field: &Property, arm: usize) -> Option<String> {
    match &field.ty {
        PropertyType::Same(_) => None,
        PropertyType::PerVariant(types) => Some(format!("read {}: {}", field.name, types[arm])),
    }
}

fn render_record(out: &mut String, record: &Record) {
    out.push('\n');
    render_doc(out, record.doc, "");
    let _ = writeln!(out, "export type {} = {{", record.name);
    for field in record.fields {
        render_doc(out, field.doc, "  ");
        let _ = writeln!(out, "  {}: {},", field.name, (field.ty)());
    }
    out.push_str("}\n");
}

fn render_module(out: &mut String) {
    out.push_str("\nexport type Lunette = {\n");
    for function in module_functions::<NullTexture>()
        .into_iter()
        .chain(subscription_functions::<NullTexture>())
    {
        render_doc(out, function.spec.doc, "  ");
        let _ = writeln!(out, "  read {}: {},", function.spec.name, (function.ty)());
    }
    render_doc(out, "The native plugin facade.", "  ");
    let _ = writeln!(out, "  read plugin: {API_TYPE_NAME},");
    out.push_str("}\n");
}

/// Writes prose as Lua comments at `indent`, wrapped to [`COLUMNS`].
///
/// A declaration states its prose as one line. The wrapping happens at render
/// time, so reflowing the file is not an edit to every declaration in it.
fn render_doc(out: &mut String, doc: &str, indent: &str) {
    let width = COLUMNS.saturating_sub(indent.len() + "-- ".len());
    let mut line = String::new();

    for word in doc.split_whitespace() {
        if !line.is_empty() && line.len() + 1 + word.len() > width {
            let _ = writeln!(out, "{indent}-- {line}");
            line.clear();
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }

    if !line.is_empty() {
        let _ = writeln!(out, "{indent}-- {line}");
    }
}

#[cfg(test)]
mod tests {
    use super::render;

    #[test]
    fn long_plugin_function_type_wraps_at_outer_arguments() {
        let output = render();

        assert!(output.contains(
            "  read define: (\n    required: unknown,\n    provided: unknown,\n    init: (context: PluginContext, config: unknown) -> unknown,\n    name: string?\n  ) -> PluginDefinition,\n"
        ));
    }
}
