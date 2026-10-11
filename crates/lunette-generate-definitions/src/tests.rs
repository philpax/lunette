//! Exercises the vendored emitter with in-memory metadata and output.

use mlua::{Function, Lua, Table};

#[test]
fn table_schemas_keep_optional_fields_read_write_splits_and_empty_tables() -> mlua::Result<()> {
    let nested = generate(
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
    assert!(nested.contains("read required: number"), "{nested}");
    assert!(nested.contains("read defaulted: boolean?"), "{nested}");
    assert!(nested.contains("read named: string?"), "{nested}");
    assert!(
        nested.contains(
            "read nested: { read items: { read [number]: string | number }?, read callback: (() -> ())? }"
        ),
        "{nested}"
    );

    let mutable = generate(
        r#"{ type = 'table', mutable = true, alias = 'FixtureConfiguration', table = {
            { name = 'enabled', type = 'boolean', writeType = 'boolean | number' },
            { name = 'window', type = 'table?', readType = 'table', table = {
                { name = 'title', type = 'string' }
            } },
            { name = 'mode', type = 'string?', values = { 'none', 'natural' } }
        } }"#,
    )?;
    assert!(
        mutable.contains(
            "export type FixtureConfiguration = { read enabled: boolean, write enabled: boolean | number"
        ),
        "{mutable}"
    );
    assert!(
        mutable.contains("read window: { title: string }, write window: { title: string }?"),
        "{mutable}"
    );
    assert!(
        mutable.contains("mode: \"none\" | \"natural\" | nil"),
        "{mutable}"
    );
    assert!(
        mutable.contains("fixture: ((t: FixtureConfiguration) -> ())?"),
        "{mutable}"
    );

    let schema_less = generate("{ type = 'table' }")?;
    assert!(
        schema_less.contains("fixture: ((t: {}) -> ())?"),
        "{schema_less}"
    );
    assert!(!schema_less.contains("fixture: ((t: any)"), "{schema_less}");
    Ok(())
}

/// An argument array is read-only, so Luau compares it covariantly and a
/// caller's narrower array fits. A returned array stays read-write.
#[test]
fn argument_arrays_are_read_only_and_optional_returns_keep_the_result_required() -> mlua::Result<()>
{
    let arrays = generate_signature("{ type = '{{number}}' }", "{ type = '{string}' }")?;
    assert!(
        arrays
            .contains("fixture: ((t: { read [number]: { read [number]: number } }) -> {string})?"),
        "{arrays}"
    );

    let optional = generate_signature(
        "{ type = 'string' }",
        "{ type = 'function?', arguments = {}, returns = { { type = '*' } } }",
    )?;
    assert!(
        optional.contains("fixture: ((t: string) -> (() -> any)?)?"),
        "{optional}"
    );
    assert!(!optional.contains("() -> any?"), "{optional}");
    Ok(())
}

#[test]
fn keyed_return_tables_preserve_their_domain_key_and_fields() -> mlua::Result<()> {
    let timing = generate_signature(
        "{ type = 'number' }",
        "{ type = 'table?', keyType = 'Pass', table = { { name = '[].duration', type = 'number' }, { name = '[].start', type = 'number?' } } }",
    )?;
    assert!(
        timing.contains("-> { [Pass]: { read duration: number, read start: number? } }?"),
        "{timing}"
    );
    for invalid in [
        "{ type = 'table', keyType = 'Pass' }",
        "{ type = 'table', keyType = 'Pass', table = { { name = 'duration', type = 'number' } } }",
    ] {
        assert!(
            generate_signature("{ type = 'number' }", invalid).is_err(),
            "{invalid}"
        );
    }
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
