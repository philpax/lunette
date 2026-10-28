//! Exercises the vendored emitter with in-memory metadata and output.

use mlua::{Function, Lua, Table, Value};

use super::{
    CANVAS_METADATA, DRAW_METADATA, GRAPHICS_METHOD_METADATA, extend_canvas_metadata,
    extend_draw_metadata, extend_graphics_method_metadata,
};

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

#[test]
fn draw_callback_adds_optional_preparation_passes_only_for_lunette() -> mlua::Result<()> {
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
    let metadata: Value = lua
        .load(include_str!(
            "../../../vendor/lovr-docs/api/lovr/callbacks/draw.lua"
        ))
        .eval()?;

    let untouched = extend_draw_metadata(&lua, "lovr/callbacks/mirror", metadata.clone())?;
    let Value::Table(untouched) = untouched else {
        return Err(mlua::Error::RuntimeError(
            "draw callback metadata is not a table".to_owned(),
        ));
    };
    let untouched_returns: Table = untouched.get("returns")?;
    assert!(untouched_returns.get::<Value>("preparations")?.is_nil());

    let Value::Table(metadata) = extend_draw_metadata(&lua, DRAW_METADATA, metadata)? else {
        return Err(mlua::Error::RuntimeError(
            "draw callback metadata is not a table".to_owned(),
        ));
    };
    let arguments: Table = metadata.get("arguments")?;
    let argument: Table = arguments.get("pass")?;
    argument.set("name", "pass")?;
    let returns: Table = metadata.get("returns")?;
    let skip: Table = returns.get("skip")?;
    skip.set("name", "skip")?;
    let preparations: Table = returns.get("preparations")?;
    preparations.set("name", "preparations")?;
    let variant: Table = metadata.get::<Table>("variants")?.raw_get(1)?;
    let variant_returns: Table = variant.get("returns")?;
    let mut resolved_returns = Vec::new();
    for name in variant_returns.sequence_values::<String>() {
        resolved_returns.push(returns.get::<Table>(name?)?);
    }
    variant.set("arguments", lua.create_sequence_from([argument])?)?;
    variant.set("returns", lua.create_sequence_from(resolved_returns)?)?;
    metadata.set("name", "draw")?;

    let api = lua.create_table()?;
    api.set("modules", lua.create_table()?)?;
    api.set("callbacks", lua.create_sequence_from([metadata])?)?;
    generator.call::<()>(api)?;
    let generated: String = lua.globals().get("generated")?;
    assert!(
        generated.contains("draw: ((pass: Pass) -> (boolean?, {Pass}?))?"),
        "{generated}"
    );
    Ok(())
}

#[test]
fn canvas_metadata_declares_runtime_texture_and_depth_shapes() -> mlua::Result<()> {
    for (name, source, is_method) in [
        (
            CANVAS_METADATA[0],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/newPass.lua"),
            false,
        ),
        (
            CANVAS_METADATA[1],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/Pass/setCanvas.lua"),
            true,
        ),
    ] {
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
        let Value::Table(metadata) = lua.load(source).eval()? else {
            return Err(mlua::Error::RuntimeError(format!(
                "{name} vendor metadata is not a table"
            )));
        };
        let arguments: Table = metadata.get("arguments")?;
        for pair in arguments.clone().pairs::<String, Table>() {
            let (argument_name, argument) = pair?;
            argument.set("name", argument_name)?;
        }
        let returns: Table = metadata.get("returns")?;
        for pair in returns.clone().pairs::<String, Table>() {
            let (return_name, value) = pair?;
            value.set("name", return_name)?;
        }
        let variants: Table = metadata.get("variants")?;
        for variant in variants.sequence_values::<Table>() {
            let variant = variant?;
            for field in ["arguments", "returns"] {
                let names: Table = variant.get(field)?;
                let resolved = names
                    .sequence_values::<String>()
                    .map(|name| {
                        let name = name?;
                        let values = if field == "arguments" {
                            &arguments
                        } else {
                            &returns
                        };
                        values.get::<Table>(name)
                    })
                    .collect::<mlua::Result<Vec<_>>>()?;
                variant.set(field, lua.create_sequence_from(resolved)?)?;
            }
        }
        metadata.set("name", if is_method { "setCanvas" } else { "newPass" })?;
        let Value::Table(metadata) = extend_canvas_metadata(&lua, name, Value::Table(metadata))?
        else {
            return Err(mlua::Error::RuntimeError(format!(
                "{name} local metadata is not a table"
            )));
        };

        let module = lua.create_table()?;
        module.set("name", if is_method { "graphics" } else { "lovr" })?;
        module.set("enums", lua.create_table()?)?;
        module.set("functions", lua.create_table()?)?;
        module.set("objects", lua.create_table()?)?;
        if is_method {
            let object = lua.create_table()?;
            object.set("name", "Pass")?;
            object.set("methods", lua.create_sequence_from([metadata])?)?;
            module.set("objects", lua.create_sequence_from([object])?)?;
        } else {
            module.set("functions", lua.create_sequence_from([metadata])?)?;
        }
        let api = lua.create_table()?;
        api.set("modules", lua.create_sequence_from([module])?)?;
        api.set("callbacks", lua.create_table()?)?;
        generator.call::<()>(api)?;
        let generated: String = lua.globals().get("generated")?;

        assert!(
            generated.contains("read texture: Texture?"),
            "{name} did not generate the optional named color texture:\n{generated}"
        );
        assert!(
            generated.contains(
                "read depth: Texture | TextureFormat | boolean | { read texture: Texture, read resolve: Texture? }"
            ),
            "{name} did not generate the runtime depth shape:\n{generated}"
        );
        assert!(
            generated.contains("read samples: number?"),
            "{name} did not generate the optional sample count:\n{generated}"
        );
    }
    Ok(())
}

#[test]
fn graphics_method_overrides_preserve_real_variants_and_correct_declarations() -> mlua::Result<()> {
    for (name, source, method_name) in [
        (
            GRAPHICS_METHOD_METADATA[0],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/Pass/getCanvas.lua"),
            "getCanvas",
        ),
        (
            GRAPHICS_METHOD_METADATA[1],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/Pass/mesh.lua"),
            "mesh",
        ),
    ] {
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
        let Value::Table(metadata) = lua.load(source).eval()? else {
            return Err(mlua::Error::RuntimeError(format!(
                "{name} vendor metadata is not a table"
            )));
        };
        metadata.set("name", method_name)?;
        let Value::Table(metadata) =
            extend_graphics_method_metadata(&lua, name, Value::Table(metadata))?
        else {
            return Err(mlua::Error::RuntimeError(format!(
                "{name} local metadata is not a table"
            )));
        };
        let arguments: Table = metadata.get("arguments")?;
        for pair in arguments.clone().pairs::<String, Table>() {
            let (argument_name, argument) = pair?;
            argument.set("name", argument_name)?;
        }
        let returns: Table = metadata.get("returns")?;
        for pair in returns.clone().pairs::<String, Table>() {
            let (return_name, value) = pair?;
            value.set("name", return_name)?;
        }
        let variants: Table = metadata.get("variants")?;
        for variant in variants.sequence_values::<Table>() {
            let variant = variant?;
            for field in ["arguments", "returns"] {
                let names: Table = variant.get(field)?;
                let resolved = names
                    .sequence_values::<String>()
                    .map(|name| {
                        let name = name?;
                        let values = if field == "arguments" {
                            &arguments
                        } else {
                            &returns
                        };
                        values.get::<Table>(name)
                    })
                    .collect::<mlua::Result<Vec<_>>>()?;
                variant.set(field, lua.create_sequence_from(resolved)?)?;
            }
        }

        let method = metadata;
        let object = lua.create_table()?;
        object.set("name", "Pass")?;
        object.set("methods", lua.create_sequence_from([method])?)?;
        let module = lua.create_table()?;
        module.set("name", "graphics")?;
        module.set("enums", lua.create_table()?)?;
        module.set("functions", lua.create_table()?)?;
        module.set("objects", lua.create_sequence_from([object])?)?;
        let api = lua.create_table()?;
        api.set("modules", lua.create_sequence_from([module])?)?;
        api.set("callbacks", lua.create_table()?)?;
        generator.call::<()>(api)?;
        let generated: String = lua.globals().get("generated")?;

        if method_name == "getCanvas" {
            assert_eq!(
                generated.matches("function getCanvas(self)").count(),
                1,
                "{generated}"
            );
            assert!(
                generated.contains(
                    "function getCanvas(self): { read depth: any, read samples: number }?"
                ),
                "{generated}"
            );
        } else {
            assert!(
                generated.contains(
                    "function mesh(self, vertexCount: number, x: number?, y: number?, z: number?"
                ),
                "numeric-count mesh overload missing:\n{generated}"
            );
            assert!(
                generated.contains("function mesh(self, vertices: Buffer?, x: number?"),
                "existing Buffer mesh overload missing:\n{generated}"
            );
        }
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
