//! Native mlua attachment bridge for the plugin contract registry and lifecycle graph.
//!
//! The attachment owns only Lua-state data. It does not retain a compositor
//! session. A state owns one contract epoch and can have several independent
//! runtime graphs. Definitions and contract tokens are shared by those graphs;
//! instances, services, effects, and configuration values remain runtime-local.

mod lifecycle;
mod types;

use std::{cell::RefCell, collections::BTreeMap, rc::Rc};

use mlua::{Lua, Table, UserDataRef, Value};

pub use self::types::{
    PluginAcquire, PluginContext, PluginContractToken, PluginDefinition, PluginEffect, PluginInit,
    PluginInstance, PluginRuntime, Unknown,
};
use self::{
    lifecycle::{
        check_owner, child, close_runtime, context_active, dispose_effect, drain_runtime, effect,
        request_instance, services, use_definition,
    },
    types::{
        ActivationAuthority, AttachmentHost, Command, DeclarationField, DefinitionData,
        InstanceState, RuntimeState,
    },
};
use crate::plugin::{
    contracts::{ContractError, ContractName, ContractRegistry},
    graph::{ContractKey, Graph, GraphError},
};

/// A compatibility installer for a native attachment function.
#[derive(Clone, Copy)]
pub struct NativeDescriptor {
    /// The Lua field name.
    pub name: &'static str,
    /// Installs the corresponding native function into a module table.
    pub install: fn(&Lua, &Table) -> mlua::Result<()>,
}

/// Returns the native functions belonging to the plugin attachment surface.
#[must_use]
pub fn native_descriptors() -> &'static [NativeDescriptor] {
    static DESCRIPTORS: [NativeDescriptor; 4] = [
        NativeDescriptor {
            name: "contract",
            install: install_contract,
        },
        NativeDescriptor {
            name: "bind",
            install: install_bind,
        },
        NativeDescriptor {
            name: "define",
            install: install_define,
        },
        NativeDescriptor {
            name: "runtime",
            install: install_runtime,
        },
    ];
    &DESCRIPTORS
}

/// Installs the state-bound contract registry if it is not already present.
///
/// The coordinator owns the module table and calls the descriptor installers
/// separately. Calling this more than once is harmless and does not replace the
/// current contract epoch.
pub fn install(lua: &Lua) -> mlua::Result<()> {
    if lua.app_data_ref::<Rc<RefCell<AttachmentHost>>>().is_none() {
        lua.set_app_data(Rc::new(RefCell::new(AttachmentHost::new())));
    }
    Ok(())
}

/// Shuts down every runtime attached to this Lua state.
///
/// Cleanup errors are returned as strings because shutdown is a recovery path:
/// every runtime is attempted, every cleanup callback is attempted, and the
/// caller can log all failures without abandoning later runtimes.
#[must_use]
pub fn shutdown_all(lua: &Lua) -> Vec<String> {
    let Some(host) = host_inner(lua) else {
        return Vec::new();
    };
    if callback_active(lua) {
        return vec![String::from(
            "plugin shutdown: cannot shut down during a plugin callback",
        )];
    }

    let runtimes = {
        let host = host.borrow();
        host.runtimes.clone()
    };
    let mut errors = Vec::new();
    for runtime in &runtimes {
        if let Err(error) = close_runtime(lua, runtime) {
            errors.push(error.to_string());
        }
        let mut state = runtime.borrow_mut();
        errors.append(&mut state.errors);
    }
    lifecycle::clear_host_references(&host);
    {
        let mut state = host.borrow_mut();
        state.runtimes.clear();
        state.registry = ContractRegistry::new();
        state.contract_keys.clear();
    }
    errors
}

/// Retires the current contract epoch after shutting down its runtimes.
pub fn reset_epoch(lua: &Lua) -> mlua::Result<()> {
    let errors = shutdown_all(lua);
    if !errors.is_empty() {
        return Err(mlua::Error::runtime(format!(
            "plugin reset: shutdown failed: {}",
            errors.join("; ")
        )));
    }
    install(lua)?;
    let host = require_host(lua)?;
    host.borrow()
        .registry
        .retire_epoch()
        .map_err(contract_error)
}

/// Reports whether execution is currently inside a plugin callback.
#[must_use]
pub fn callback_active(lua: &Lua) -> bool {
    host_inner(lua).is_some_and(|host| host.borrow().callback_depth != 0)
}

/// Declares a qualified contract identity in this state's current epoch.
pub fn contract(lua: &Lua, (name, schema): (String, u64)) -> mlua::Result<PluginContractToken> {
    let host = require_host(lua)?;
    let contract_name = ContractName::from_qualified(name).map_err(contract_error)?;
    let key_name = contract_name.qualified();
    let schema_u32 = u32::try_from(schema)
        .map_err(|_| mlua::Error::runtime("plugin contract: schema does not fit the graph"))?;
    let registry = host.borrow().registry.clone();
    let token = registry
        .declare(contract_name, schema)
        .map_err(contract_error)?;
    let id = registry.validate_token(&token).map_err(contract_error)?;
    host.borrow_mut()
        .contract_keys
        .insert(id, ContractKey::new(key_name, schema_u32));
    Ok(token)
}

/// Binds one erased native wrapper to one contract token.
pub fn bind(
    lua: &Lua,
    token: UserDataRef<PluginContractToken>,
    wrapper: Unknown,
) -> mlua::Result<()> {
    let host = require_host(lua)?;
    let table = match wrapper.0 {
        Value::Table(table) => table,
        other => {
            return Err(mlua::Error::runtime(format!(
                "plugin contract: wrapper must be a table, not a {}",
                other.type_name()
            )));
        }
    };
    let registry = host.borrow().registry.clone();
    registry.bind_token(&token, &table).map_err(contract_error)
}

/// Defines a reusable plugin from exact required/provided token records.
pub fn define(
    lua: &Lua,
    (required, provided, init): (Unknown, Unknown, PluginInit),
) -> mlua::Result<PluginDefinition> {
    let host = require_host(lua)?;
    let (required, provided) = {
        let host_ref = host.borrow();
        let required = host_ref
            .registry
            .validate_declaration(required.0)
            .map_err(contract_error)?;
        let provided = host_ref
            .registry
            .validate_declaration(provided.0)
            .map_err(contract_error)?;
        (
            fields_for_declaration(&host_ref, &required)?,
            fields_for_declaration(&host_ref, &provided)?,
        )
    };
    let definition = Rc::new(DefinitionData {
        host: Rc::downgrade(&host),
        required,
        provided,
        init: RefCell::new(Some(init.0)),
    });
    host.borrow_mut()
        .definitions
        .push(Rc::downgrade(&definition));
    Ok(PluginDefinition { data: definition })
}

/// Creates an independent runtime in the current Lua state.
pub fn runtime(lua: &Lua, _: ()) -> mlua::Result<PluginRuntime> {
    let host = require_host(lua)?;
    let state = Rc::new(RefCell::new(RuntimeState {
        host: Rc::downgrade(&host),
        graph: Graph::new(64),
        instances: BTreeMap::new(),
        queue: std::collections::VecDeque::new(),
        draining: false,
        closed: false,
        closing: false,
        errors: Vec::new(),
    }));
    host.borrow_mut().runtimes.push(Rc::clone(&state));
    Ok(PluginRuntime { state })
}

fn install_contract(lua: &Lua, module: &Table) -> mlua::Result<()> {
    module.set("contract", lua.create_function(contract)?)
}

fn install_bind(lua: &Lua, module: &Table) -> mlua::Result<()> {
    module.set(
        "bind",
        lua.create_function(
            |lua, (token, wrapper): (UserDataRef<PluginContractToken>, Unknown)| {
                bind(lua, token, wrapper)
            },
        )?,
    )
}

fn install_define(lua: &Lua, module: &Table) -> mlua::Result<()> {
    module.set("define", lua.create_function(define)?)
}

fn install_runtime(lua: &Lua, module: &Table) -> mlua::Result<()> {
    module.set("runtime", lua.create_function(runtime)?)
}

fn host_inner(lua: &Lua) -> Option<Rc<RefCell<AttachmentHost>>> {
    lua.app_data_ref::<Rc<RefCell<AttachmentHost>>>()
        .map(|host| Rc::clone(&host))
}

fn require_host(lua: &Lua) -> mlua::Result<Rc<RefCell<AttachmentHost>>> {
    host_inner(lua).ok_or_else(|| mlua::Error::runtime("plugin attachment: not installed"))
}

fn contract_error(error: ContractError) -> mlua::Error {
    mlua::Error::runtime(error.to_string())
}

fn graph_error(error: GraphError) -> mlua::Error {
    mlua::Error::runtime(error.to_string())
}

fn fields_for_declaration(
    host: &AttachmentHost,
    declaration: &crate::plugin::contracts::ValidatedDeclaration,
) -> mlua::Result<Vec<DeclarationField>> {
    declaration
        .iter()
        .map(|(field, id)| {
            let key = host.contract_keys.get(&id).cloned().ok_or_else(|| {
                mlua::Error::runtime("plugin contract: token has no graph identity")
            })?;
            Ok(DeclarationField {
                field: field.to_owned(),
                key,
            })
        })
        .collect()
}
