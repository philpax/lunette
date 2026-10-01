//! Exercises the vendored emitter with in-memory metadata and output.

use mlua::{Function, Lua, Table};

use super::ALIAS_FILES;

#[test]
fn installed_lua_root_metadata_is_strict_relative_and_excludes_specs() {
    let generated = ALIAS_FILES
        .iter()
        .find(|(path, _, _)| *path == "etc/lunette/installed.luaurc")
        .map(|(_, root, render)| (*root, render(root)));
    assert_eq!(
        generated,
        Some((
            ".",
            "{\n  \"languageMode\": \"strict\",\n  \"aliases\": {\n    \"lunette\": \"./lunette\",\n    \"lunette-plugin\": \"./lunette-plugin\",\n    \"lunette-contracts\": \"./lunette-contracts\",\n    \"lunette-plugins\": \"./lunette-plugins\",\n    \"lunette-desktop\": \"./lunette-desktop\"\n  }\n}\n".to_owned(),
        ))
    );
}

#[test]
fn nested_input_schemas_preserve_optional_fields_arrays_and_functions() -> mlua::Result<()> {
    let generated = generate(
        r#"{ type = 'table?', table = {
            { name = 'required', type = 'number' },
            { name = 'defaulted', type = 'boolean', default = 'false' },
            { name = 'named?', type = 'string' },
            { name = 'nested', type = 'table', table = {
                { name = 'items', type = '{string | number}?' },
                { name = 'callback', type = 'function?' }
            } }
        } }"#,
    )?;
    assert!(generated.contains("read required: number"), "{generated}");
    assert!(
        generated.contains("read defaulted: boolean?"),
        "{generated}"
    );
    assert!(generated.contains("read named: string?"), "{generated}");
    assert!(
        generated.contains(
            "read nested: { read items: { read [number]: string | number }?, read callback: (() -> ())? }"
        ),
        "{generated}"
    );
    Ok(())
}

#[test]
fn mutable_schemas_preserve_read_write_types_and_closed_values() -> mlua::Result<()> {
    let generated = generate(
        r#"{ type = 'table', mutable = true, alias = 'FixtureConfiguration', table = {
            { name = 'enabled', type = 'boolean', writeType = 'boolean | number' },
            { name = 'window', type = 'table?', readType = 'table', table = {
                { name = 'title', type = 'string' }
            } },
            { name = 'mode', type = 'string?', values = { 'none', 'natural' } }
        } }"#,
    )?;
    assert!(generated.contains("export type FixtureConfiguration = { read enabled: boolean, write enabled: boolean | number"), "{generated}");
    assert!(
        generated.contains("read window: { title: string }, write window: { title: string }?"),
        "{generated}"
    );
    assert!(
        generated.contains("mode: \"none\" | \"natural\" | nil"),
        "{generated}"
    );
    assert!(
        generated.contains("fixture: ((t: FixtureConfiguration) -> ())?"),
        "{generated}"
    );
    Ok(())
}

#[test]
fn optional_function_return_does_not_make_the_loop_result_optional() -> mlua::Result<()> {
    let generated = generate_signature(
        "{ type = 'string' }",
        "{ type = 'function?', arguments = {}, returns = { { type = '*' } } }",
    )?;
    assert!(
        generated.contains("fixture: ((t: string) -> (() -> any)?)?"),
        "{generated}"
    );
    assert!(!generated.contains("() -> any?"), "{generated}");
    Ok(())
}

/// An array LÖVR reads from its caller is read-only, so Luau compares it
/// covariantly: a table literal passed to an overloaded function, and a
/// caller's narrower array, both answer it. An array LÖVR answers stays
/// read-write, so a caller can change what it was given.
#[test]
fn argument_arrays_are_read_only_and_returned_arrays_are_not() -> mlua::Result<()> {
    let generated = generate_signature("{ type = '{{number}}' }", "{ type = '{string}' }")?;
    assert!(
        generated
            .contains("fixture: ((t: { read [number]: { read [number]: number } }) -> {string})?"),
        "{generated}"
    );
    Ok(())
}

#[test]
fn schema_less_tables_keep_existing_empty_table_semantics() -> mlua::Result<()> {
    let generated = generate("{ type = 'table' }")?;
    assert!(
        generated.contains("fixture: ((t: {}) -> ())?"),
        "{generated}"
    );
    assert!(!generated.contains("any"), "{generated}");
    Ok(())
}

fn generate(argument: &str) -> mlua::Result<String> {
    generate_signature(argument, "")
}

fn generate_signature(argument: &str, returns: &str) -> mlua::Result<String> {
    let lua = Lua::new();
    lua.load(
        r#"
        lovr = {
            filesystem = { getSource = function() return 'memory' end },
            system = { getOS = function() return 'Linux' end }
        }
        os = { execute = function() end }
        io = { open = function()
            return {
                write = function(_, text) generated = text end,
                close = function() end
            }
        end }
        "#,
    )
    .exec()?;
    let generator: Function = lua
        .load(include_str!(
            "../../../vendor/lovr-docs/api/generators/luau.lua"
        ))
        .eval()?;
    let api: Table = lua
        .load(format!(
            "local argument = {argument}; argument.name = 't'; return {{ modules = {{}}, callbacks = {{ {{ name = 'fixture', variants = {{ {{ arguments = {{ argument }}, returns = {{ {returns} }} }} }} }} }} }}"
        ))
        .eval()?;
    generator.call::<()>(api)?;
    lua.globals().get("generated")
}
