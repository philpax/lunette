//! The native plugin facade and its generated Luau surface. One set of
//! function descriptors drives both the `lunette.plugin` table and the
//! generated `PluginApi` type, so the two cannot diverge.

use std::fmt::Write as _;

use lunette_luau::{Arguments, Parameter, Type, Typed};
use mlua::{FromLuaMulti, IntoLuaMulti, Lua, MaybeSend, Table, UserDataRef};

use crate::{
    lua::declarations::{Signature, collect_methods},
    plugin::attachment::{
        self, DefineArguments, PluginContext, PluginContractToken, PluginDefinition, PluginEffect,
        PluginInstance, PluginRuntime, PluginState, Unknown,
    },
};

/// The name of the nested plugin facade on the native module.
pub const API_NAME: &str = "plugin";
/// The Luau type of the nested plugin facade.
pub const API_TYPE_NAME: &str = "PluginApi";

/// A function in the plugin facade. Its concrete callback is also the source
/// for the generated argument and return types.
#[derive(Clone, Copy, Debug)]
pub struct FunctionSpec {
    pub name: &'static str,
    /// The parameter names used in the generated declaration.
    pub parameters: &'static [&'static str],
    /// The documentation emitted beside the field.
    pub doc: &'static str,
    callback: NativeFunction,
}

#[derive(Clone, Copy, Debug)]
enum NativeFunction {
    Contract(fn(&Lua, (String, u64)) -> mlua::Result<PluginContractToken>),
    Bind(fn(&Lua, UserDataRef<PluginContractToken>, Unknown) -> mlua::Result<()>),
    Define(fn(&Lua, DefineArguments) -> mlua::Result<PluginDefinition>),
    Runtime(fn(&Lua, ()) -> mlua::Result<PluginRuntime>),
}

impl NativeFunction {
    fn install(self, lua: &Lua, module: &Table, name: &'static str) -> mlua::Result<()> {
        match self {
            Self::Contract(function) => module.set(name, lua.create_function(function)?),
            Self::Bind(function) => module.set(
                name,
                lua.create_function(move |lua, (token, wrapper)| function(lua, token, wrapper))?,
            ),
            Self::Define(function) => module.set(name, lua.create_function(function)?),
            Self::Runtime(function) => module.set(name, lua.create_function(function)?),
        }
    }

    fn ty(self, parameters: &[&'static str]) -> Type {
        match self {
            Self::Contract(function) => native_type(function, parameters),
            Self::Bind(function) => native_type(
                move |lua, (token, wrapper)| function(lua, token, wrapper),
                parameters,
            ),
            Self::Define(function) => native_type(function, parameters),
            Self::Runtime(function) => native_type(function, parameters),
        }
    }
}

fn native_type<A, R, F>(_: F, names: &[&'static str]) -> Type
where
    A: Arguments + FromLuaMulti,
    R: IntoLuaMulti + Typed,
    F: Fn(&Lua, A) -> mlua::Result<R> + MaybeSend + 'static,
{
    Type::Function {
        receiver: None,
        parameters: names
            .iter()
            .copied()
            .zip(A::luau())
            .map(|(name, ty)| Parameter { name, ty })
            .collect(),
        returns: Box::new(R::luau()),
    }
}

/// Returns the plugin functions in facade order.
#[must_use]
pub fn functions() -> &'static [FunctionSpec] {
    &FUNCTIONS
}

/// Installs the state-local attachment. It is separate from [`install`]
/// because reload cleanup retires its epoch even when no configuration has
/// required `@lunette`.
pub fn install_attachment(lua: &Lua) -> mlua::Result<()> {
    Ok(attachment::install(lua)?)
}

/// Installs the nested `lunette.plugin` table from the function descriptors.
pub fn install(lua: &Lua, module: &Table) -> mlua::Result<()> {
    attachment::install(lua).map_err(mlua::Error::from)?;
    let plugin = lua.create_table()?;
    for function in functions() {
        function.callback.install(lua, &plugin, function.name)?;
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
            function.callback.ty(function.parameters)
        );
    }
    out.push_str("}\n");
}

const FUNCTIONS: [FunctionSpec; 4] = [
    FunctionSpec {
        name: "contract",
        parameters: &["name", "schema"],
        doc: "Declares a qualified contract identity for the current Lua state epoch.",
        callback: NativeFunction::Contract(attachment::contract),
    },
    FunctionSpec {
        name: "bind",
        parameters: &["token", "wrapper"],
        doc: "Binds one erased native wrapper to a contract token.",
        callback: NativeFunction::Bind(attachment::bind),
    },
    FunctionSpec {
        name: "define",
        parameters: &["required", "provided", "init", "name"],
        doc: "Defines a reusable plugin from required and provided contract records. The optional name labels it in diagnostics; without one, it is named for where its initializer is defined.",
        callback: NativeFunction::Define(attachment::define),
    },
    FunctionSpec {
        name: "runtime",
        parameters: &[],
        doc: "Creates an independent plugin runtime in the current Lua state.",
        callback: NativeFunction::Runtime(attachment::runtime),
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

/// Explains the phantom field every handle declares.
///
/// The field makes the handle type nominal, so a structural table cannot
/// satisfy it. Its type is a singleton string rather than `never`, because
/// Luau treats a table with a `never` property as uninhabited and rejects
/// casts to any type containing it.
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

/// Writes prose using the same width as the main declaration renderer.
fn render_doc(out: &mut String, doc: &str, indent: &str) {
    let width = 80usize.saturating_sub(indent.len() + 3);
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
    #[test]
    fn plugin_types_are_rendered_as_nested_api() {
        let output = crate::lua::declarations::render();
        assert!(output.contains("export type PluginRuntime"));
        assert!(output.contains("read plugin: PluginApi"));
    }

    #[test]
    fn plugin_handles_are_nominal() {
        let output = crate::lua::declarations::render();
        for (handle, brand) in [
            ("PluginContractToken", "__pluginContractToken"),
            ("PluginDefinition", "__pluginDefinition"),
            ("PluginRuntime", "__pluginRuntime"),
            ("PluginInstance", "__pluginInstance"),
            ("PluginContext", "__pluginContext"),
            ("PluginEffect", "__pluginEffect"),
        ] {
            let declaration = output
                .split(&format!("export type {handle} = {{"))
                .nth(1)
                .and_then(|rest| rest.split("\n}").next())
                .unwrap_or_default();
            assert!(
                declaration.contains(&format!("read {brand}: '{handle}',")),
                "{handle} is not branded: {declaration}"
            );
        }
    }
}
