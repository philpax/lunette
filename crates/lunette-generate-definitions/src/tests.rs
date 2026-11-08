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
    let lua = emitter()?;
    let metadata: Table = lua
        .load(include_str!(
            "../../../vendor/lovr-docs/api/lovr/callbacks/draw.lua"
        ))
        .eval()?;
    let untouched: Table = lua.unpack(extend_draw_metadata(
        &lua,
        "lovr/callbacks/mirror",
        Value::Table(metadata.clone()),
    )?)?;
    assert!(
        untouched
            .get::<Table>("returns")?
            .get::<Value>("preparations")?
            .is_nil()
    );
    let generated = emit_metadata(&lua, DRAW_METADATA, metadata)?;
    assert_contains(
        &generated,
        &["draw: ((pass: Pass) -> (boolean?, {Pass}?))?"],
    );
    Ok(())
}

#[test]
fn canvas_metadata_declares_runtime_texture_and_depth_shapes() -> mlua::Result<()> {
    for (name, source) in [
        (
            CANVAS_METADATA[0],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/newPass.lua"),
        ),
        (
            CANVAS_METADATA[1],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/Pass/setCanvas.lua"),
        ),
    ] {
        let lua = emitter()?;
        let generated = emit_metadata(&lua, name, lua.load(source).eval()?)?;
        assert_contains(
            &generated,
            &[
                "read texture: Texture?",
                "read depth: Texture | TextureFormat | boolean | { read texture: Texture, read resolve: Texture? }",
                "read samples: number?",
            ],
        );
    }
    Ok(())
}

#[test]
fn graphics_method_overrides_preserve_real_variants_and_correct_declarations() -> mlua::Result<()> {
    for (name, source, expected) in [
        (
            GRAPHICS_METHOD_METADATA[0],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/Pass/getCanvas.lua"),
            &["function getCanvas(self): { read depth: any, read samples: number }?"][..],
        ),
        (
            GRAPHICS_METHOD_METADATA[1],
            include_str!("../../../vendor/lovr-docs/api/lovr/graphics/Pass/mesh.lua"),
            &[
                "function mesh(self, vertexCount: number, x: number?, y: number?, z: number?",
                "function mesh(self, vertices: Buffer?, x: number?",
            ][..],
        ),
    ] {
        let lua = emitter()?;
        let generated = emit_metadata(&lua, name, lua.load(source).eval()?)?;
        assert_contains(&generated, expected);
        if name == GRAPHICS_METHOD_METADATA[0] {
            assert_eq!(
                generated.matches("function getCanvas(self)").count(),
                1,
                "{generated}"
            );
        }
    }
    Ok(())
}

fn assert_contains(generated: &str, expected: &[&str]) {
    for text in expected {
        assert!(generated.contains(text), "missing {text}:\n{generated}");
    }
}

fn generate(argument: &str) -> mlua::Result<String> {
    generate_signature(argument, "")
}

fn generate_signature(argument: &str, returns: &str) -> mlua::Result<String> {
    let lua = emitter()?;
    let api: Table = lua
        .load(format!(
            "local argument = {argument}; argument.name = 't'; return {{ modules = {{}}, callbacks = {{ {{ name = 'fixture', variants = {{ {{ arguments = {{ argument }}, returns = {{ {returns} }} }} }} }} }} }}"
        ))
        .eval()?;
    lua.globals().get::<Function>("emit")?.call::<()>(api)?;
    lua.globals().get("generated")
}

fn emit_metadata(lua: &Lua, name: &str, metadata: Table) -> mlua::Result<String> {
    let metadata = extend_draw_metadata(lua, name, Value::Table(metadata))?;
    let metadata = extend_canvas_metadata(lua, name, metadata)?;
    let metadata: Table = lua.unpack(extend_graphics_method_metadata(lua, name, metadata)?)?;
    lua.globals()
        .get::<Function>("emitMetadata")?
        .call((name, metadata))
}

fn emitter() -> mlua::Result<Lua> {
    let lua = Lua::new();
    lua.load(
        r#"
        lovr = {
            filesystem = { getSource = function() return 'memory' end },
            system = { getOS = function() return 'Linux' end }
        }
        os = { execute = function() end }
        io = { open = function()
            return { write = function(_, text) generated = text end, close = function() end }
        end }
        function emitMetadata(path, metadata)
            metadata.name = path:match('[^/]+$')
            for _, field in ipairs { 'arguments', 'returns' } do
                local values = metadata[field]
                for name, value in pairs(values) do
                    value.name = name
                end
                for _, variant in ipairs(metadata.variants) do
                    local resolved = {}
                    for _, name in ipairs(variant[field]) do
                        resolved[#resolved + 1] = assert(values[name], 'missing metadata: ' .. name)
                    end
                    variant[field] = resolved
                end
            end
            local api = { modules = {}, callbacks = {} }
            if path:find('/callbacks/', 1, true) then
                api.callbacks = { metadata }
            else
                local module = { name = 'graphics', enums = {}, functions = {}, objects = {} }
                if path:find('/Pass/', 1, true) then
                    module.objects = { { name = 'Pass', methods = { metadata } } }
                else
                    module.name = 'lovr'
                    module.functions = { metadata }
                end
                api.modules = { module }
            end
            emit(api)
            return generated
        end
        "#,
    )
    .exec()?;
    let generator: Function = lua
        .load(include_str!(
            "../../../vendor/lovr-docs/api/generators/luau.lua"
        ))
        .eval()?;
    lua.globals().set("emit", generator)?;
    Ok(lua)
}
