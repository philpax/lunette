//! Registers the native plugin facade and generates its Luau declarations.
//! Function descriptors define both the runtime table and the `PluginApi` type.

use std::fmt::Write as _;

use lunette_luau::{Arguments, Type, Typed};
use mlua::{FromLuaMulti, Function, IntoLuaMulti, Lua, MaybeSend, Table};

use crate::{
    lua::declarations::{Signature, collect_methods, function_type, render_doc},
    plugin::attachment::{
        self, PluginAuthority, PluginContext, PluginContractToken, PluginDefinition, PluginEffect,
        PluginEffectState, PluginInstance, PluginRuntime, PluginState,
    },
};

pub const API_NAME: &str = "plugin";

pub const API_TYPE_NAME: &str = "PluginApi";

/// A plugin function descriptor that supplies its runtime callback and Luau type.
#[derive(Clone, Copy, Debug)]
pub struct FunctionSpec {
    pub name: &'static str,

    pub parameters: &'static [&'static str],

    pub doc: &'static str,
    callback: NativeFunction,
}

#[derive(Clone, Copy, Debug)]
struct NativeFunction {
    create: fn(&Lua) -> mlua::Result<Function>,
    ty: fn(&[&'static str]) -> Type,
}

macro_rules! native {
    ($callback:path) => {
        NativeFunction {
            create: |lua| lua.create_function($callback),
            ty: |parameters| native_type($callback, parameters),
        }
    };
}

fn native_type<A, R, F>(_: F, names: &[&'static str]) -> Type
where
    A: Arguments + FromLuaMulti,
    R: IntoLuaMulti + Typed,
    F: Fn(&Lua, A) -> mlua::Result<R> + MaybeSend + 'static,
{
    function_type(None, names, &A::luau(), R::luau())
}

/// Returns the plugin functions in facade order.
#[must_use]
pub fn functions() -> &'static [FunctionSpec] {
    &FUNCTIONS
}

/// Installs the nested `lunette.plugin` table from the function descriptors.
pub fn install(lua: &Lua, module: &Table) -> mlua::Result<()> {
    attachment::install(lua);
    let plugin = lua.create_table()?;
    for function in functions() {
        plugin.set(function.name, (function.callback.create)(lua)?)?;
    }

    module.set(API_NAME, plugin)
}

/// Renders the plugin handle and nested-module declarations.
pub(crate) fn render_types(out: &mut String) {
    out.push('\n');
    render_doc(out, "The lifecycle state of a plugin instance.", "");
    let _ = writeln!(
        out,
        "export type {} = {}",
        PluginState::luau(),
        Type::literals(PluginState::NAMES)
    );
    for (name, names) in [
        (PluginAuthority::luau(), PluginAuthority::NAMES),
        (PluginEffectState::luau(), PluginEffectState::NAMES),
    ] {
        let _ = writeln!(out, "export type {name} = {}", Type::literals(names));
    }
    for record in attachment::snapshot_records() {
        out.push('\n');
        render_doc(out, record.doc, "");
        let _ = writeln!(out, "export type {} = {{", record.name);
        for field in record.fields {
            render_doc(out, field.doc, "  ");
            let _ = writeln!(out, "  read {}: {},", field.name, (field.ty)());
        }
        out.push_str("}\n");
    }
    for handle in HANDLES {
        out.push('\n');
        render_doc(out, handle.doc, "");
        let _ = writeln!(out, "export type {} = {{", (handle.name)());
        render_doc(out, BRAND_DOC, "  ");
        let _ = writeln!(out, "  read {}: '{}',", handle.brand, (handle.name)());
        for method in (handle.methods)() {
            render_doc(out, method.doc, "  ");
            let _ = writeln!(out, "  read {}: {},", method.name, method.ty);
        }
        out.push_str("}\n");
    }

    out.push('\n');
    render_doc(out, "The native plugin facade.", "");
    let _ = writeln!(out, "export type {API_TYPE_NAME} = {{");
    for function in functions() {
        render_doc(out, function.doc, "  ");
        let _ = writeln!(
            out,
            "  read {}: {},",
            function.name,
            (function.callback.ty)(function.parameters)
        );
    }
    out.push_str("}\n");
}

const FUNCTIONS: [FunctionSpec; 3] = [
    FunctionSpec {
        name: "contract",
        parameters: &["name", "schema"],
        doc: "Declares a qualified contract identity for the current Lua state epoch.",
        callback: native!(attachment::contract),
    },
    FunctionSpec {
        name: "define",
        parameters: &["required", "provided", "init", "name"],
        doc: "Defines a reusable plugin from required and provided contract records. The optional name labels it in diagnostics; without one, it is named for where its initializer is defined.",
        callback: native!(attachment::define),
    },
    FunctionSpec {
        name: "runtime",
        parameters: &[],
        doc: "Creates an independent plugin runtime in the current Lua state.",
        callback: native!(attachment::runtime),
    },
];

const HANDLES: [HandleSpec; 6] = [
    HandleSpec {
        name: PluginContractToken::luau,
        brand: "__pluginContractToken",
        doc: "An opaque native token naming one contract declaration.",
        methods: no_methods,
    },
    HandleSpec {
        name: PluginDefinition::luau,
        brand: "__pluginDefinition",
        doc: "A reusable plugin definition.",
        methods: no_methods,
    },
    HandleSpec {
        name: PluginRuntime::luau,
        brand: "__pluginRuntime",
        doc: "A runtime-local plugin graph.",
        methods: || collect_methods::<PluginRuntime>(),
    },
    HandleSpec {
        name: PluginInstance::luau,
        brand: "__pluginInstance",
        doc: "A plugin installed in a runtime.",
        methods: || collect_methods::<PluginInstance>(),
    },
    HandleSpec {
        name: PluginContext::luau,
        brand: "__pluginContext",
        doc: "A context bound to one plugin activation.",
        methods: || collect_methods::<PluginContext>(),
    },
    HandleSpec {
        name: PluginEffect::luau,
        brand: "__pluginEffect",
        doc: "A one-shot resource effect.",
        methods: || collect_methods::<PluginEffect>(),
    },
];

/// The singleton string field keeps structural tables from satisfying handle types.
/// Luau rejects casts to types with a `never` field.
const BRAND_DOC: &str =
    "A type brand that makes this handle nominal. The field does not exist at runtime.";

fn no_methods() -> Vec<Signature> {
    Vec::new()
}

#[derive(Clone, Copy, Debug)]
struct HandleSpec {
    name: fn() -> Type,
    /// The name of the phantom field that makes the handle nominal.
    brand: &'static str,
    doc: &'static str,
    methods: fn() -> Vec<Signature>,
}
